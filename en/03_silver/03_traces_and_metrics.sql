-- =====================================================================
--  MODULE 3 · Silver: traces and metrics
-- =====================================================================
--  Traces and metrics do not go through bronze: the OpenTelemetry collector
--  already sends them structured (OTLP), the exporter writes them straight
--  into otel_traces and otel_metrics_*. We do the same with the simulator.
--  Then we build in SQL what a collector usually computes:
--    · latency histograms from the spans (the "spanmetrics" connector)
--    · pod CPU and memory every 15 s (the "kubeletstats" receiver)
--    · application metrics: HikariCP pool, Kafka consumer lag, restarts
-- =====================================================================


-- STEP 1 · The spans of the day, in 4 batches
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 0, to_s = 28800);        -- 00:00 to 08:00
-- Measured: 5.5 s · 28,800 rows read (225 KB) · 2.3 M rows written · 5.3 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 28800, to_s = 50400);    -- 08:00 to 14:00
-- Measured: 5.39 s · 21,600 rows read (168.8 KB) · 2.4 M rows written · 5.6 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 50400, to_s = 68400);    -- 14:00 to 19:00
-- Measured: 8.04 s · 18,000 rows read (140.6 KB) · 4.8 M rows written · 9 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 68400, to_s = 86400);    -- 19:00 to 24:00
-- Measured: 9.25 s · 18,000 rows read (140.6 KB) · 5 M rows written · 8.2 GB memory

SELECT count() AS spans, uniqExact(TraceId) AS traces, round(count() / uniqExact(TraceId), 1) AS spans_per_trace
FROM payflow_otel.otel_traces;
-- Measured: 288 ms · 14.6 M rows read (486.5 MB) · 506.5 MB memory


-- STEP 2 · Latency histograms per service and span, every minute (spanmetrics)
--  An OpenTelemetry histogram stores, for each interval, the count per bucket
--  (BucketCounts) for fixed bounds (ExplicitBounds), plus count, sum, min, max.
--  The exemplar keeps the trace id of the slowest request of the minute: from a
--  latency chart you can jump straight to the guilty trace (module 8).
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
    1                                                                                                  AS AggregationTemporality   -- delta: each row covers its own minute
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY ServiceName, SpanName, StatusCode, toStartOfMinute(toDateTime(Timestamp)) AS minute;
-- Measured: 668 ms · 14.6 M rows read (631.5 MB) · 23,350 rows written · 374.4 MB memory
-- Watch out: arrayFirstIndex returns 0 when the value is above the last bound: in that
-- case no b in 1..12 matches. Here no span is longer than 10 s, so every span lands in a bucket.


-- STEP 3 · Pod CPU and memory, every 15 seconds (kubeletstats)
--  Load follows the traffic. Two stories hide in these numbers:
--    · the v2.4.1 payment pods use LESS CPU: their threads wait for a connection
--    · the fraud-scoring pod on ip-10-0-3-17 grows from 14:05 (retries) up to its
--      2 GiB limit, is killed at 14:21:07, restarts at 14:21:52
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
                 (900 + (s - 50700) / 967 * 1240) * 1048576,                        -- 900 MiB to 2.1 GiB in 16 minutes
             p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 51667 AND s < 51712, 0,   -- killed, restarting
             p.deployment = 'fraud-scoring', (700 + 200 * least(1, greatest(0, (s - 51712) / 600.0) + if(p.slot = 2, 0, 1))) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), s)),
             p.deployment IN ('payment', 'card-network-adapter', 'ledger'), (1400 + 300 * pf_rate(s) / 40) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), s)),
             (180 + 60 * pf_rate(s) / 40) * 1048576 * (0.95 + 0.1 * pf_r(cityHash64(p.pod_name), s))))] AS m
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Measured: 1.29 s · 49 rows read (3.4 KB) · 426,240 rows written · 644.5 MB memory


-- STEP 4 · The HikariCP connection pool of each payment pod (the smoking gun)
--  max is the configured size: 50 in v2.4.0, 10 in v2.4.1. When the pool is
--  full, requests queue (pending) and give up after 3 s.
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
-- Measured: 389 ms · 49 rows read (3.4 KB) · 103,680 rows written · 172.2 MB memory


-- STEP 5 · Kafka consumer lag and container restarts
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
-- Measured: 82 ms · 5,760 rows read (45 KB) · 5,760 rows written

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
    2, true   -- cumulative and monotonic: a counter that only goes up
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 60) AS s
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Measured: 168 ms · 49 rows read (2.4 KB) · 53,280 rows written · 65.2 MB memory

SELECT MetricName, count() AS points, round(min(Value), 2) AS min_value, round(max(Value), 2) AS max_value
FROM payflow_otel.otel_metrics_gauge
GROUP BY MetricName
ORDER BY MetricName;
-- Measured: 16 ms · 535,680 rows read (18.3 MB) · 65.5 MB memory


-- STEP 6 · The three signals, side by side, for one minute of the incident
SELECT 'logs' AS signal, count() AS records FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'spans', count() FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'metric points', count() FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix >= '2026-11-27 14:10:00' AND TimeUnix < '2026-11-27 14:11:00';
-- Measured: 197 ms · 6.7 M rows read (50.9 MB) · 78.8 MB memory


-- STEP 7 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_traces) > 14000000, 'OK', 'KO')                                   AS spans,
    if((SELECT count() FROM payflow_otel.otel_metrics_histogram) > 10000, 'OK', 'KO')                         AS histograms,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'hikaricp.connections.pending') > 20, 'OK', 'KO') AS pool_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_sum WHERE MetricName = 'k8s.container.restarts') = 1, 'OK', 'KO')         AS restart_story,
    -- every log line that carries a trace id points to a span that exists
    if((SELECT count() FROM (SELECT TraceId FROM payflow_otel.otel_logs WHERE TraceId != '' AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:10' LIMIT 1000)
        WHERE TraceId NOT IN (SELECT TraceId FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN '2026-11-27 14:09:50' AND '2026-11-27 14:10:20')) = 0, 'OK', 'KO') AS logs_to_traces
SETTINGS select_sequential_consistency = 1;
-- Measured: 309 ms · 4.2 M rows read (39.3 MB) · 178.2 MB memory
