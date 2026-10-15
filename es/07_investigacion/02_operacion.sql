-- =====================================================================
--  MÓDULO 7 · Operar la plataforma: retención, reproceso, borrado, seguridad
-- =====================================================================
--  Una plataforma de observabilidad es en sí misma un sistema de producción:
--    · conservar cada capa mientras sea útil, no más (TTL)
--    · corregir una regla de parsing y reconstruir silver desde bronze, de forma atómica
--    · borrar lo que haya que borrar (RGPD), sin reescribir la tabla
--    · mostrar a cada equipo solo sus datos, y cerrar bronze (números de tarjeta)
--    · observar el propio ClickHouse con las tablas de sistema
-- =====================================================================


-- PASO 1 · Retención por capa
--  Cada tabla ya elimina particiones diarias completas al cumplirse su TTL (aquí 3 años,
--  para que los datos del workshop no caduquen nunca). Una política de producción sería así:
--      ALTER TABLE payflow_raw.log_records   MODIFY TTL toDateTime(received_at) + INTERVAL 7 DAY;   -- líneas brutas, con números de tarjeta
--      ALTER TABLE payflow_otel.otel_logs    MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;
--      ALTER TABLE payflow_otel.otel_traces  MODIFY TTL toDate(Timestamp) + INTERVAL 15 DAY;
--      ALTER TABLE payflow_sre.red_1m        MODIFY TTL minute + INTERVAL 13 MONTH;               -- los agregados viven mucho
--  Atención: los datos del workshop tienen fecha de noviembre de 2026. No apliques esto en
--  tu servicio después de esa fecha más el TTL: ClickHouse borraría los datos.
SELECT database, table, any(engine_full LIKE '%TTL%') AS has_ttl,
       formatReadableSize(sum(total_bytes)) AS size
FROM system.tables
WHERE database LIKE 'payflow\\_%' AND engine LIKE '%MergeTree'
GROUP BY database, table
ORDER BY sum(total_bytes) DESC;
-- Medido: 4 ms · 18 filas leídas (4,6 KB)
-- Qué observar: las tablas gold ocupan unos MB, las tablas bruta y silver, GB.
-- Una retención larga sale barata allí donde los datos están agregados.


-- PASO 2 · Reconstruir silver desde bronze y publicarlo de forma atómica
--  Escenario: las reglas de parsing han cambiado (aquí son las mismas, lo que importa
--  es el mecanismo). Reconstruimos el día en una tabla intermedia, la comprobamos y
--  luego intercambiamos la partición en una sola operación atómica: los lectores nunca
--  ven un día a medio construir.
CREATE OR REPLACE TABLE payflow_otel.otel_logs__build AS payflow_otel.otel_logs;

INSERT INTO payflow_otel.otel_logs__build
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
WHERE source = 'fluent-bit' AND toDate(parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'time'), 9, 'UTC')) = '2026-11-27';   -- OrZero: el WHERE puede evaluarse antes que el filtro sobre source
-- Medido: 15,6 s · 8,1 M filas leídas (3,7 GB) · 8,1 M filas escritas · 11 GB de memoria

INSERT INTO payflow_otel.otel_logs__build
SELECT * EXCEPT (`__hdx_materialized_k8s.cluster.name`, `__hdx_materialized_k8s.container.name`, `__hdx_materialized_k8s.deployment.name`,
                 `__hdx_materialized_k8s.namespace.name`, `__hdx_materialized_k8s.node.name`, `__hdx_materialized_k8s.pod.name`,
                 `__hdx_materialized_k8s.pod.uid`, `__hdx_materialized_deployment.environment.name`)
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events' AND toDate(Timestamp) = '2026-11-27';
-- Medido: 236 ms · 5,2 M filas leídas (5,1 MB) · 354 filas escritas · 158,7 MB de memoria

--  Comprobación antes de publicar: mismo número de líneas por severidad en prod
--  y en la reconstrucción
SELECT
    SeverityText,
    countIf(_table = 'otel_logs')        AS prod,
    countIf(_table = 'otel_logs__build') AS rebuild,
    if(prod = rebuild, 'OK, listo para publicar', 'KO, no publicar') AS verdict
