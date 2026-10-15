-- =====================================================================
--  MODULE 2 · Collection (3/4): traces and metrics over OTLP
-- =====================================================================
--  Traces and metrics leave the applications already structured: the OpenTelemetry
--  SDK sends them over OTLP (gRPC 4317, HTTP 4318) to the gateway, the ClickHouse
--  exporter writes them into otel_traces and otel_metrics_*. No parsing needed.
--  The gateway only adds context (the team, like the logs in file 02).
--  Metrics come from three places, all simulated here:
--    · the kubeletstats receiver of the agents: CPU and memory of every pod, every 15 s
--    · the application itself: the HikariCP connection pool, the Kafka consumer lag
--    · the k8s_cluster receiver: container restarts
--  The trace id lookup table (module 1 file 02) fills itself through its view.
-- =====================================================================


-- STEP 1 · The spans of the day, in 4 batches
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_s = 0, to_s = 28800);        -- 00:00 to 08:00
-- Measured: 8.12 s · 3.4 M rows read (156.6 MB) · 3.6 M rows written · 7.3 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_s = 28800, to_s = 50400);    -- 08:00 to 14:00
-- Measured: 7.95 s · 3.5 M rows read (161.5 MB) · 3.8 M rows written · 7.4 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_s = 50400, to_s = 68400);    -- 14:00 to 19:00
-- Measured: 12.7 s · 7.2 M rows read (327.9 MB) · 7.6 M rows written · 10 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_s = 68400, to_s = 86400);    -- 19:00 to 24:00
-- Measured: 14.2 s · 7.4 M rows read (339.6 MB) · 7.9 M rows written · 9.8 GB memory

SELECT count() AS spans, uniqExact(TraceId) AS traces, round(count() / uniqExact(TraceId), 1) AS spans_per_trace
FROM payflow_otel.otel_traces;
-- Measured: 308 ms · 21.5 M rows read (719.1 MB) · 720.6 MB memory


-- STEP 2 · Pod CPU and memory, every 15 seconds (kubeletstats)
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
FROM payflow_inventory.pod AS p
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
-- Measured: 1.34 s · 49 rows read (3.4 KB) · 426,240 rows written · 644.5 MB memory


-- STEP 3 · The HikariCP connection pool of each payment pod (the smoking gun)
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
FROM payflow_inventory.pod AS p
ARRAY JOIN range(0, 86400, 15) AS s
ARRAY JOIN [
    ('hikaricp.connections.max',     'Configured pool size', toFloat64(if(p.version = 'v2.4.1', 10, 50))),
    ('hikaricp.connections.active',  'Connections in use',
        if(p.version = 'v2.4.1' AND s >= 50580, 10, round(1 + pf_rate(s) / 8 + 2 * pf_r(cityHash64(p.pod_name), s)))),
    ('hikaricp.connections.pending', 'Threads waiting for a connection',
        if(p.version = 'v2.4.1' AND s >= 50580, round(pf_rate(s) * 1.4 * (0.8 + 0.4 * pf_r(cityHash64(p.pod_name, 'p'), s))), 0))] AS m
WHERE p.deployment = 'payment'
  AND addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Measured: 424 ms · 49 rows read (3.4 KB) · 103,680 rows written · 172.2 MB memory


-- STEP 4 · Kafka consumer lag and container restarts
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
-- Measured: 75 ms · 5,760 rows read (45 KB) · 5,760 rows written

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
FROM payflow_inventory.pod AS p
ARRAY JOIN range(0, 86400, 60) AS s
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Measured: 192 ms · 49 rows read (2.4 KB) · 53,280 rows written · 65.2 MB memory

SELECT MetricName, count() AS points, round(min(Value), 2) AS min_value, round(max(Value), 2) AS max_value
FROM payflow_otel.otel_metrics_gauge
GROUP BY MetricName
ORDER BY MetricName;
-- Measured: 15 ms · 535,680 rows read (18.3 MB) · 60.3 MB memory


-- STEP 5 · The three signals, side by side, for one minute of the incident
SELECT 'logs' AS signal, count() AS records FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'spans', count() FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'metric points', count() FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix >= '2026-11-27 14:10:00' AND TimeUnix < '2026-11-27 14:11:00';
-- Measured: 246 ms · 4.3 M rows read (32.9 MB) · 74.6 MB memory


-- STEP 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_traces) > 14000000, 'OK', 'KO')                                   AS spans,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'hikaricp.connections.pending') > 20, 'OK', 'KO') AS pool_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_sum WHERE MetricName = 'k8s.container.restarts') = 1, 'OK', 'KO')         AS restart_story,
    -- every log line that carries a trace id points to a span that exists
    if((SELECT count() FROM (SELECT TraceId FROM payflow_otel.otel_logs WHERE TraceId != '' AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:10' LIMIT 1000)
        WHERE TraceId NOT IN (SELECT TraceId FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN '2026-11-27 14:09:50' AND '2026-11-27 14:10:20')) = 0, 'OK', 'KO') AS logs_to_traces
SETTINGS select_sequential_consistency = 1;
-- Measured: 203 ms · 4.1 M rows read (42.4 MB) · 235.9 MB memory
