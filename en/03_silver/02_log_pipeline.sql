-- =====================================================================
--  MODULE 3 · Silver: from raw container logs to OpenTelemetry logs
-- =====================================================================
--  One parsing pipeline, written once, applied to every line at ingestion:
--    · detect the severity, whatever the language (nginx, Go, Java, Python)
--    · extract the trace id and span id, to link each log to its trace
--    · keep the message as Body, turn the useful fields into LogAttributes
--    · mask card numbers (PCI DSS) BEFORE the line is stored in silver
--  Materialized views run this on every INSERT into bronze: no batch job,
--  no stream processor, the database does it (rule mv-incremental).
-- =====================================================================


-- STEP 1 · The parsing rules, as SQL functions
--  Written once, used by the materialized view AND by the backfill below.
--  Severity: Go writes {"level":"error"}, Java " ERROR ", Python "ERROR:",
--  nginx only an HTTP status. We normalise to the OpenTelemetry names.
CREATE OR REPLACE FUNCTION pf_log_severity AS (line) ->
    replaceRegexpOne(replaceRegexpOne(upper(multiIf(
        startsWith(line, '{'),                       JSONExtractString(line, 'level'),
        match(line, '^\\d{4}-\\d{2}-\\d{2} '),       extract(line, '^\\S+ \\S+\\s+([A-Z]+) '),
        match(line, '^[A-Z]+:'),                     extract(line, '^([A-Z]+):'),
        match(line, '" \\d{3} '),                    multiIf(extract(line, '" (\\d)\\d{2} ') = '5', 'ERROR', extract(line, '" (\\d)\\d{2} ') = '4', 'WARN', 'INFO'),
        'INFO')), '^WARNING$', 'WARN'), '^CRITICAL$', 'FATAL');

CREATE OR REPLACE FUNCTION pf_severity_number AS (sev) ->
    toUInt8(multiIf(sev = 'TRACE', 1, sev = 'DEBUG', 5, sev = 'INFO', 9, sev = 'WARN', 13, sev = 'ERROR', 17, sev = 'FATAL', 21, 0));

--  Trace and span ids: every format writes them as trace_id=..., "trace_id":"..."
CREATE OR REPLACE FUNCTION pf_log_trace_id AS (line) -> extract(line, 'trace_id[=":]+([0-9a-f]{32})');
CREATE OR REPLACE FUNCTION pf_log_span_id  AS (line) -> extract(line, 'span_id[=":]+([0-9a-f]{16})');

--  The message: the "msg" field in JSON, the text after " : " in Java,
--  after the logger in Python, the whole line for nginx.
CREATE OR REPLACE FUNCTION pf_log_body AS (line) ->
    multiIf(startsWith(line, '{'), concat(JSONExtractString(line, 'msg'),
                                          if(JSONHas(line, 'error'), concat(': ', JSONExtractString(line, 'error')), '')),
            match(line, '^\\d{4}-\\d{2}-\\d{2} '), substring(line, position(line, ' : ') + 3),   -- Java: the text after " : "
            match(line, '^[A-Z]+:[a-z._]+:'), replaceRegexpOne(replaceRegexpOne(line, '^[A-Z]+:[a-z._]+:', ''), ' trace_id=[0-9a-f]+$', ''),
            line);

--  The logger (OpenTelemetry "scope"): Java class, Python logger, Go caller
CREATE OR REPLACE FUNCTION pf_log_scope AS (line) ->
    multiIf(startsWith(line, '{'), JSONExtractString(line, 'caller'),
            match(line, '^\\d{4}-\\d{2}-\\d{2} '), extract(line, '\\] ([A-Za-z0-9_.$]+) '),
            match(line, '^[A-Z]+:[a-z._]+:'), extract(line, '^[A-Z]+:([a-z._]+):'),
            'nginx.access');

