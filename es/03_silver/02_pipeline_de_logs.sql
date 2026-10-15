-- =====================================================================
--  MÓDULO 3 · Silver: de los logs brutos de contenedor a logs OpenTelemetry
-- =====================================================================
--  Un único pipeline de parseo, escrito una vez y aplicado a cada línea al ingerir:
--    · detectar la severidad, sea cual sea el lenguaje (nginx, Go, Java, Python)
--    · extraer el trace id y el span id, para enlazar cada log con su traza
--    · guardar el mensaje como Body y convertir los campos útiles en LogAttributes
--    · enmascarar los números de tarjeta (PCI DSS) ANTES de guardar la línea en silver
--  Las vistas materializadas lo ejecutan en cada INSERT en bronze: sin job batch,
--  sin motor de streaming, lo hace la base de datos (regla mv-incremental).
-- =====================================================================


-- PASO 1 · Las reglas de parseo, como funciones SQL
--  Escritas una vez, las usan la vista materializada Y el backfill de más abajo.
--  Severidad: Go escribe {"level":"error"}, Java " ERROR ", Python "ERROR:",
--  nginx solo un código HTTP. Normalizamos a los nombres de OpenTelemetry.
CREATE OR REPLACE FUNCTION pf_log_severity AS (line) ->
    replaceRegexpOne(replaceRegexpOne(upper(multiIf(
        startsWith(line, '{'),                       JSONExtractString(line, 'level'),
        match(line, '^\\d{4}-\\d{2}-\\d{2} '),       extract(line, '^\\S+ \\S+\\s+([A-Z]+) '),
        match(line, '^[A-Z]+:'),                     extract(line, '^([A-Z]+):'),
        match(line, '" \\d{3} '),                    multiIf(extract(line, '" (\\d)\\d{2} ') = '5', 'ERROR', extract(line, '" (\\d)\\d{2} ') = '4', 'WARN', 'INFO'),
        'INFO')), '^WARNING$', 'WARN'), '^CRITICAL$', 'FATAL');

CREATE OR REPLACE FUNCTION pf_severity_number AS (sev) ->
    toUInt8(multiIf(sev = 'TRACE', 1, sev = 'DEBUG', 5, sev = 'INFO', 9, sev = 'WARN', 13, sev = 'ERROR', 17, sev = 'FATAL', 21, 0));

--  Trace id y span id: todos los formatos los escriben como trace_id=..., "trace_id":"..."
CREATE OR REPLACE FUNCTION pf_log_trace_id AS (line) -> extract(line, 'trace_id[=":]+([0-9a-f]{32})');
CREATE OR REPLACE FUNCTION pf_log_span_id  AS (line) -> extract(line, 'span_id[=":]+([0-9a-f]{16})');

--  El mensaje: el campo "msg" en JSON, el texto tras " : " en Java,
--  tras el logger en Python, la línea entera en nginx.
CREATE OR REPLACE FUNCTION pf_log_body AS (line) ->
    multiIf(startsWith(line, '{'), concat(JSONExtractString(line, 'msg'),
                                          if(JSONHas(line, 'error'), concat(': ', JSONExtractString(line, 'error')), '')),
            match(line, '^\\d{4}-\\d{2}-\\d{2} '), substring(line, position(line, ' : ') + 3),   -- Java: el texto tras " : "
            match(line, '^[A-Z]+:[a-z._]+:'), replaceRegexpOne(replaceRegexpOne(line, '^[A-Z]+:[a-z._]+:', ''), ' trace_id=[0-9a-f]+$', ''),
            line);

--  El logger ("scope" de OpenTelemetry): clase Java, logger Python, caller Go
CREATE OR REPLACE FUNCTION pf_log_scope AS (line) ->
    multiIf(startsWith(line, '{'), JSONExtractString(line, 'caller'),
            match(line, '^\\d{4}-\\d{2}-\\d{2} '), extract(line, '\\] ([A-Za-z0-9_.$]+) '),
            match(line, '^[A-Z]+:[a-z._]+:'), extract(line, '^[A-Z]+:([a-z._]+):'),
            'nginx.access');

--  Campos estructurados: todas las claves de una línea JSON, pares clave=valor en el
--  resto, y los campos del access log en nginx. extractKeyValuePairs hace el trabajo k=v.
CREATE OR REPLACE FUNCTION pf_log_attributes AS (line) ->
    multiIf(startsWith(line, '{'),
                mapFilter((k, v) -> k NOT IN ('level', 'ts', 'msg', 'error', 'caller', 'trace_id', 'span_id'),
                          mapFromArrays(arrayMap(x -> x.1, JSONExtractKeysAndValuesRaw(line)),
                                        arrayMap(x -> trim(BOTH '"' FROM x.2), JSONExtractKeysAndValuesRaw(line)))),
            match(line, '" \\d{3} '),
                map('client.address', extract(line, '^(\\S+) '),
                    'http.request.method', extract(line, '"([A-Z]+) '),
                    'url.path', extract(line, '"[A-Z]+ (\\S+) '),
                    'http.response.status_code', extract(line, '" (\\d{3}) '),
                    'http.server.request.duration', extract(line, 'rt=([0-9.]+)'),
                    'user_agent.original', extract(line, '"[^"]*" "([^"]*)"')),
            mapFilter((k, v) -> k NOT IN ('trace_id', 'span_id'), extractKeyValuePairs(pf_log_body(line), '=', ' ,', '"')));

