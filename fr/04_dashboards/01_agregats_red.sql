-- =====================================================================
--  MODULE 4 · Dashboards : les agrégats (rollups) RED qui les alimentent
-- =====================================================================
--  RED = Rate, Errors, Duration (débit, erreurs, durée) : les trois chiffres de tout
--  service, et la première ligne de tout dashboard. Dans le collecteur, le connecteur
--  spanmetrics les calcule à partir des spans. Dans ClickHouse, une vue matérialisée
--  incrémentale fait la même chose à l'insertion, de façon exacte et sans répartiteur
--  de charge devant les collecteurs : des états d'agrégation partiels, fusionnés en
--  arrière-plan par AggregatingMergeTree, finalisés par la requête avec -Merge. La doc
--  ClickStack le dit sans détour : les vues matérialisées déplacent le coût de la
--  requête vers l'insertion.
--  Deux sorties :
--    · payflow_sre.red_1m, pour les tuiles SQL, les SLO et les alertes (modules 4 et 5)
--    · l'histogramme spanmetrics dans otel_metrics_histogram, tel que l'écrirait le
--      collecteur, avec un exemplar : d'un graphe de latence, un clic vers la trace
--      la plus lente
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


-- ÉTAPE 3 · Remplir la journée (backfill) : la vue ne voit que les nouvelles insertions
INSERT INTO payflow_sre.red_1m
SELECT
    toStartOfMinute(toDateTime(Timestamp)), ServiceName, SpanName,
    count(), countIf(StatusCode = 'Error'), quantilesTDigestState(0.5, 0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27'   -- l'historique ; le flux en direct passe par la vue
GROUP BY 1, 2, 3;
-- Mesuré : 1,27 s · 21,5 M lignes lues (199,6 Mo) · 20 160 lignes écrites · 337,1 Mo de mémoire

SELECT count() AS rollup_rows, (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27') AS server_spans
FROM payflow_sre.red_1m
WHERE toDate(minute) = '2026-11-27';
-- Mesuré : 28 ms · 10 M lignes lues (84,9 Mo) · 108,3 Mo de mémoire
-- À observer : 20 000 lignes résument 8 millions de spans serveur.


-- ÉTAPE 4 · Le RED du point d'entrée, minute par minute, autour de l'incident
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
-- Mesuré : 30 ms · 8 192 lignes lues (1,2 Mo)
-- À observer : le p99 saute de ~300 ms à 3 s à 13h58 (le rollout), les erreurs montent
-- à ~30 % au pic de la vente flash, les deux retombent à 14h44. Le dashboard du README
-- est cette requête.


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
-- Mesuré : 38 ms · 90 112 lignes lues (1,6 Mo)
-- À observer : même courbe, 10 fois plus de lignes lues depuis les spans. Ici les
-- spans sont triés par service et nom de span, la requête brute reste donc peu coûteuse.
-- L'agrégat fait la différence sur les longues plages (un mois : 20 000 lignes au lieu
-- de 400 millions de spans) et sur les dashboards qui agrègent tous les services à la fois.


-- ÉTAPE 6 · L'histogramme spanmetrics, lisible par ClickStack comme une métrique
--  Un histogramme OpenTelemetry stocke, pour chaque intervalle, le nombre par bucket
--  (BucketCounts) pour des bornes fixes (ExplicitBounds), plus count, sum, min, max.
--  L'exemplar garde l'identifiant de trace de la requête la plus lente de la minute :
--  d'un graphe de latence, on saute directement à la trace coupable (README de ce module).
INSERT INTO payflow_otel.otel_metrics_histogram
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix,
     Count, Sum, BucketCounts, ExplicitBounds, `Exemplars.FilteredAttributes`, `Exemplars.TimeUnix`, `Exemplars.Value`,
     `Exemplars.SpanId`, `Exemplars.TraceId`, Min, Max, AggregationTemporality)
WITH [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] AS bounds
SELECT
    map('service.name', ServiceName, 'k8s.cluster.name', 'payflow-prod-eu')                            AS ResourceAttributes,
    ServiceName,
    'traces.span.metrics.duration'                                                                     AS MetricName,   -- le nom qu'utilise le connecteur
    'Duration of server spans, computed from the traces'                                               AS MetricDescription,
    's'                                                                                                AS MetricUnit,
    map('span.name', SpanName, 'span.kind', 'SPAN_KIND_SERVER', 'status.code', if(StatusCode = 'Error', 'STATUS_CODE_ERROR', 'STATUS_CODE_UNSET')) AS Attributes,
    toDateTime64(minute, 9, 'UTC')                                                                     AS StartTimeUnix,
    toDateTime64(minute + 60, 9, 'UTC')                                                                AS TimeUnix,
    count()                                                                                            AS Count,
    sum(Duration / 1e9)                                                                                AS Sum,
    sumForEach(arrayMap(b -> toUInt64(b = arrayFirstIndex(x -> Duration / 1e9 <= x, bounds)), range(1, 13))) AS BucketCounts,
    bounds                                                                                             AS ExplicitBounds,
    [map()]                                                                                            AS `Exemplars.FilteredAttributes`,
    [argMax(Timestamp, Duration)]                                                                      AS `Exemplars.TimeUnix`,
    [max(Duration) / 1e9]                                                                              AS `Exemplars.Value`,
    [argMax(SpanId, Duration)]                                                                         AS `Exemplars.SpanId`,
    [argMax(TraceId, Duration)]                                                                        AS `Exemplars.TraceId`,
    min(Duration / 1e9)                                                                                AS Min,
    max(Duration / 1e9)                                                                                AS Max,
    1                                                                                                  AS AggregationTemporality   -- delta : chaque ligne couvre sa propre minute
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27'
GROUP BY ServiceName, SpanName, StatusCode, toStartOfMinute(toDateTime(Timestamp)) AS minute;
-- Mesuré : 751 ms · 9,9 M lignes lues (631,6 Mo) · 23 345 lignes écrites · 405,6 Mo de mémoire
-- Attention : arrayFirstIndex renvoie 0 quand la valeur dépasse la dernière borne, et
-- alors aucun b de 1..12 ne correspond. Ici aucun span ne dépasse 10 s : chacun tombe
-- dans un bucket.


-- ÉTAPE 7 · Checkpoint
SELECT
    if((SELECT sum(requests) FROM payflow_sre.red_1m WHERE toDate(minute) = '2026-11-27') = (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server' AND toDate(Timestamp) = '2026-11-27'), 'OK', 'KO') AS no_span_lost,
    if((SELECT count() FROM payflow_otel.otel_metrics_histogram WHERE MetricName = 'traces.span.metrics.duration') > 10000, 'OK', 'KO') AS spanmetrics_histogram,
    if((SELECT max(errors) FROM payflow_sre.red_1m WHERE service = 'payment') > 300, 'OK', 'KO')                                                AS incident_visible
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 64 ms · 9,1 M lignes lues (78,7 Mo) · 81,9 Mo de mémoire
