-- =====================================================================
--  MODULE 6 · Search a billion log lines: indexes, projections, replicas
-- =====================================================================
--  Observability queries are needles in haystacks: one error message, one
--  trace id, one pod. ClickHouse reads only what it must:
--    · the primary index (ORDER BY) skips by service and time
--    · the text index skips granules that do not contain a token
--    · the bloom filter skips granules that cannot contain a trace id
--    · the projection answers aggregates from a pre-aggregated copy
--  Each query is run with and without its helper. Compare the "Measured" lines:
--  time, and above all rows read.
--  Watch out: two caches would make the second run of a query instant. They are
--  disabled here so that every timing is a real read (steps 6 and 7 show them):
--    · the query cache keeps whole results
--    · the query condition cache remembers which granules matched a WHERE clause
-- =====================================================================

SET use_query_cache = 0;
SET use_query_condition_cache = 0;


-- STEP 1 · Full-text search: a rare word in 910 million lines
--  hasToken(lower(Body), 'oomkilled') uses idx_lower_body, built with the same
--  expression lower(Body) and the same tokenizer (splitByNonAlpha).
SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled');
-- Measured: 461 ms · 311,296 rows read (304 KB)

SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled')
SETTINGS use_skip_indexes = 0;   -- the same query, index disabled: every Body is read
-- Measured: 3.45 s · 910 M rows read (53.6 GB) · 447.4 MB memory

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%oomkilled%'
SETTINGS use_skip_indexes = 0;   -- what a grep would do
-- Measured: 2.93 s · 910 M rows read (53.6 GB) · 462.9 MB memory
-- What to look for: with the index, a few hundred thousand rows read instead of 910 million.


-- STEP 2 · A frequent word: the HikariPool errors of every region
SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster;
-- Measured: 333 ms · 9.5 M rows read (18.1 MB)

SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster
SETTINGS use_skip_indexes = 0;
-- Measured: 2.97 s · 910 M rows read (53.6 GB) · 355 MB memory
-- What to look for: the gain shrinks when the word is everywhere, but stays large:
-- the index still skips every granule without the word.


-- STEP 3 · One trace id among 910 million lines
--  The bloom filter alone already skips most granules. Bounding the time as well
--  lets the primary index and the partitions do the rest: this is why tracing
--  tools first look up the time range of a trace (step 5).
SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN '2026-11-21 10:00:00' AND '2026-11-21 10:00:10' AND TraceId != '');
-- Measured: 2.73 s · 1.8 M rows read (34.4 MB) · 94.8 MB memory

SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN '2026-11-21 10:00:00' AND '2026-11-21 10:00:10' AND TraceId != '')
  AND Timestamp BETWEEN '2026-11-21 09:59:00' AND '2026-11-21 10:01:00';
-- Measured: 18 ms · 835,584 rows read (4.3 MB) · 86.5 MB memory
-- What to look for: the second query reads a few thousand rows, in a few milliseconds.


-- STEP 4 · Errors per minute for a dashboard: the projection
--  p_errors_per_minute was built at insert time. The query does not mention it:
--  ClickHouse picks it because it can answer from it.
SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5;
-- Measured: 115 ms · 593,063 rows read (12.4 MB)

SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Measured: 890 ms · 910 M rows read (3 GB) · 244.9 MB memory
-- What to look for: the same 5 minutes (14:21 every day: the copies of Black Friday),
-- from about 600,000 rows instead of 910 million.

EXPLAIN indexes = 1, projections = 1
SELECT toStartOfMinute(Timestamp) AS minute, count()
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute;
-- Measured: 5 ms · 14 rows read


-- STEP 5 · The trace id lookup table (the pattern used by tracing UIs)
--  A small table, sorted by TraceId, keeps the start and end of each trace.
--  It is fed by a materialized view: one lookup gives the time range, the
--  real query then reads one narrow time window of otel_traces.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_trace_id_ts
(
    TraceId  String CODEC(ZSTD(1)),
    Start    SimpleAggregateFunction(min, DateTime64(9)),
    End      SimpleAggregateFunction(max, DateTime64(9))
)
ENGINE = AggregatingMergeTree
ORDER BY TraceId;

CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_trace_id_ts TO payflow_otel.otel_traces_trace_id_ts AS
SELECT TraceId, min(Timestamp) AS Start, max(Timestamp) AS End
FROM payflow_otel.otel_traces
GROUP BY TraceId;

INSERT INTO payflow_otel.otel_traces_trace_id_ts
SELECT TraceId, min(Timestamp), max(Timestamp) FROM payflow_otel.otel_traces GROUP BY TraceId;
-- Measured: 1.41 s · 14.6 M rows read (597.4 MB) · 1.4 M rows written · 1.1 GB memory

WITH (SELECT any(TraceId) FROM payflow_otel.otel_traces WHERE ServiceName = 'payment' AND StatusCode = 'Error'
      AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01') AS tid,
     (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS range
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN range.1 - INTERVAL 1 SECOND AND range.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Measured: 28 ms · 188,416 rows read (4.1 MB)
-- What to look for: a whole trace, read from a window of a few seconds.


-- STEP 6 · The query cache
--  The result of a heavy query is kept in memory: the second run answers in ~1 ms.
--  Watch out: the cache is per replica and is not invalidated by inserts.
--  It suits dashboards refreshed by many users, not alerting.
SYSTEM DROP QUERY CACHE;

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Measured: 6.89 s · 910 M rows read (53.7 GB) · 298 MB memory

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Measured: 1 ms · 1 row read


-- STEP 7 · The query condition cache: the filter remembered, not the result
--  For each part, ClickHouse remembers which granules matched a WHERE condition.
--  Run the same search again, even with another SELECT list: granules that did
--  not match are skipped without reading them. On by default since 25.3.
SET use_query_condition_cache = 1;

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
SETTINGS use_skip_indexes = 0;
-- Measured: 1.71 s · 593 M rows read (34.9 GB) · 461.4 MB memory

SELECT Cluster, count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
GROUP BY Cluster
SETTINGS use_skip_indexes = 0;
-- Measured: 13 ms · 540,672 rows read (23.7 MB) · 112.2 MB memory
-- What to look for: the first run reads everything, the second almost nothing.

SET use_query_condition_cache = 0;


-- STEP 8 · Three replicas on the same scan
--  The same full scan, first on one replica, then split across the 3 replicas
--  of the service (parallel replicas). Storage is shared: no data moves.
SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null;
-- Measured: 6.8 s · 910 M rows read (57 GB) · 405.2 MB memory

SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null
SETTINGS enable_parallel_replicas = 1;
-- Measured: 3.77 s · 910 M rows read (57 GB) · 258.2 MB memory
-- What to look for: close to 3 times faster, without changing the SQL.
