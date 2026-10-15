-- =====================================================================
--  MÓDULO 2 · Recolección (2/4): la pasarela (gateway), en SQL
-- =====================================================================
--  En producción, los agentes envían a un colector con rol de pasarela (el colector
--  de ClickStack), que ejecuta procesadores antes del exportador ClickHouse:
--      filter → transform → k8sattributes → redaction → batch → clickhouse exporter
--  Aquí la pasarela corre dentro de ClickHouse, como sugiere la documentación de
--  ClickHouse para el procesamiento pesado: una tabla de aterrizaje con el motor Null
--  (no guarda nada) y vistas materializadas que procesan cada bloque insertado de
--  camino a las tablas OpenTelemetry. Cada vista hace de uno o varios procesadores:
--    · filter        descarta los health checks del kubelet (ruido, ~4 % del volumen)
--    · transform     parsea 4 formatos de log: severidad, trace id, mensaje, atributos
--    · k8sattributes añade deployment, versión, nodo, zona y equipo a partir del pod
--    · redaction     enmascara los números de tarjeta; con la tabla Null nunca se guarda
--                    una línea en bruto
--    · routing       logs de contenedores y eventos de Kubernetes van por caminos distintos
--    · count         un conector: cuenta cada registro por servicio y minuto, antes del filtro
-- =====================================================================


-- PASO 1 · La tabla de aterrizaje de la pasarela
--  ENGINE = Null: un INSERT pasa por las vistas materializadas asociadas a la tabla y
--  luego los datos se descartan. Nada se guarda dos veces, y las líneas en bruto (con
--  los números de tarjeta) nunca tocan el disco.
CREATE OR REPLACE TABLE payflow_ingest.agent_records
(
    received_at  DateTime64(3, 'UTC'),
    source       LowCardinality(String),       -- filelog (logs de contenedores) o k8sobjects (eventos)
    payload      String
)
ENGINE = Null;


-- PASO 2 · transform: las reglas de parseo, como funciones SQL
--  En el colector es el procesador transform (sentencias OTTL) o los operadores de
--  filelog. ClickHouse recomienda hacer este trabajo en la base de datos: es más rápido
--  y más barato que en el colector, y cambiar una regla no obliga a redesplegar agentes.
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

--  Ids de traza y de span: todos los formatos los escriben como trace_id=..., "trace_id":"..."
CREATE OR REPLACE FUNCTION pf_log_trace_id AS (line) -> extract(line, 'trace_id[=":]+([0-9a-f]{32})');
CREATE OR REPLACE FUNCTION pf_log_span_id  AS (line) -> extract(line, 'span_id[=":]+([0-9a-f]{16})');

--  El mensaje: el campo "msg" en JSON, el texto tras " : " en Java, lo que sigue
--  al logger en Python, la línea entera en nginx.
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
    FROM payflow_sim.raw_records(from_s = 51000, to_s = 51001)
    WHERE source = 'filelog' AND payload NOT LIKE '%health%'
    LIMIT 1 BY splitByChar('/', JSONExtractString(payload, 'log.file.path'))[6], pf_log_severity(JSONExtractString(payload, 'log'))
)
FORMAT Vertical;
-- Medido: 731 ms · 198 filas leídas (8,3 KB)
-- Qué observar: una línea por servicio y severidad. Entran cinco formatos, sale un modelo.

--  k8sattributes: el agente solo conoce la ruta del fichero. La pasarela la parsea y pide el
--  resto al catálogo (diccionarios del módulo 1), igual que el procesador consulta la API
--  de Kubernetes.
CREATE OR REPLACE FUNCTION pf_pod_from_path AS (path) -> splitByChar('_', splitByChar('/', path)[5])[2];

