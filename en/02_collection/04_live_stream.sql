-- =====================================================================
--  MODULE 2 · Collection (4/4): up to now, then live, and a switch to break things
-- =====================================================================
--  The simulated month ends with Black Friday. Between Black Friday and today there
--  are a few more days (one to seven, depending on the day you run the workshop),
--  and ClickStack's live tail, its "last 15 minutes" and its alerts need data
--  arriving NOW. The same simulator does both:
--    · catch-up: the days after Black Friday, up to the current minute (step 1)
--    · live stream: refreshable materialized views run the simulator every minute,
--      for the minutes not written yet (step 3). After an idle service wakes up,
--      they fill the gap themselves (up to 2 hours).
--    · chaos mode: three more views replay the worst minutes of Black Friday instead
--      (14:05 to 14:35), thinned to a quarter of their traffic: the faulty v2.4.1
--      pods, the HikariPool timeouts and the angry customers, now
--  REFRESH EVERY 1 MINUTE APPEND: each refresh adds rows, and the materialized views
--  of the next modules (RED rollups, trace lookup) see them like any insert. The logs
--  go to the landing table of the gateway: the live stream is parsed, enriched and
--  masked like the history.
--
--  Watch out: set the idling of your service to 1 hour or more. The views do not
--  keep it awake. The stream stops by itself after 8 hours; stop_live_stream.sql
--  stops it at once.
-- =====================================================================


-- STEP 1 · Catch-up: from the day after Black Friday to the current minute
--  Fixed windows, clipped to the current minute: on a Saturday the last ones are
--  empty, on a Friday they cover a whole week.
INSERT INTO payflow_ingest.agent_records
SELECT * FROM payflow_sim.raw_records(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = least(pf_day(5), toStartOfMinute(now())));
-- Measured: 20.7 s · 8 M rows read (2.7 GB) · 4.8 M rows written · 5.7 GB memory
INSERT INTO payflow_ingest.agent_records
SELECT * FROM payflow_sim.raw_records(from_t = least(pf_day(5), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Measured: 16.9 s · 5 M rows read (1.7 GB) · 3 M rows written · 3.7 GB memory

INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Measured: 22.9 s · 10.2 M rows read (444.3 MB) · 10.2 M rows written · 9.7 GB memory

INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Measured: 10 s · 37,275 rows read (304.3 KB) · 6.1 M rows written · 5.7 GB memory

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
SELECT * FROM payflow_sim.sum_metrics(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Measured: 2.34 s · 87 rows read (4.8 KB) · 453,887 rows written · 527.5 MB memory

SELECT toDate(Timestamp) AS day, toDayOfWeek(day) AS dow, count() AS spans
FROM payflow_otel.otel_traces
WHERE Timestamp >= pf_day(-2)
GROUP BY day
ORDER BY day;
-- Measured: 257 ms · 34.5 M rows read (263.3 MB) · 202 MB memory
-- What to look for: Black Friday, then every day up to today, the last one partial.


-- STEP 2 · The switch
--  One row per change. The latest row wins: enabled = 1 means chaos.
CREATE OR REPLACE TABLE payflow_sim.chaos
(
    changed_at   DateTime('UTC') DEFAULT now(),
    enabled      UInt8,
    live_until   DateTime('UTC') DEFAULT now() + INTERVAL 8 HOUR,
    note         String
)
ENGINE = MergeTree
ORDER BY changed_at;

INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'normal traffic');


-- STEP 3 · The live stream: the simulator, every minute
--  The live stream goes through landing tables of the gateway, like real agents: the
--  logs through agent_records (file 02), the spans and metrics through three more Null
--  tables, the OTLP receiver of the gateway, whose views forward to the OpenTelemetry
--  tables. Each refresh reads the latest timestamp of an OpenTelemetry table to know
--  where it stopped; a refreshable view may not read the table it writes to, the
--  landing tables solve that too.
CREATE OR REPLACE TABLE payflow_ingest.otlp_spans AS payflow_otel.otel_traces ENGINE = Null;
CREATE OR REPLACE TABLE payflow_ingest.otlp_gauge AS payflow_otel.otel_metrics_gauge ENGINE = Null;
CREATE OR REPLACE TABLE payflow_ingest.otlp_sum AS payflow_otel.otel_metrics_sum ENGINE = Null;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_spans TO payflow_otel.otel_traces AS SELECT * FROM payflow_ingest.otlp_spans;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_gauge TO payflow_otel.otel_metrics_gauge AS SELECT * FROM payflow_ingest.otlp_gauge;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_sum TO payflow_otel.otel_metrics_sum AS SELECT * FROM payflow_ingest.otlp_sum;

--  from_minute: the first minute not written yet (the latest timestamp of the table,
--  less 30 s for the spans and lines that end after their minute), at most 2 hours
--  back. to_minute: the current minute, or from_minute (nothing) in chaos mode.
CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_logs
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.agent_records AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(Timestamp) - INTERVAL 30 SECOND) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 3 HOUR AND now()), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(chaos = 0 AND now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * FROM payflow_sim.raw_records(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;   -- read what the other replicas just wrote

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_traces
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.otlp_spans AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(Timestamp) - INTERVAL 30 SECOND) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 3 HOUR AND now()), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(chaos = 0 AND now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_metrics
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.otlp_gauge AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(TimeUnix)) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix BETWEEN now() - INTERVAL 3 HOUR AND now()
          AND MetricName = 'k8s.node.condition_ready'), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(chaos = 0 AND now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * FROM payflow_sim.gauge_metrics(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_sums
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.otlp_sum AS
WITH
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(TimeUnix)) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_metrics_sum WHERE TimeUnix BETWEEN now() - INTERVAL 3 HOUR AND now()), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * FROM payflow_sim.sum_metrics(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;


-- STEP 4 · Chaos mode: replay the incident, now
--  dst = the minute that just ended, src = a minute of the incident. One trace in 4 is
--  kept (cityHash64(TraceId)): whole traces, three times the traffic of an ordinary day.
--  Trace ids get a suffix per minute, logs and traces of a replayed minute stay linked.
--  The filter is in a subquery: the REPLACE aliases are global and would shift it too.
CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_chaos_traces
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_traces AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    pf_at('14:05') + toIntervalMinute(toMinute(dst) % 30)            AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    concat(substring(TraceId, 1, 24), salt)                          AS TraceId,
    arrayMap(x -> addSeconds(x, shift), `Events.Timestamp`)          AS `Events.Timestamp`)
