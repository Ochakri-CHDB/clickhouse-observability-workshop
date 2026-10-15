-- =====================================================================
--  MODULE 4 · Dashboards: the RED rollups behind them
-- =====================================================================
--  RED = Rate, Errors, Duration: the three numbers of every service, and the first
--  row of every dashboard. In the collector, the spanmetrics connector computes them
--  from the spans. In ClickHouse, an incremental materialized view does the same at
--  insert time, exactly and without a load balancer in front of the collectors:
--  partial aggregation states, merged in the background by AggregatingMergeTree,
--  finished by the query with -Merge. The ClickStack documentation says it plainly:
--  materialized views move the cost from query time to insert time.
--  Two outputs:
--    · payflow_sre.red_1m, for the SQL tiles, the SLOs and the alerts (modules 4 and 5)
--    · the spanmetrics histogram in otel_metrics_histogram, as the collector would write
--      it, with an exemplar: from a latency chart, one click to the slowest trace
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
WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27'   -- the history; the live stream goes through the view
GROUP BY 1, 2, 3;
-- Measured: 1.27 s · 21.5 M rows read (199.6 MB) · 20,160 rows written · 337.1 MB memory

SELECT count() AS rollup_rows, (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27') AS server_spans
FROM payflow_sre.red_1m
WHERE toDate(minute) = '2026-11-27';
-- Measured: 28 ms · 10 M rows read (84.9 MB) · 108.3 MB memory
-- What to look for: 20,000 rows summarise 8 million server spans.


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
-- Measured: 30 ms · 8,192 rows read (1.2 MB)
-- What to look for: p99 jumps from ~300 ms to 3 s at 13:58 (the rollout), errors climb to ~30%
-- once the flash sale peaks, both fall back at 14:44. The dashboard of the README is this query.


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
-- Measured: 38 ms · 90,112 rows read (1.6 MB)
-- What to look for: same curve, 10 times more rows read from the spans. Here the spans
-- are sorted by service and span name, so the raw query stays cheap. Gold makes the
-- difference on long ranges (a month: 20,000 rows instead of 400 million spans) and on
-- dashboards that aggregate every service at once.


-- STEP 6 · The spanmetrics histogram, readable by ClickStack as a metric
--  An OpenTelemetry histogram stores, for each interval, the count per bucket
--  (BucketCounts) for fixed bounds (ExplicitBounds), plus count, sum, min, max.
--  The exemplar keeps the trace id of the slowest request of the minute: from a
--  latency chart you can jump straight to the guilty trace (README of this module).
INSERT INTO payflow_otel.otel_metrics_histogram
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix,
     Count, Sum, BucketCounts, ExplicitBounds, `Exemplars.FilteredAttributes`, `Exemplars.TimeUnix`, `Exemplars.Value`,
     `Exemplars.SpanId`, `Exemplars.TraceId`, Min, Max, AggregationTemporality)
WITH [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] AS bounds
SELECT
    map('service.name', ServiceName, 'k8s.cluster.name', 'payflow-prod-eu')                            AS ResourceAttributes,
    ServiceName,
    'traces.span.metrics.duration'                                                                     AS MetricName,   -- the name the connector uses
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
WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27'
GROUP BY ServiceName, SpanName, StatusCode, toStartOfMinute(toDateTime(Timestamp)) AS minute;
-- Measured: 751 ms · 9.9 M rows read (631.6 MB) · 23,345 rows written · 405.6 MB memory
-- Watch out: arrayFirstIndex returns 0 when the value is above the last bound: in that
-- case no b in 1..12 matches. Here no span is longer than 10 s, so every span lands in a bucket.


-- STEP 7 · Checkpoint
SELECT
    if((SELECT sum(requests) FROM payflow_sre.red_1m WHERE toDate(minute) = '2026-11-27') = (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27'), 'OK', 'KO') AS no_span_lost,
    if((SELECT count() FROM payflow_otel.otel_metrics_histogram WHERE MetricName = 'traces.span.metrics.duration') > 10000, 'OK', 'KO') AS spanmetrics_histogram,
    if((SELECT max(errors) FROM payflow_sre.red_1m WHERE service = 'payment') > 300, 'OK', 'KO')                                                AS incident_visible
SETTINGS select_sequential_consistency = 1;
-- Measured: 64 ms · 9.1 M rows read (78.7 MB) · 81.9 MB memory
