-- =====================================================================
--  MODULE 3 · Correlation scenarios: three ways into the same incident
-- =====================================================================
--  An investigation can start from any signal. The on-call engineer rarely chooses:
--    · scenario A starts from a LOG: a merchant calls support about one payment
--    · scenario B starts from a METRIC ALERT: the connection pool of a pod saturates
--    · scenario C starts from a TRACE: a new kind of error appears in the waterfalls
--  Each one walks the other signals until it reaches a cause. Three keys do the work:
--    · TraceId links a log line to its trace (and back)
--    · the resource attributes (k8s.pod.name, k8s.node.name, service.version) link
--      logs and traces to the metrics of the pod and of the node
--    · time: every query is bounded, and the trace lookup table gives the bounds
--  The README of this module walks the same three paths in ClickStack, by clicks.
-- =====================================================================


-- =====================================================================
--  SCENARIO A · Log → trace → metrics → log
--  14:12, a ticket: "merchant m_16523, a payment failed just after 14:09". All you have
--  is a merchant id. The checkout logs carry it as an attribute.
-- =====================================================================

-- STEP A1 · The log line: search the merchant id in the log attributes
--  In ClickStack: LogAttributes.merchant_id:m_16523 SeverityText:ERROR
--  LogAttributeItems turns each pair into 'key=value': its text index answers the filter.
SELECT Timestamp, ServiceName, Body, LogAttributes['payment_id'] AS payment_id, TraceId
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
  AND has(LogAttributeItems, 'merchant_id=m_16523')
  AND SeverityText = 'ERROR';
-- Measured: 20 ms · 65,537 rows read (2 MB)
-- What to look for: one line, "payment failed: payment service returned 503", and its TraceId.
-- checkout only reports the error of another service: the log does not say why.

-- STEP A2 · The trace: every span of that request, in order
--  The trace lookup table (module 1) gives the start and end of the trace, so the
--  scan of otel_traces is bounded to a few seconds instead of the whole day.
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS bounds
SELECT
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1) AS start_ms,
    round(Duration / 1e6, 1)                                                     AS duration_ms,
    ServiceName, SpanKind, SpanName, StatusCode, StatusMessage,
    ResourceAttributes['k8s.pod.name']                                           AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN bounds.1 AND bounds.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Measured: 56 ms · 106,497 rows read (6 MB)
-- What to look for: the error is born in payment, on INSERT payflow.payments: 3 seconds
-- waiting for a connection, "HikariPool-1 - Connection is not available". The pod column
-- names the payment pod that served the request: the next step looks at its metrics.

-- STEP A3 · The metrics of that pod, minute by minute
--  The same pod name is a resource attribute of the gauges (kubeletstats and HikariCP).
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE TraceId = tid AND StatusCode = 'Error'
       AND Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')) AS failing_pod
SELECT
    toStartOfMinute(toDateTime(TimeUnix))                                        AS minute,
    failing_pod                                                                  AS pod,
    round(avgIf(Value, MetricName = 'k8s.pod.cpu.utilization'), 2)               AS cpu,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'))              AS pool_active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.max'))                 AS pool_max,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'))             AS pool_pending
FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix BETWEEN pf_at('14:05') AND pf_at('14:10:59')
  AND ResourceAttributes['k8s.pod.name'] = failing_pod
GROUP BY minute
ORDER BY minute;
-- Measured: 59 ms · 190,913 rows read (9.7 MB)
-- What to look for: the pod is not busy (low CPU). Its pool is full (active = max) and
-- dozens of requests wait for a connection. And the pool max is 10, not 50.

-- STEP A4 · Back to the logs: what the pod said when it started
--  Why 10? The pod logs its pool configuration at startup.
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE TraceId = tid AND StatusCode = 'Error'
       AND Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')) AS failing_pod
SELECT Timestamp, ResourceAttributes['service.version'] AS version, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('13:50') AND pf_at('14:10')
  AND ResourceAttributes['k8s.pod.name'] = failing_pod
  AND hasAllTokens(lower(Body), ['maximumpoolsize']);
