-- =====================================================================
--  MODULE 5 · Gold: the service map and the log patterns
-- =====================================================================
--  Two things nobody declares but the data knows:
--    · who calls whom: every span points to its parent. Joining child spans
--      to their parent across services gives the dependency graph, with the
--      traffic, the errors and the latency of each edge.
--    · what the logs say: millions of lines, but a few dozen messages. Replace
--      the variable parts (ids, numbers) by <*> and count the patterns.
-- =====================================================================


-- STEP 1 · The service map, per 5 minutes
--  Edges between services: a server span whose parent lives in another service.
--  Edges to dependencies: client spans to postgres, redis and the card networks.
CREATE OR REPLACE TABLE payflow_sre.service_map_5m
(
    bucket     DateTime('UTC'),
    caller     LowCardinality(String),
    callee     LowCardinality(String),
    calls      UInt64,
    errors     UInt64,
    p95_ms     Float64
)
ENGINE = MergeTree
ORDER BY (caller, callee, bucket);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_service_map
REFRESH EVERY 10 MINUTE
TO payflow_sre.service_map_5m AS
SELECT bucket, caller, callee, count() AS calls, countIf(failed) AS errors, round(quantile(0.95)(duration_ns) / 1e6, 1) AS p95_ms
FROM
(
    SELECT toStartOfFiveMinutes(toDateTime(c.Timestamp)) AS bucket, p.ServiceName AS caller, c.ServiceName AS callee,
           c.StatusCode = 'Error' AS failed, c.Duration AS duration_ns
    FROM payflow_otel.otel_traces AS c
    INNER JOIN
    (
        SELECT TraceId, SpanId, ServiceName FROM payflow_otel.otel_traces WHERE SpanKind IN ('Server', 'Producer')
    ) AS p ON p.TraceId = c.TraceId AND p.SpanId = c.ParentSpanId
    WHERE c.SpanKind IN ('Server', 'Consumer') AND c.ParentSpanId != '' AND p.ServiceName != c.ServiceName

    UNION ALL

    SELECT toStartOfFiveMinutes(toDateTime(Timestamp)), ServiceName,
           concat(SpanAttributes['db.system'] != '' ? SpanAttributes['db.system'] : 'https', ' ', SpanAttributes['server.address']),
           StatusCode = 'Error', Duration
    FROM payflow_otel.otel_traces
    WHERE SpanKind = 'Client'
)
GROUP BY bucket, caller, callee;

SYSTEM WAIT VIEW payflow_sre.rmv_service_map;

SELECT caller, callee, sum(calls) AS calls_per_day, round(100 * sum(errors) / sum(calls), 2) AS error_pct, max(p95_ms) AS worst_p95_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY caller, calls_per_day DESC;
-- Measured: 36 ms · 4,618 rows read (117.8 KB)
-- What to look for: 16 edges. Nobody drew this map: it comes from the traces.
-- The edge payment → postgres payments-db carries the errors.


-- STEP 2 · The map during the incident versus one hour before
SELECT caller, callee,
       sumIf(calls, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00')                AS calls_before,
       sumIf(calls, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 15:00:00')                AS calls_during,
       maxIf(p95_ms, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00')               AS p95_before_ms,
       maxIf(p95_ms, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00')               AS p95_during_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 6;
-- Measured: 4 ms · 4,618 rows read (99.7 KB)
-- What to look for: the edges whose latency exploded. The database edge is at the top,
-- fraud-scoring follows: the retries make it slower too (a second, smaller fire).


-- STEP 3 · Log patterns per service, every 10 minutes
--  replaceRegexpAll turns ids and numbers into <*>: millions of lines, a few dozen patterns.
CREATE OR REPLACE FUNCTION pf_log_pattern AS (body) ->
    replaceRegexpAll(replaceRegexpAll(body, '(pay|m)_[0-9a-f]+|[0-9a-f]{16,}|\\*{6}', '<*>'), '[0-9]+([.:/][0-9]+)*', '<*>');

CREATE OR REPLACE TABLE payflow_sre.log_patterns_10m
(
    bucket    DateTime('UTC'),
    service   LowCardinality(String),
    severity  LowCardinality(String),
    pattern   String,
    n         UInt64,
    example   String
)
ENGINE = MergeTree
ORDER BY (service, severity, bucket);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_log_patterns
REFRESH EVERY 10 MINUTE
TO payflow_sre.log_patterns_10m AS
SELECT
    toStartOfTenMinutes(toDateTime(Timestamp)) AS bucket,
    ServiceName                                AS service,
    SeverityText                               AS severity,
    pf_log_pattern(Body)                       AS pattern,
    count()                                    AS n,
    any(Body)                                  AS example
FROM payflow_otel.otel_logs
WHERE ServiceName NOT IN ('api-gateway', 'k8s-events')   -- access logs are better read as metrics (status, duration)
GROUP BY bucket, service, severity, pattern;

SYSTEM WAIT VIEW payflow_sre.rmv_log_patterns;

SELECT uniqExact(pattern) AS patterns, sum(n) AS log_lines
FROM payflow_sre.log_patterns_10m;
-- Measured: 12 ms · 3,920 rows read (163.7 KB)


-- STEP 4 · The patterns that only appear during the incident
--  Compare 14:00-14:40 with the same 40 minutes one hour earlier.
SELECT service, severity, pattern,
       sumIf(n, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS during,
       sumIf(n, bucket >= '2026-11-27 12:50:00' AND bucket < '2026-11-27 13:30:00') AS before
FROM payflow_sre.log_patterns_10m
GROUP BY service, severity, pattern
HAVING during > 10 * greatest(before, 1)
ORDER BY during DESC
LIMIT 10;
-- Measured: 5 ms · 3,920 rows read (186.9 KB)
-- What to look for: the HikariPool timeout comes first, by far. Then the checkout
-- errors that only relay it, the fraud-scoring warnings and its OOM. The root cause
-- is the most frequent NEW pattern of the most upstream failing service.


-- STEP 5 · Checkpoint
SELECT
    if((SELECT uniqExact(caller, callee) FROM payflow_sre.service_map_5m) >= 12, 'OK', 'KO')                            AS service_map,
    if((SELECT argMax(pattern, n) FROM (SELECT pattern, sum(n) AS n FROM payflow_sre.log_patterns_10m
        WHERE severity = 'ERROR' GROUP BY pattern)) LIKE 'HikariPool%', 'OK', 'KO')                                    AS top_error_pattern
SETTINGS select_sequential_consistency = 1;
-- Measured: 90 ms · 8,539 rows read (177.2 KB)
