-- =====================================================================
--  MÓDULO 3 · Silver: trazas y métricas
-- =====================================================================
--  Las trazas y las métricas no pasan por bronze: el collector OpenTelemetry
--  ya las envía estructuradas (OTLP) y el exportador las escribe directamente
--  en otel_traces y otel_metrics_*. Hacemos lo mismo con el simulador.
--  Después construimos en SQL lo que normalmente calcula un collector:
--    · histogramas de latencia a partir de los spans (el conector "spanmetrics")
--    · CPU y memoria de los pods cada 15 s (el receiver "kubeletstats")
--    · métricas de aplicación: pool HikariCP, consumer lag de Kafka, reinicios
-- =====================================================================


-- PASO 1 · Los spans del día, en 4 lotes
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 0, to_s = 28800);        -- de 00:00 a 08:00
-- Medido: 5,5 s · 28 800 filas leídas (225 KB) · 2,3 M filas escritas · 5,3 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 28800, to_s = 50400);    -- de 08:00 a 14:00
-- Medido: 5,39 s · 21 600 filas leídas (168,8 KB) · 2,4 M filas escritas · 5,6 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 50400, to_s = 68400);    -- de 14:00 a 19:00
-- Medido: 8,04 s · 18 000 filas leídas (140,6 KB) · 4,8 M filas escritas · 9 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 68400, to_s = 86400);    -- de 19:00 a 24:00
-- Medido: 9,25 s · 18 000 filas leídas (140,6 KB) · 5 M filas escritas · 8,2 GB de memoria

SELECT count() AS spans, uniqExact(TraceId) AS traces, round(count() / uniqExact(TraceId), 1) AS spans_per_trace
FROM payflow_otel.otel_traces;
-- Medido: 288 ms · 14,6 M filas leídas (486,5 MB) · 506,5 MB de memoria


-- PASO 2 · Histogramas de latencia por servicio y span, cada minuto (spanmetrics)
--  Un histograma OpenTelemetry guarda, para cada intervalo, el recuento por bucket
--  (BucketCounts) para unos límites fijos (ExplicitBounds), más count, sum, min y max.
--  El exemplar guarda el trace id de la petición más lenta del minuto: desde un
--  gráfico de latencia saltas directamente a la traza culpable (módulo 8).
INSERT INTO payflow_otel.otel_metrics_histogram
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix,
     Count, Sum, BucketCounts, ExplicitBounds, `Exemplars.FilteredAttributes`, `Exemplars.TimeUnix`, `Exemplars.Value`,
     `Exemplars.SpanId`, `Exemplars.TraceId`, Min, Max, AggregationTemporality)
WITH [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] AS bounds
SELECT
    map('service.name', ServiceName, 'k8s.cluster.name', 'payflow-prod-eu')                            AS ResourceAttributes,
    ServiceName,
    'http.server.request.duration'                                                                     AS MetricName,
    'Duration of server spans, computed from the traces'                                               AS MetricDescription,
    's'                                                                                                AS MetricUnit,
    map('span.name', SpanName, 'span.kind', 'SPAN_KIND_SERVER', 'status.code', if(StatusCode = 'Error', 'STATUS_CODE_ERROR', 'STATUS_CODE_UNSET')) AS Attributes,
    toDateTime64(minute, 9, 'UTC')                                                                     AS StartTimeUnix,
    toDateTime64(minute + 60, 9, 'UTC')                                                                AS TimeUnix,
    count()                                                                                            AS Count,
    sum(Duration / 1e9)                                                                                AS Sum,
    sumForEach(arrayMap(b -> toUInt64(b = arrayFirstIndex(x -> Duration / 1e9 <= x, bounds)), range(1, 13))) AS BucketCounts,
    bounds                                                                                             AS ExplicitBounds,
    [map()]                                                                                            AS `Exemplars.FilteredAttributes`,
    [argMax(Timestamp, Duration)]                                                                      AS `Exemplars.TimeUnix`,
    [max(Duration) / 1e9]                                                                              AS `Exemplars.Value`,
    [argMax(SpanId, Duration)]                                                                         AS `Exemplars.SpanId`,
    [argMax(TraceId, Duration)]                                                                        AS `Exemplars.TraceId`,
    min(Duration / 1e9)                                                                                AS Min,
    max(Duration / 1e9)                                                                                AS Max,
    1                                                                                                  AS AggregationTemporality   -- delta: cada fila cubre su propio minuto
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY ServiceName, SpanName, StatusCode, toStartOfMinute(toDateTime(Timestamp)) AS minute;
-- Medido: 668 ms · 14,6 M filas leídas (631,5 MB) · 23 350 filas escritas · 374,4 MB de memoria
-- Atención: arrayFirstIndex devuelve 0 cuando el valor supera el último límite: en ese caso
-- ningún b de 1..12 coincide. Aquí ningún span pasa de 10 s: todos caen en un bucket.


