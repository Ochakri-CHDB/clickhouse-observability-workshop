-- =====================================================================
--  MÓDULO 6 · Investigación (2/2): del aviso a la causa raíz, en SQL
-- =====================================================================
--  14:00 UTC, Black Friday. Salta el aviso (page) al ingeniero de guardia: "POST /v1/payments:
--  error budget burning 19x faster than allowed". Diez preguntas, diez consultas.
--  Todas las respuestas salen de la misma base de datos: sin cambiar de herramienta, sin
--  copiar datos entre una herramienta de logs, una de trazas y una de métricas.
-- =====================================================================


-- P1 · ¿Qué ha saltado, y cuándo?
SELECT ts, rule, service, state, summary
FROM payflow_sre.alerts
WHERE ts BETWEEN pf_at('13:50') AND pf_at('15:00')
ORDER BY ts;
-- Medido: 31 ms · 12 filas leídas (1 KB)


-- P2 · ¿Cómo de grave es? Errores y latencia de cada servicio, ahora frente a hace una hora
SELECT
    service,
    round(100 * sumIf(errors, minute >= pf_at('14:05') AND minute < pf_at('14:15'))
              / sumIf(requests, minute >= pf_at('14:05') AND minute < pf_at('14:15')), 2)          AS error_pct_now,
    round(100 * sumIf(errors, minute >= pf_at('13:05') AND minute < pf_at('13:15'))
              / sumIf(requests, minute >= pf_at('13:05') AND minute < pf_at('13:15')), 2)          AS error_pct_before,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency, minute >= pf_at('14:05') AND minute < pf_at('14:15'))[3] / 1e6) AS p99_ms_now,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency, minute >= pf_at('13:05') AND minute < pf_at('13:15'))[3] / 1e6) AS p99_ms_before
FROM payflow_sre.red_1m
GROUP BY service
ORDER BY error_pct_now DESC;
-- Medido: 139 ms · 721 414 filas leídas (102,8 MB) · 337,8 MB de memoria
-- Qué observar: fallan tres servicios (api-gateway, checkout, payment). ¿Quién es la causa
-- y quién solo propaga el error?


-- P3 · ¿Dónde nace el error? El span con fallo más profundo de cada traza fallida
--  Un span que ha fallado sin que ninguno de sus hijos falle es donde nació el error.
SELECT ServiceName, SpanName, StatusMessage, count() AS failed_traces
FROM payflow_otel.otel_traces AS s
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND StatusCode = 'Error'
  AND SpanId NOT IN
  (
      SELECT ParentSpanId FROM payflow_otel.otel_traces
      WHERE Timestamp BETWEEN pf_at('14:04') AND pf_at('14:16') AND StatusCode = 'Error'
  )
GROUP BY ServiceName, SpanName, StatusMessage
ORDER BY failed_traces DESC
LIMIT 5;
-- Medido: 705 ms · 1,6 M filas leídas (17,3 MB) · 66 MB de memoria
-- Qué observar: la llamada a la base de datos de payment, "Connection is not available,
-- request timed out after 3000ms". Los demás son víctimas.