FROM merge('payflow_otel', '^otel_logs(__build)?$')
WHERE toDate(Timestamp) = '2026-11-27'
GROUP BY SeverityText
ORDER BY SeverityText;
-- Medido: 60 ms · 16,3 M filas leídas (139,6 MB) · 216,3 MB de memoria

--  El intercambio atómico del día
ALTER TABLE payflow_otel.otel_logs REPLACE PARTITION '2026-11-27' FROM payflow_otel.otel_logs__build;
DROP TABLE payflow_otel.otel_logs__build;


-- PASO 3 · RGPD: un comercio pide borrar sus datos personales de los logs
--  El DELETE ligero (lightweight DELETE) marca las filas como borradas al instante
--  (desaparecen de todas las consultas) y el espacio se recupera en los siguientes
--  merges. Sin reescribir la tabla entera.
SELECT count() AS lines_before FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Medido: 59 ms · 4,6 M filas leídas (24,2 MB) · 91,8 MB de memoria

DELETE FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Medido: 38,3 s

SELECT count() AS lines_after FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Medido: 60 ms · 3,5 M filas leídas (23 MB) · 174,3 MB de memoria


-- PASO 4 · Cada equipo ve su propio namespace
--  Un rol por equipo, una row policy por tabla: la base de datos añade el filtro
--  a cada consulta del rol, también a través de las vistas y de ClickStack.
CREATE ROLE IF NOT EXISTS payflow_team_payments;
GRANT SELECT ON payflow_otel.* TO payflow_team_payments;
GRANT SELECT ON payflow_sre.* TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_logs   ON payflow_otel.otel_logs   USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_traces ON payflow_otel.otel_traces USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
--  Bronze contiene números de tarjeta en claro: nadie salvo el pipeline lo lee.
REVOKE ALL ON payflow_raw.* FROM payflow_team_payments;
-- Medido: 13 ms

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE short_name LIKE 'pf\\_%';
-- Medido: 1 ms · 13 filas leídas (3,1 KB)


-- PASO 5 · Observar la plataforma de observabilidad
--  ClickHouse registra cada consulta, cada insert, cada ejecución de vista. El mismo SQL
--  que has usado con la plataforma de pagos funciona con el propio ClickHouse.
SYSTEM FLUSH LOGS;

SELECT
    query_kind,
    count()                                                    AS queries,
    round(quantile(0.5)(query_duration_ms))                    AS p50_ms,
    max(query_duration_ms)                                     AS max_ms,
    formatReadableQuantity(sum(read_rows))                     AS rows_read,
    formatReadableSize(max(memory_usage))                      AS max_memory
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND event_date >= today() - 1 AND has(databases, 'payflow_otel')
GROUP BY query_kind
ORDER BY queries DESC;
-- Medido: 25 ms · 60 908 filas leídas (2,1 MB)

SELECT view_name, count() AS runs, round(avg(view_duration_ms), 1) AS avg_ms, sum(written_rows) AS rows_written
FROM clusterAllReplicas('default', system.query_views_log)
WHERE event_date >= today() - 1 AND view_name LIKE 'payflow\\_%'
GROUP BY view_name
ORDER BY rows_written DESC;
-- Medido: 16 ms · 26 895 filas leídas (494,4 KB)
-- Qué observar: las vistas materializadas de los módulos 3 y 5, cuántas veces se ejecutaron
-- y cuántas filas escribieron. Es la salud del pipeline.


-- PASO 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE toDate(Timestamp) = '2026-11-27') > 8000000, 'OK', 'KO') AS replay_published,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042') = 0, 'OK', 'KO') AS gdpr_delete,
    if((SELECT count() FROM system.row_policies WHERE short_name LIKE 'pf\\_payments%') = 2, 'OK', 'KO')            AS row_policies
SETTINGS select_sequential_consistency = 1;
-- Medido: 37 ms · 8,1 M filas leídas (69,8 MB)
