-- =====================================================================
--  MODULE 2 · Collection (3/4): traces and metrics over OTLP
-- =====================================================================
--  Traces and metrics leave the applications already structured: the OpenTelemetry
--  SDK sends them over OTLP (gRPC 4317, HTTP 4318) to the gateway, the ClickHouse
--  exporter writes them into otel_traces and otel_metrics_*. No parsing needed.
--  The gateway only adds context (the team, like the logs in file 02).
--  Metrics come from three places, all simulated here:
--    · the kubeletstats receiver of the agents: CPU, memory and disk of every pod and node
--    · the k8s_cluster receiver: pod and namespace phases, node readiness, restarts
--    · the application itself: the HikariCP connection pool, the Kafka consumer lag
--  The trace id lookup table (module 1 file 02) fills itself through its view.
-- =====================================================================


-- STEP 1 · The spans of the month: 3 batches of ordinary days, then Black Friday
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_day(-29), to_t = pf_day(-19));
-- Measured: 32 s · 16.5 M rows read (720.5 MB) · 16.6 M rows written · 10.5 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_day(-19), to_t = pf_day(-9));
-- Measured: 30.5 s · 16.4 M rows read (719.7 MB) · 16.6 M rows written · 10.2 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_day(-9), to_t = pf_day(0));
-- Measured: 29.4 s · 15.1 M rows read (661.6 MB) · 15.2 M rows written · 10.5 GB memory
--  Black Friday
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_at('00:00'), to_t = pf_at('12:00'));
-- Measured: 10.7 s · 5.5 M rows read (248.8 MB) · 5.8 M rows written · 9.2 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_at('12:00'), to_t = pf_at('18:00'));
-- Measured: 13 s · 7.1 M rows read (321.8 MB) · 7.5 M rows written · 9.5 GB memory
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_at('18:00'), to_t = pf_day(1));
-- Measured: 16.3 s · 9.1 M rows read (415.1 MB) · 9.6 M rows written · 10 GB memory

SELECT if(toDate(Timestamp) = pf_black_friday(), 'Black Friday', 'ordinary days') AS days,
       uniqExact(toDate(Timestamp)) AS day_count,
       count() AS spans, uniqExact(TraceId) AS traces, round(count() / uniqExact(TraceId), 1) AS spans_per_trace
FROM payflow_otel.otel_traces
GROUP BY days;
-- Measured: 1.19 s · 67 M rows read (2.7 GB) · 844 MB memory


-- STEP 2 · The metric generators, as parameterized views
--  They follow the names of the OpenTelemetry receivers, which is what ClickStack's
--  Kubernetes dashboard and Infrastructure tab look for:
--    · kubeletstats: k8s.pod.cpu.utilization, k8s.pod.memory.usage, their
--      *_limit_utilization, k8s.pod.filesystem.available, the same for each node
--    · k8s_cluster: k8s.pod.phase, k8s.container.restarts, k8s.node.condition_ready,
--      k8s.namespace.phase
--  Every 30 s, the default bucket of ClickStack's Infrastructure charts.
--    · the application: the HikariCP connection pool, the Kafka consumer lag
--  Load follows the traffic of each moment (pf_rate_at). Stories hide in these numbers:
--    · the v2.4.1 payment pods use LESS CPU: their threads wait for a connection
--    · the fraud-scoring pod on ip-10-0-3-17 grows from 14:05 (retries) up to its
--      2 GiB limit, is killed at 14:21:07, restarts at 14:21:52; its small node runs
--      out of memory at the same time
--  ts is a point every 30 s, s its second of the day, bf whether it is Black Friday.

--  Every running pod, every 30 s: CPU, memory, disk, phase, restarts
CREATE OR REPLACE VIEW payflow_sim.pod_metrics AS
SELECT
    map('service.name', p.deployment, 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name)                                          AS ResourceAttributes,
    p.deployment                                                                                          AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    m.3                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    toDateTime64(t, 9, 'UTC')                                                                             AS StartTimeUnix,
    toDateTime64(t, 9, 'UTC')                                                                             AS TimeUnix,
    m.4                                                                                                   AS Value
