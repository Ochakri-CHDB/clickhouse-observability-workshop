-- =====================================================================
--  MODULE 5 · Gold: SLOs, error budget burn rate and alerts
-- =====================================================================
--  An SLO turns "is it working?" into a number. The gateway promises 99.95%
--  of successful payments: the error budget is 0.05% of requests. The burn
--  rate says how fast the budget is spent: 1 = exactly on budget over the
--  month, 14.4 = the whole month's budget gone in 2 days.
--  Multi-window alerting (Google SRE workbook): page when BOTH the last
--  hour and the last 5 minutes burn faster than 14.4. The 1 h window avoids
--  paging on a blip, the 5 min window stops the alert as soon as it is fixed.
--
--  Refreshable materialized views recompute these tables on a schedule
--  (REFRESH EVERY 1 MINUTE): the right tool for windows and joins that an
--  incremental view cannot express.
-- =====================================================================


-- STEP 1 · The burn rate, minute by minute, for every gateway route
CREATE OR REPLACE TABLE payflow_sre.slo_burn
(
    minute        DateTime('UTC'),
    route         LowCardinality(String),
    requests      UInt64,
    errors        UInt64,
    slo_target    Float32,
    burn_5m       Float64,
    burn_1h       Float64,
    fast_burn     Bool
)
ENGINE = MergeTree
ORDER BY (route, minute);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_slo_burn
REFRESH EVERY 1 MINUTE
TO payflow_sre.slo_burn AS
WITH dictGet('payflow_ref.dict_service', 'slo_target', 'api-gateway') AS target
SELECT
    minute, route, n_req AS requests, n_err AS errors, target AS slo_target,
    sum(n_err) OVER w5 / greatest(sum(n_req) OVER w5, 1) / (1 - target / 100)   AS burn_5m,
    sum(n_err) OVER w60 / greatest(sum(n_req) OVER w60, 1) / (1 - target / 100) AS burn_1h,
    burn_5m > 14.4 AND burn_1h > 14.4                                             AS fast_burn
FROM
(
    SELECT minute, operation AS route, sum(requests) AS n_req, sum(errors) AS n_err
    FROM payflow_sre.red_1m
    WHERE service = 'api-gateway'
    GROUP BY minute, route
)
WINDOW w5  AS (PARTITION BY route ORDER BY minute ROWS BETWEEN 4 PRECEDING AND CURRENT ROW),
       w60 AS (PARTITION BY route ORDER BY minute ROWS BETWEEN 59 PRECEDING AND CURRENT ROW);

SYSTEM WAIT VIEW payflow_sre.rmv_slo_burn;   -- wait for the first refresh before reading (and before views that depend on it)

SELECT minute, requests, errors, round(burn_5m, 1) AS burn_5m, round(burn_1h, 1) AS burn_1h, fast_burn
FROM payflow_sre.slo_burn
WHERE route = 'POST /v1/payments' AND minute BETWEEN '2026-11-27 13:56:00' AND '2026-11-27 14:06:00'
ORDER BY minute;
-- Measured: 15 ms · 5,760 rows read (208.7 KB)
-- What to look for: the 5 min window crosses 14.4 at 13:58, the 1 h window a little
-- later. The alert fires when both are above: detection time, in minutes.