-- PASO 3 · CPU y memoria de los pods, cada 15 segundos (kubeletstats)
--  La carga sigue al tráfico. En estas cifras se esconden dos historias:
--    · los pods payment en v2.4.1 usan MENOS CPU: sus hilos esperan una conexión
--    · el pod fraud-scoring de ip-10-0-3-17 crece desde las 14:05 (reintentos) hasta
--      su límite de 2 GiB, lo matan a las 14:21:07 y se reinicia a las 14:21:52
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', p.deployment, 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name)                                          AS ResourceAttributes,
    p.deployment                                                                                          AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    m.3                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    addSeconds(day0, s)                                                                                   AS StartTimeUnix,
    addSeconds(day0, s)                                                                                   AS TimeUnix,
    m.4                                                                                                   AS Value
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 15) AS s
ARRAY JOIN [
    ('k8s.pod.cpu.utilization', 'CPU used, as a share of the pod limit', '1',
     least(0.98, (0.08 + 0.5 * pf_rate(s) / 40 * if(p.version = 'v2.4.1', 0.45, 1)
                  * if(p.deployment = 'fraud-scoring' AND s >= 50700 AND s < 53100, 2.2, 1)) * (0.9 + 0.2 * pf_r(cityHash64(p.pod_name), s)))),
    ('k8s.pod.memory.working_set', 'Memory working set of the pod', 'By',
     multiIf(p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 50700 AND s < 51667,
                 (900 + (s - 50700) / 967 * 1240) * 1048576,                        -- de 900 MiB a 2,1 GiB en 16 minutos
             p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 51667 AND s < 51712, 0,   -- matado, reiniciando
             p.deployment = 'fraud-scoring', (700 + 200 * least(1, greatest(0, (s - 51712) / 600.0) + if(p.slot = 2, 0, 1))) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), s)),
             p.deployment IN ('payment', 'card-network-adapter', 'ledger'), (1400 + 300 * pf_rate(s) / 40) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), s)),
             (180 + 60 * pf_rate(s) / 40) * 1048576 * (0.95 + 0.1 * pf_r(cityHash64(p.pod_name), s))))] AS m
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Medido: 1,29 s · 49 filas leídas (3,4 KB) · 426 240 filas escritas · 644,5 MB de memoria


-- PASO 4 · El pool de conexiones HikariCP de cada pod payment (la prueba del delito)
--  max es el tamaño configurado: 50 en v2.4.0, 10 en v2.4.1. Cuando el pool está
--  lleno, las peticiones hacen cola (pending) y abandonan a los 3 s.
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', 'payment', 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', 'payment', 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name),
    'payment', m.1, m.2, '{connection}', map('pool', 'HikariPool-1'),
    addSeconds(day0, s), addSeconds(day0, s), m.3
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 15) AS s
ARRAY JOIN [
    ('hikaricp.connections.max',     'Configured pool size', toFloat64(if(p.version = 'v2.4.1', 10, 50))),
    ('hikaricp.connections.active',  'Connections in use',
        if(p.version = 'v2.4.1' AND s >= 50580, 10, round(1 + pf_rate(s) / 8 + 2 * pf_r(cityHash64(p.pod_name), s)))),
    ('hikaricp.connections.pending', 'Threads waiting for a connection',
        if(p.version = 'v2.4.1' AND s >= 50580, round(pf_rate(s) * 1.4 * (0.8 + 0.4 * pf_r(cityHash64(p.pod_name, 'p'), s))), 0))] AS m
