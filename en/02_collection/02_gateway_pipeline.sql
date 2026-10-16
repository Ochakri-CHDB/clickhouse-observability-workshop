-- =====================================================================
--  MODULE 2 · Collection (2/4): the gateway, in SQL
-- =====================================================================
--  In production, the agents send to a collector in the gateway role (the
--  ClickStack collector), which runs processors before the ClickHouse exporter:
--      filter → transform → k8sattributes → redaction → batch → clickhouse exporter
--  Here the gateway runs inside ClickHouse, as the ClickHouse documentation suggests
--  for heavy processing: a landing table with the Null engine (it stores nothing),
--  and materialized views that process every inserted block on its way to the
--  OpenTelemetry tables. Each view plays one or several processors:
--    · filter        drop the kubelet health checks (noise, a share of the volume)
--    · transform     parse 4 log formats: severity, trace id, message, attributes
--    · k8sattributes add deployment, version, node, zone and team from the pod name
--    · redaction     mask card numbers; the Null table means no raw line is ever stored
--    · routing       container logs and Kubernetes events take different paths
--    · count         a connector: count every record per service and minute, before the filter
-- =====================================================================


-- STEP 1 · The landing table of the gateway
--  ENGINE = Null: an INSERT goes through the materialized views attached to the table,
--  then the data is thrown away. Nothing is stored twice, and the raw lines (with the
--  card numbers) never touch the disk.
CREATE OR REPLACE TABLE payflow_ingest.agent_records
(
    received_at  DateTime64(3, 'UTC'),
    source       LowCardinality(String),       -- filelog (container logs) or k8sobjects (events)
    payload      String
)
ENGINE = Null;


-- STEP 2 · transform: the parsing rules, as SQL functions
--  In the collector this is the transform processor (OTTL statements) or the filelog
--  operators. ClickHouse recommends doing this work in the database: it is faster and
--  cheaper than in the collector, and a rule change does not mean redeploying agents.
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
    FROM payflow_sim.raw_records(from_t = pf_at('14:10:00'), to_t = pf_at('14:10:01'))
    WHERE source = 'filelog' AND payload NOT LIKE '%health%'
    LIMIT 1 BY splitByChar('/', JSONExtractString(payload, 'log.file.path'))[6], pf_log_severity(JSONExtractString(payload, 'log'))
)
FORMAT Vertical;
-- Measured: 643 ms · 225 rows read (12.8 KB) · 60.6 MB memory
-- What to look for: one line per service and severity. Five formats in, one model out.

--  k8sattributes: the agent only knows the file path. The gateway parses it, then asks
--  the catalog (module 1 dictionaries) for the rest, as the processor asks the Kubernetes API.
CREATE OR REPLACE FUNCTION pf_pod_from_path AS (path) -> splitByChar('_', splitByChar('/', path)[5])[2];

CREATE OR REPLACE FUNCTION pf_k8s_resource AS (path) ->
    map('service.name',               dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)),
        'service.version',            dictGet('payflow_inventory.dict_pod', 'version', pf_pod_from_path(path)),
        'service.team',               dictGet('payflow_inventory.dict_service', 'team', dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path))),
        'k8s.cluster.name',           'payflow-prod-eu',
        'k8s.namespace.name',         splitByChar('_', splitByChar('/', path)[5])[1],
        'k8s.deployment.name',        dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)),
        'k8s.pod.name',               pf_pod_from_path(path),
        'k8s.pod.uid',                splitByChar('_', splitByChar('/', path)[5])[3],
        'k8s.container.name',         splitByChar('/', path)[6],
        'k8s.node.name',              dictGet('payflow_inventory.dict_pod', 'node_name', pf_pod_from_path(path)),
        'cloud.availability_zone',    dictGet('payflow_inventory.dict_node', 'zone', dictGet('payflow_inventory.dict_pod', 'node_name', pf_pod_from_path(path))),
        'deployment.environment.name', 'production');

--  filter: the kubelet probes, as the filter processor would drop them
CREATE OR REPLACE FUNCTION pf_is_health_check AS (line) ->
    line LIKE '%GET /healthz%' OR line LIKE '%health status UP%' OR line LIKE '%"msg":"health check"%';