FROM payflow_inventory.pod AS p
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30) * 30, toUnixTimestamp({to_t:DateTime}), 30) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t
ARRAY JOIN [toUInt32(ts % 86400)] AS s
ARRAY JOIN [toDate(t) = pf_black_friday()] AS bf
ARRAY JOIN [multiIf(p.deployment = 'fraud-scoring', 2048, p.deployment IN ('payment', 'card-network-adapter', 'ledger'), 2560, 512)] AS limit_mib
ARRAY JOIN [least(0.98, (0.08 + 0.5 * pf_rate_at(t) / 40 * if(p.version = 'v2.4.1', 0.45, 1)
                   * if(p.deployment = 'fraud-scoring' AND bf AND s >= 50700 AND s < 53100, 2.2, 1)) * (0.9 + 0.2 * pf_r(cityHash64(p.pod_name), ts)))] AS cpu
ARRAY JOIN [multiIf(p.deployment = 'fraud-scoring' AND p.slot = 2 AND bf AND s >= 50700 AND s < 51667,
                        (900 + (s - 50700) / 967 * 1240) * 1048576,                        -- 900 MiB to 2.1 GiB in 16 minutes
                    p.deployment = 'fraud-scoring' AND p.slot = 2 AND bf AND s >= 51667 AND s < 51712, 0,   -- killed, restarting
                    p.deployment = 'fraud-scoring' AND p.slot = 2 AND bf AND s >= 51712,
                        (700 + 200 * least(1, (s - 51712) / 600.0)) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), ts)),
                    p.deployment = 'fraud-scoring', 900 * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), ts)),
                    p.deployment IN ('payment', 'card-network-adapter', 'ledger'),
                        (1400 + 300 * pf_rate_at(t) / 40) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), ts)),
                    (180 + 60 * pf_rate_at(t) / 40) * 1048576 * (0.95 + 0.1 * pf_r(cityHash64(p.pod_name), ts)))] AS mem
ARRAY JOIN [
    ('k8s.pod.cpu.utilization',          'CPU used, in cores', '1', cpu),
    ('k8s.pod.cpu_limit_utilization',    'CPU used, as a share of the pod limit (1 core)', '1', cpu),
    ('k8s.pod.memory.usage',             'Memory used by the pod', 'By', mem),
    ('k8s.pod.memory_limit_utilization', 'Memory used, as a share of the pod limit', '1', mem / (limit_mib * 1048576)),
    ('k8s.pod.phase',                    'Pod phase: 1 Pending, 2 Running, 3 Succeeded, 4 Failed', '1', 2),
    ('k8s.pod.filesystem.available',     'Free space on the pod volume', 'By', (8192 - 300 * pf_r(p.pod_name, toDate(t))) * 1048576),
    ('k8s.container.restarts',           'Restarts of the container since the pod started', '{restart}',
        toFloat64(p.deployment = 'fraud-scoring' AND p.slot = 2 AND pf_at('14:21:52') BETWEEN p.started_at AND p.stopped_at
                  AND t >= pf_at('14:21:52')))] AS m
WHERE t >= p.started_at AND t <= p.stopped_at;

--  Every node, from the pods it runs: CPU (cores used / cores), memory (system + pods)
--  The smallest node, ip-10-0-3-17, is crowded: 10.3 GiB of its 16 GiB are taken by
--  the system and the node agents, which is why it runs out of memory first.
CREATE OR REPLACE VIEW payflow_sim.node_metrics AS
SELECT
    map('k8s.cluster.name', 'payflow-prod-eu', 'k8s.node.name', node, 'cloud.availability_zone', pf_zone(node)) AS ResourceAttributes,
    ''                                                                                                    AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    m.3                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    TimeUnix                                                                                              AS StartTimeUnix,
    TimeUnix,
    m.4                                                                                                   AS Value
FROM
(
    SELECT ResourceAttributes['k8s.node.name'] AS node, TimeUnix,
           sumIf(Value, MetricName = 'k8s.pod.cpu.utilization')  AS pods_cpu,
           sumIf(Value, MetricName = 'k8s.pod.memory.usage')     AS pods_mem
    FROM payflow_sim.pod_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
    WHERE MetricName IN ('k8s.pod.cpu.utilization', 'k8s.pod.memory.usage')
    GROUP BY node, TimeUnix
)
ARRAY JOIN [dictGet('payflow_inventory.dict_node', 'memory_gib', node)] AS mem_gib
ARRAY JOIN [toUInt8(if(node = 'ip-10-0-3-17', 4, 8))] AS cores
ARRAY JOIN [
    ('k8s.node.cpu.utilization',      'CPU used, as a share of the node', '1', least(0.97, (0.3 + pods_cpu) / cores)),
    ('k8s.node.memory.usage',         'Memory used on the node', 'By',
        (if(node = 'ip-10-0-3-17', 10.3, mem_gib * 0.25) * 1073741824 + pods_mem)),
    ('k8s.node.filesystem.available', 'Free space on the node disk', 'By', (61440 - 2000 * pf_r(node, toDate(TimeUnix))) * 1048576),
    ('k8s.node.condition_ready',      'Node is Ready (1) or not (0)', '1', 1)] AS m;

