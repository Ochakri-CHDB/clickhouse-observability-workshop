-- =====================================================================
--  MÓDULO 7 · La investigación: del aviso (page) a la causa raíz, en SQL
-- =====================================================================
--  14:00 UTC, Black Friday. Al ingeniero de guardia le llega un aviso: "POST /v1/payments:
--  presupuesto de errores consumiéndose 19 veces más rápido de lo permitido". Diez
--  preguntas, diez consultas. Todas las respuestas salen de la misma base de datos:
--  sin cambiar de herramienta, sin copiar datos entre una herramienta de logs,
--  una de trazas y una de métricas.
-- =====================================================================


-- Q1 · ¿Qué ha saltado y cuándo?
SELECT ts, rule, service, state, summary
FROM payflow_sre.alerts
WHERE ts BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 15:00:00'
ORDER BY ts;
-- Medido: 20 ms · 11 filas leídas


-- Q2 · ¿Cómo de grave es? Errores y latencia de cada servicio, ahora frente a hace una hora
SELECT
    service,
    round(100 * sumIf(errors, minute >= '2026-11-27 14:05:00' AND minute < '2026-11-27 14:15:00')
              / sumIf(requests, minute >= '2026-11-27 14:05:00' AND minute < '2026-11-27 14:15:00'), 2)          AS error_pct_now,
    round(100 * sumIf(errors, minute >= '2026-11-27 13:05:00' AND minute < '2026-11-27 13:15:00')
              / sumIf(requests, minute >= '2026-11-27 13:05:00' AND minute < '2026-11-27 13:15:00'), 2)          AS error_pct_before,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency, minute >= '2026-11-27 14:05:00' AND minute < '2026-11-27 14:15:00')[3] / 1e6) AS p99_ms_now,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency, minute >= '2026-11-27 13:05:00' AND minute < '2026-11-27 13:15:00')[3] / 1e6) AS p99_ms_before
FROM payflow_sre.red_1m
GROUP BY service
ORDER BY error_pct_now DESC;
-- Medido: 74 ms · 20 165 filas leídas (3 MB)
-- Qué observar: fallan tres servicios (api-gateway, checkout, payment). ¿Cuál es la causa
-- y cuáles solo propagan el error?


-- Q3 · ¿Dónde nace el error? El span fallido más profundo de cada traza fallida
--  Un span que ha fallado sin que falle ninguno de sus hijos es donde nació el error.
SELECT ServiceName, SpanName, StatusMessage, count() AS failed_traces
FROM payflow_otel.otel_traces AS s
WHERE Timestamp BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:15:00'
  AND StatusCode = 'Error'
  AND SpanId NOT IN
  (
      SELECT ParentSpanId FROM payflow_otel.otel_traces
      WHERE Timestamp BETWEEN '2026-11-27 14:04:00' AND '2026-11-27 14:16:00' AND StatusCode = 'Error'
  )
GROUP BY ServiceName, SpanName, StatusMessage
ORDER BY failed_traces DESC
LIMIT 5;
-- Medido: 319 ms · 1,1 M filas leídas (11,3 MB)
-- Qué observar: la llamada a la base de datos de payment, "Connection is not available,
-- request timed out after 3000ms". Los demás son víctimas.


-- Q4 · Una traza fallida, en forma de árbol (una CTE recursiva)
--  WITH RECURSIVE baja desde el span raíz hasta sus hijos, nivel a nivel.
WITH RECURSIVE
    (SELECT TraceId FROM payflow_otel.otel_traces
     WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments' AND StatusCode = 'Error'
       AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01' LIMIT 1) AS tid,
    spans AS
    (
        SELECT SpanId, ParentSpanId, ServiceName, SpanName, Timestamp, Duration, StatusCode
        FROM payflow_otel.otel_traces
        WHERE TraceId = tid AND Timestamp BETWEEN '2026-11-27 14:09:55' AND '2026-11-27 14:10:10'
    ),
    tree AS
    (
        SELECT SpanId, ServiceName, SpanName, Timestamp, Duration, StatusCode, 0 AS depth
        FROM spans WHERE ParentSpanId = ''
        UNION ALL
        SELECT s.SpanId, s.ServiceName, s.SpanName, s.Timestamp, s.Duration, s.StatusCode, t.depth + 1
        FROM spans AS s INNER JOIN tree AS t ON s.ParentSpanId = t.SpanId
    )
SELECT
    concat(repeat('   ', depth), SpanName)                                                    AS span,
    ServiceName                                                                                AS service,
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1)                 AS start_ms,
    round(Duration / 1e6, 1)                                                                   AS duration_ms,
    StatusCode                                                                                 AS status
