-- =====================================================================
--  MODULE 6 · Investigation (2/2): from the page to the root cause, in SQL
-- =====================================================================
--  14:00 UTC, Black Friday. The on-call engineer is paged: "POST /v1/payments:
--  error budget burning 19x faster than allowed". Ten questions, ten queries.
--  Every answer comes from the same database: no tool switching, no copy of
--  data between a log tool, a tracing tool and a metrics tool.
-- =====================================================================


-- Q1 · What fired, and when?
SELECT ts, rule, service, state, summary
FROM payflow_sre.alerts
WHERE ts BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 15:00:00'
ORDER BY ts;
-- Measured: 3 ms · 11 rows read


-- Q2 · How bad is it? Errors and latency of every service, now versus one hour ago
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
-- Measured: 68 ms · 20,160 rows read (3 MB)
-- What to look for: three services fail (api-gateway, checkout, payment). Who is the cause,
-- who only relays the error?


-- Q3 · Where does the error start? The deepest failing span of each failed trace
--  A span that failed while none of its children failed is where the error was born.
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
-- Measured: 209 ms · 1.6 M rows read (17.7 MB) · 56.3 MB memory
-- What to look for: the database call of payment, "Connection is not available,
-- request timed out after 3000ms". The others are victims.


-- Q4 · One failed trace, as a tree (a recursive CTE)
--  WITH RECURSIVE walks from the root span down to its children, level by level.
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
-- Measured: 128 ms · 638,998 rows read (34.9 MB)
-- What to look for: the waterfall of module 3, in plain SQL. 3 seconds spent waiting
-- in INSERT payflow.payments; card network, ledger and notification never ran.


-- Q5 · What changed? The change that was live for each error, and the deployments
--  The range dictionary of module 1 stamps every error span with the change live at
--  that second; the team comes from the service catalog.
SELECT
    dictGet('payflow_inventory.dict_service', 'team', ServiceName)                            AS team,
    ServiceName,
    dictGet('payflow_inventory.dict_deployment', 'change_id', ServiceName, toDateTime(Timestamp)) AS change_live,
    count()                                                                                    AS error_spans
FROM payflow_otel.otel_traces
WHERE StatusCode = 'Error' AND SpanKind = 'Client' AND SpanAttributes['rpc.system'] = '' AND toDate(Timestamp) = '2026-11-27'
GROUP BY team, ServiceName, change_live
ORDER BY error_spans DESC
LIMIT 5;
-- Measured: 379 ms · 21.5 M rows read (63.4 MB) · 137.6 MB memory
-- What to look for: the payments team, change CHG-4117. Page the right team first.

SELECT deployment, version, change_id, author, valid_from, note
FROM payflow_inventory.deployment_history
WHERE valid_from BETWEEN '2026-11-27 12:00:00' AND '2026-11-27 16:00:00'
ORDER BY valid_from;
-- Measured: 3 ms · 11 rows read

SELECT
    ResourceAttributes['service.version']           AS pod_version,
    count()                                         AS db_calls,
    round(100 * countIf(StatusCode = 'Error') / count(), 2) AS error_pct,
    round(quantile(0.99)(Duration) / 1e6)           AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
  AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:42:00'
GROUP BY pod_version;
-- Measured: 21 ms · 81,920 rows read (1.9 MB)
-- What to look for: during the rollout both versions served traffic side by side.
-- Only v2.4.1 fails. Same database, same traffic: the version is the cause.


-- Q6 · Why does v2.4.1 fail? The connection pool, seen by the metrics
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
-- Measured: 15 ms · 57,344 rows read (2.7 MB)
-- What to look for: v2.4.1 has 10 connections, all busy, and dozens of threads waiting.


-- Q7 · ... and seen by the logs: the startup line of a v2.4.1 pod
SELECT Timestamp, ResourceAttributes['k8s.pod.name'] AS pod, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND hasToken(lower(Body), 'maximumpoolsize')
  AND Timestamp BETWEEN '2026-11-27 13:55:00' AND '2026-11-27 14:50:00'
