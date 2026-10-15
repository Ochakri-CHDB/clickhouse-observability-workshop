-- =====================================================================
--  MODULE 7 · Operating the platform: retention, replay, deletion, security
-- =====================================================================
--  An observability platform is itself a production system:
--    · keep each layer as long as it is useful, not longer (TTL)
--    · fix a parsing rule and replay silver from bronze, atomically
--    · delete what must be deleted (GDPR), without rewriting the table
--    · show each team its own data only, and lock bronze (card numbers)
--    · observe ClickHouse itself with the system tables
-- =====================================================================


-- STEP 1 · Retention per layer
--  Each table already drops whole daily partitions after its TTL (here 3 years,
--  so that the workshop data never expires). A production policy looks like this:
--      ALTER TABLE payflow_raw.log_records   MODIFY TTL toDateTime(received_at) + INTERVAL 7 DAY;   -- raw lines, card numbers inside
--      ALTER TABLE payflow_otel.otel_logs    MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;
--      ALTER TABLE payflow_otel.otel_traces  MODIFY TTL toDate(Timestamp) + INTERVAL 15 DAY;
--      ALTER TABLE payflow_sre.red_1m        MODIFY TTL minute + INTERVAL 13 MONTH;               -- the rollups live long
--  Watch out: the workshop data is dated November 2026. Do not apply these on
--  your service after that date plus the TTL: ClickHouse would drop the data.
SELECT database, table, any(engine_full LIKE '%TTL%') AS has_ttl,
       formatReadableSize(sum(total_bytes)) AS size
FROM system.tables
WHERE database LIKE 'payflow\\_%' AND engine LIKE '%MergeTree'
GROUP BY database, table
ORDER BY sum(total_bytes) DESC;
-- Measured: 4 ms · 18 rows read (4.6 KB)
-- What to look for: the gold tables are a few MB, the raw and silver tables GB.
-- Long retention is cheap where the data is aggregated.


-- STEP 2 · Replay silver from bronze, and publish it atomically
--  Scenario: the parsing rules changed (here: they are the same, the mechanism
--  is what matters). We rebuild the day into a staging table, check it, then
--  swap the partition in one atomic operation: readers never see a half-built day.
CREATE OR REPLACE TABLE payflow_otel.otel_logs__build AS payflow_otel.otel_logs;

INSERT INTO payflow_otel.otel_logs__build
    (Timestamp, TraceId, SpanId, TraceFlags, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes)
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC'),
    pf_log_trace_id(line), pf_log_span_id(line), toUInt8(pf_log_trace_id(line) != ''),
    pf_log_severity(line), pf_severity_number(pf_log_severity(line)),
    JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
    pf_mask_pan(pf_log_body(line)),
    map('service.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production'),
    pf_log_scope(line),
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND toDate(parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'time'), 9, 'UTC')) = '2026-11-27';   -- OrZero: the WHERE may be evaluated before the source filter
-- Measured: 15.6 s · 8.1 M rows read (3.7 GB) · 8.1 M rows written · 11 GB memory

INSERT INTO payflow_otel.otel_logs__build
SELECT * EXCEPT (`__hdx_materialized_k8s.cluster.name`, `__hdx_materialized_k8s.container.name`, `__hdx_materialized_k8s.deployment.name`,
                 `__hdx_materialized_k8s.namespace.name`, `__hdx_materialized_k8s.node.name`, `__hdx_materialized_k8s.pod.name`,
                 `__hdx_materialized_k8s.pod.uid`, `__hdx_materialized_deployment.environment.name`)
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events' AND toDate(Timestamp) = '2026-11-27';
-- Measured: 236 ms · 5.2 M rows read (5.1 MB) · 354 rows written · 158.7 MB memory

--  Check before publishing: same number of lines per severity in prod and in the rebuild
SELECT
    SeverityText,
    countIf(_table = 'otel_logs')        AS prod,
    countIf(_table = 'otel_logs__build') AS rebuild,
    if(prod = rebuild, 'OK, ready to publish', 'KO, do not publish') AS verdict
FROM merge('payflow_otel', '^otel_logs(__build)?$')
WHERE toDate(Timestamp) = '2026-11-27'
GROUP BY SeverityText
ORDER BY SeverityText;
-- Measured: 60 ms · 16.3 M rows read (139.6 MB) · 216.3 MB memory

--  The atomic swap of the day
ALTER TABLE payflow_otel.otel_logs REPLACE PARTITION '2026-11-27' FROM payflow_otel.otel_logs__build;
DROP TABLE payflow_otel.otel_logs__build;


-- STEP 3 · GDPR: a merchant asks to delete its personal data from the logs
--  Lightweight DELETE marks the rows as deleted at once (they disappear from every
--  query), the space is reclaimed by the next merges. No full rewrite of the table.
SELECT count() AS lines_before FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Measured: 59 ms · 4.6 M rows read (24.2 MB) · 91.8 MB memory

DELETE FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Measured: 38.3 s

SELECT count() AS lines_after FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Measured: 60 ms · 3.5 M rows read (23 MB) · 174.3 MB memory


-- STEP 4 · Each team sees its own namespace
--  A role per team, a row policy per table: the filter is added by the database
--  to every query of the role, including through views and ClickStack.
CREATE ROLE IF NOT EXISTS payflow_team_payments;
GRANT SELECT ON payflow_otel.* TO payflow_team_payments;
GRANT SELECT ON payflow_sre.* TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_logs   ON payflow_otel.otel_logs   USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_traces ON payflow_otel.otel_traces USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
--  Bronze holds raw card numbers: nobody but the pipeline reads it.
REVOKE ALL ON payflow_raw.* FROM payflow_team_payments;
-- Measured: 13 ms

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE short_name LIKE 'pf\\_%';
-- Measured: 1 ms · 13 rows read (3.1 KB)


-- STEP 5 · Observe the observability platform
--  ClickHouse logs every query, every insert, every view execution. The same SQL
--  you used on the payment platform works on ClickHouse itself.
SYSTEM FLUSH LOGS;

SELECT
    query_kind,
    count()                                                    AS queries,
    round(quantile(0.5)(query_duration_ms))                    AS p50_ms,
    max(query_duration_ms)                                     AS max_ms,
    formatReadableQuantity(sum(read_rows))                     AS rows_read,
    formatReadableSize(max(memory_usage))                      AS max_memory
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND event_date >= today() - 1 AND has(databases, 'payflow_otel')
GROUP BY query_kind
ORDER BY queries DESC;
-- Measured: 25 ms · 60,908 rows read (2.1 MB)

SELECT view_name, count() AS runs, round(avg(view_duration_ms), 1) AS avg_ms, sum(written_rows) AS rows_written
FROM clusterAllReplicas('default', system.query_views_log)
WHERE event_date >= today() - 1 AND view_name LIKE 'payflow\\_%'
GROUP BY view_name
ORDER BY rows_written DESC;
-- Measured: 16 ms · 26,895 rows read (494.4 KB)
-- What to look for: the materialized views of modules 3 and 5, how often they ran
-- and how many rows they wrote. This is the health of the pipeline.


-- STEP 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE toDate(Timestamp) = '2026-11-27') > 8000000, 'OK', 'KO') AS replay_published,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042') = 0, 'OK', 'KO') AS gdpr_delete,
    if((SELECT count() FROM system.row_policies WHERE short_name LIKE 'pf\\_payments%') = 2, 'OK', 'KO')            AS row_policies
SETTINGS select_sequential_consistency = 1;
-- Measured: 37 ms · 8.1 M rows read (69.8 MB)