--  The HikariCP connection pool of each payment pod (the smoking gun)
--  max is the configured size: 50 in v2.4.0, 10 in v2.4.1. When the pool is
--  full, requests queue (pending) and give up after 3 s.
CREATE OR REPLACE VIEW payflow_sim.pool_metrics AS
SELECT
    map('service.name', 'payment', 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', 'payment', 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name)                                          AS ResourceAttributes,
    'payment'                                                                                             AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    '{connection}'                                                                                        AS MetricUnit,
    map('pool', 'HikariPool-1')                                                                           AS Attributes,
    toDateTime64(t, 9, 'UTC')                                                                             AS StartTimeUnix,
    toDateTime64(t, 9, 'UTC')                                                                             AS TimeUnix,
    m.3                                                                                                   AS Value
FROM payflow_inventory.pod AS p
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30) * 30, toUnixTimestamp({to_t:DateTime}), 30) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t
ARRAY JOIN [
    ('hikaricp.connections.max',     'Configured pool size', toFloat64(if(p.version = 'v2.4.1', 10, 50))),
    ('hikaricp.connections.active',  'Connections in use',
        if(p.version = 'v2.4.1' AND t >= pf_at('14:03'), 10, round(1 + pf_rate_at(t) / 8 + 2 * pf_r(cityHash64(p.pod_name), ts)))),
    ('hikaricp.connections.pending', 'Threads waiting for a connection',
        if(p.version = 'v2.4.1' AND t >= pf_at('14:03'), round(pf_rate_at(t) * 1.4 * (0.8 + 0.4 * pf_r(cityHash64(p.pod_name, 'p'), ts))), 0))] AS m
WHERE p.deployment = 'payment' AND t >= p.started_at AND t <= p.stopped_at;

--  Everything that goes to otel_metrics_gauge, in one view: pods, nodes, pools,
--  namespaces (k8s_cluster) and the Kafka consumer lag of notification
CREATE OR REPLACE VIEW payflow_sim.gauge_metrics AS
SELECT * FROM payflow_sim.pod_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
UNION ALL
SELECT * FROM payflow_sim.node_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
UNION ALL
SELECT * FROM payflow_sim.pool_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
UNION ALL
SELECT map('k8s.cluster.name', 'payflow-prod-eu', 'k8s.namespace.name', ns), '', 'k8s.namespace.phase',
       'Namespace phase: 1 Active, 0 Terminating', '1', map(), toDateTime64(t, 9, 'UTC'), toDateTime64(t, 9, 'UTC'), 1
FROM numbers(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30), greatest(0, intDiv(toUnixTimestamp({to_t:DateTime}) + 29, 30) - intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30)))
ARRAY JOIN [toDateTime(number * 30, 'UTC')] AS t
ARRAY JOIN ['edge', 'payments', 'risk'] AS ns
UNION ALL
SELECT map('service.name', 'notification', 'k8s.cluster.name', 'payflow-prod-eu'), 'notification',
       'kafka.consumer.lag', 'Messages not yet processed by the consumer group', '{message}',
       map('messaging.destination.name', 'payment.events', 'messaging.consumer.group.name', 'notification'),
       toDateTime64(t, 9, 'UTC'), toDateTime64(t, 9, 'UTC'),
       round(pf_rate_at(t) * 4 * (0.5 + pf_r(toInt64(number) - intDiv(toInt64(toUnixTimestamp(pf_day(0))), 30), 'lag')))
FROM numbers(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30), greatest(0, intDiv(toUnixTimestamp({to_t:DateTime}) + 29, 30) - intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30)))
ARRAY JOIN [toDateTime(number * 30, 'UTC')] AS t;

