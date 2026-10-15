-- =====================================================================
--  MODULE 8 · AI and governance (SQL part): deletion, rights, self-observability
-- =====================================================================
--  An observability platform holds personal data and production secrets:
--    · delete what must be deleted (GDPR), without rewriting the table
--    · show each team its own namespace only (the same rule applies in ClickStack)
--    · observe ClickHouse itself with its system tables
--  The README of this module covers the ClickStack side: AI Notebooks, MCP, ClickHouse
--  Agents, RBAC, the status API and read/write isolation.
-- =====================================================================


-- STEP 1 · GDPR: a merchant asks to delete its personal data from the logs
--  Lightweight DELETE marks the rows as deleted at once (they disappear from every
--  query), the space is reclaimed by the next merges. No full rewrite of the table.
SELECT count() AS lines_before FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Measured: 540 ms · 3.4 M rows read (19.1 MB) · 206.7 MB memory

DELETE FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Measured: 1.03 s

SELECT count() AS lines_after FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042';
-- Measured: 69 ms · 3.4 M rows read (20.6 MB) · 265 MB memory


-- STEP 2 · Each team sees its own namespace
--  A role per team, a row policy per table: the filter is added by the database
--  to every query of the role, including through views and ClickStack.
CREATE ROLE IF NOT EXISTS payflow_team_payments;
GRANT SELECT ON payflow_otel.* TO payflow_team_payments;
GRANT SELECT ON payflow_sre.* TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_logs   ON payflow_otel.otel_logs   USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
CREATE ROW POLICY OR REPLACE pf_payments_traces ON payflow_otel.otel_traces USING ResourceAttributes['k8s.namespace.name'] = 'payments' TO payflow_team_payments;
--  The gateway landing table is the pipeline's, nobody else writes to it.
REVOKE ALL ON payflow_ingest.* FROM payflow_team_payments;
-- Measured: 5 ms

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE short_name LIKE 'pf\\_%';
-- Measured: 1 ms · 13 rows read (3.1 KB)


-- STEP 3 · Observe the observability platform
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
-- Measured: 23 ms · 17,263 rows read (605.3 KB)

SELECT view_name, count() AS runs, round(avg(view_duration_ms), 1) AS avg_ms, sum(written_rows) AS rows_written
FROM clusterAllReplicas('default', system.query_views_log)
WHERE event_date >= today() - 1 AND view_name LIKE 'payflow\\_%'
GROUP BY view_name
ORDER BY rows_written DESC;
-- Measured: 17 ms · 2,927 rows read (55.4 KB)
-- What to look for: the materialized views of modules 3 and 5, how often they ran
-- and how many rows they wrote. This is the health of the pipeline.


-- STEP 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE LogAttributes['merchant_id'] = 'm_00042') = 0, 'OK', 'KO') AS gdpr_delete,
    if((SELECT count() FROM system.row_policies WHERE short_name LIKE 'pf\\_payments%') = 2, 'OK', 'KO')            AS row_policies
SETTINGS select_sequential_consistency = 1;
-- Measured: 17 ms · 14 rows read (3.1 KB)