--  PCI DSS: conservar los 6 primeros y los 4 últimos dígitos de todo número de 13 a 19 cifras
CREATE OR REPLACE FUNCTION pf_mask_pan AS (s) -> replaceRegexpAll(s, '\\b([0-9]{6})[0-9]{3,9}([0-9]{4})\\b', '\\1******\\2');

SELECT
    line,
    pf_log_severity(line) AS severity,
    pf_log_trace_id(line) AS trace_id,
    pf_mask_pan(pf_log_body(line)) AS body,
    pf_log_scope(line) AS scope,
    pf_log_attributes(line) AS attributes
FROM
(
    SELECT JSONExtractString(payload, 'log') AS line
    FROM payflow_raw.log_records
    WHERE source = 'fluent-bit' AND received_at BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01'
      AND payload NOT LIKE '%health%'
    LIMIT 1 BY JSONExtractString(payload, 'kubernetes', 'labels', 'app'), pf_log_severity(JSONExtractString(payload, 'log'))
)
FORMAT Vertical;
-- Medido: 14 ms · 8 192 filas leídas (3,9 MB)
-- Qué observar: una línea por servicio y severidad. Entran cinco formatos, sale un solo modelo.


-- PASO 2 · Las vistas materializadas: bronze → silver, en cada insert
--  Una vista materializada es un trigger: cada bloque insertado en payflow_raw.log_records
--  pasa por este SELECT, y el resultado se escribe en otel_logs.
--  Dos vistas, una por fuente, escriben en la misma tabla.
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_container_logs TO payflow_otel.otel_logs AS
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC')   AS Timestamp,
    pf_log_trace_id(line)                                                     AS TraceId,
    pf_log_span_id(line)                                                      AS SpanId,
    toUInt8(TraceId != '')                                                    AS TraceFlags,
    pf_log_severity(line)                                                     AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')                 AS ServiceName,
    pf_mask_pan(pf_log_body(line))                                            AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    map('service.name', ServiceName,
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', ServiceName,
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production')                          AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    pf_log_scope(line)                                                        AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))          AS LogAttributes,
    ''                                                                        AS EventName
FROM payflow_raw.log_records
WHERE source = 'fluent-bit';

--  Los eventos de Kubernetes también se convierten en logs, con el motivo como EventName
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_k8s_events TO payflow_otel.otel_logs AS
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'firstTimestamp'), 9, 'UTC') AS Timestamp,
    ''                                                                        AS TraceId,
    ''                                                                        AS SpanId,
    toUInt8(0)                                                                AS TraceFlags,
    if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO')        AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    'k8s-events'                                                              AS ServiceName,
    JSONExtractString(payload, 'message')                                     AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    map('k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'involvedObject', 'namespace'),
        'k8s.node.name', JSONExtractString(payload, 'source', 'host'),
        'k8s.pod.name', if(JSONExtractString(payload, 'involvedObject', 'kind') = 'Pod', JSONExtractString(payload, 'involvedObject', 'name'), ''),
        'deployment.environment.name', 'production')                          AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    'k8sobjects'                                                              AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    map('k8s.event.reason', JSONExtractString(payload, 'reason'),
        'k8s.event.type', JSONExtractString(payload, 'type'),
        'k8s.object.kind', JSONExtractString(payload, 'involvedObject', 'kind'),
        'k8s.object.name', JSONExtractString(payload, 'involvedObject', 'name'),
        'k8s.event.source', JSONExtractString(payload, 'source', 'component'))    AS LogAttributes,
    JSONExtractString(payload, 'reason')                                      AS EventName
FROM payflow_raw.log_records
WHERE source = 'k8s-events';


