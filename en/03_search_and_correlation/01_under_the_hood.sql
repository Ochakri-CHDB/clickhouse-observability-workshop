-- =====================================================================
--  MODULE 3 · Search and correlation: what ClickStack runs underneath
-- =====================================================================
--  ClickStack's search bar speaks Lucene (ServiceName:payment "HikariPool") or SQL.
--  Either way it becomes one ClickHouse query on otel_logs or otel_traces. This file
--  runs those queries by hand, to see why they are fast:
--    · the primary key skips by time and service
--    · the text index on lower(Body) answers full-text search (hasToken, hasAllTokens)
--    · the text indexes on the attribute items answer key=value filters on the maps
--    · TraceId links a log to its trace, the resource attributes link both to the metrics
--  The README of this module does the same in the ClickStack UI.
-- =====================================================================


-- STEP 1 · A search: payment errors that mention HikariPool, around 14:10
--  In ClickStack: ServiceName:payment SeverityText:ERROR "HikariPool"
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND ServiceName = 'payment' AND SeverityText = 'ERROR'
  AND hasAllTokens(lower(Body), ['hikaripool'])
ORDER BY Timestamp DESC
LIMIT 5;
-- Measured: 741 ms · 172,033 rows read (2.9 MB)

--  Which indexes did it use? Parts and granules skipped at each step.
EXPLAIN indexes = 1
SELECT count()
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND hasAllTokens(lower(Body), ['hikaripool']);
-- Measured: 8 ms · 33 rows read (1.3 KB)
-- What to look for: the partition and the primary key keep one day and ten minutes,
-- then idx_lower_body keeps only the granules that contain the word.


-- STEP 2 · A filter on an attribute: service.version, without a column for it
--  The resource attributes are a Map. ResourceAttributeItems is an ALIAS that turns each
--  pair into 'key=value'; its text index answers the filter without reading the map.
SELECT ResourceAttributes['k8s.pod.name'] AS pod, count() AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:45')
  AND has(ResourceAttributeItems, 'service.version=v2.4.1')
  AND SeverityText = 'ERROR'
GROUP BY pod
ORDER BY errors DESC;
-- Measured: 509 ms · 163,841 rows read (39.1 MB)

--  The materialized columns: the exporter promotes the most used attributes
SELECT name, type, default_expression
FROM system.columns
WHERE database = 'payflow_otel' AND table = 'otel_logs' AND default_kind = 'MATERIALIZED';
-- Measured: 2 ms · 27 rows read (3.5 KB)


-- STEP 3 · Correlation: from a log line to its trace, then to the pod metrics
WITH (SELECT any(TraceId) FROM payflow_otel.otel_logs
      WHERE ServiceName = 'checkout' AND SeverityText = 'ERROR'
        AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:05')) AS tid
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode, ResourceAttributes['k8s.pod.name'] AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN pf_at('14:09:55') AND pf_at('14:10:15')
ORDER BY Timestamp;
-- Measured: 1.87 s · 3.3 M rows read (19.4 MB) · 132.3 MB memory
-- What to look for: the trace of the failed payment. In ClickStack, one click on the log
-- line opens this waterfall, and the Infrastructure tab shows the metrics of the pod.

SELECT toStartOfMinute(toDateTime(TimeUnix)) AS minute, MetricName, round(avg(Value), 2) AS value
FROM payflow_otel.otel_metrics_gauge
WHERE ResourceAttributes['k8s.pod.name'] = 'payment-5c8b7f9d21-50d24'
  AND MetricName IN ('k8s.pod.cpu.utilization', 'hikaricp.connections.pending')
  AND TimeUnix BETWEEN pf_at('14:05') AND pf_at('14:10')
GROUP BY minute, MetricName
ORDER BY minute, MetricName;
-- Measured: 23 ms · 24,577 rows read (1.7 MB)
-- What to look for: the pod is not busy (low CPU), it waits (dozens of pending connections).


-- STEP 4 · Live tail: the last lines of the stream
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN now() - INTERVAL 2 MINUTE AND now()
ORDER BY Timestamp DESC
LIMIT 10;
-- Measured: 8 ms · 137,436 rows read (1.4 MB)


-- STEP 5 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
        AND hasAllTokens(lower(Body), ['hikaripool'])) > 1000, 'OK', 'KO')                                   AS full_text_search,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 0, 'OK', 'KO') AS live_tail
SETTINGS select_sequential_consistency = 1;
-- Measured: 84 ms · 295,287 rows read (2.4 MB)