CREATE OR REPLACE FUNCTION pf_k8s_resource AS (path) ->
    map('service.name',               dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)),
        'service.version',            dictGet('payflow_inventory.dict_pod', 'version', pf_pod_from_path(path)),
        'service.team',               dictGet('payflow_inventory.dict_service', 'team', dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path))),
        'k8s.cluster.name',           'payflow-prod-eu',
        'k8s.namespace.name',         splitByChar('_', splitByChar('/', path)[5])[1],
        'k8s.deployment.name',        dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)),
        'k8s.pod.name',               pf_pod_from_path(path),
        'k8s.pod.uid',                splitByChar('_', splitByChar('/', path)[5])[3],
        'k8s.container.name',         splitByChar('/', path)[6],
        'k8s.node.name',              dictGet('payflow_inventory.dict_pod', 'node_name', pf_pod_from_path(path)),
        'cloud.availability_zone',    dictGet('payflow_inventory.dict_node', 'zone', dictGet('payflow_inventory.dict_pod', 'node_name', pf_pod_from_path(path))),
        'deployment.environment.name', 'production');

--  filter: las probes del kubelet, tal como las descartaría el procesador filter
CREATE OR REPLACE FUNCTION pf_is_health_check AS (line) ->
    line LIKE '%GET /healthz%' OR line LIKE '%health status UP%' OR line LIKE '%"msg":"health check"%';


-- PASO 3 · Los procesadores, como vistas materializadas sobre la tabla de aterrizaje
--  Logs de contenedores: filter, y luego transform, k8sattributes y redaction en un solo SELECT.
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_gateway_logs TO payflow_otel.otel_logs AS
WITH JSONExtractString(payload, 'log') AS line,
     JSONExtractString(payload, 'log.file.path') AS path
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC')   AS Timestamp,
    pf_log_trace_id(line)                                                     AS TraceId,
    pf_log_span_id(line)                                                      AS SpanId,
    toUInt8(TraceId != '')                                                    AS TraceFlags,
    pf_log_severity(line)                                                     AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)) AS ServiceName,
    pf_mask_pan(pf_log_body(line))                                            AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    pf_k8s_resource(path)                                                     AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    pf_log_scope(line)                                                        AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    mapUpdate(mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line)),
              map('log.file.path', path, 'log.iostream', JSONExtractString(payload, 'stream'))) AS LogAttributes,
    ''                                                                        AS EventName
FROM payflow_ingest.agent_records
WHERE source = 'filelog' AND NOT pf_is_health_check(JSONExtractString(payload, 'log'));

--  routing: los eventos de Kubernetes van por otro camino, con el motivo del evento como EventName
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_gateway_k8s_events TO payflow_otel.otel_logs AS
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
FROM payflow_ingest.agent_records
WHERE source = 'k8sobjects';

--  count: un conector. Cuenta cada registro por minuto, servicio y severidad, conservado
--  o descartado por el filtro. Así se ve lo que ahorra el filtro.
CREATE OR REPLACE TABLE payflow_sre.log_volume_1m
(
    minute     DateTime('UTC'),
    service    LowCardinality(String),
    severity   LowCardinality(String),
    dropped    Bool,
    records    UInt64,
    bytes      UInt64
)
ENGINE = SummingMergeTree
ORDER BY (service, severity, dropped, minute);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.mv_log_volume_1m TO payflow_sre.log_volume_1m AS
WITH JSONExtractString(payload, 'log') AS line
SELECT
    toStartOfMinute(toDateTime(received_at))                                          AS minute,
    if(source = 'k8sobjects', 'k8s-events', dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(JSONExtractString(payload, 'log.file.path')))) AS service,
    if(source = 'k8sobjects', if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO'), pf_log_severity(line)) AS severity,
    source = 'filelog' AND pf_is_health_check(line)                                   AS dropped,
    count()                                                                           AS records,
    sum(length(payload))                                                              AS bytes
FROM payflow_ingest.agent_records
GROUP BY minute, service, severity, dropped;


-- PASO 4 · Los agentes envían el día, a través de la pasarela
--  6 lotes de 4 horas. Cada INSERT ejecuta el simulador y luego las 3 vistas: parseo,
--  enriquecimiento y enmascarado ocurren en la misma sentencia, por debajo de los 60 s
--  de la consola.
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_s = 0, to_s = 14400);       -- de 00:00 a 04:00
-- Medido: 11,8 s · 2 M filas leídas (737,4 MB) · 1,3 M filas escritas · 2,5 GB de memoria
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_s = 14400, to_s = 28800);   -- de 04:00 a 08:00
-- Medido: 11,6 s · 2,1 M filas leídas (748,9 MB) · 1,3 M filas escritas · 2,6 GB de memoria
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_s = 28800, to_s = 43200);   -- de 08:00 a 12:00
-- Medido: 12,7 s · 2,4 M filas leídas (866,2 MB) · 1,5 M filas escritas · 2,7 GB de memoria
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_s = 43200, to_s = 57600);   -- de 12:00 a 16:00
-- Medido: 14,8 s · 4,7 M filas leídas (1,7 GB) · 3 M filas escritas · 4,8 GB de memoria
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_s = 57600, to_s = 72000);   -- de 16:00 a 20:00
-- Medido: 16,1 s · 7 M filas leídas (2,5 GB) · 4,6 M filas escritas · 7,3 GB de memoria
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_s = 72000, to_s = 86400);   -- de 20:00 a 24:00
-- Medido: 16,1 s · 6,4 M filas leídas (2,3 GB) · 4,2 M filas escritas · 6,7 GB de memoria

