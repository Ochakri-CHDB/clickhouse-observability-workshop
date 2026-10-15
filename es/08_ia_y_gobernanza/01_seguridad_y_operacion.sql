-- =====================================================================
--  MÓDULO 8 · IA y gobernanza (parte SQL): borrado, permisos, auto-observabilidad
-- =====================================================================
--  Una plataforma de observabilidad guarda datos personales y secretos de producción:
--    · borrar lo que hay que borrar (RGPD), sin reescribir la tabla
--    · mostrar a cada equipo solo su namespace (la misma regla se aplica en ClickStack)
--    · observar el propio ClickHouse con sus tablas de sistema
--  El README de este módulo cubre la parte ClickStack: AI Notebooks, MCP, ClickHouse
--  Agents, RBAC, la API de estado y el aislamiento entre lectura y escritura.
-- =====================================================================


-- PASO 1 · RGPD: un comercio pide borrar sus datos personales de los logs
--  El DELETE ligero marca las filas como borradas al instante (desaparecen de todas
--  las consultas) y el espacio se recupera en los siguientes merges. Sin reescribir la tabla.
SELECT count() AS lines_before FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Medido: 540 ms · 3,4 M filas leídas (19,1 MB) · 206,7 MB de memoria

DELETE FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Medido: 1,03 s

SELECT count() AS lines_after FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Medido: 69 ms · 3,4 M filas leídas (20,6 MB) · 265 MB de memoria


-- PASO 2 · Cada equipo ve su propio namespace
--  Un rol por equipo, una row policy por tabla: la base de datos añade el filtro
--  a cada consulta del rol, también a través de las vistas y de ClickStack.
CREATE ROLE IF NOT EXISTS payflow_team_payments;
GRANT SELECT ON payflow_otel.* TO payflow_team_payments;
GRANT SELECT ON payflow_sre.* TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_logs   ON payflow_otel.otel_logs   USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_traces ON payflow_otel.otel_traces USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
--  La tabla de aterrizaje de la pasarela es del pipeline, nadie más escribe en ella.
REVOKE ALL ON payflow_ingest.* FROM payflow_team_payments;
-- Medido: 5 ms

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE short_name LIKE 'pf\\_%';
-- Medido: 1 ms · 13 filas leídas (3,1 KB)


-- PASO 3 · Observar la plataforma de observabilidad
--  ClickHouse registra cada consulta, cada inserción, cada ejecución de vista. El mismo SQL
--  que usaste con la plataforma de pagos funciona con el propio ClickHouse.
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
-- Medido: 23 ms · 17 263 filas leídas (605,3 KB)

SELECT view_name, count() AS runs, round(avg(view_duration_ms), 1) AS avg_ms, sum(written_rows) AS rows_written
FROM clusterAllReplicas('default', system.query_views_log)
WHERE event_date >= today() - 1 AND view_name LIKE 'payflow\\_%'
GROUP BY view_name
ORDER BY rows_written DESC;
-- Medido: 17 ms · 2 927 filas leídas (55,4 KB)
-- Qué observar: las vistas materializadas de los módulos 3 y 5, cuántas veces se
-- ejecutaron y cuántas filas escribieron. Es la salud del pipeline.


-- PASO 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042') = 0, 'OK', 'KO') AS gdpr_delete,
    if((SELECT count() FROM system.row_policies WHERE short_name LIKE 'pf\\_payments%') = 2, 'OK', 'KO')            AS row_policies
SETTINGS select_sequential_consistency = 1;
-- Medido: 17 ms · 14 filas leídas (3,1 KB)