FROM
(
    SELECT * FROM payflow_otel.otel_traces
    WHERE chaos = 1 AND Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE AND cityHash64(TraceId) % 4 = 0
)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_chaos_logs
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_logs AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    pf_at('14:05') + toIntervalMinute(toMinute(dst) % 30)            AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    if(TraceId = '', '', concat(substring(TraceId, 1, 24), salt))    AS TraceId,
    -- the applications print the date in the line itself: replay it with today's date
    replaceAll(replaceAll(Body, toString(toDate(src)), toString(toDate(dst))),
               formatDateTime(src, '%d/%b/%Y'), formatDateTime(dst, '%d/%b/%Y')) AS Body)
FROM
(
    SELECT * FROM payflow_otel.otel_logs
    WHERE chaos = 1 AND Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND ServiceName != 'k8s-events' AND (TraceId = '' OR cityHash64(TraceId) % 4 = 0)
)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_chaos_metrics
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_metrics_gauge AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    pf_at('14:05') + toIntervalMinute(toMinute(dst) % 30)            AS src,
    dateDiff('second', src, dst)                                     AS shift
SELECT * REPLACE (
    addSeconds(StartTimeUnix, shift)                                 AS StartTimeUnix,
    addSeconds(TimeUnix, shift)                                      AS TimeUnix)
FROM
(
    SELECT * FROM payflow_otel.otel_metrics_gauge
    WHERE chaos = 1 AND TimeUnix >= src AND TimeUnix < src + INTERVAL 1 MINUTE
)
SETTINGS select_sequential_consistency = 1;

SYSTEM WAIT VIEW payflow_sim.rmv_live_logs;
SYSTEM WAIT VIEW payflow_sim.rmv_live_traces;
SYSTEM WAIT VIEW payflow_sim.rmv_live_metrics;
SYSTEM WAIT VIEW payflow_sim.rmv_live_sums;


-- STEP 5 · Is it live?
SELECT 'spans' AS signal, count() AS last_5_minutes, max(Timestamp) AS latest FROM payflow_otel.otel_traces WHERE Timestamp >= now() - INTERVAL 5 MINUTE
UNION ALL
SELECT 'logs', count(), max(Timestamp) FROM payflow_otel.otel_logs WHERE Timestamp >= now() - INTERVAL 5 MINUTE
UNION ALL
SELECT 'metric points', count(), max(TimeUnix) FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix >= now() - INTERVAL 5 MINUTE;
-- Measured: 12 ms · 726,010 rows read (5.5 MB)
-- What to look for: the minutes just before now, stamped with the current time. In
-- ClickStack, "Last 15 minutes" shows live traffic.

SELECT view, status, last_success_time, next_refresh_time, written_rows
FROM system.view_refreshes
WHERE database = 'payflow_sim'
ORDER BY view;
-- Measured: 2 ms · 31 rows read (13.5 KB)


-- STEP 6 · Checkpoint
SELECT
    if((SELECT count() FROM system.view_refreshes WHERE database = 'payflow_sim' AND status != 'Error') = 7, 'OK', 'KO') AS seven_live_views,
    if((SELECT max(Timestamp) FROM payflow_otel.otel_traces) BETWEEN now() - INTERVAL 3 MINUTE AND now(), 'OK', 'KO')      AS up_to_now,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp >= now() - INTERVAL 5 MINUTE) > 100, 'OK', 'KO')     AS live_spans,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp >= now() - INTERVAL 5 MINUTE) > 50, 'OK', 'KO')        AS live_logs,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp > now() + INTERVAL 1 MINUTE) = 0, 'OK', 'KO')        AS nothing_in_the_future
SETTINGS select_sequential_consistency = 1;
-- Measured: 101 ms · 316,246 rows read (2.4 MB)

--  To break production (module 5), from any SQL tab:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
--  To fix it:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
