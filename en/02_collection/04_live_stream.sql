-- =====================================================================
--  MODULE 2 · Collection (4/4): a live stream, and a switch to break things
-- =====================================================================
--  The Black Friday day is history: it is dated 27 November 2026. ClickStack's
--  live tail, its "last 15 minutes" and its alerts need data arriving NOW.
--  Three refreshable materialized views replay one minute of recorded traffic
--  every minute, shifted to the current time (traffic replay):
--    · normal mode: a quiet hour of the day (10:00 to 11:00)
--    · chaos mode: the worst minutes of the incident (14:05 to 14:35), with the
--      faulty v2.4.1 pods, the HikariPool timeouts and the angry customers
--  Trace ids get a suffix per minute: logs and traces of the stream stay linked.
--  REFRESH EVERY 1 MINUTE APPEND: each refresh adds rows, and the materialized views
--  of the next modules (RED rollups, trace lookup) see them like any insert.
--
--  Watch out: a view refreshed every minute keeps the service awake (no idling).
--  The stream stops by itself after 8 hours; stop_live_stream.sql stops it at once.
-- =====================================================================


-- STEP 1 · The switch
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


-- STEP 2 · The three replay views: spans, logs, pod and pool metrics
--  src = the recorded minute to replay, dst = the minute that just ended.
CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_traces
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_traces AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    if(chaos = 1, toDateTime('2026-11-27 14:05:00', 'UTC') + toIntervalMinute(toMinute(now()) % 30),
                  toDateTime('2026-11-27 10:00:00', 'UTC') + toIntervalMinute(toMinute(now()) % 60)) AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    concat(substring(TraceId, 1, 24), salt)                          AS TraceId,
    arrayMap(x -> addSeconds(x, shift), `Events.Timestamp`)          AS `Events.Timestamp`)
FROM
(
    -- filter in a subquery: the REPLACE aliases above are global and would shift the filter too
    SELECT * FROM payflow_otel.otel_traces
    WHERE Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND toDate(Timestamp) = '2026-11-27'      -- never replay the replayed rows
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- read what the other replicas just wrote

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_logs
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_logs AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    if(chaos = 1, toDateTime('2026-11-27 14:05:00', 'UTC') + toIntervalMinute(toMinute(now()) % 30),
                  toDateTime('2026-11-27 10:00:00', 'UTC') + toIntervalMinute(toMinute(now()) % 60)) AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    if(TraceId = '', '', concat(substring(TraceId, 1, 24), salt))    AS TraceId)
FROM
(
    -- filter in a subquery: the REPLACE aliases above are global and would shift the filter too
    SELECT * FROM payflow_otel.otel_logs
    WHERE Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND toDate(Timestamp) = '2026-11-27'
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- read what the other replicas just wrote

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_metrics
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_metrics_gauge AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    if(chaos = 1, toDateTime('2026-11-27 14:05:00', 'UTC') + toIntervalMinute(toMinute(now()) % 30),
                  toDateTime('2026-11-27 10:00:00', 'UTC') + toIntervalMinute(toMinute(now()) % 60)) AS src,
    dateDiff('second', src, dst)                                     AS shift
SELECT * REPLACE (
    addSeconds(StartTimeUnix, shift)                                 AS StartTimeUnix,
    addSeconds(TimeUnix, shift)                                      AS TimeUnix)
FROM
(
    -- filter in a subquery: the REPLACE aliases above are global and would shift the filter too
    SELECT * FROM payflow_otel.otel_metrics_gauge
    WHERE TimeUnix >= src AND TimeUnix < src + INTERVAL 1 MINUTE
      AND toDate(TimeUnix) = '2026-11-27'
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- read what the other replicas just wrote

SYSTEM WAIT VIEW payflow_sim.rmv_live_traces;
SYSTEM WAIT VIEW payflow_sim.rmv_live_logs;
SYSTEM WAIT VIEW payflow_sim.rmv_live_metrics;


-- STEP 3 · Is it live?
SELECT 'spans' AS signal, count() AS last_minutes, max(Timestamp) AS latest FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()
UNION ALL
SELECT 'logs', count(), max(Timestamp) FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()
UNION ALL
SELECT 'metric points', count(), max(TimeUnix) FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix BETWEEN now() - INTERVAL 5 MINUTE AND now();
-- Measured: 9 ms · 76,317 rows read (596.2 KB)
-- What to look for: one quiet minute of traffic per minute (about 9,000 spans and 3,000 log
-- lines), stamped with the current time. In ClickStack, "Last 15 minutes" now shows live traffic.
-- Watch out: the Black Friday day is dated in the future until 27 November 2026. A filter
-- such as Timestamp > now() - INTERVAL 5 MINUTE would also catch it: always bound both ends.

SELECT view, status, last_success_time, next_refresh_time, written_rows
FROM system.view_refreshes
WHERE database = 'payflow_sim';
-- Measured: 1 ms · 31 rows read (13.5 KB)


-- STEP 4 · Checkpoint
SELECT
    if((SELECT count() FROM system.view_refreshes WHERE database = 'payflow_sim' AND status != 'Error') = 3, 'OK', 'KO') AS three_live_views,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 500, 'OK', 'KO')  AS live_spans,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 200, 'OK', 'KO')    AS live_logs
SETTINGS select_sequential_consistency = 1;
-- Measured: 30 ms · 73,745 rows read (589.4 KB)

--  To break production (module 5), from any SQL tab:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
--  To fix it:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