-- P4 · Una traza fallida, en forma de árbol (una CTE recursiva)
--  WITH RECURSIVE baja desde el span raíz hasta sus hijos, nivel a nivel.
WITH RECURSIVE
    (SELECT TraceId FROM payflow_otel.otel_traces
     WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments' AND StatusCode = 'Error'
       AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:01') LIMIT 1) AS tid,
    spans AS
    (
        SELECT SpanId, ParentSpanId, ServiceName, SpanName, Timestamp, Duration, StatusCode
        FROM payflow_otel.otel_traces
        WHERE TraceId = tid AND Timestamp BETWEEN pf_at('14:09:55') AND pf_at('14:10:10')
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
-- Medido: 1,66 s · 638 999 filas leídas (34,2 MB)
-- Qué observar: la cascada (waterfall) del módulo 3, en SQL a secas. 3 segundos esperando
-- en INSERT payflow.payments; la red de tarjetas, ledger y notification nunca se ejecutaron.


-- P5 · ¿Qué ha cambiado? El cambio activo en cada error, y los despliegues
--  El diccionario de rangos del módulo 1 sella cada span de error con el cambio activo
--  en ese segundo; el equipo sale del catálogo de servicios.
SELECT
    dictGet('payflow_inventory.dict_service', 'team', ServiceName)                            AS team,
    ServiceName,
    dictGet('payflow_inventory.dict_deployment', 'change_id', ServiceName, toDateTime(Timestamp)) AS change_live,
    count()                                                                                    AS error_spans
FROM payflow_otel.otel_traces
WHERE StatusCode = 'Error' AND SpanKind = 'Client' AND SpanAttributes['rpc.system'] = '' AND toDate(Timestamp) = pf_black_friday()
GROUP BY team, ServiceName, change_live
ORDER BY error_spans DESC
LIMIT 5;
-- Medido: 227 ms · 21,5 M filas leídas (62 MB) · 146,4 MB de memoria
-- Qué observar: el equipo payments, cambio CHG-4117. Avisa primero al equipo correcto.

SELECT deployment, version, change_id, author, valid_from, note
FROM payflow_inventory.deployment_history
WHERE valid_from BETWEEN pf_at('12:00') AND pf_at('16:00')
ORDER BY valid_from;
-- Medido: 6 ms · 17 filas leídas (1,2 KB)

SELECT
    ResourceAttributes['service.version']           AS pod_version,
    count()                                         AS db_calls,
    round(100 * countIf(StatusCode = 'Error') / count(), 2) AS error_pct,
    round(quantile(0.99)(Duration) / 1e6)           AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
  AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:42')
GROUP BY pod_version;
-- Medido: 142 ms · 65 537 filas leídas (1,6 MB)
-- Qué observar: durante el despliegue progresivo (rollout) las dos versiones sirvieron
-- tráfico a la vez. Solo falla v2.4.1. Misma base, mismo tráfico: la causa es la versión.


-- P6 · ¿Por qué falla v2.4.1? El pool de conexiones, visto por las métricas
SELECT
    toStartOfFiveMinutes(toDateTime(TimeUnix))                                          AS t,
    ResourceAttributes['service.version']                                                AS version,
    maxIf(Value, MetricName = 'hikaricp.connections.max')                                AS pool_size,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'), 1)                   AS active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'), 1)                  AS waiting
FROM payflow_otel.otel_metrics_gauge
WHERE ServiceName = 'payment' AND MetricName LIKE 'hikaricp.%'
  AND TimeUnix BETWEEN pf_at('13:40') AND pf_at('15:00')
GROUP BY t, version
ORDER BY t, version;
-- Medido: 200 ms · 49 153 filas leídas (2,5 MB)
-- Qué observar: v2.4.1 tiene 10 conexiones, todas ocupadas, y decenas de hilos esperando.


-- P7 · ... y visto por los logs: la línea de arranque de un pod v2.4.1
SELECT Timestamp, ResourceAttributes['k8s.pod.name'] AS pod, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND hasToken(lower(Body), 'maximumpoolsize')
  AND Timestamp BETWEEN pf_at('13:55') AND pf_at('14:50')
ORDER BY Timestamp
LIMIT 4;
-- Medido: 699 ms · 40 961 filas leídas (1,5 MB)
-- Qué observar: maximumPoolSize=10 a las 13:58, maximumPoolSize=50 tras la marcha atrás
-- (rollback). La nota del cambio decía "pool size 50 to 10": la revisión no tuvo en
-- cuenta la carga de Black Friday.


-- P8 · El segundo fuego: fraud-scoring en el nodo pequeño
--  Los reintentos añaden carga, fraud-scoring se ralentiza, su memoria crece hasta que
--  el kernel lo mata.
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE (ServiceName = 'k8s-events' AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17'
       AND SeverityText = 'WARN' AND EventName != 'Unhealthy')
   OR (ServiceName = 'fraud-scoring' AND SeverityNumber >= 13 AND Body NOT LIKE 'score=%')
ORDER BY Timestamp
LIMIT 20;
-- Medido: 970 ms · 25,1 M filas leídas (2 GB) · 401,9 MB de memoria

SELECT
    toStartOfMinute(toDateTime(TimeUnix))                         AS minute,
    round(max(Value) / 1048576)                                   AS memory_mib
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'k8s.pod.memory.usage'
  AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17' AND ServiceName = 'fraud-scoring'
  AND TimeUnix BETWEEN pf_at('14:00') AND pf_at('14:30')