--  Cumulative counters for otel_metrics_sum: how long each pod and node has been up
CREATE OR REPLACE VIEW payflow_sim.sum_metrics AS
SELECT
    map('service.name', p.deployment, 'k8s.cluster.name', 'payflow-prod-eu', 'k8s.namespace.name', p.namespace,
        'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name, 'k8s.pod.uid', p.pod_uid,
        'k8s.node.name', p.node_name)                                                                     AS ResourceAttributes,
    p.deployment                                                                                          AS ServiceName,
    'k8s.pod.uptime'                                                                                      AS MetricName,
    'Time since the pod started'                                                                          AS MetricDescription,
    's'                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    toDateTime64(p.started_at, 9, 'UTC')                                                                  AS StartTimeUnix,
    toDateTime64(t, 9, 'UTC')                                                                             AS TimeUnix,
    toFloat64(dateDiff('second', p.started_at, t))                                                        AS Value,
    2                                                                                                     AS AggregationTemporality,   -- cumulative
    true                                                                                                  AS IsMonotonic
FROM payflow_inventory.pod AS p
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 59, 60) * 60, toUnixTimestamp({to_t:DateTime}), 60) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t
WHERE t >= p.started_at AND t <= p.stopped_at
UNION ALL
SELECT map('k8s.cluster.name', 'payflow-prod-eu', 'k8s.node.name', n.node_name), '', 'k8s.node.uptime',
       'Time since the node started', 's', map(), toDateTime64(pf_day(-45), 9, 'UTC'), toDateTime64(t, 9, 'UTC'),
       toFloat64(dateDiff('second', pf_day(-45), t)), 2, true
FROM payflow_inventory.node AS n
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 59, 60) * 60, toUnixTimestamp({to_t:DateTime}), 60) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t;


-- STEP 3 · Send the metrics of the month
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = pf_day(-29), to_t = pf_day(-19));
-- Measured: 15.2 s · 57,823 rows read (464.8 KB) · 9.5 M rows written · 9.5 GB memory
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = pf_day(-19), to_t = pf_day(-9));
-- Measured: 14.8 s · 57,823 rows read (464.8 KB) · 9.5 M rows written · 9.7 GB memory
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = pf_day(-9), to_t = pf_day(1));
-- Measured: 14.9 s · 57,823 rows read (464.8 KB) · 9.5 M rows written · 9.4 GB memory

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
SELECT * FROM payflow_sim.sum_metrics(from_t = pf_day(-29), to_t = pf_day(1));
-- Measured: 6.53 s · 87 rows read (4.8 KB) · 2.1 M rows written · 2.4 GB memory

SELECT MetricName, count() AS points, round(min(Value), 2) AS min_value, round(max(Value), 2) AS max_value
FROM payflow_otel.otel_metrics_gauge
GROUP BY MetricName
ORDER BY MetricName;
-- Measured: 228 ms · 28.4 M rows read (949.5 MB) · 300.6 MB memory


-- STEP 4 · The three signals, side by side, for one minute of the incident
SELECT 'logs' AS signal, count() AS records FROM payflow_otel.otel_logs
WHERE Timestamp >= pf_at('14:10') AND Timestamp < pf_at('14:11')
UNION ALL
SELECT 'spans', count() FROM payflow_otel.otel_traces
WHERE Timestamp >= pf_at('14:10') AND Timestamp < pf_at('14:11')
UNION ALL
SELECT 'metric points', count() FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix >= pf_at('14:10') AND TimeUnix < pf_at('14:11');
-- Measured: 56 ms · 5.4 M rows read (41.4 MB) · 61.2 MB memory


-- STEP 5 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_traces) > 60000000, 'OK', 'KO')                                   AS spans,
    if((SELECT count() FROM (SELECT toDate(Timestamp) AS d FROM payflow_otel.otel_traces WHERE Timestamp < pf_day(1) GROUP BY d HAVING count() > 1000000)) = 30, 'OK', 'KO') AS thirty_days,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'hikaricp.connections.pending') > 20, 'OK', 'KO') AS pool_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'k8s.container.restarts') = 1, 'OK', 'KO')       AS restart_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'k8s.node.memory.usage'
        AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17') > 16 * 1073741824, 'OK', 'KO')                              AS node_pressure,
    -- every log line that carries a trace id points to a span that exists
    if((SELECT count() FROM (SELECT TraceId FROM payflow_otel.otel_logs WHERE TraceId != '' AND Timestamp BETWEEN pf_at('14:10:00') AND pf_at('14:10:10') LIMIT 1000)
        WHERE TraceId NOT IN (SELECT TraceId FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN pf_at('14:09:50') AND pf_at('14:10:20'))) = 0, 'OK', 'KO') AS logs_to_traces
SETTINGS select_sequential_consistency = 1;
-- Measured: 652 ms · 84.2 M rows read (966.6 MB) · 235.9 MB memory