FROM tree
ORDER BY Timestamp;
-- Medido: 96 ms · 294 926 filas leídas (18,9 MB)
-- Qué observar: el waterfall del módulo 8, en SQL puro. 3 segundos esperando en
-- INSERT payflow.payments; card network, ledger y notification no llegaron a ejecutarse.


-- Q5 · ¿Qué ha cambiado? Los despliegues en torno al inicio de los errores
SELECT deployment, version, change_id, author, valid_from, note
FROM payflow_ref.deployment_history
WHERE valid_from BETWEEN '2026-11-27 12:00:00' AND '2026-11-27 16:00:00'
ORDER BY valid_from;
-- Medido: 3 ms · 11 filas leídas

SELECT
    ResourceAttributes['service.version']           AS pod_version,
    count()                                         AS db_calls,
    round(100 * countIf(StatusCode = 'Error') / count(), 2) AS error_pct,
    round(quantile(0.99)(Duration) / 1e6)           AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
  AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:42:00'
GROUP BY pod_version;
-- Medido: 130 ms · 65 536 filas leídas (1,8 MB)
-- Qué observar: durante el despliegue progresivo (rollout) las dos versiones sirvieron
-- tráfico a la vez. Solo falla v2.4.1. Misma base de datos, mismo tráfico: la causa es
-- la versión.


-- Q6 · ¿Por qué falla v2.4.1? El pool de conexiones, visto por las métricas
SELECT
    toStartOfFiveMinutes(toDateTime(TimeUnix))                                          AS t,
    ResourceAttributes['service.version']                                                AS version,
    maxIf(Value, MetricName = 'hikaricp.connections.max')                                AS pool_size,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'), 1)                   AS active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'), 1)                  AS waiting
FROM payflow_otel.otel_metrics_gauge
WHERE ServiceName = 'payment' AND MetricName LIKE 'hikaricp.%'
  AND TimeUnix BETWEEN '2026-11-27 13:40:00' AND '2026-11-27 15:00:00'
GROUP BY t, version
ORDER BY t, version;
-- Medido: 12 ms · 57 344 filas leídas (2,7 MB)
-- Qué observar: v2.4.1 tiene 10 conexiones, todas ocupadas, y decenas de hilos esperando.


-- Q7 · ... y visto por los logs: la línea de arranque de un pod v2.4.1
SELECT Timestamp, ResourceAttributes['k8s.pod.name'] AS pod, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND hasToken(lower(Body), 'maximumpoolsize')
  AND Timestamp BETWEEN '2026-11-27 13:55:00' AND '2026-11-27 14:50:00'
ORDER BY Timestamp
LIMIT 4;
-- Medido: 414 ms · 55 614 filas leídas (2,4 MB)
-- Qué observar: maximumPoolSize=10 a las 13:58, maximumPoolSize=50 tras la marcha atrás
-- (rollback). La nota del cambio decía "pool size 50 to 10": la revisión no tuvo en cuenta
-- la carga del Black Friday.


-- Q8 · El segundo incendio: fraud-scoring en el nodo pequeño
--  Los reintentos añaden carga, fraud-scoring se ralentiza y su memoria crece hasta que
--  el kernel lo mata.
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE (ServiceName = 'k8s-events' AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17'
       AND SeverityText = 'WARN' AND EventName != 'Unhealthy')
   OR (ServiceName = 'fraud-scoring' AND SeverityNumber >= 13 AND Body NOT LIKE 'score=%')
ORDER BY Timestamp
LIMIT 20;
-- Medido: 321 ms · 6 M filas leídas (469,1 MB) · 320,6 MB de memoria

