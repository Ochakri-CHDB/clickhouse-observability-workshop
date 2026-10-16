-- =====================================================================
--  MODULE 1 · The data model: the OpenTelemetry tables
-- =====================================================================
--  OpenTelemetry describes three signals with the same building blocks:
--    · Resource: who emits (service.name, service.version, k8s.pod.name, k8s.node.name...)
--    · Scope: which library or logger emitted it (ScopeName, ScopeVersion)
--    · Attributes: the details of this one event (http.route, payment.id, db.system...)
--    · plus the body of a log, the duration and parent of a span, the value of a metric
--  ClickStack calls this "wide events": rich records, high cardinality allowed, all in
--  one database, correlated by TraceId, SpanId and the resource attributes.
--
--  The ClickHouse exporter of the OpenTelemetry collector creates these tables. We create
--  them with its exact DDL (from the ClickStack documentation), so that ClickStack
--  recognises them as sources without any mapping (module 3).
--
--  What to read in these definitions (rule schema-pk-plan-before-creation):
--    · otel_logs is sorted by 5-minute bucket, then service, then time: logs are almost
--      always read "last N minutes, this service".
--    · otel_traces is sorted by service, then span name, then time.
--    · attributes are Map(LowCardinality(String), String): any key, no schema change.
--      The most used ones are promoted to MATERIALIZED columns (__hdx_materialized_*).
--    · text indexes (TYPE text) on the body and on the attribute items make full-text
--      search and "key=value" filters skip most granules (modules 3 and 7).
--    · bloom filters on TraceId, minmax on Duration.
--    · DateTime64(9) with Delta + ZSTD: nanosecond timestamps almost for free.
--    · PARTITION BY day and TTL with ttl_only_drop_parts: expired days are dropped as
--      whole parts. The retention here is 3 years, so that the month of workshop data
--      never expires during the course; ClickStack's default is 3 days (module 7).
-- =====================================================================


-- STEP 1 · Logs, traces and metrics: the exact DDL of the exporter
-- 1a · logs
CREATE OR REPLACE TABLE payflow_otel.otel_logs
(
  `Timestamp` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
  `TraceId` String CODEC(ZSTD(1)),
  `SpanId` String CODEC(ZSTD(1)),
  `TraceFlags` UInt8,
  `SeverityText` LowCardinality(String) CODEC(ZSTD(1)),
  `SeverityNumber` UInt8,
  `ServiceName` LowCardinality(String) CODEC(ZSTD(1)),
  `Body` String CODEC(ZSTD(1)),
  `ResourceSchemaUrl` LowCardinality(String) CODEC(ZSTD(1)),
  `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
  `ScopeSchemaUrl` LowCardinality(String) CODEC(ZSTD(1)),
  `ScopeName` String CODEC(ZSTD(1)),
  `ScopeVersion` LowCardinality(String) CODEC(ZSTD(1)),
  `ScopeAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
  `LogAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
  `EventName` String CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.cluster.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.cluster.name'] CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.container.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'] CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.deployment.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.deployment.name'] CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.namespace.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'] CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.node.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'] CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.pod.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'] CODEC(ZSTD(1)),
  `__hdx_materialized_k8s.pod.uid` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.uid'] CODEC(ZSTD(1)),
  `__hdx_materialized_deployment.environment.name` LowCardinality(String) MATERIALIZED ResourceAttributes['deployment.environment.name'] CODEC(ZSTD(1)),
  `ResourceAttributeItems` Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), ResourceAttributes::Array(Tuple(String, String))),
  `ScopeAttributeItems` Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), ScopeAttributes::Array(Tuple(String, String))),
  `LogAttributeItems` Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), LogAttributes::Array(Tuple(String, String))),
  INDEX idx_trace_id TraceId TYPE text(tokenizer = 'array'),
  INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE text(tokenizer = 'array'),
  INDEX idx_res_attr_items ResourceAttributeItems TYPE text(tokenizer = 'array'),
  INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE text(tokenizer = 'array'),
  INDEX idx_scope_attr_items ScopeAttributeItems TYPE text(tokenizer = 'array'),
  INDEX idx_log_attr_key mapKeys(LogAttributes) TYPE text(tokenizer = 'array'),
  INDEX idx_log_attr_items LogAttributeItems TYPE text(tokenizer = 'array'),
  INDEX idx_lower_body lower(Body) TYPE text(tokenizer = 'splitByNonAlpha')

)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)
TTL toDateTime(Timestamp) + toIntervalYear(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1, enable_block_number_column = 1, enable_block_offset_column = 1;

-- 1b · traces (one row per span)
CREATE OR REPLACE TABLE payflow_otel.otel_traces
(
    `Timestamp` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TraceId` String CODEC(ZSTD(1)),
    `SpanId` String CODEC(ZSTD(1)),
    `ParentSpanId` String CODEC(ZSTD(1)),
    `TraceState` String CODEC(ZSTD(1)),
    `SpanName` LowCardinality(String) CODEC(ZSTD(1)),
    `SpanKind` LowCardinality(String) CODEC(ZSTD(1)),
    `ServiceName` LowCardinality(String) CODEC(ZSTD(1)),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeName` String CODEC(ZSTD(1)),
    `ScopeVersion` String CODEC(ZSTD(1)),
    `SpanAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `Duration` UInt64 CODEC(ZSTD(1)),
    `StatusCode` LowCardinality(String) CODEC(ZSTD(1)),
    `StatusMessage` String CODEC(ZSTD(1)),
    `Events.Timestamp` Array(DateTime64(9)) CODEC(ZSTD(1)),
    `Events.Name` Array(LowCardinality(String)) CODEC(ZSTD(1)),
    `Events.Attributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
    `Links.TraceId` Array(String) CODEC(ZSTD(1)),
    `Links.SpanId` Array(String) CODEC(ZSTD(1)),
    `Links.TraceState` Array(String) CODEC(ZSTD(1)),
    `Links.Attributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
    `__hdx_materialized_rum.sessionId` String MATERIALIZED ResourceAttributes['rum.sessionId'] CODEC(ZSTD(1)),
    `SampleRate` UInt64 MATERIALIZED greatest(toUInt64OrZero(SpanAttributes['SampleRate']), 1) CODEC(T64, ZSTD(1)),
    `ResourceAttributeItems` Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), ResourceAttributes::Array(Tuple(String, String))),
    `SpanAttributeItems` Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), SpanAttributes::Array(Tuple(String, String))),
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_rum_session_id __hdx_materialized_rum.sessionId TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_items ResourceAttributeItems TYPE text(tokenizer = 'array'),
    INDEX idx_span_attr_key mapKeys(SpanAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_span_attr_items SpanAttributeItems TYPE text(tokenizer = 'array'),
    INDEX idx_duration Duration TYPE minmax GRANULARITY 1,
    INDEX idx_lower_span_name lower(SpanName) TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 8

)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (ServiceName, SpanName, toDateTime(Timestamp))
TTL toDate(Timestamp) + toIntervalYear(3)
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;

