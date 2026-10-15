-- =====================================================================
--  MODULE 5 · Gold : métriques RED, mises à jour à chaque insert
-- =====================================================================
--  RED = Rate, Errors, Duration : les trois chiffres qu'un SRE surveille pour chaque
--  service. Les recalculer depuis 14 millions de spans à chaque rafraîchissement de
--  dashboard serait du gaspillage. Une vue matérialisée incrémentale les garde par minute,
--  sous forme d'états d'agrégation partiels : AggregatingMergeTree fusionne les états en
--  arrière-plan, la requête termine l'agrégation avec -Merge.
-- =====================================================================


-- ÉTAPE 1 · La table cible : une ligne par service, opération et minute
--  quantilesTDigestState garde un petit résumé de la distribution des latences :
--  des quantiles de quantiles seraient faux, des t-digests fusionnés sont justes.
CREATE OR REPLACE TABLE payflow_sre.red_1m
(
    minute       DateTime('UTC'),
    service      LowCardinality(String),
    operation    LowCardinality(String),
    requests     SimpleAggregateFunction(sum, UInt64),
    errors       SimpleAggregateFunction(sum, UInt64),
    latency      AggregateFunction(quantilesTDigest(0.5, 0.95, 0.99), UInt64)   -- nanosecondes
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(minute)
ORDER BY (service, operation, minute);


-- ÉTAPE 2 · La vue matérialisée incrémentale, à partir des spans serveur
CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.mv_red_1m TO payflow_sre.red_1m AS
SELECT
    toStartOfMinute(toDateTime(Timestamp))                AS minute,
    ServiceName                                           AS service,
    SpanName                                              AS operation,
    count()                                               AS requests,
    countIf(StatusCode = 'Error')                         AS errors,
    quantilesTDigestState(0.5, 0.95, 0.99)(Duration)      AS latency
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY minute, service, operation;


-- ÉTAPE 3 · Backfill de la journée : la vue ne voit que les nouveaux inserts
INSERT INTO payflow_sre.red_1m
SELECT
    toStartOfMinute(toDateTime(Timestamp)), ServiceName, SpanName,
    count(), countIf(StatusCode = 'Error'), quantilesTDigestState(0.5, 0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY 1, 2, 3;
-- Mesuré : 1,25 s · 14,6 M lignes lues (186,7 Mo) · 20 165 lignes écrites · 308,1 Mo de mémoire

SELECT count() AS rows_gold, (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server') AS server_spans
FROM payflow_sre.red_1m;
-- Mesuré : 12 ms · 14,6 M lignes lues (13,9 Mo) · 89,1 Mo de mémoire
-- À observer : quelques dizaines de milliers de lignes résument des millions de spans.


-- ÉTAPE 4 · RED du point d'entrée, minute par minute, autour de l'incident
SELECT
    minute,
    sum(requests)                                                       AS n_requests,   -- pas "AS requests" : un alias est global
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[1] / 1e6)     AS p50_ms,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:55:00'
GROUP BY minute
ORDER BY minute;
-- Mesuré : 27 ms · 8 192 lignes lues (1,2 Mo)
-- À observer : le p99 saute de ~300 ms à 3 s à 13h58 (le rollout), les erreurs montent à ~30 %
-- au pic de la vente flash, les deux retombent à 14h44. Le dashboard du module 8, c'est
-- cette requête.


-- ÉTAPE 5 · Les mêmes chiffres directement depuis les spans, pour comparer le coût
SELECT
    toStartOfMinute(toDateTime(Timestamp))                              AS minute,
    count()                                                             AS n_requests,
    round(100 * countIf(StatusCode = 'Error') / count(), 2)             AS error_pct,
    round(quantileTDigest(0.99)(Duration) / 1e6)                        AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:55:59'
GROUP BY minute
ORDER BY minute;
-- Mesuré : 39 ms · 81 920 lignes lues (1,5 Mo)
-- À observer : même courbe, 10 fois plus de lignes lues dans les spans. Ici les spans
-- sont triés par service et nom de span, donc la requête brute reste peu coûteuse. Gold fait
-- la différence sur les longues périodes (un mois : 20 000 lignes au lieu de 400 millions
-- de spans) et sur les dashboards qui agrègent tous les services d'un coup.


-- ÉTAPE 6 · Checkpoint
SELECT
    if((SELECT sum(requests) FROM payflow_sre.red_1m) = (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server'), 'OK', 'KO') AS no_span_lost,
    if((SELECT max(errors) FROM payflow_sre.red_1m WHERE service = 'payment') > 300, 'OK', 'KO')                                                AS incident_visible
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 39 ms · 11,3 M lignes lues (11 Mo) · 84,3 Mo de mémoire
