-- =====================================================================
--  MODULE 5 · Gold : SLO, taux de consommation du budget d'erreur et alertes
-- =====================================================================
--  Un SLO transforme "est-ce que ça marche ?" en un chiffre. La gateway promet 99,95 %
--  de paiements réussis : le budget d'erreur est de 0,05 % des requêtes. Le taux de
--  consommation (burn rate) dit à quelle vitesse le budget part : 1 = pile dans le budget
--  sur le mois, 14,4 = tout le budget du mois consommé en 2 jours.
--  Alerte multi-fenêtres (Google SRE workbook) : on réveille l'astreinte quand la dernière
--  heure ET les 5 dernières minutes consomment plus vite que 14,4. La fenêtre de 1 h évite
--  de réveiller pour un simple pic, celle de 5 min arrête l'alerte dès que c'est corrigé.
--
--  Les vues rafraîchissables recalculent ces tables selon un planning
--  (REFRESH EVERY 1 MINUTE) : le bon outil pour les fenêtres et les jointures qu'une
--  vue incrémentale ne sait pas exprimer.
-- =====================================================================


-- ÉTAPE 1 · Le burn rate, minute par minute, pour chaque route de la gateway
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

SYSTEM WAIT VIEW payflow_sre.rmv_slo_burn;   -- attendre le 1er refresh avant de lire (et avant les vues qui en dépendent)

SELECT minute, requests, errors, round(burn_5m, 1) AS burn_5m, round(burn_1h, 1) AS burn_1h, fast_burn
FROM payflow_sre.slo_burn
WHERE route = 'POST /v1/payments' AND minute BETWEEN '2026-11-27 13:56:00' AND '2026-11-27 14:06:00'
ORDER BY minute;
-- Mesuré : 15 ms · 5 760 lignes lues (208,7 Ko)
-- À observer : la fenêtre de 5 min franchit 14,4 à 13h58, celle de 1 h un peu plus
-- tard. L'alerte se déclenche quand les deux sont au-dessus : le temps de détection, en minutes.


-- ÉTAPE 2 · Les règles d'alerte, évaluées chaque minute
--  Quatre règles, une table. Chaque règle produit FIRING quand sa condition devient
--  vraie et RESOLVED quand elle cesse (lagInFrame compare une minute à la précédente).
--    · fast burn du SLO sur une route de la gateway
--    · latence p99 de payment.AuthorizePayment au-dessus de 1 s pendant 3 minutes d'affilée
--    · un conteneur a redémarré (le compteur k8s.container.restarts a augmenté)
--    · un node signale une pression mémoire (événement Kubernetes)
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
    -- règle 1 : fast burn, par route
    SELECT minute AS ts, 'slo_fast_burn' AS rule, 'page' AS severity, 'api-gateway' AS service,
           if(fast_burn, 'FIRING', 'RESOLVED') AS state,
           if(fast_burn, concat(route, ': error budget burning ', toString(round(burn_1h)), 'x faster than allowed (1 h window)'),
                         concat(route, ': back under the threshold on the 5 min window (burn ', toString(round(burn_5m, 1)), ')')) AS summary,
           fast_burn != lagInFrame(fast_burn, 1, false) OVER (PARTITION BY route ORDER BY minute) AS changed
    FROM payflow_sre.slo_burn

    UNION ALL

    -- règle 2 : p99 au-dessus de 1 s pendant 3 minutes consécutives
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

    -- règle 3 : redémarrages de conteneurs (le compteur ne fait que monter)
    SELECT toDateTime(TimeUnix), 'container_restart', 'ticket', ServiceName, 'FIRING',
           concat(ResourceAttributes['k8s.pod.name'], ' restarted on ', ResourceAttributes['k8s.node.name']),
           Value > lagInFrame(Value, 1, Value) OVER (PARTITION BY ResourceAttributes['k8s.pod.name'] ORDER BY TimeUnix)
    FROM payflow_otel.otel_metrics_sum
    WHERE MetricName = 'k8s.container.restarts'

    UNION ALL

    -- règle 4 : pression mémoire sur un node, directement depuis les événements Kubernetes
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
-- Mesuré : 26 ms · 11 lignes lues (1 Ko)
-- À observer : tout l'incident en une douzaine de lignes. La première page (alerte qui
-- réveille l'astreinte), le ticket de latence, la pression mémoire du node, le redémarrage
-- OOM, puis les lignes RESOLVED.


-- ÉTAPE 3 · Temps moyen de détection (MTTD)
SELECT
    toDateTime('2026-11-27 13:58:00', 'UTC')                                                  AS deployed,
    (SELECT min(ts) FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'FIRING') AS first_page,
    dateDiff('minute', deployed, first_page)                                                   AS minutes_to_detect;
-- Mesuré : 4 ms · 12 lignes lues


-- ÉTAPE 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'FIRING') >= 1, 'OK', 'KO') AS page_fired,
    if((SELECT count() FROM payflow_sre.alerts WHERE rule = 'container_restart') = 1, 'OK', 'KO')                    AS restart_alert,
    if((SELECT max(ts) FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'RESOLVED') > '2026-11-27 14:40:00', 'OK', 'KO') AS resolved
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 23 ms · 34 lignes lues
