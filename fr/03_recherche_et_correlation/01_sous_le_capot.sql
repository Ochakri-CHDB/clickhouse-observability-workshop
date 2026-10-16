-- =====================================================================
--  MODULE 3 · Recherche et corrélation : ce que ClickStack exécute en dessous
-- =====================================================================
--  La barre de recherche de ClickStack parle Lucene (ServiceName:payment "HikariPool")
--  ou SQL. Dans les deux cas, elle devient une requête ClickHouse sur otel_logs ou
--  otel_traces. Ce fichier lance ces requêtes à la main, pour voir d'où vient la vitesse :
--    · la clé primaire saute par heure et par service
--    · l'index texte sur lower(Body) sert la recherche plein texte (hasToken, hasAllTokens)
--    · les index texte sur les items d'attributs servent les filtres clé=valeur des maps
--    · TraceId relie un log à sa trace, les attributs de ressource relient les deux
--      aux métriques
--  Le README de ce module fait la même chose dans l'interface ClickStack.
-- =====================================================================


-- ÉTAPE 1 · Une recherche : les erreurs de payment qui mentionnent HikariPool, vers 14h10
--  Dans ClickStack : ServiceName:payment SeverityText:ERROR "HikariPool"
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND ServiceName = 'payment' AND SeverityText = 'ERROR'
  AND hasAllTokens(lower(Body), ['hikaripool'])
ORDER BY Timestamp DESC
LIMIT 5;
-- Mesuré : 741 ms · 172 033 lignes lues (2,9 Mo)

--  Quels index a-t-elle utilisés ? Parts et granules sautés à chaque étape.
EXPLAIN indexes = 1
SELECT count()
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND hasAllTokens(lower(Body), ['hikaripool']);
-- Mesuré : 8 ms · 33 lignes lues (1,3 Ko)
-- À observer : la partition garde un jour, la clé primaire dix minutes, puis
-- idx_lower_body ne garde que les granules qui contiennent le mot.


-- ÉTAPE 2 · Un filtre sur un attribut : service.version, sans colonne dédiée
--  Les attributs de ressource sont une Map. ResourceAttributeItems est un ALIAS qui
--  transforme chaque paire en 'clé=valeur' ; son index texte répond au filtre sans lire
--  la map.
SELECT ResourceAttributes['k8s.pod.name'] AS pod, count() AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:45')
  AND has(ResourceAttributeItems, 'service.version=v2.4.1')
  AND SeverityText = 'ERROR'
GROUP BY pod
ORDER BY errors DESC;
-- Mesuré : 509 ms · 163 841 lignes lues (39,1 Mo)

--  Les colonnes matérialisées : l'exporteur promeut les attributs les plus utilisés
SELECT name, type, default_expression
FROM system.columns
WHERE database = 'payflow_otel' AND table = 'otel_logs' AND default_kind = 'MATERIALIZED';
-- Mesuré : 2 ms · 27 lignes lues (3,5 Ko)


-- ÉTAPE 3 · Corrélation : d'une ligne de log à sa trace, puis aux métriques du pod
WITH (SELECT any(TraceId) FROM payflow_otel.otel_logs
      WHERE ServiceName = 'checkout' AND SeverityText = 'ERROR'
        AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:05')) AS tid
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode, ResourceAttributes['k8s.pod.name'] AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN pf_at('14:09:55') AND pf_at('14:10:15')
ORDER BY Timestamp;
-- Mesuré : 1,87 s · 3,3 M lignes lues (19,4 Mo) · 132,3 Mo de mémoire
-- À observer : la trace du paiement en échec. Dans ClickStack, un clic sur la ligne de log
-- ouvre ce waterfall, et l'onglet Infrastructure montre les métriques du pod.

SELECT toStartOfMinute(toDateTime(TimeUnix)) AS minute, MetricName, round(avg(Value), 2) AS value
FROM payflow_otel.otel_metrics_gauge
WHERE ResourceAttributes['k8s.pod.name'] = 'payment-5c8b7f9d21-50d24'
  AND MetricName IN ('k8s.pod.cpu.utilization', 'hikaricp.connections.pending')
  AND TimeUnix BETWEEN pf_at('14:05') AND pf_at('14:10')
GROUP BY minute, MetricName
ORDER BY minute, MetricName;
-- Mesuré : 23 ms · 24 577 lignes lues (1,7 Mo)
-- À observer : le pod ne travaille pas (CPU bas), il attend (des dizaines de connexions
-- en file).


-- ÉTAPE 4 · Live tail : les dernières lignes du flux
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN now() - INTERVAL 2 MINUTE AND now()
ORDER BY Timestamp DESC
LIMIT 10;
-- Mesuré : 8 ms · 137 436 lignes lues (1,4 Mo)


-- ÉTAPE 5 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
        AND hasAllTokens(lower(Body), ['hikaripool'])) > 1000, 'OK', 'KO')                                   AS full_text_search,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 0, 'OK', 'KO') AS live_tail
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 84 ms · 295 287 lignes lues (2,4 Mo)
