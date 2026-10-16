-- =====================================================================
--  MODULE 7 · Scale and cost (3/3): rollups, retention, sampling
-- =====================================================================
--  Three levers decide what an observability platform costs:
--    · rollups: keep pre-aggregated minutes for months, raw events for days
--    · retention: drop old data by whole partitions (TTL), shrink what you keep
--    · sampling: keep fewer traces, but the right ones
--  ClickStack's position is to keep everything when you can ("priced on
--  infrastructure, not events"): compression makes it affordable. This file
--  measures what each lever saves on PayFlow.
-- =====================================================================


-- STEP 1 · A rollup ClickStack can use by itself
--  ClickStack can answer a chart, a dashboard tile or an alert from a materialized
--  view instead of the raw spans, if the view follows its convention: AggregatingMergeTree,
--  a Timestamp at a fixed granularity, the grouping columns, and aggregate columns
--  named <function>__<column>. You then register it on the trace source (README).
--  This is the example of the ClickStack documentation, applied to PayFlow.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_1m
(
    `Timestamp`            DateTime,
    `ServiceName`          LowCardinality(String),
    `SpanName`             LowCardinality(String),
    `StatusCode`           LowCardinality(String),
    `count`                SimpleAggregateFunction(sum, UInt64),
    `avg__Duration`        AggregateFunction(avg, UInt64),
    `max__Duration`        SimpleAggregateFunction(max, UInt64),
    `quantiles__Duration`  AggregateFunction(quantiles(0.95, 0.99), UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (Timestamp, ServiceName, SpanName, StatusCode);

CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.otel_traces_1m_mv TO payflow_otel.otel_traces_1m AS
SELECT
    toStartOfMinute(Timestamp)            AS Timestamp,
    ServiceName,
    SpanName,
    StatusCode,
    count()                               AS count,
    avgState(Duration)                    AS avg__Duration,
    maxSimpleState(Duration)              AS max__Duration,
    quantilesState(0.95, 0.99)(Duration)  AS quantiles__Duration
FROM payflow_otel.otel_traces
GROUP BY Timestamp, ServiceName, SpanName, StatusCode;

--  A view only sees new inserts: backfill the month once, up to the minute before the
--  view was created (module 4 explains the cut-off)
INSERT INTO payflow_otel.otel_traces_1m
SELECT toStartOfMinute(Timestamp), ServiceName, SpanName, StatusCode, count(),
       avgState(Duration), maxSimpleState(Duration), quantilesState(0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE Timestamp < (SELECT toStartOfMinute(metadata_modification_time) - INTERVAL 1 MINUTE
                   FROM system.tables WHERE database = 'payflow_otel' AND name = 'otel_traces_1m_mv')
GROUP BY 1, 2, 3, 4;
-- Measured: 9.9 s · 76.7 M rows read (1.4 GB) · 1.7 M rows written · 3.7 GB memory

SELECT
    (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = pf_black_friday()) AS spans,
    (SELECT count() FROM payflow_otel.otel_traces_1m WHERE toDate(Timestamp) = pf_black_friday()) AS rollup_rows,
    round(spans / rollup_rows)                                                              AS spans_per_row;
-- Measured: 17 ms · 32,773 rows read (128.1 KB)

SELECT Timestamp, sum(count) AS requests, round(avgMerge(avg__Duration) / 1e6) AS avg_ms
FROM payflow_otel.otel_traces_1m
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN pf_at('13:55') AND pf_at('14:05')
GROUP BY Timestamp
ORDER BY Timestamp;
-- Measured: 29 ms · 16,385 rows read (609.6 KB)


-- STEP 2 · What each signal costs per day
--  The partitions are daily: system.parts gives the raw and compressed size of each day.
SELECT
    table,
    formatReadableQuantity(sum(rows))                                       AS rows_per_day,
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw,
    formatReadableSize(sum(data_compressed_bytes))                          AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1)     AS ratio
FROM system.parts
WHERE database = 'payflow_otel' AND active AND partition = toString(pf_black_friday())
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;
-- Measured: 8 ms · 727 rows read (59.8 KB)
-- What to look for: logs and traces are most of the volume, metrics and rollups are small.
-- A year of PayFlow at this rate is the daily on_disk figure times 365.


-- STEP 3 · Retention: what to keep, and for how long
--  Every OpenTelemetry table already drops whole daily partitions after its TTL
--  (ttl_only_drop_parts = 1: no rewrite, no mutation). A production policy:
--      ALTER TABLE payflow_otel.otel_traces  MODIFY TTL toDate(Timestamp) + INTERVAL 15 DAY;
--      ALTER TABLE payflow_otel.otel_logs    MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;
--      ALTER TABLE payflow_otel.otel_traces_1m MODIFY TTL Timestamp + INTERVAL 13 MONTH;   -- rollups live long
--  Two finer tools exist: a TTL on one column (drop Body after 7 days, keep the attributes),
--  and TTL ... RECOMPRESS CODEC(ZSTD(3)) to squeeze older parts harder.
--  Watch out: do not apply these here. The workshop data covers the last month: with a
--  15-day TTL, ClickHouse would drop half of it. ClickStack's default is 3 days.
SELECT table, engine_full LIKE '%TTL%' AS has_ttl, extract(engine_full, 'TTL ([^S]+) SETTINGS') AS ttl
FROM system.tables
WHERE database = 'payflow_otel' AND name LIKE 'otel\\_%' AND engine LIKE '%MergeTree'
ORDER BY name;
-- Measured: 3 ms · 7 rows read (2.3 KB)


-- STEP 4 · Sampling: keep 10% of the traces, and see what you lose
--  Head sampling (probabilistic_sampler in the collector) keeps a trace if a hash of its
--  id falls below the threshold: the same decision for every span of a trace.
SELECT
    countIf(SpanName = 'POST /v1/payments')                                          AS all_requests,
    countIf(SpanName = 'POST /v1/payments' AND cityHash64(TraceId) % 10 = 0) * 10   AS estimated_from_10pct,
    round(100 * countIf(SpanName = 'POST /v1/payments' AND StatusCode = 'Error') / all_requests, 2) AS error_pct,
    round(100 * countIf(SpanName = 'POST /v1/payments' AND StatusCode = 'Error' AND cityHash64(TraceId) % 10 = 0)
              / countIf(SpanName = 'POST /v1/payments' AND cityHash64(TraceId) % 10 = 0), 2)       AS error_pct_from_10pct
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND toDate(Timestamp) = pf_black_friday();
-- Measured: 198 ms · 4.1 M rows read (181.8 MB) · 170.1 MB memory
-- What to look for: rates survive sampling, counts must be multiplied back (ClickStack does
-- it with the Sample Rate Expression of the source). What you lose is the one rare trace
-- you needed: the 12 card network timeouts of the incident, 1 or 2 of them kept.

--  Retention sampling: keep everything for a few days, and keep for months only the
--  traces worth keeping (an error, or slower than 1 s). The decision sees the whole trace.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_kept AS payflow_otel.otel_traces;

INSERT INTO payflow_otel.otel_traces_kept
SELECT * FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = pf_black_friday()
  AND TraceId IN
  (
      SELECT TraceId FROM payflow_otel.otel_traces
      WHERE toDate(Timestamp) = pf_black_friday() AND (StatusCode = 'Error' OR Duration > 1000000000)
  );
-- Measured: 3.78 s · 43.1 M rows read (7.7 GB) · 602,753 rows written · 1.6 GB memory

SELECT
    (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = pf_black_friday())   AS all_spans,
    (SELECT count() FROM payflow_otel.otel_traces_kept)                                     AS kept_spans,
    round(100 * kept_spans / all_spans, 1)                                                   AS kept_pct;
-- Measured: 10 ms · 5 rows read
-- What to look for: a few percent of the spans, and every trace of the incident is there.


-- STEP 5 · Sizing: the ClickStack rule of thumb
--  Ingest: about 1 vCPU per 10 MB/s of raw data. Query: about 1 vCPU per query per second
--  over 10 MB/s. Compute PayFlow's ingest rate from the day.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw_per_day,
    formatReadableSize(sum(data_uncompressed_bytes) / 86400)                AS raw_per_second,
    round(sum(data_uncompressed_bytes) / 86400 / 1e7, 2)                    AS ingest_vcpu_needed
FROM system.parts
WHERE database = 'payflow_otel' AND active AND partition = toString(pf_black_friday())
  AND table IN ('otel_logs', 'otel_traces', 'otel_metrics_gauge', 'otel_metrics_sum', 'otel_metrics_histogram');
-- Measured: 6 ms · 498 rows read (33.9 KB)
-- What to look for: PayFlow is a small platform for ClickHouse: a fraction of a vCPU of
-- ingest. The 3 replicas of the workshop are sized for the billion-line module.


-- STEP 6 · Checkpoint
SELECT
    if((SELECT sum(count) FROM payflow_otel.otel_traces_1m WHERE toDate(Timestamp) = pf_black_friday())
       = (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = pf_black_friday()), 'OK', 'KO') AS rollup_complete,
    if((SELECT count() FROM payflow_otel.otel_traces_kept) BETWEEN 100000 AND 2000000, 'OK', 'KO')       AS retention_sampling
SETTINGS select_sequential_consistency = 1;
-- Measured: 50 ms · 65,541 rows read (768.1 KB)
