-- =====================================================================
--  MODULE 7 · Scale and cost (1/3): from one day to a billion log lines
-- =====================================================================
--  PayFlow runs in 8 regions. Two weeks of logs for all of them is close to
--  a billion lines. We build that table, then measure what ClickHouse does
--  with it: storage, full-text search, trace lookup, projections, 3 replicas.
--
--  The XL table keeps the columns that matter for search (time, service,
--  severity, body, trace id, pod, node, cluster). The full OpenTelemetry schema,
--  with its maps and 8 indexes, costs about 10 times more to write: worth
--  knowing when sizing an ingestion pipeline.
-- =====================================================================


-- STEP 1 · The XL table: a text index on the body, a bloom filter on the trace id
--  The projection pre-aggregates errors per service and minute: dashboards
--  read it instead of the billion rows. It is declared in the CREATE so that
--  it is built while inserting (MATERIALIZE PROJECTION on a full table is slow).
CREATE OR REPLACE TABLE payflow_otel.logs_xl
(
    Timestamp     DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    TraceId       String CODEC(ZSTD(1)),
    SeverityText  LowCardinality(String),
    ServiceName   LowCardinality(String),
    Body          String CODEC(ZSTD(1)),
    Cluster       LowCardinality(String),
    PodName       LowCardinality(String),
    NodeName      LowCardinality(String),
    INDEX idx_lower_body lower(Body) TYPE text(tokenizer = 'splitByNonAlpha'),
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    PROJECTION p_errors_per_minute
    (
        SELECT Cluster, ServiceName, SeverityText, toStartOfMinute(Timestamp), count()
        GROUP BY Cluster, ServiceName, SeverityText, toStartOfMinute(Timestamp)
    )
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (ServiceName, Timestamp)
SETTINGS min_bytes_for_wide_part = 0;   -- one file per column even for small parts, to read sizes per column (step 3)


-- STEP 2 · 8 regions x 14 days, one region per statement
--  Each statement copies the day 14 times (shifted by d days) for one region,
--  with new trace ids. max_insert_threads = 16 writes in parallel.
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(0 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-eu-west', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 1/8: eu-west
-- Measured: 26.6 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.6 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(1 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-eu-central', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 2/8: eu-central
-- Measured: 26.7 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.7 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(2 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-us-east', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 3/8: us-east
-- Measured: 26.4 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.3 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(3 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-us-west', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 4/8: us-west
-- Measured: 26.7 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.6 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(4 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ap-south', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 5/8: ap-south
-- Measured: 26.5 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.6 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(5 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ap-northeast', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 6/8: ap-northeast
-- Measured: 27.1 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.9 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(6 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-sa-east', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 7/8: sa-east
-- Measured: 29.5 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.2 GB memory
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(7 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ca-central', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = '2026-11-27'
SETTINGS max_insert_threads = 16;   -- region 8/8: ca-central
-- Measured: 27.4 s · 7.8 M rows read (1.1 GB) · 109 M rows written · 10.7 GB memory


-- STEP 3 · What a billion log lines cost on disk
SELECT
    formatReadableQuantity(sum(rows))                                       AS log_lines,
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw,
    formatReadableSize(sum(data_compressed_bytes))                          AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1)     AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 1)                        AS bytes_per_line
FROM system.parts
WHERE database = 'payflow_otel' AND table = 'logs_xl' AND active;
-- Measured: 4 ms · 319 rows read (18.7 KB)

SELECT column,
       formatReadableSize(sum(column_data_compressed_bytes))   AS on_disk,
       round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'payflow_otel' AND table = 'logs_xl' AND active AND column NOT LIKE '\\_%'
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- Measured: 14 ms · 2,785 rows read (186.4 KB)
-- What to look for: Body is most of the storage. LowCardinality columns (service,
-- pod, node, cluster) cost almost nothing. Timestamps compress well with Delta.


-- STEP 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.logs_xl) > 850000000, 'OK', 'KO') AS billion_scale,
    if((SELECT uniqExact(Cluster) FROM payflow_otel.logs_xl) = 8, 'OK', 'KO') AS regions
SETTINGS select_sequential_consistency = 1;
-- Measured: 1.92 s · 875 M rows read (834.1 MB) · 246.1 MB memory