-- STEP 3 · The processors, as materialized views on the landing table
--  Container logs: filter, then transform, k8sattributes and redaction in one SELECT.
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_gateway_logs TO payflow_otel.otel_logs AS
WITH JSONExtractString(payload, 'log') AS line,
     JSONExtractString(payload, 'log.file.path') AS path
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC')   AS Timestamp,
    pf_log_trace_id(line)                                                     AS TraceId,
    pf_log_span_id(line)                                                      AS SpanId,
    toUInt8(TraceId != '')                                                    AS TraceFlags,
    pf_log_severity(line)                                                     AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)) AS ServiceName,
    pf_mask_pan(pf_log_body(line))                                            AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    pf_k8s_resource(path)                                                     AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    pf_log_scope(line)                                                        AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    mapUpdate(mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line)),
              map('log.file.path', path, 'log.iostream', JSONExtractString(payload, 'stream'))) AS LogAttributes,
    ''                                                                        AS EventName
FROM payflow_ingest.agent_records
WHERE source = 'filelog' AND NOT pf_is_health_check(JSONExtractString(payload, 'log'));

--  routing: Kubernetes events take another path, with the event reason as EventName
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_gateway_k8s_events TO payflow_otel.otel_logs AS
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
        'k8s.event.source', JSONExtractString(payload, 'source', 'component'),
        -- what ClickStack's Pod Timeline reads: the event as the events.k8s.io API returns it
        'k8s.resource.name', 'events',
        'object', toJSONString(CAST((
            tuple(JSONExtractString(payload, 'firstTimestamp')),
            JSONExtractString(payload, 'reason'), JSONExtractString(payload, 'message'), JSONExtractString(payload, 'type'),
            (JSONExtractString(payload, 'involvedObject', 'kind'), JSONExtractString(payload, 'involvedObject', 'name'),
             JSONExtractString(payload, 'involvedObject', 'namespace'),
             dictGetOrDefault('payflow_inventory.dict_pod', 'pod_uid', JSONExtractString(payload, 'involvedObject', 'name'), ''))),
            'Tuple(metadata Tuple(creationTimestamp String), reason String, note String, type String, regarding Tuple(kind String, name String, namespace String, uid String))')))
                                                                              AS LogAttributes,
    JSONExtractString(payload, 'reason')                                      AS EventName
FROM payflow_ingest.agent_records
WHERE source = 'k8sobjects';

--  count: a connector. It counts every record per minute, service and severity, kept
--  or dropped by the filter. This is how you see what the filter saves.
CREATE OR REPLACE TABLE payflow_sre.log_volume_1m
(
    minute     DateTime('UTC'),
    service    LowCardinality(String),
    severity   LowCardinality(String),
    dropped    Bool,
    records    UInt64,
    bytes      UInt64
)
ENGINE = SummingMergeTree
ORDER BY (service, severity, dropped, minute);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.mv_log_volume_1m TO payflow_sre.log_volume_1m AS
WITH JSONExtractString(payload, 'log') AS line
SELECT
    toStartOfMinute(toDateTime(received_at))                                          AS minute,
    if(source = 'k8sobjects', 'k8s-events', dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(JSONExtractString(payload, 'log.file.path')))) AS service,
    if(source = 'k8sobjects', if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO'), pf_log_severity(line)) AS severity,
    source = 'filelog' AND pf_is_health_check(line)                                   AS dropped,
    count()                                                                           AS records,
    sum(length(payload))                                                              AS bytes
FROM payflow_ingest.agent_records
GROUP BY minute, service, severity, dropped;


-- STEP 4 · The agents send the month, through the gateway
--  Each INSERT runs the simulator, then the 3 views: parsing, enrichment and masking
--  happen in the same statement, under the 60 s of the console. The ordinary days go
--  by batches of 4 or 5 days; Black Friday, twelve times busier, by thirds of a day.
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-29), to_t = pf_day(-25));
-- Measured: 18.7 s · 8.1 M rows read (2.7 GB) · 4.8 M rows written · 5.8 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-25), to_t = pf_day(-21));
-- Measured: 20 s · 9 M rows read (3 GB) · 5.4 M rows written · 7.7 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-21), to_t = pf_day(-17));
-- Measured: 17.7 s · 8 M rows read (2.7 GB) · 4.8 M rows written · 6.1 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-17), to_t = pf_day(-13));
-- Measured: 19.4 s · 9 M rows read (3 GB) · 5.4 M rows written · 7.6 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-13), to_t = pf_day(-9));
-- Measured: 18 s · 8 M rows read (2.7 GB) · 4.8 M rows written · 5.8 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-9), to_t = pf_day(-5));
-- Measured: 17.5 s · 8.5 M rows read (2.9 GB) · 5.1 M rows written · 5.8 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-5), to_t = pf_day(0));
-- Measured: 19.6 s · 10.8 M rows read (3.6 GB) · 6.5 M rows written · 9 GB memory
--  Black Friday
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_at('00:00'), to_t = pf_at('10:00'));
-- Measured: 14.1 s · 4.9 M rows read (1.8 GB) · 3.2 M rows written · 4.8 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_at('10:00'), to_t = pf_at('17:00'));
-- Measured: 15.7 s · 7.3 M rows read (2.6 GB) · 4.8 M rows written · 6.8 GB memory
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_at('17:00'), to_t = pf_day(1));
-- Measured: 20.5 s · 11.7 M rows read (4.3 GB) · 7.7 M rows written · 10.7 GB memory

