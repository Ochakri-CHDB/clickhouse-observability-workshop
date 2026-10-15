-- =====================================================================
--  MODULE 5 · Gold : la carte des services et les motifs de logs
-- =====================================================================
--  Deux choses que personne ne déclare mais que les données connaissent :
--    · qui appelle qui : chaque span pointe vers son parent. Joindre les spans enfants
--      à leur parent d'un autre service donne le graphe des dépendances, avec le
--      trafic, les erreurs et la latence de chaque arête.
--    · ce que disent les logs : des millions de lignes, mais quelques dizaines de messages.
--      On remplace les parties variables (ids, nombres) par <*> et on compte les motifs.
-- =====================================================================


-- ÉTAPE 1 · La carte des services, par tranche de 5 minutes
--  Arêtes entre services : un span serveur dont le parent vit dans un autre service.
--  Arêtes vers les dépendances : spans client vers postgres, redis et les réseaux de cartes.
CREATE OR REPLACE TABLE payflow_sre.service_map_5m
(
    bucket     DateTime('UTC'),
    caller     LowCardinality(String),
    callee     LowCardinality(String),
    calls      UInt64,
    errors     UInt64,
    p95_ms     Float64
)
ENGINE = MergeTree
ORDER BY (caller, callee, bucket);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_service_map
REFRESH EVERY 10 MINUTE
TO payflow_sre.service_map_5m AS
SELECT bucket, caller, callee, count() AS calls, countIf(failed) AS errors, round(quantile(0.95)(duration_ns) / 1e6, 1) AS p95_ms
FROM
(
    SELECT toStartOfFiveMinutes(toDateTime(c.Timestamp)) AS bucket, p.ServiceName AS caller, c.ServiceName AS callee,
           c.StatusCode = 'Error' AS failed, c.Duration AS duration_ns
    FROM payflow_otel.otel_traces AS c
    INNER JOIN
    (
        SELECT TraceId, SpanId, ServiceName FROM payflow_otel.otel_traces WHERE SpanKind IN ('Server', 'Producer')
    ) AS p ON p.TraceId = c.TraceId AND p.SpanId = c.ParentSpanId
    WHERE c.SpanKind IN ('Server', 'Consumer') AND c.ParentSpanId != '' AND p.ServiceName != c.ServiceName

    UNION ALL

    SELECT toStartOfFiveMinutes(toDateTime(Timestamp)), ServiceName,
           concat(SpanAttributes['db.system'] != '' ? SpanAttributes['db.system'] : 'https', ' ', SpanAttributes['server.address']),
           StatusCode = 'Error', Duration
    FROM payflow_otel.otel_traces
    WHERE SpanKind = 'Client'
)
GROUP BY bucket, caller, callee;

SYSTEM WAIT VIEW payflow_sre.rmv_service_map;

SELECT caller, callee, sum(calls) AS calls_per_day, round(100 * sum(errors) / sum(calls), 2) AS error_pct, max(p95_ms) AS worst_p95_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY caller, calls_per_day DESC;
-- Mesuré : 36 ms · 4 618 lignes lues (117,8 Ko)
-- À observer : 16 arêtes. Personne n'a dessiné cette carte : elle vient des traces.
-- C'est l'arête payment → postgres payments-db qui porte les erreurs.


-- ÉTAPE 2 · La carte pendant l'incident, comparée à une heure avant
SELECT caller, callee,
       sumIf(calls, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00')                AS calls_before,
       sumIf(calls, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 15:00:00')                AS calls_during,
       maxIf(p95_ms, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00')               AS p95_before_ms,
       maxIf(p95_ms, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00')               AS p95_during_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 6;
-- Mesuré : 4 ms · 4 618 lignes lues (99,7 Ko)
-- À observer : les arêtes dont la latence a explosé. L'arête vers la base est en tête,
-- fraud-scoring suit : les retries le ralentissent aussi (un second incendie, plus petit).


-- ÉTAPE 3 · Motifs de logs par service, toutes les 10 minutes
--  replaceRegexpAll remplace ids et nombres par <*> : des millions de lignes,
--  quelques dizaines de motifs.
CREATE OR REPLACE FUNCTION pf_log_pattern AS (body) ->
    replaceRegexpAll(replaceRegexpAll(body, '(pay|m)_[0-9a-f]+|[0-9a-f]{16,}|\\*{6}', '<*>'), '[0-9]+([.:/][0-9]+)*', '<*>');

CREATE OR REPLACE TABLE payflow_sre.log_patterns_10m
(
    bucket    DateTime('UTC'),
    service   LowCardinality(String),
    severity  LowCardinality(String),
    pattern   String,
    n         UInt64,
    example   String
)
ENGINE = MergeTree
ORDER BY (service, severity, bucket);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_log_patterns
REFRESH EVERY 10 MINUTE
TO payflow_sre.log_patterns_10m AS
SELECT
    toStartOfTenMinutes(toDateTime(Timestamp)) AS bucket,
    ServiceName                                AS service,
    SeverityText                               AS severity,
    pf_log_pattern(Body)                       AS pattern,
    count()                                    AS n,
    any(Body)                                  AS example
FROM payflow_otel.otel_logs
WHERE ServiceName NOT IN ('api-gateway', 'k8s-events')   -- les access logs se lisent mieux en métriques (statut, durée)
GROUP BY bucket, service, severity, pattern;

SYSTEM WAIT VIEW payflow_sre.rmv_log_patterns;

SELECT uniqExact(pattern) AS patterns, sum(n) AS log_lines
FROM payflow_sre.log_patterns_10m;
-- Mesuré : 12 ms · 3 920 lignes lues (163,7 Ko)


-- ÉTAPE 4 · Les motifs qui n'apparaissent que pendant l'incident
--  On compare 14h00-14h40 aux mêmes 40 minutes une heure plus tôt.
SELECT service, severity, pattern,
       sumIf(n, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS during,
       sumIf(n, bucket >= '2026-11-27 12:50:00' AND bucket < '2026-11-27 13:30:00') AS before
FROM payflow_sre.log_patterns_10m
GROUP BY service, severity, pattern
HAVING during > 10 * greatest(before, 1)
ORDER BY during DESC
LIMIT 10;
-- Mesuré : 5 ms · 3 920 lignes lues (186,9 Ko)
-- À observer : le timeout HikariPool arrive en tête, de loin. Puis les erreurs de checkout
-- qui ne font que le relayer, les warnings de fraud-scoring et son OOM. La cause racine
-- est le NOUVEAU motif le plus fréquent du service en échec le plus en amont.


-- ÉTAPE 5 · Checkpoint
SELECT
    if((SELECT uniqExact(caller, callee) FROM payflow_sre.service_map_5m) >= 12, 'OK', 'KO')                            AS service_map,
    if((SELECT argMax(pattern, n) FROM (SELECT pattern, sum(n) AS n FROM payflow_sre.log_patterns_10m
        WHERE severity = 'ERROR' GROUP BY pattern)) LIKE 'HikariPool%', 'OK', 'KO')                                    AS top_error_pattern
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 90 ms · 8 539 lignes lues (177,2 Ko)