-- 1c · metrics: gauges (a value at an instant: CPU, memory, pool usage)
CREATE OR REPLACE TABLE payflow_otel.otel_metrics_gauge
(
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ResourceSchemaUrl` String CODEC(ZSTD(1)),
    `ScopeName` String CODEC(ZSTD(1)),
    `ScopeVersion` String CODEC(ZSTD(1)),
    `ScopeAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeDroppedAttrCount` UInt32 CODEC(ZSTD(1)),
    `ScopeSchemaUrl` String CODEC(ZSTD(1)),
    `ServiceName` LowCardinality(String) CODEC(ZSTD(1)),
    `MetricName` String CODEC(ZSTD(1)),
    `MetricDescription` String CODEC(ZSTD(1)),
    `MetricUnit` String CODEC(ZSTD(1)),
    `Attributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `StartTimeUnix` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TimeUnix` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `Value` Float64 CODEC(ZSTD(1)),
    `Flags` UInt32 CODEC(ZSTD(1)),
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
    `Exemplars.TimeUnix` Array(DateTime64(9)) CODEC(ZSTD(1)),
    `Exemplars.Value` Array(Float64) CODEC(ZSTD(1)),
    `Exemplars.SpanId` Array(String) CODEC(ZSTD(1)),
    `Exemplars.TraceId` Array(String) CODEC(ZSTD(1)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1

)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
TTL toDateTime(TimeUnix) + toIntervalYear(3)
SETTINGS ttl_only_drop_parts = 1;

-- 1d · metrics: sums (counters: restarts, requests)
CREATE OR REPLACE TABLE payflow_otel.otel_metrics_sum
(
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ResourceSchemaUrl` String CODEC(ZSTD(1)),
    `ScopeName` String CODEC(ZSTD(1)),
    `ScopeVersion` String CODEC(ZSTD(1)),
    `ScopeAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeDroppedAttrCount` UInt32 CODEC(ZSTD(1)),
    `ScopeSchemaUrl` String CODEC(ZSTD(1)),
    `ServiceName` LowCardinality(String) CODEC(ZSTD(1)),
    `MetricName` String CODEC(ZSTD(1)),
    `MetricDescription` String CODEC(ZSTD(1)),
    `MetricUnit` String CODEC(ZSTD(1)),
    `Attributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `StartTimeUnix` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TimeUnix` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `Value` Float64 CODEC(ZSTD(1)),
    `Flags` UInt32 CODEC(ZSTD(1)),
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
    `Exemplars.TimeUnix` Array(DateTime64(9)) CODEC(ZSTD(1)),
    `Exemplars.Value` Array(Float64) CODEC(ZSTD(1)),
    `Exemplars.SpanId` Array(String) CODEC(ZSTD(1)),
    `Exemplars.TraceId` Array(String) CODEC(ZSTD(1)),
    `AggregationTemporality` Int32 CODEC(ZSTD(1)),
    `IsMonotonic` Bool CODEC(ZSTD(1)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1

)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
TTL toDateTime(TimeUnix) + toIntervalYear(3)
SETTINGS ttl_only_drop_parts = 1;

-- 1e · metrics: histograms (latency distributions)
CREATE OR REPLACE TABLE payflow_otel.otel_metrics_histogram
(
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ResourceSchemaUrl` String CODEC(ZSTD(1)),
    `ScopeName` String CODEC(ZSTD(1)),
    `ScopeVersion` String CODEC(ZSTD(1)),
    `ScopeAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeDroppedAttrCount` UInt32 CODEC(ZSTD(1)),
    `ScopeSchemaUrl` String CODEC(ZSTD(1)),
    `ServiceName` LowCardinality(String) CODEC(ZSTD(1)),
    `MetricName` String CODEC(ZSTD(1)),
    `MetricDescription` String CODEC(ZSTD(1)),
    `MetricUnit` String CODEC(ZSTD(1)),
    `Attributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `StartTimeUnix` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TimeUnix` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `Count` UInt64 CODEC(Delta(8), ZSTD(1)),
    `Sum` Float64 CODEC(ZSTD(1)),
    `BucketCounts` Array(UInt64) CODEC(ZSTD(1)),
    `ExplicitBounds` Array(Float64) CODEC(ZSTD(1)),
    `Exemplars.FilteredAttributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
    `Exemplars.TimeUnix` Array(DateTime64(9)) CODEC(ZSTD(1)),
    `Exemplars.Value` Array(Float64) CODEC(ZSTD(1)),
    `Exemplars.SpanId` Array(String) CODEC(ZSTD(1)),
    `Exemplars.TraceId` Array(String) CODEC(ZSTD(1)),
    `Flags` UInt32 CODEC(ZSTD(1)),
    `Min` Float64 CODEC(ZSTD(1)),
    `Max` Float64 CODEC(ZSTD(1)),
    `AggregationTemporality` Int32 CODEC(ZSTD(1)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_key mapKeys(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_attr_value mapValues(Attributes) TYPE bloom_filter(0.01) GRANULARITY 1

)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (ServiceName, MetricName, Attributes, toUnixTimestamp64Nano(TimeUnix))
TTL toDateTime(TimeUnix) + toIntervalYear(3)
SETTINGS ttl_only_drop_parts = 1;

-- STEP 2 · The trace lookup table, also created by the exporter
--  A tracing UI first asks "when did this trace happen?". This small table, sorted by
--  TraceId, keeps the first and last timestamp of each trace; its view fills it on every
--  insert into otel_traces. The real query then reads one narrow time window (module 7).
CREATE OR REPLACE TABLE payflow_otel.otel_traces_trace_id_ts
(
    TraceId  String CODEC(ZSTD(1)),
    Start    DateTime CODEC(Delta, ZSTD(1)),
    End      DateTime CODEC(Delta, ZSTD(1)),
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toDate(Start)
ORDER BY (TraceId, Start)
TTL toDate(Start) + toIntervalYear(3);

CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.otel_traces_trace_id_ts_mv TO payflow_otel.otel_traces_trace_id_ts AS
SELECT TraceId, min(Timestamp) AS Start, max(Timestamp) AS End
FROM payflow_otel.otel_traces
WHERE TraceId != ''
GROUP BY TraceId;


-- STEP 3 · Checkpoint
SELECT
    if((SELECT count() FROM system.tables WHERE database = 'payflow_otel' AND name LIKE 'otel\\_%' AND engine LIKE '%MergeTree') = 6, 'OK', 'KO') AS otel_tables,
    if((SELECT count() FROM system.data_skipping_indices WHERE database = 'payflow_otel' AND table = 'otel_logs' AND type = 'text') >= 7, 'OK', 'KO') AS text_indexes
SETTINGS select_sequential_consistency = 1;
-- Measured: 6 ms · 42 rows read (2.5 KB)
