-- =====================================================================
--  MODULE 7 · Scale and cost (2/3): search a billion log lines
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


-- STEP 1 · Full-text search: a rare word in 875 million lines
--  hasToken(lower(Body), 'oomkilled') uses idx_lower_body, built with the same
--  expression lower(Body) and the same tokenizer (splitByNonAlpha).
SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled');
-- Measured: 774 ms · 286,720 rows read (280 KB)

SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled')
SETTINGS use_skip_indexes = 0;   -- the same query, index disabled: every Body is read
-- Measured: 4.27 s · 875 M rows read (52.5 GB) · 448 MB memory

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%oomkilled%'
SETTINGS use_skip_indexes = 0;   -- what a grep would do
-- Measured: 2.98 s · 875 M rows read (52.5 GB) · 462 MB memory
-- What to look for: with the index, a few hundred thousand rows read instead of 875 million.


-- STEP 2 · A frequent word: the HikariPool errors of every region
SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster;
-- Measured: 367 ms · 9.7 M rows read (18.4 MB) · 110.2 MB memory

SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster
SETTINGS use_skip_indexes = 0;
-- Measured: 3.09 s · 875 M rows read (52.6 GB) · 365.1 MB memory
-- What to look for: the gain shrinks when the word is everywhere, but stays large:
-- the index still skips every granule without the word.


-- STEP 3 · One trace id among 875 million lines
--  The bloom filter alone already skips most granules. Bounding the time as well
--  lets the primary index and the partitions do the rest: this is why tracing
--  tools first look up the time range of a trace (step 5).
SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN pf_at('10:00:00') - INTERVAL 6 DAY AND pf_at('10:00:10') - INTERVAL 6 DAY AND TraceId != '');
-- Measured: 2.96 s · 1.2 M rows read (31.5 MB) · 91.4 MB memory

SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN pf_at('10:00:00') - INTERVAL 6 DAY AND pf_at('10:00:10') - INTERVAL 6 DAY AND TraceId != '')
  AND Timestamp BETWEEN pf_at('09:59:00') - INTERVAL 6 DAY AND pf_at('10:01:00') - INTERVAL 6 DAY;
-- Measured: 22 ms · 368,641 rows read (3.7 MB)
-- What to look for: the second query answers in a few milliseconds: the time range lets
-- the primary index skip every other day, only the granules of that window are read.


-- STEP 4 · Errors per minute for a dashboard: the projection
--  p_errors_per_minute was built at insert time. The query does not mention it:
--  ClickHouse picks it because it can answer from it.
SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5;
-- Measured: 712 ms · 465,928 rows read (9.8 MB)

SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Measured: 1.08 s · 875 M rows read (2.9 GB) · 241.9 MB memory
-- What to look for: the same 5 minutes (14:21 every day: the copies of Black Friday),
-- from about 600,000 rows instead of 875 million.

EXPLAIN indexes = 1, projections = 1
SELECT toStartOfMinute(Timestamp) AS minute, count()
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute;
-- Measured: 5 ms · 14 rows read


-- STEP 5 · The trace lookup table at work
--  otel_traces_trace_id_ts (module 1) keeps the start and end of each trace. One lookup
--  gives the time range, the real query then reads one narrow window of otel_traces.
--  This is what ClickStack does when you open a trace.
WITH (SELECT any(TraceId) FROM payflow_otel.otel_traces WHERE ServiceName = 'payment' AND StatusCode = 'Error'
      AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:01')) AS tid,
     (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS range
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN range.1 - INTERVAL 1 SECOND AND range.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Measured: 454 ms · 245,761 rows read (5.5 MB)
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
-- Measured: 6.99 s · 875 M rows read (52.7 GB) · 302.6 MB memory

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
-- Measured: 2.94 s · 875 M rows read (52.5 GB) · 462 MB memory

SELECT Cluster, count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
GROUP BY Cluster
SETTINGS use_skip_indexes = 0;
-- Measured: 14 ms · 745,472 rows read (32.5 MB) · 99.9 MB memory
-- What to look for: the first run reads everything, the second almost nothing.

SET use_query_condition_cache = 0;


-- STEP 8 · Three replicas on the same scan
--  The same full scan, first on one replica, then split across the 3 replicas
--  of the service (parallel replicas). Storage is shared: no data moves.
SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null;
-- Measured: 7.03 s · 875 M rows read (55.8 GB) · 398.4 MB memory

SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null
SETTINGS enable_parallel_replicas = 1;
-- Measured: 3.56 s · 875 M rows read (55.8 GB) · 261 MB memory
-- What to look for: about twice as fast with 3 replicas, without changing the SQL.