SELECT
    toStartOfMinute(toDateTime(TimeUnix))                         AS minute,
    round(max(Value) / 1048576)                                   AS memory_mib
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'k8s.pod.memory.working_set'
  AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17' AND ServiceName = 'fraud-scoring'
  AND TimeUnix BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:30:00'
GROUP BY minute
ORDER BY minute WITH FILL STEP INTERVAL 1 MINUTE;
-- Medido: 14 ms · 32 768 filas leídas (1,9 MB)
-- Qué observar: la memoria sube hasta 2 GiB, cae a 0 a las 14:21 (matado) y vuelve a arrancar.


-- Q9 · El impacto de negocio: pagos fallidos, importe, comercios
SELECT
    count()                                                                            AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                            AS amount_eur,
    uniqExact(SpanAttributes['merchant.id'])                                           AS merchants_hit
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:50:00';
-- Medido: 175 ms · 73 728 filas leídas (2,8 MB)

SELECT
    dictGet('payflow_ref.dict_merchant', 'name', SpanAttributes['merchant.id'])          AS merchant,
    dictGet('payflow_ref.dict_merchant', 'tier', SpanAttributes['merchant.id'])          AS tier,
    count()                                                                              AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                              AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:50:00'
GROUP BY merchant, tier
ORDER BY amount_eur DESC
LIMIT 10;
-- Medido: 37 ms · 73 728 filas leídas (2,8 MB)
-- Qué observar: las cifras de impacto en clientes para el informe del incidente.
-- Los account managers saben a quién llamar primero.


-- Q10 · La cronología del incidente, con todas las señales a la vez
SELECT ts, source, what
FROM
(
    SELECT valid_from AS ts, 'deploy' AS source, concat(deployment, ' ', version, ' (', change_id, ', ', author, ')') AS what
    FROM payflow_ref.deployment_history WHERE valid_from BETWEEN '2026-11-27 13:00:00' AND '2026-11-27 15:00:00'
    UNION ALL
    SELECT ts, concat('alert ', state), concat(rule, ': ', summary) FROM payflow_sre.alerts
    UNION ALL
    SELECT min(toDateTime(Timestamp)), 'first error log', any(Body) FROM payflow_otel.otel_logs
    WHERE hasToken(lower(Body), 'hikaripool') AND SeverityText = 'ERROR'
    UNION ALL
    SELECT max(toDateTime(Timestamp)), 'last error log', any(Body) FROM payflow_otel.otel_logs
    WHERE hasToken(lower(Body), 'hikaripool') AND SeverityText = 'ERROR'
    UNION ALL
    SELECT toDateTime(Timestamp), 'k8s', concat(EventName, ': ', Body) FROM payflow_otel.otel_logs
    WHERE ServiceName = 'k8s-events' AND SeverityText = 'WARN' AND EventName != 'Unhealthy'
)
ORDER BY ts;
-- Medido: 260 ms · 5,7 M filas leídas (42,3 MB) · 176,2 MB de memoria
-- Qué observar: despliegue 13:58, primer error 13:58, aviso 14:00, OOM 14:21,
-- marcha atrás 14:42, último error 14:44, resuelto 14:47. Tiempo de detección: 2 minutos.
-- Tiempo de mitigación: 44 minutos. El postmortem se escribe solo.


-- Checkpoint
SELECT
    if((SELECT argMax(SpanName, c) FROM (SELECT SpanName, count() AS c FROM payflow_otel.otel_traces
        WHERE StatusCode = 'Error' AND Timestamp BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:15:00' AND SpanKind = 'Client'
        GROUP BY SpanName)) = 'INSERT payflow.payments', 'OK', 'KO')                                                   AS root_cause_span,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE hasToken(lower(Body), 'maximumpoolsize') AND Body LIKE '%maximumPoolSize=10%') = 6, 'OK', 'KO') AS startup_clue,
    if((SELECT countIf(StatusCode = 'Error') FROM payflow_otel.otel_traces
        WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
          AND ResourceAttributes['service.version'] = 'v2.4.0' AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:42:00') = 0, 'OK', 'KO') AS only_v241_fails
SETTINGS select_sequential_consistency = 1;
-- Medido: 165 ms · 637 673 filas leídas (4,9 MB)