SELECT count() AS records_in_landing_table FROM payflow_ingest.agent_records;
-- Medido: 2 ms
-- Qué observar: 0. La tabla Null no ha guardado nada; todo está en otel_logs.


-- PASO 5 · Lo que ha hecho la pasarela
SELECT
    sum(records)                                                    AS received,
    sumIf(records, dropped)                                         AS dropped_by_filter,
    round(100 * sumIf(records, dropped) / sum(records), 1)          AS dropped_pct,
    formatReadableSize(sumIf(bytes, dropped))                       AS bytes_saved
FROM payflow_sre.log_volume_1m;
-- Medido: 4 ms · 30 440 filas leídas (505,4 KB)

SELECT ServiceName, ResourceAttributes['service.version'] AS version, ResourceAttributes['service.team'] AS team,
       ResourceAttributes['cloud.availability_zone'] AS zone, count() AS log_records
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:05:00'
GROUP BY ALL
ORDER BY log_records DESC;
-- Medido: 166 ms · 2,2 M filas leídas (14,9 MB) · 103,2 MB de memoria
-- Qué observar: el agente solo envió una ruta de fichero. Versión, equipo y zona los ha
-- añadido la pasarela. Durante el rollout, las dos versiones escriben logs en paralelo.

SELECT
    countIf(match(Body, '\\b[0-9]{13,19}\\b'))       AS full_pans_stored,
    countIf(Body LIKE '%pan=%******%')                AS masked_pans,
    any(if(Body LIKE '%pan=%', Body, NULL))           AS example
FROM payflow_otel.otel_logs
WHERE ServiceName = 'card-network-adapter';
-- Medido: 253 ms · 4,5 M filas leídas (251,2 MB) · 92,7 MB de memoria
-- Qué observar: cero números de tarjeta completos guardados, todos enmascarados.


-- PASO 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_ingest.agent_records) = 0, 'OK', 'KO')                                       AS nothing_stored_raw,
    if((SELECT count() FROM payflow_otel.otel_logs) = (SELECT sumIf(records, NOT dropped) FROM payflow_sre.log_volume_1m), 'OK', 'KO') AS every_kept_record_written,
    if((SELECT countIf(match(Body, '\\b[0-9]{13,19}\\b')) FROM payflow_otel.otel_logs) = 0, 'OK', 'KO')       AS pci_masking,
    if((SELECT countIf(ResourceAttributes['service.team'] = '' AND ServiceName != 'k8s-events') FROM payflow_otel.otel_logs) = 0, 'OK', 'KO') AS enrichment,
    if((SELECT countIf(TraceId != '') / count() FROM payflow_otel.otel_logs) > 0.9, 'OK', 'KO')                  AS trace_ids
SETTINGS select_sequential_consistency = 1;
-- Medido: 542 ms · 23,5 M filas leídas (823,6 MB) · 152,3 MB de memoria