ORDER BY Timestamp
LIMIT 4;
-- Measured: 10 ms · 40,960 rows read (1.5 MB)
-- What to look for: maximumPoolSize=10 at 13:58, maximumPoolSize=50 after the rollback.
-- The change note said "pool size 50 to 10": the review missed the Black Friday load.


-- Q8 · The second fire: fraud-scoring on the small node
--  Retries add load, fraud-scoring slows down, its memory grows until the kernel kills it.
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE (ServiceName = 'k8s-events' AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17'
       AND SeverityText = 'WARN' AND EventName != 'Unhealthy')
   OR (ServiceName = 'fraud-scoring' AND SeverityNumber >= 13 AND Body NOT LIKE 'score=%')
ORDER BY Timestamp
LIMIT 20;
-- Measured: 363 ms · 5 M rows read (400.1 MB) · 283.1 MB memory

SELECT
    toStartOfMinute(toDateTime(TimeUnix))                         AS minute,
    round(max(Value) / 1048576)                                   AS memory_mib
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'k8s.pod.memory.working_set'
  AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17' AND ServiceName = 'fraud-scoring'
  AND TimeUnix BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:30:00'
GROUP BY minute
ORDER BY minute WITH FILL STEP INTERVAL 1 MINUTE;
-- Measured: 12 ms · 32,768 rows read (1.9 MB)
-- What to look for: memory climbs to 2 GiB, drops to 0 at 14:21 (killed), restarts.


-- Q9 · The business impact: failed payments, amount, merchants
SELECT
    count()                                                                            AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                            AS amount_eur,
    uniqExact(SpanAttributes['merchant.id'])                                           AS merchants_hit
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:50:00';
-- Measured: 80 ms · 90,112 rows read (3 MB)

SELECT
    dictGet('payflow_inventory.dict_merchant', 'name', SpanAttributes['merchant.id'])          AS merchant,
    dictGet('payflow_inventory.dict_merchant', 'tier', SpanAttributes['merchant.id'])          AS tier,
    count()                                                                              AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                              AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:50:00'
GROUP BY merchant, tier
ORDER BY amount_eur DESC
LIMIT 10;
-- Measured: 38 ms · 90,112 rows read (3 MB)
-- What to look for: the customer-facing numbers for the incident report.
-- The account managers know whom to call first.


-- Q10 · The timeline of the incident, from every signal at once
SELECT ts, source, what
FROM
(
    SELECT valid_from AS ts, 'deploy' AS source, concat(deployment, ' ', version, ' (', change_id, ', ', author, ')') AS what
    FROM payflow_inventory.deployment_history WHERE valid_from BETWEEN '2026-11-27 13:00:00' AND '2026-11-27 15:00:00'
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
-- Measured: 203 ms · 4.5 M rows read (32.6 MB) · 180.1 MB memory
-- What to look for: deploy 13:58, first error 13:58, page 14:00, OOM 14:21,
-- rollback 14:42, last error 14:44, resolved 14:47. Time to detect: 2 minutes.
-- Time to mitigate: 44 minutes. The postmortem writes itself.


-- Checkpoint
SELECT
    if((SELECT argMax(SpanName, c) FROM (SELECT SpanName, count() AS c FROM payflow_otel.otel_traces
        WHERE StatusCode = 'Error' AND Timestamp BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:15:00' AND SpanKind = 'Client'
          AND SpanAttributes['rpc.system'] = ''
        GROUP BY SpanName)) = 'INSERT payflow.payments', 'OK', 'KO')                                                   AS root_cause_span,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE hasToken(lower(Body), 'maximumpoolsize') AND Body LIKE '%maximumPoolSize=10%') = 6, 'OK', 'KO') AS startup_clue,
    if((SELECT countIf(StatusCode = 'Error') FROM payflow_otel.otel_traces
        WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
          AND ResourceAttributes['service.version'] = 'v2.4.0' AND Timestamp BETWEEN '2026-11-27 13:58:00' AND '2026-11-27 14:42:00') = 0, 'OK', 'KO') AS only_v241_fails
SETTINGS select_sequential_consistency = 1;
-- Measured: 111 ms · 884,737 rows read (6.1 MB) · 58.2 MB memory
