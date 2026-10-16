-- =====================================================================
--  MODULE 7 · Échelle et coût (2/3) : chercher dans un milliard de lignes de log
-- =====================================================================
--  Les requêtes d'observabilité cherchent des aiguilles dans des bottes de foin : un
--  message d'erreur, un trace id, un pod. ClickHouse ne lit que le nécessaire :
--    · l'index primaire (ORDER BY) saute par service et par temps
--    · l'index texte saute les granules qui ne contiennent pas un token
--    · le bloom filter saute les granules qui ne peuvent pas contenir un trace id
--    · la projection répond aux agrégations depuis une copie pré-agrégée
--  Chaque requête est lancée avec et sans son accélérateur. Comparez les lignes
--  "Mesuré" : le temps, et surtout les lignes lues.
--  Attention : deux caches rendraient la seconde exécution d'une requête instantanée.
--  Ils sont désactivés ici pour que chaque mesure soit une vraie lecture (les étapes
--  6 et 7 les montrent) :
--    · le cache de requêtes (query cache) garde des résultats entiers
--    · le query condition cache retient quels granules ont satisfait une clause WHERE
-- =====================================================================

SET use_query_cache = 0;
SET use_query_condition_cache = 0;


-- ÉTAPE 1 · Recherche plein texte : un mot rare dans 875 millions de lignes
--  hasToken(lower(Body), 'oomkilled') utilise idx_lower_body, construit avec la même
--  expression lower(Body) et le même tokenizer (splitByNonAlpha).
SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled');
-- Mesuré : 774 ms · 286 720 lignes lues (280 Ko)

SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled')
SETTINGS use_skip_indexes = 0;   -- la même requête, index désactivé : chaque Body est lu
-- Mesuré : 4,27 s · 875 M lignes lues (52,5 Go) · 448 Mo de mémoire

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%oomkilled%'
SETTINGS use_skip_indexes = 0;   -- ce que ferait un grep
-- Mesuré : 2,98 s · 875 M lignes lues (52,5 Go) · 462 Mo de mémoire
-- À observer : avec l'index, quelques centaines de milliers de lignes lues au lieu
-- de 875 millions.


-- ÉTAPE 2 · Un mot fréquent : les erreurs HikariPool de toutes les régions
SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster;
-- Mesuré : 367 ms · 9,7 M lignes lues (18,4 Mo) · 110,2 Mo de mémoire

SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster
SETTINGS use_skip_indexes = 0;
-- Mesuré : 3,09 s · 875 M lignes lues (52,6 Go) · 365,1 Mo de mémoire
-- À observer : le gain diminue quand le mot est partout, mais reste important :
-- l'index saute quand même chaque granule qui ne contient pas le mot.


-- ÉTAPE 3 · Un trace id parmi 875 millions de lignes
--  Le bloom filter seul saute déjà la plupart des granules. Borner aussi le temps
--  laisse l'index primaire et les partitions faire le reste : c'est pourquoi les outils
--  de tracing cherchent d'abord la plage de temps d'une trace (étape 5).
SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN pf_at('10:00:00') - INTERVAL 6 DAY AND pf_at('10:00:10') - INTERVAL 6 DAY AND TraceId != '');
-- Mesuré : 2,96 s · 1,2 M lignes lues (31,5 Mo) · 91,4 Mo de mémoire

SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN pf_at('10:00:00') - INTERVAL 6 DAY AND pf_at('10:00:10') - INTERVAL 6 DAY AND TraceId != '')
  AND Timestamp BETWEEN pf_at('09:59:00') - INTERVAL 6 DAY AND pf_at('10:01:00') - INTERVAL 6 DAY;
-- Mesuré : 22 ms · 368 641 lignes lues (3,7 Mo)
-- À observer : la seconde requête répond en quelques millisecondes. La plage de temps
-- permet à l'index primaire de sauter tous les autres jours : seuls les granules de cette
-- fenêtre sont lus.


-- ÉTAPE 4 · Les erreurs par minute pour un dashboard : la projection
--  p_errors_per_minute a été construite à l'insertion. La requête ne la mentionne pas :
--  ClickHouse la choisit parce qu'elle suffit pour répondre.
SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5;
-- Mesuré : 712 ms · 465 928 lignes lues (9,8 Mo)

SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Mesuré : 1,08 s · 875 M lignes lues (2,9 Go) · 241,9 Mo de mémoire
-- À observer : les mêmes 5 minutes (14h21 chaque jour : les copies du Black Friday),
-- à partir d'environ 600 000 lignes au lieu de 875 millions.

EXPLAIN indexes = 1, projections = 1
SELECT toStartOfMinute(Timestamp) AS minute, count()
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute;
-- Mesuré : 5 ms · 14 lignes lues


-- ÉTAPE 5 · La table d'accès par trace à l'œuvre
--  otel_traces_trace_id_ts (module 1) garde le début et la fin de chaque trace. Une
--  recherche donne la plage de temps, la vraie requête lit ensuite une fenêtre étroite
--  d'otel_traces. C'est ce que fait ClickStack quand vous ouvrez une trace.
WITH (SELECT any(TraceId) FROM payflow_otel.otel_traces WHERE ServiceName = 'payment' AND StatusCode = 'Error'
      AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:01')) AS tid,
     (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS range
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN range.1 - INTERVAL 1 SECOND AND range.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Mesuré : 454 ms · 245 761 lignes lues (5,5 Mo)
-- À observer : une trace entière, lue dans une fenêtre de quelques secondes.


-- ÉTAPE 6 · Le cache de requêtes (query cache)
--  Le résultat d'une requête lourde est gardé en mémoire : la seconde exécution répond
--  en ~1 ms.
--  Attention : le cache est par réplique et n'est pas invalidé par les insertions.
--  Il convient aux dashboards rafraîchis par beaucoup d'utilisateurs, pas à l'alerting.
SYSTEM DROP QUERY CACHE;

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Mesuré : 6,99 s · 875 M lignes lues (52,7 Go) · 302,6 Mo de mémoire

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Mesuré : 1 ms · 1 ligne lue


-- ÉTAPE 7 · Le query condition cache : le filtre mémorisé, pas le résultat
--  Pour chaque part, ClickHouse retient quels granules ont satisfait une condition WHERE.
--  Relancez la même recherche, même avec une autre liste SELECT : les granules qui ne
--  correspondaient pas sont sautés sans être lus. Activé par défaut depuis la 25.3.
SET use_query_condition_cache = 1;

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
SETTINGS use_skip_indexes = 0;
-- Mesuré : 2,94 s · 875 M lignes lues (52,5 Go) · 462 Mo de mémoire

SELECT Cluster, count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
GROUP BY Cluster
SETTINGS use_skip_indexes = 0;
-- Mesuré : 14 ms · 745 472 lignes lues (32,5 Mo) · 99,9 Mo de mémoire
-- À observer : la première exécution lit tout, la seconde presque rien.

SET use_query_condition_cache = 0;


-- ÉTAPE 8 · Trois répliques sur le même scan
--  Le même scan complet, d'abord sur une réplique, puis réparti sur les 3 répliques
--  du service (parallel replicas). Le stockage est partagé : aucune donnée ne bouge.
SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null;
-- Mesuré : 7,03 s · 875 M lignes lues (55,8 Go) · 398,4 Mo de mémoire

SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null
SETTINGS enable_parallel_replicas = 1;
-- Mesuré : 3,56 s · 875 M lignes lues (55,8 Go) · 261 Mo de mémoire
-- À observer : environ deux fois plus rapide avec 3 répliques, sans changer le SQL.
