-- =====================================================================
--  MODULE 6 · Chercher dans un milliard de lignes de log : index, projections, répliques
-- =====================================================================
--  Les requêtes d'observabilité cherchent une aiguille dans une botte de foin : un
--  message d'erreur, un trace id, un pod. ClickHouse ne lit que le nécessaire :
--    · l'index primaire (ORDER BY) saute par service et par heure
--    · l'index texte saute les granules qui ne contiennent pas un token
--    · le bloom filter saute les granules qui ne peuvent pas contenir un trace id
--    · la projection répond aux agrégats depuis une copie pré-agrégée
--  Chaque requête est lancée avec et sans son accélérateur. Comparez les lignes
--  "Mesuré" : le temps, et surtout les lignes lues.
--  Attention : deux caches rendraient instantanée la deuxième exécution d'une requête.
--  Ils sont désactivés ici pour que chaque mesure soit une vraie lecture (les étapes
--  6 et 7 les montrent) :
--    · le cache de requêtes garde des résultats entiers
--    · le query condition cache retient quels granules ont satisfait une clause WHERE
-- =====================================================================

SET use_query_cache = 0;
SET use_query_condition_cache = 0;


-- ÉTAPE 1 · Recherche plein texte : un mot rare dans 910 millions de lignes
--  hasToken(lower(Body), 'oomkilled') utilise idx_lower_body, construit avec la même
--  expression lower(Body) et le même tokenizer (splitByNonAlpha).
SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled');
-- Mesuré : 461 ms · 311 296 lignes lues (304 Ko)

SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled')
SETTINGS use_skip_indexes = 0;   -- la même requête, index désactivé : chaque Body est lu
-- Mesuré : 3,45 s · 910 M lignes lues (53,6 Go) · 447,4 Mo de mémoire

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%oomkilled%'
SETTINGS use_skip_indexes = 0;   -- ce que ferait un grep
-- Mesuré : 2,93 s · 910 M lignes lues (53,6 Go) · 462,9 Mo de mémoire
-- À observer : avec l'index, quelques centaines de milliers de lignes lues
-- au lieu de 910 millions.


-- ÉTAPE 2 · Un mot fréquent : les erreurs HikariPool de toutes les régions
SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster;
-- Mesuré : 333 ms · 9,5 M lignes lues (18,1 Mo)

SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster
SETTINGS use_skip_indexes = 0;
-- Mesuré : 2,97 s · 910 M lignes lues (53,6 Go) · 355 Mo de mémoire
-- À observer : le gain diminue quand le mot est partout, mais reste important :
-- l'index saute toujours chaque granule qui ne contient pas le mot.


-- ÉTAPE 3 · Un trace id parmi 910 millions de lignes
--  Le bloom filter seul saute déjà la plupart des granules. Borner aussi le temps
--  laisse l'index primaire et les partitions faire le reste : c'est pourquoi les
--  outils de tracing cherchent d'abord la plage horaire d'une trace (étape 5).
SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN '2026-11-21 10:00:00' AND '2026-11-21 10:00:10' AND TraceId != '');
-- Mesuré : 2,73 s · 1,8 M lignes lues (34,4 Mo) · 94,8 Mo de mémoire

SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN '2026-11-21 10:00:00' AND '2026-11-21 10:00:10' AND TraceId != '')
  AND Timestamp BETWEEN '2026-11-21 09:59:00' AND '2026-11-21 10:01:00';
-- Mesuré : 18 ms · 835 584 lignes lues (4,3 Mo) · 86,5 Mo de mémoire
-- À observer : la deuxième requête répond en quelques millisecondes : la plage de temps
-- permet à l'index primaire d'écarter tous les autres jours, seuls les granules de la fenêtre sont lus.


-- ÉTAPE 4 · Erreurs par minute pour un dashboard : la projection
--  p_errors_per_minute a été construite à l'insertion. La requête ne la mentionne pas :
--  ClickHouse la choisit parce qu'elle peut y répondre.
SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5;
-- Mesuré : 115 ms · 593 063 lignes lues (12,4 Mo)

SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Mesuré : 890 ms · 910 M lignes lues (3 Go) · 244,9 Mo de mémoire
-- À observer : les mêmes 5 minutes (14h21 chaque jour : les copies du Black Friday),
-- à partir d'environ 600 000 lignes au lieu de 910 millions.

EXPLAIN indexes = 1, projections = 1
SELECT toStartOfMinute(Timestamp) AS minute, count()
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute;
-- Mesuré : 5 ms · 14 lignes lues


-- ÉTAPE 5 · La table de correspondance des trace ids (le modèle des UI de tracing)
--  Une petite table, triée par TraceId, garde le début et la fin de chaque trace.
--  Elle est alimentée par une vue matérialisée : une recherche donne la plage horaire,
--  la vraie requête lit ensuite une fenêtre étroite de otel_traces.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_trace_id_ts
(
    TraceId  String CODEC(ZSTD(1)),
    Start    SimpleAggregateFunction(min, DateTime64(9)),
    End      SimpleAggregateFunction(max, DateTime64(9))
)
ENGINE = AggregatingMergeTree
ORDER BY TraceId;

CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_trace_id_ts TO payflow_otel.otel_traces_trace_id_ts AS
SELECT TraceId, min(Timestamp) AS Start, max(Timestamp) AS End
FROM payflow_otel.otel_traces
GROUP BY TraceId;

INSERT INTO payflow_otel.otel_traces_trace_id_ts
SELECT TraceId, min(Timestamp), max(Timestamp) FROM payflow_otel.otel_traces GROUP BY TraceId;
-- Mesuré : 1,41 s · 14,6 M lignes lues (597,4 Mo) · 1,4 M lignes écrites · 1,1 Go de mémoire

WITH (SELECT any(TraceId) FROM payflow_otel.otel_traces WHERE ServiceName = 'payment' AND StatusCode = 'Error'
      AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01') AS tid,
     (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS range
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN range.1 - INTERVAL 1 SECOND AND range.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Mesuré : 28 ms · 188 416 lignes lues (4,1 Mo)
-- À observer : une trace entière, lue dans une fenêtre de quelques secondes.


-- ÉTAPE 6 · Le cache de requêtes
--  Le résultat d'une requête lourde est gardé en mémoire : la deuxième exécution
--  répond en ~1 ms.
--  Attention : le cache est par réplique et n'est pas invalidé par les insertions.
--  Il convient aux dashboards rafraîchis par beaucoup d'utilisateurs, pas à l'alerting.
SYSTEM DROP QUERY CACHE;

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Mesuré : 6,89 s · 910 M lignes lues (53,7 Go) · 298 Mo de mémoire

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Mesuré : 1 ms · 1 ligne lue


-- ÉTAPE 7 · Le query condition cache : le filtre mémorisé, pas le résultat
--  Pour chaque part, ClickHouse retient quels granules ont satisfait une condition
--  WHERE. Relancez la même recherche, même avec une autre liste SELECT : les granules
--  qui ne correspondaient pas sont sautés sans être lus. Actif par défaut depuis 25.3.
SET use_query_condition_cache = 1;

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
SETTINGS use_skip_indexes = 0;
-- Mesuré : 1,71 s · 593 M lignes lues (34,9 Go) · 461,4 Mo de mémoire

SELECT Cluster, count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
GROUP BY Cluster
SETTINGS use_skip_indexes = 0;
-- Mesuré : 13 ms · 540 672 lignes lues (23,7 Mo) · 112,2 Mo de mémoire
-- À observer : la première exécution lit tout, la deuxième presque rien.

SET use_query_condition_cache = 0;


-- ÉTAPE 8 · Trois répliques sur le même scan
--  Le même scan complet, d'abord sur une réplique, puis réparti sur les 3 répliques
--  du service (parallel replicas). Le stockage est partagé : aucune donnée ne bouge.
SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null;
-- Mesuré : 6,8 s · 910 M lignes lues (57 Go) · 405,2 Mo de mémoire

SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null
SETTINGS enable_parallel_replicas = 1;
-- Mesuré : 3,77 s · 910 M lignes lues (57 Go) · 258,2 Mo de mémoire
-- À observer : environ deux fois plus rapide avec 3 répliques, sans changer le SQL.