-- Measured: 52 ms · 90,113 rows read (4.8 MB)
-- What to look for: "maximumPoolSize=10", logged by a v2.4.1 pod started a few minutes
-- before the ticket. One merchant id led to the release that broke payments.


-- =====================================================================
--  SCENARIO B · Metric alert → metric → trace → log → change
--  A chart alert watches hikaricp.connections.pending: "more than 20 requests wait for a
--  database connection on a pod, over one minute". It fires. Nothing else is known.
-- =====================================================================

-- STEP B1 · The alert: what ClickStack evaluates every minute
--  A chart alert is a GROUP BY on a time bucket with a threshold: the first rows are
--  the first minutes where it fires.
SELECT
    toStartOfMinute(toDateTime(TimeUnix))          AS minute,
    count(DISTINCT ResourceAttributes['k8s.pod.name']) AS pods_over,
    argMax(ResourceAttributes['k8s.pod.name'], Value) AS worst_pod,
    max(Value)                                     AS max_pending
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'hikaricp.connections.pending'
  AND TimeUnix BETWEEN pf_at('12:00') AND pf_at('16:00')
  AND Value > 20
GROUP BY minute
ORDER BY minute
LIMIT 5;
-- Measured: 16 ms · 114,689 rows read (3.4 MB)
-- What to look for: it fires at 14:03, on the 6 payment pods at once. A problem on every
-- pod at the same time is rarely a hardware fault: think of a change.