SELECT count() AS records_in_landing_table FROM payflow_ingest.agent_records;
-- Measured: 2 ms
-- What to look for: 0. The Null table kept nothing; everything is in otel_logs.


-- STEP 5 · What the gateway did
SELECT
    sum(records)                                                    AS received,
    sumIf(records, dropped)                                         AS dropped_by_filter,
    round(100 * sumIf(records, dropped) / sum(records), 1)          AS dropped_pct,
    formatReadableSize(sumIf(bytes, dropped))                       AS bytes_saved
FROM payflow_sre.log_volume_1m;
-- Measured: 54 ms · 822,544 rows read (13.3 MB)

SELECT ServiceName, ResourceAttributes['service.version'] AS version, ResourceAttributes['service.team'] AS team,
       ResourceAttributes['cloud.availability_zone'] AS zone, count() AS log_records
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND Timestamp BETWEEN pf_at('14:00') AND pf_at('14:05')
GROUP BY ALL
ORDER BY log_records DESC;
-- Measured: 29 ms · 502,877 rows read (3.8 MB)
-- What to look for: the agent only sent a file path. Version, team and zone were added
-- by the gateway. During the rollout, both versions log side by side.

SELECT
    countIf(match(Body, '\\b[0-9]{13,19}\\b'))       AS full_pans_stored,
    countIf(Body LIKE '%pan=%******%')                AS masked_pans,
    any(if(Body LIKE '%pan=%', Body, NULL))           AS example
FROM payflow_otel.otel_logs
WHERE ServiceName = 'card-network-adapter';
-- Measured: 376 ms · 20.7 M rows read (1.3 GB) · 324.2 MB memory
-- What to look for: zero full card number stored, every one masked.


-- STEP 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_ingest.agent_records) = 0, 'OK', 'KO')                                       AS nothing_stored_raw,
    if((SELECT count() FROM payflow_otel.otel_logs) = (SELECT sumIf(records, NOT dropped) FROM payflow_sre.log_volume_1m), 'OK', 'KO') AS every_kept_record_written,
    if((SELECT countIf(match(Body, '\\b[0-9]{13,19}\\b')) FROM payflow_otel.otel_logs) = 0, 'OK', 'KO')       AS pci_masking,
    if((SELECT countIf(ResourceAttributes['service.team'] = '' AND ServiceName != 'k8s-events') FROM payflow_otel.otel_logs) = 0, 'OK', 'KO') AS enrichment,
    if((SELECT countIf(TraceId != '') / count() FROM payflow_otel.otel_logs) > 0.9, 'OK', 'KO')                  AS trace_ids
SETTINGS select_sequential_consistency = 1;
-- Measured: 1.32 s · 73.8 M rows read (2.5 GB) · 324.3 MB memory
