-- =====================================================================
--  MODULE 5 · Gold: RED metrics, updated on every insert
-- =====================================================================
--  RED = Rate, Errors, Duration: the three numbers an SRE watches for each
--  service. Computing them from 14 million spans for every dashboard refresh
--  would be wasteful. An incremental materialized view keeps them per minute,
--  as partial aggregation states: AggregatingMergeTree merges the states in
--  the background, the query finishes the aggregation with -Merge.
-- =====================================================================


-- STEP 1 · The target table: one row per service, operation and minute
--  quantilesTDigestState keeps a small summary of the latency distribution:
--  quantiles of quantiles would be wrong, merged t-digests are right.
CREATE OR REPLACE TABLE payflow_sre.red_1m
(
    minute       DateTime('UTC'),
    service      LowCardinality(String),
    operation    LowCardinality(String),
    requests     SimpleAggregateFunction(sum, UInt64),
    errors       SimpleAggregateFunction(sum, UInt64),
    latency      AggregateFunction(quantilesTDigest(0.5, 0.95, 0.99), UInt64)   -- nanoseconds
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(minute)
ORDER BY (service, operation, minute);


-- STEP 2 · The incremental materialized view, from server spans
CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.mv_red_1m TO payflow_sre.red_1m AS
SELECT
    toStartOfMinute(toDateTime(Timestamp))                AS minute,
    ServiceName                                           AS service,
    SpanName                                              AS operation,
    count()                                               AS requests,
    countIf(StatusCode = 'Error')                         AS errors,
    quantilesTDigestState(0.5, 0.95, 0.99)(Duration)      AS latency
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY minute, service, operation;


-- STEP 3 · Backfill the day: the view only sees new inserts
INSERT INTO payflow_sre.red_1m
SELECT
    toStartOfMinute(toDateTime(Timestamp)), ServiceName, SpanName,
    count(), countIf(StatusCode = 'Error'), quantilesTDigestState(0.5, 0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY 1, 2, 3;
-- Measured: 1.25 s · 14.6 M rows read (186.7 MB) · 20,165 rows written · 308.1 MB memory

SELECT count() AS rows_gold, (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server') AS server_spans
FROM payflow_sre.red_1m;
-- Measured: 12 ms · 14.6 M rows read (13.9 MB) · 89.1 MB memory
-- What to look for: a few tens of thousands of rows summarise millions of spans.


-- STEP 4 · RED of the entry point, minute by minute, around the incident
SELECT
    minute,
    sum(requests)                                                       AS n_requests,   -- not "AS requests": an alias is global
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[1] / 1e6)     AS p50_ms,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:55:00'
GROUP BY minute
ORDER BY minute;
-- Measured: 27 ms · 8,192 rows read (1.2 MB)
-- What to look for: p99 jumps from ~300 ms to 3 s at 13:58 (the rollout), errors climb to ~30%
-- once the flash sale peaks, both fall back at 14:44. The dashboard of module 8 is this query.


-- STEP 5 · The same numbers straight from the spans, to compare the cost
SELECT
    toStartOfMinute(toDateTime(Timestamp))                              AS minute,
    count()                                                             AS n_requests,
    round(100 * countIf(StatusCode = 'Error') / count(), 2)             AS error_pct,
    round(quantileTDigest(0.99)(Duration) / 1e6)                        AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:55:59'
GROUP BY minute
ORDER BY minute;
-- Measured: 39 ms · 81,920 rows read (1.5 MB)
-- What to look for: same curve, 10 times more rows read from the spans. Here the spans
-- are sorted by service and span name, so the raw query stays cheap. Gold makes the
-- difference on long ranges (a month: 20,000 rows instead of 400 million spans) and on
-- dashboards that aggregate every service at once.


-- STEP 6 · Checkpoint
SELECT
    if((SELECT sum(requests) FROM payflow_sre.red_1m) = (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server'), 'OK', 'KO') AS no_span_lost,
    if((SELECT max(errors) FROM payflow_sre.red_1m WHERE service = 'payment') > 300, 'OK', 'KO')                                                AS incident_visible
SETTINGS select_sequential_consistency = 1;
-- Measured: 39 ms · 11.3 M rows read (11 MB) · 84.3 MB memory