-- STEP 2 · The alert rules, evaluated every minute
--  Four rules, one table. Each rule produces FIRING when its condition becomes
--  true and RESOLVED when it stops (lagInFrame compares a minute with the previous one).
--    · SLO fast burn on a gateway route
--    · p99 latency of payment.AuthorizePayment above 1 s for 3 minutes in a row
--    · a container restarted (counter k8s.container.restarts went up)
--    · a node reports memory pressure (Kubernetes event)
CREATE OR REPLACE TABLE payflow_sre.alerts
(
    ts        DateTime('UTC'),
    rule      LowCardinality(String),
    severity  LowCardinality(String),
    service   LowCardinality(String),
    state     LowCardinality(String),    -- FIRING / RESOLVED
    summary   String
)
ENGINE = MergeTree
ORDER BY (ts, rule);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_alerts
REFRESH EVERY 1 MINUTE
DEPENDS ON payflow_sre.rmv_slo_burn
TO payflow_sre.alerts AS
SELECT ts, rule, severity, service, state, summary
FROM
(
    -- rule 1: fast burn, per route
    SELECT minute AS ts, 'slo_fast_burn' AS rule, 'page' AS severity, 'api-gateway' AS service,
           if(fast_burn, 'FIRING', 'RESOLVED') AS state,
           if(fast_burn, concat(route, ': error budget burning ', toString(round(burn_1h)), 'x faster than allowed (1 h window)'),
                         concat(route, ': back under the threshold on the 5 min window (burn ', toString(round(burn_5m, 1)), ')')) AS summary,
           fast_burn != lagInFrame(fast_burn, 1, false) OVER (PARTITION BY route ORDER BY minute) AS changed
    FROM payflow_sre.slo_burn

    UNION ALL

    -- rule 2: p99 above 1 s for 3 consecutive minutes
    SELECT minute, 'p99_latency', 'ticket', 'payment', if(slow3, 'FIRING', 'RESOLVED'),
           concat('payment.AuthorizePayment p99 = ', toString(round(p99_ms)), ' ms'),
           slow3 != lagInFrame(slow3, 1, false) OVER (ORDER BY minute)
    FROM
    (
        SELECT minute, p99_ms,
               min(p99_ms) OVER (ORDER BY minute ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) > 1000 AS slow3
        FROM
        (
            SELECT minute, quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 AS p99_ms
            FROM payflow_sre.red_1m
            WHERE service = 'payment' AND operation = 'payment.AuthorizePayment'
            GROUP BY minute
        )
    )

    UNION ALL

    -- rule 3: container restarts (the counter only goes up)
    SELECT toDateTime(TimeUnix), 'container_restart', 'ticket', ServiceName, 'FIRING',
           concat(ResourceAttributes['k8s.pod.name'], ' restarted on ', ResourceAttributes['k8s.node.name']),
           Value > lagInFrame(Value, 1, Value) OVER (PARTITION BY ResourceAttributes['k8s.pod.name'] ORDER BY TimeUnix)
    FROM payflow_otel.otel_metrics_sum
    WHERE MetricName = 'k8s.container.restarts'

    UNION ALL

    -- rule 4: node memory pressure, straight from the Kubernetes events
    SELECT toDateTime(Timestamp), 'node_memory_pressure', 'ticket', 'kubernetes',
           if(EventName = 'NodeHasInsufficientMemory', 'FIRING', 'RESOLVED'), Body, true
    FROM payflow_otel.otel_logs
    WHERE ServiceName = 'k8s-events' AND EventName IN ('NodeHasInsufficientMemory', 'NodeHasSufficientMemory')
)
WHERE changed;

SYSTEM WAIT VIEW payflow_sre.rmv_alerts;

SELECT ts, rule, severity, service, state, summary
FROM payflow_sre.alerts
ORDER BY ts;
-- Measured: 26 ms · 11 rows read (1 KB)
-- What to look for: the whole incident in a dozen lines. The first page, the
-- latency ticket, the node memory pressure, the OOM restart, then the RESOLVED lines.


-- STEP 3 · Mean time to detect
SELECT
    toDateTime('2026-11-27 13:58:00', 'UTC')                                                  AS deployed,
    (SELECT min(ts) FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'FIRING') AS first_page,
    dateDiff('minute', deployed, first_page)                                                   AS minutes_to_detect;
-- Measured: 4 ms · 12 rows read


-- STEP 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'FIRING') >= 1, 'OK', 'KO') AS page_fired,
    if((SELECT count() FROM payflow_sre.alerts WHERE rule = 'container_restart') = 1, 'OK', 'KO')                    AS restart_alert,
    if((SELECT max(ts) FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'RESOLVED') > '2026-11-27 14:40:00', 'OK', 'KO') AS resolved
SETTINGS select_sequential_consistency = 1;
-- Measured: 23 ms · 34 rows read