--  Structured fields: every key of a JSON line, key=value pairs elsewhere,
--  and the access log fields for nginx. extractKeyValuePairs does the k=v work.
CREATE OR REPLACE FUNCTION pf_log_attributes AS (line) ->
    multiIf(startsWith(line, '{'),
                mapFilter((k, v) -> k NOT IN ('level', 'ts', 'msg', 'error', 'caller', 'trace_id', 'span_id'),
                          mapFromArrays(arrayMap(x -> x.1, JSONExtractKeysAndValuesRaw(line)),
                                        arrayMap(x -> trim(BOTH '"' FROM x.2), JSONExtractKeysAndValuesRaw(line)))),
            match(line, '" \\d{3} '),
                map('client.address', extract(line, '^(\\S+) '),
                    'http.request.method', extract(line, '"([A-Z]+) '),
                    'url.path', extract(line, '"[A-Z]+ (\\S+) '),
                    'http.response.status_code', extract(line, '" (\\d{3}) '),
                    'http.server.request.duration', extract(line, 'rt=([0-9.]+)'),
                    'user_agent.original', extract(line, '"[^"]*" "([^"]*)"')),
            mapFilter((k, v) -> k NOT IN ('trace_id', 'span_id'), extractKeyValuePairs(pf_log_body(line), '=', ' ,', '"')));

--  PCI DSS: keep the first 6 and last 4 digits of any 13 to 19 digit number
CREATE OR REPLACE FUNCTION pf_mask_pan AS (s) -> replaceRegexpAll(s, '\\b([0-9]{6})[0-9]{3,9}([0-9]{4})\\b', '\\1******\\2');

SELECT
    line,
    pf_log_severity(line) AS severity,
    pf_log_trace_id(line) AS trace_id,
    pf_mask_pan(pf_log_body(line)) AS body,
    pf_log_scope(line) AS scope,
    pf_log_attributes(line) AS attributes
FROM
(
    SELECT JSONExtractString(payload, 'log') AS line
    FROM payflow_raw.log_records
    WHERE source = 'fluent-bit' AND received_at BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01'
      AND payload NOT LIKE '%health%'
    LIMIT 1 BY JSONExtractString(payload, 'kubernetes', 'labels', 'app'), pf_log_severity(JSONExtractString(payload, 'log'))
)
FORMAT Vertical;
-- Measured: 14 ms · 8,192 rows read (3.9 MB)
-- What to look for: one line per service and severity. Five formats in, one model out.


-- STEP 2 · The materialized views: bronze → silver, on every insert
--  A materialized view is a trigger: each block inserted into payflow_raw.log_records
--  goes through this SELECT, and the result is written into otel_logs.
--  Two views, one per source, write into the same table.
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_container_logs TO payflow_otel.otel_logs AS
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC')   AS Timestamp,
    pf_log_trace_id(line)                                                     AS TraceId,
    pf_log_span_id(line)                                                      AS SpanId,
    toUInt8(TraceId != '')                                                    AS TraceFlags,
    pf_log_severity(line)                                                     AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')                 AS ServiceName,
    pf_mask_pan(pf_log_body(line))                                            AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    map('service.name', ServiceName,
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', ServiceName,
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production')                          AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    pf_log_scope(line)                                                        AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))          AS LogAttributes,
    ''                                                                        AS EventName
FROM payflow_raw.log_records
WHERE source = 'fluent-bit';

--  Kubernetes events become log records too, with the event reason as EventName
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_k8s_events TO payflow_otel.otel_logs AS
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'firstTimestamp'), 9, 'UTC') AS Timestamp,
    ''                                                                        AS TraceId,
    ''                                                                        AS SpanId,
    toUInt8(0)                                                                AS TraceFlags,
    if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO')        AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    'k8s-events'                                                              AS ServiceName,
    JSONExtractString(payload, 'message')                                     AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    map('k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'involvedObject', 'namespace'),
        'k8s.node.name', JSONExtractString(payload, 'source', 'host'),
        'k8s.pod.name', if(JSONExtractString(payload, 'involvedObject', 'kind') = 'Pod', JSONExtractString(payload, 'involvedObject', 'name'), ''),
        'deployment.environment.name', 'production')                          AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    'k8sobjects'                                                              AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    map('k8s.event.reason', JSONExtractString(payload, 'reason'),
        'k8s.event.type', JSONExtractString(payload, 'type'),
        'k8s.object.kind', JSONExtractString(payload, 'involvedObject', 'kind'),
        'k8s.object.name', JSONExtractString(payload, 'involvedObject', 'name'),
        'k8s.event.source', JSONExtractString(payload, 'source', 'component'))    AS LogAttributes,
    JSONExtractString(payload, 'reason')                                      AS EventName