-- PASO 3 · Backfill: las vistas solo ven los inserts NUEVOS
--  Bronze ya contiene el día hasta las 20:00, cargado antes de que existieran las vistas.
--  Lo reprocesamos una vez con las mismas reglas, en dos lotes (cada uno de menos de 60 s).
--  El SELECT es el de la vista: escrito con las funciones, se queda corto.
INSERT INTO payflow_otel.otel_logs
    (Timestamp, TraceId, SpanId, TraceFlags, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes)
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC'),
    pf_log_trace_id(line), pf_log_span_id(line), toUInt8(pf_log_trace_id(line) != ''),
    pf_log_severity(line), pf_severity_number(pf_log_severity(line)),
    JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
    pf_mask_pan(pf_log_body(line)),
    map('service.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production'),
    pf_log_scope(line),
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND received_at < '2026-11-27 12:00:00';
-- Medido: 4,86 s · 2,1 M filas leídas (1000,3 MB) · 2,1 M filas escritas · 6,2 GB de memoria

INSERT INTO payflow_otel.otel_logs
    (Timestamp, TraceId, SpanId, TraceFlags, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes)
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC'),
    pf_log_trace_id(line), pf_log_span_id(line), toUInt8(pf_log_trace_id(line) != ''),
    pf_log_severity(line), pf_severity_number(pf_log_severity(line)),
    JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
    pf_mask_pan(pf_log_body(line)),
    map('service.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production'),
    pf_log_scope(line),
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND received_at >= '2026-11-27 12:00:00';
-- Medido: 7,88 s · 3,9 M filas leídas (1,8 GB) · 3,9 M filas escritas · 7,5 GB de memoria

--  Los eventos de Kubernetes: unos cientos de filas
INSERT INTO payflow_otel.otel_logs
    (Timestamp, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes, EventName)
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'firstTimestamp'), 9, 'UTC'),
    if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO'),
    pf_severity_number(if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO')),
    'k8s-events',
    JSONExtractString(payload, 'message'),
    map('k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'involvedObject', 'namespace'),
        'k8s.node.name', JSONExtractString(payload, 'source', 'host'),
        'k8s.pod.name', if(JSONExtractString(payload, 'involvedObject', 'kind') = 'Pod', JSONExtractString(payload, 'involvedObject', 'name'), ''),
        'deployment.environment.name', 'production'),
    'k8sobjects',
    map('k8s.event.reason', JSONExtractString(payload, 'reason'),
        'k8s.event.type', JSONExtractString(payload, 'type'),
        'k8s.object.kind', JSONExtractString(payload, 'involvedObject', 'kind'),
        'k8s.object.name', JSONExtractString(payload, 'involvedObject', 'name'),
        'k8s.event.source', JSONExtractString(payload, 'source', 'component')),
    JSONExtractString(payload, 'reason')
FROM payflow_raw.log_records
WHERE source = 'k8s-events';
-- Medido: 68 ms · 4 334 filas leídas (1,6 MB) · 354 filas escritas


-- PASO 4 · El flujo continuo: llega la noche
--  A partir de ahora no hay nada más que hacer: insertamos la noche en bronze,
--  y las dos vistas llenan silver en la misma transacción.
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 72000, to_s = 86400);   -- de 20:00 a 24:00
-- Medido: 18,7 s · 4,3 M filas leídas (2 GB) · 4,3 M filas escritas · 4,8 GB de memoria

SELECT toStartOfHour(Timestamp) AS hour, count() AS log_records, countIf(SeverityText = 'ERROR') AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 18:00:00'
GROUP BY hour
ORDER BY hour;
-- Medido: 37 ms · 6 M filas leídas (49 MB) · 145,8 MB de memoria
-- Qué observar: las horas de 20:00 a 23:00 las han escrito las vistas, sin ningún job.


-- PASO 5 · ¿Ha funcionado el enmascarado?
SELECT
    countIf(match(Body, '\\b[0-9]{13,19}\\b'))       AS full_pans_in_silver,
    countIf(Body LIKE '%pan=%******%')                AS masked_pans,
    any(if(Body LIKE '%pan=%', Body, NULL))           AS example
FROM payflow_otel.otel_logs
WHERE ServiceName = 'card-network-adapter';
-- Medido: 63 ms · 5,7 M filas leídas (373,3 MB) · 308,8 MB de memoria
-- Qué observar: ningún número de tarjeta completo en silver, todos están enmascarados.


-- PASO 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs) = (SELECT count() FROM payflow_raw.log_records), 'OK', 'KO') AS one_log_per_record,
    if((SELECT countIf(match(Body, '\\b[0-9]{13,19}\\b')) FROM payflow_otel.otel_logs) = 0, 'OK', 'KO')       AS pci_masking,
    if((SELECT countIf(TraceId != '') / count() FROM payflow_otel.otel_logs) > 0.85, 'OK', 'KO')            AS trace_ids,
    if((SELECT max(Timestamp) FROM payflow_otel.otel_logs) > '2026-11-27 23:59:00', 'OK', 'KO')             AS continuous_flow
SETTINGS select_sequential_consistency = 1;
-- Medido: 219 ms · 16,3 M filas leídas (755,6 MB) · 225,8 MB de memoria