WHERE p.deployment = 'payment'
  AND addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Medido: 389 ms · 49 filas leídas (3,4 KB) · 103 680 filas escritas · 172,2 MB de memoria


-- PASO 5 · Consumer lag de Kafka y reinicios de contenedores
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', 'notification', 'k8s.cluster.name', 'payflow-prod-eu'), 'notification',
    'kafka.consumer.lag', 'Messages not yet processed by the consumer group', '{message}',
    map('messaging.destination.name', 'payment.events', 'messaging.consumer.group.name', 'notification'),
    addSeconds(day0, s), addSeconds(day0, s),
    round(pf_rate(s) * 4 * (0.5 + pf_r(s, 'lag')))
FROM numbers(5760) ARRAY JOIN [toUInt32(number * 15)] AS s;
-- Medido: 82 ms · 5 760 filas leídas (45 KB) · 5 760 filas escritas

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', p.deployment, 'k8s.cluster.name', 'payflow-prod-eu', 'k8s.namespace.name', p.namespace,
        'k8s.pod.name', p.pod_name, 'k8s.node.name', p.node_name),
    p.deployment, 'k8s.container.restarts', 'Restarts of the container since the pod started', '{restart}', map(),
    toDateTime64(p.started_at, 9, 'UTC'), addSeconds(day0, s),
    if(p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 51712, 1, 0),
    2, true   -- acumulativo y monótono: un contador que solo sube
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 60) AS s
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Medido: 168 ms · 49 filas leídas (2,4 KB) · 53 280 filas escritas · 65,2 MB de memoria

SELECT MetricName, count() AS points, round(min(Value), 2) AS min_value, round(max(Value), 2) AS max_value
FROM payflow_otel.otel_metrics_gauge
GROUP BY MetricName
ORDER BY MetricName;
-- Medido: 16 ms · 535 680 filas leídas (18,3 MB) · 65,5 MB de memoria


-- PASO 6 · Las tres señales, lado a lado, durante un minuto del incidente
SELECT 'logs' AS signal, count() AS records FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'spans', count() FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'metric points', count() FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix >= '2026-11-27 14:10:00' AND TimeUnix < '2026-11-27 14:11:00';
-- Medido: 197 ms · 6,7 M filas leídas (50,9 MB) · 78,8 MB de memoria


-- PASO 7 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_traces) > 14000000, 'OK', 'KO')                                   AS spans,
    if((SELECT count() FROM payflow_otel.otel_metrics_histogram) > 10000, 'OK', 'KO')                         AS histograms,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'hikaricp.connections.pending') > 20, 'OK', 'KO') AS pool_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_sum WHERE MetricName = 'k8s.container.restarts') = 1, 'OK', 'KO')         AS restart_story,
    -- toda línea de log que lleva un trace id apunta a un span que existe
    if((SELECT count() FROM (SELECT TraceId FROM payflow_otel.otel_logs WHERE TraceId != '' AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:10' LIMIT 1000)
        WHERE TraceId NOT IN (SELECT TraceId FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN '2026-11-27 14:09:50' AND '2026-11-27 14:10:20')) = 0, 'OK', 'KO') AS logs_to_traces
SETTINGS select_sequential_consistency = 1;
-- Medido: 309 ms · 4,2 M filas leídas (39,3 MB) · 178,2 MB de memoria