FROM payflow_raw.log_records
WHERE source = 'k8s-events';


-- STEP 3 · Backfill: the views only see NEW inserts
--  Bronze already holds the day until 20:00, loaded before the views existed.
--  We replay it once with the same rules, in two batches (each under 60 s).
--  The SELECT is the one of the view: written with the functions, it stays short.
INSERT INTO payflow_otel.otel_logs
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
WHERE source = 'fluent-bit' AND received_at < '2026-11-27 12:00:00';
-- Measured: 4.86 s · 2.1 M rows read (1000.3 MB) · 2.1 M rows written · 6.2 GB memory

INSERT INTO payflow_otel.otel_logs
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
WHERE source = 'fluent-bit' AND received_at >= '2026-11-27 12:00:00';
-- Measured: 7.88 s · 3.9 M rows read (1.8 GB) · 3.9 M rows written · 7.5 GB memory

--  The Kubernetes events: a few hundred rows
INSERT INTO payflow_otel.otel_logs
    (Timestamp, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes, EventName)
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'firstTimestamp'), 9, 'UTC'),
    if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO'),
    pf_severity_number(if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO')),
    'k8s-events',
    JSONExtractString(payload, 'message'),
    map('k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'involvedObject', 'namespace'),
        'k8s.node.name', JSONExtractString(payload, 'source', 'host'),
        'k8s.pod.name', if(JSONExtractString(payload, 'involvedObject', 'kind') = 'Pod', JSONExtractString(payload, 'involvedObject', 'name'), ''),
        'deployment.environment.name', 'production'),
    'k8sobjects',
    map('k8s.event.reason', JSONExtractString(payload, 'reason'),
        'k8s.event.type', JSONExtractString(payload, 'type'),
        'k8s.object.kind', JSONExtractString(payload, 'involvedObject', 'kind'),
        'k8s.object.name', JSONExtractString(payload, 'involvedObject', 'name'),
        'k8s.event.source', JSONExtractString(payload, 'source', 'component')),
    JSONExtractString(payload, 'reason')
FROM payflow_raw.log_records
WHERE source = 'k8s-events';
-- Measured: 68 ms · 4,334 rows read (1.6 MB) · 354 rows written


-- STEP 4 · The continuous flow: the evening arrives
--  From now on, nothing else to do: we insert the evening into bronze,
--  the two views fill silver in the same transaction.
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 72000, to_s = 86400);   -- 20:00 to 24:00
-- Measured: 18.7 s · 4.3 M rows read (2 GB) · 4.3 M rows written · 4.8 GB memory

SELECT toStartOfHour(Timestamp) AS hour, count() AS log_records, countIf(SeverityText = 'ERROR') AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 18:00:00'
GROUP BY hour
ORDER BY hour;
-- Measured: 37 ms · 6 M rows read (49 MB) · 145.8 MB memory
-- What to look for: the 20:00 to 23:00 hours were written by the views, without any job.


-- STEP 5 · Did the masking work?
SELECT
    countIf(match(Body, '\\b[0-9]{13,19}\\b'))       AS full_pans_in_silver,
    countIf(Body LIKE '%pan=%******%')                AS masked_pans,
    any(if(Body LIKE '%pan=%', Body, NULL))           AS example
FROM payflow_otel.otel_logs
WHERE ServiceName = 'card-network-adapter';
-- Measured: 63 ms · 5.7 M rows read (373.3 MB) · 308.8 MB memory
-- What to look for: zero full card number in silver, every one is masked.


-- STEP 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs) = (SELECT count() FROM payflow_raw.log_records), 'OK', 'KO') AS one_log_per_record,
    if((SELECT countIf(match(Body, '\\b[0-9]{13,19}\\b')) FROM payflow_otel.otel_logs) = 0, 'OK', 'KO')       AS pci_masking,
    if((SELECT countIf(TraceId != '') / count() FROM payflow_otel.otel_logs) > 0.85, 'OK', 'KO')            AS trace_ids,
    if((SELECT max(Timestamp) FROM payflow_otel.otel_logs) > '2026-11-27 23:59:00', 'OK', 'KO')             AS continuous_flow
SETTINGS select_sequential_consistency = 1;
-- Measured: 219 ms · 16.3 M rows read (755.6 MB) · 225.8 MB memory