GROUP BY minute
ORDER BY minute WITH FILL STEP INTERVAL 1 MINUTE;
-- Medido: 98 ms · 8 193 filas leídas (466,7 KB)
-- Qué observar: la memoria sube hasta 2 GiB, cae a 0 a las 14:21 (matado) y vuelve a arrancar.


-- P9 · El impacto de negocio: pagos fallidos, importe, comercios
SELECT
    count()                                                                            AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                            AS amount_eur,
    uniqExact(SpanAttributes['merchant.id'])                                           AS merchants_hit
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:50');
-- Medido: 144 ms · 73 729 filas leídas (2,8 MB)

SELECT
    dictGet('payflow_inventory.dict_merchant', 'name', SpanAttributes['merchant.id'])          AS merchant,
    dictGet('payflow_inventory.dict_merchant', 'tier', SpanAttributes['merchant.id'])          AS tier,
    count()                                                                              AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                              AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:50')
GROUP BY merchant, tier
ORDER BY amount_eur DESC
LIMIT 10;
-- Medido: 42 ms · 73 729 filas leídas (2,8 MB)
-- Qué observar: las cifras de cara al cliente para el informe del incidente.
-- Los gestores de cuenta saben a quién llamar primero.


-- P10 · La cronología del incidente, con todas las señales a la vez
SELECT ts, source, what
FROM
(
    SELECT valid_from AS ts, 'deploy' AS source, concat(deployment, ' ', version, ' (', change_id, ', ', author, ')') AS what
    FROM payflow_inventory.deployment_history WHERE valid_from BETWEEN pf_at('13:00') AND pf_at('15:00')
    UNION ALL
    SELECT ts, concat('alert ', state), concat(rule, ': ', summary) FROM payflow_sre.alerts WHERE ts BETWEEN pf_at('13:00') AND pf_at('15:00')
    UNION ALL
    SELECT min(toDateTime(Timestamp)), 'first error log', any(Body) FROM payflow_otel.otel_logs
    WHERE hasToken(lower(Body), 'hikaripool') AND SeverityText = 'ERROR' AND toDate(Timestamp) = pf_black_friday()
    UNION ALL
    SELECT max(toDateTime(Timestamp)), 'last error log', any(Body) FROM payflow_otel.otel_logs
    WHERE hasToken(lower(Body), 'hikaripool') AND SeverityText = 'ERROR' AND toDate(Timestamp) = pf_black_friday()
    UNION ALL
    SELECT toDateTime(Timestamp), 'k8s', concat(EventName, ': ', Body) FROM payflow_otel.otel_logs
    WHERE ServiceName = 'k8s-events' AND SeverityText = 'WARN' AND EventName != 'Unhealthy'
      AND Timestamp BETWEEN pf_at('13:00') AND pf_at('15:00')
)
ORDER BY ts;
-- Medido: 76 ms · 3,2 M filas leídas (31,4 MB) · 184,5 MB de memoria
-- Qué observar: despliegue 13:58, primer error 13:58, aviso 14:00, OOM 14:21,
-- marcha atrás 14:42, último error 14:44, resuelto 14:47. Tiempo de detección: 2 minutos.
-- Tiempo de mitigación: 44 minutos. El postmortem se escribe solo.


-- Checkpoint
SELECT
    if((SELECT argMax(SpanName, c) FROM (SELECT SpanName, count() AS c FROM payflow_otel.otel_traces
        WHERE StatusCode = 'Error' AND Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15') AND SpanKind = 'Client'
          AND SpanAttributes['rpc.system'] = ''
        GROUP BY SpanName)) = 'INSERT payflow.payments', 'OK', 'KO')                                                   AS root_cause_span,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE hasToken(lower(Body), 'maximumpoolsize') AND Body LIKE '%maximumPoolSize=10%') = 6, 'OK', 'KO') AS startup_clue,
    if((SELECT countIf(StatusCode = 'Error') FROM payflow_otel.otel_traces
        WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
          AND ResourceAttributes['service.version'] = 'v2.4.0' AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:42')) = 0, 'OK', 'KO') AS only_v241_fails
SETTINGS select_sequential_consistency = 1;
-- Medido: 509 ms · 901 152 filas leídas (6,1 MB) · 64,9 MB de memoria