-- STEP B2 · The metric in context: the pool of each version, before and during
SELECT
    if(TimeUnix < pf_at('13:58'), 'before 13:58', 'at 14:03')               AS period,
    ResourceAttributes['service.version']                                          AS version,
    count(DISTINCT ResourceAttributes['k8s.pod.name'])                             AS pods,
    round(avgIf(Value, MetricName = 'hikaricp.connections.max'))                   AS pool_max,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'), 1)             AS pool_active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'), 1)            AS pool_pending
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName LIKE 'hikaricp.%'
  AND (TimeUnix BETWEEN pf_at('13:50') AND pf_at('13:52:59')
       OR TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59'))
GROUP BY period, version
ORDER BY period DESC, version;
-- Measured: 25 ms · 131,073 rows read (5.3 MB)
-- What to look for: v2.4.0 had a pool of 50 and used a few connections. v2.4.1 has 10,
-- all busy. The metric already points at the version; the traces show the effect.

-- STEP B3 · From the metric to the traces: what the worst pod served in that minute
--  ClickStack does the same when you click a point of the chart: same pod, same minute.
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59')) AS worst_pod
SELECT
    worst_pod                                                      AS pod,
    SpanName,
    count()                                                        AS spans,
    countIf(StatusCode = 'Error')                                  AS errors,
    round(quantile(0.5)(Duration) / 1e6)                           AS p50_ms,
    round(max(Duration) / 1e6)                                     AS max_ms,
    argMinIf(TraceId, Timestamp, StatusCode = 'Error')             AS first_failed_trace
FROM payflow_otel.otel_traces
WHERE Timestamp BETWEEN pf_at('14:03') AND pf_at('14:03:59')
  AND ServiceName = 'payment' AND SpanKind = 'Server'
  AND ResourceAttributes['k8s.pod.name'] = worst_pod
GROUP BY SpanName
ORDER BY spans DESC;
-- Measured: 34 ms · 253,953 rows read (5.1 MB)
-- What to look for: a median above one second and failures at 3 seconds, the HikariCP
-- timeout. first_failed_trace is the trace id to open.

-- STEP B4 · From the trace to its logs: everything written while serving it
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59')) AS worst_pod,
    (SELECT argMinIf(TraceId, Timestamp, StatusCode = 'Error') FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:03') AND pf_at('14:03:59')
       AND ServiceName = 'payment' AND SpanKind = 'Server'
       AND ResourceAttributes['k8s.pod.name'] = worst_pod) AS tid
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE TraceId = tid
  AND Timestamp BETWEEN pf_at('14:02:50') AND pf_at('14:04:20')
ORDER BY Timestamp;
-- Measured: 35 ms · 49,153 rows read (3.9 MB)
-- What to look for: the same request seen by three services: payment times out on the
-- pool, checkout reports a 503, the api-gateway access log returns the 503 to the merchant.

-- STEP B5 · What changed on that pod? The Kubernetes events
--  The k8sobjects receiver of module 2 wrote the cluster events into otel_logs.
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59')) AS worst_pod
SELECT Timestamp, EventName, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events'
  AND Timestamp BETWEEN pf_at('13:50') AND pf_at('14:03')
  AND (LogAttributes['k8s.object.name'] = worst_pod OR EventName = 'ScalingReplicaSet')
ORDER BY Timestamp;
-- Measured: 34 ms · 2.9 M rows read (7.4 MB) · 179.2 MB memory
-- What to look for: "Scaled up replica set payment-5c8b7f9d21 (rolling update CHG-4117)",
-- then the pod scheduled, its v2.4.1 image pulled, started. Alert to change in 5 queries.


-- =====================================================================
--  SCENARIO C · Trace → log → metrics → events
--  14:25. The HikariPool errors are known and a rollback is being prepared. But a trace
--  shows an error that is not the pool. Is it a second problem?
-- =====================================================================

-- STEP C1 · The traces: which error messages are new since 14:15?
--  The pool timeout has been known since 14:00. A message seen for the first time later
--  is a new lead. In ClickStack: traces, StatusCode:Error, group by StatusMessage.
SELECT ServiceName, SpanName, StatusMessage,
       count() AS error_spans, min(Timestamp) AS first_seen, max(Timestamp) AS last_seen
FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = pf_black_friday() AND Timestamp < pf_at('14:25')
  AND StatusCode = 'Error' AND SpanKind = 'Server' AND StatusMessage != ''
GROUP BY ServiceName, SpanName, StatusMessage
HAVING first_seen >= pf_at('14:15')
ORDER BY error_spans DESC;
-- Measured: 35 ms · 7.9 M rows read (21.1 MB)
-- What to look for: fraud.ScoreTransaction, "connect: connection refused", 290 spans in
-- under a minute from 14:21:07. Something on fraud-scoring stopped answering.

-- STEP C2 · One of these traces, span by span
WITH
    (SELECT argMin(TraceId, Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS tid,
    (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS bounds
SELECT
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1) AS start_ms,
    round(Duration / 1e6, 1)                                                     AS duration_ms,
    ServiceName, SpanKind, SpanName, StatusCode, StatusMessage,
    ResourceAttributes['k8s.pod.name']                                           AS pod,
    ResourceAttributes['k8s.node.name']                                          AS node
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN bounds.1 AND bounds.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Measured: 54 ms · 172,033 rows read (7.4 MB)
-- What to look for: checkout calls fraud-scoring, which fails at once. The pod and the
-- node of fraud-scoring are the next leads.

-- STEP C3 · The logs of that pod in the minutes before, grouped by message
--  Not the logs of the trace: those only repeat the error. What the pod said before.
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod
SELECT SeverityText, replaceRegexpAll(Body, '[0-9]+([.:/][0-9]+)*', '<n>') AS message,
       count() AS lines, min(Timestamp) AS first_seen
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:10') AND pf_at('14:22')
  AND ResourceAttributes['k8s.pod.name'] = fraud_pod
  AND SeverityNumber >= 13
GROUP BY SeverityText, message
ORDER BY first_seen;
-- Measured: 82 ms · 4 M rows read (142.9 MB) · 284.1 MB memory
-- What to look for: the queue grows ("scoring slower than arrival rate"), the feature
-- cache reaches 1.9 GiB of a 2 GiB limit, then a FATAL worker timeout at 14:21:07.

-- STEP C4 · The metrics: why the queue grows, and the memory of the pod
--  The request rate of fraud-scoring (from the traces) and its memory (from kubeletstats).
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod
SELECT
    m.minute,
    t.requests,
    m.memory_mb
FROM
(
    SELECT toStartOfFiveMinutes(toDateTime(TimeUnix)) AS minute,
           round(max(Value) / 1e6) AS memory_mb
    FROM payflow_otel.otel_metrics_gauge
    WHERE MetricName = 'k8s.pod.memory.usage'
      AND TimeUnix BETWEEN pf_at('13:40') AND pf_at('14:34:59')
      AND ResourceAttributes['k8s.pod.name'] = fraud_pod
    GROUP BY minute
) AS m
LEFT JOIN
(
    SELECT toStartOfFiveMinutes(Timestamp) AS minute, count() AS requests
    FROM payflow_otel.otel_traces
    WHERE Timestamp BETWEEN pf_at('13:40') AND pf_at('14:34:59')
      AND ServiceName = 'fraud-scoring' AND SpanKind = 'Server'
    GROUP BY minute
) AS t ON t.minute = m.minute
ORDER BY m.minute;
-- Measured: 29 ms · 204,801 rows read (2 MB)
-- What to look for: the requests double from 13:55 (checkout retries the failed payments,
-- and scores each retry again), the memory climbs from about 750 MB to 2.2 GB, then falls
-- to 900 MB after 14:21: the process was killed and restarted.

-- STEP C5 · The Kubernetes events confirm it
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod,
    (SELECT any(ResourceAttributes['k8s.node.name']) FROM payflow_otel.otel_metrics_gauge
     WHERE TimeUnix BETWEEN pf_at('14:20') AND pf_at('14:20:59')
       AND ResourceAttributes['k8s.pod.name'] = fraud_pod) AS fraud_node
SELECT Timestamp, EventName, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events'
  AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:30')
  AND EventName != 'Unhealthy'
  AND (LogAttributes['k8s.object.name'] IN (fraud_pod, fraud_node) OR Body LIKE concat('%', fraud_node, '%')
       OR Body LIKE '%fraud-scoring%')
ORDER BY Timestamp;
-- Measured: 60 ms · 3 M rows read (9.2 MB) · 179.6 MB memory
-- What to look for: node memory pressure at 14:19, the OOM kill at 14:21:07, the restart
-- back-off, the node back to normal at 14:23. Not a second bug: a consequence of the
-- first one. The retries of failed payments overloaded fraud-scoring until it ran out of
-- memory. Fixing the pool (the rollback at 14:42) fixes both.


-- STEP D · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
          AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') = 1, 'OK', 'KO')     AS a_log_found,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE Timestamp BETWEEN pf_at('13:50') AND pf_at('14:10')
          AND ResourceAttributes['service.version'] = 'v2.4.1'
          AND hasAllTokens(lower(Body), ['maximumpoolsize'])) = 6, 'OK', 'KO')                               AS a_pool_config,
    if((SELECT min(toStartOfMinute(toDateTime(TimeUnix))) FROM payflow_otel.otel_metrics_gauge
        WHERE MetricName = 'hikaricp.connections.pending' AND Value > 20
          AND toDate(TimeUnix) = pf_black_friday()) = pf_at('14:03'), 'OK', 'KO')                          AS b_alert_fires,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE ServiceName = 'k8s-events' AND EventName = 'ScalingReplicaSet'
          AND Timestamp BETWEEN pf_at('13:50') AND pf_at('14:03')
          AND Body LIKE '%CHG-4117%') = 1, 'OK', 'KO')                                                       AS b_change_found,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE ServiceName = 'k8s-events' AND EventName = 'OOMKilling'
          AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:30')) >= 1, 'OK', 'KO')           AS c_oom_found
SETTINGS select_sequential_consistency = 1;
-- Measured: 149 ms · 6 M rows read (3.9 MB) · 129.1 MB memory
