-- =====================================================================
--  MODULE 3 · Scénarios de corrélation : trois chemins vers le même incident
-- =====================================================================
--  Une enquête peut partir de n'importe quel signal. L'astreinte choisit rarement :
--    · le scénario A part d'un LOG : un marchand appelle le support pour un paiement
--    · le scénario B part d'une ALERTE MÉTRIQUE : le pool de connexions d'un pod sature
--    · le scénario C part d'une TRACE : un nouveau type d'erreur apparaît dans les waterfalls
--  Chacun parcourt les autres signaux jusqu'à trouver une cause. Trois clés font le travail :
--    · TraceId relie une ligne de log à sa trace (et inversement)
--    · les attributs de ressource (k8s.pod.name, k8s.node.name, service.version) relient
--      logs et traces aux métriques du pod et du nœud
--    · le temps : chaque requête est bornée, et la table de recherche des traces donne
--      les bornes
--  Le README de ce module parcourt les trois mêmes chemins dans ClickStack, par clics.
-- =====================================================================


-- =====================================================================
--  SCÉNARIO A · Log → trace → métriques → log
--  14h12, un ticket : "marchand m_16523, un paiement a échoué juste après 14h09". Vous
--  n'avez qu'un identifiant de marchand. Les logs de checkout le portent en attribut.
-- =====================================================================

-- ÉTAPE A1 · La ligne de log : chercher l'identifiant du marchand dans les attributs
--  Dans ClickStack : LogAttributes.merchant_id:m_16523 SeverityText:ERROR
--  LogAttributeItems transforme chaque paire en 'clé=valeur' : son index texte répond au filtre.
SELECT Timestamp, ServiceName, Body, LogAttributes['payment_id'] AS payment_id, TraceId
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00'
  AND has(LogAttributeItems, 'merchant_id=m_16523')
  AND SeverityText = 'ERROR';
-- Mesuré : 15 ms · 49 152 lignes lues (2 Mo)
-- À observer : une ligne, "payment failed: payment service returned 503", et son TraceId.
-- checkout ne fait que relayer l'erreur d'un autre service : le log ne dit pas pourquoi.

-- ÉTAPE A2 · La trace : tous les spans de cette requête, dans l'ordre
--  La table de recherche des traces (module 1) donne le début et la fin de la trace :
--  le scan d'otel_traces est borné à quelques secondes au lieu de la journée entière.
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00'
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS bounds
SELECT
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1) AS start_ms,
    round(Duration / 1e6, 1)                                                     AS duration_ms,
    ServiceName, SpanKind, SpanName, StatusCode, StatusMessage,
    ResourceAttributes['k8s.pod.name']                                           AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN bounds.1 AND bounds.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Mesuré : 206 ms · 106 496 lignes lues (6,6 Mo)
-- À observer : l'erreur naît dans payment, sur INSERT payflow.payments : 3 secondes à
-- attendre une connexion, "HikariPool-1 - Connection is not available". La colonne pod
-- nomme le pod payment qui a servi la requête : l'étape suivante regarde ses métriques.

-- ÉTAPE A3 · Les métriques de ce pod, minute par minute
--  Le même nom de pod est un attribut de ressource des jauges (kubeletstats et HikariCP).
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00'
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE TraceId = tid AND StatusCode = 'Error'
       AND Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00') AS failing_pod
SELECT
    toStartOfMinute(toDateTime(TimeUnix))                                        AS minute,
    failing_pod                                                                  AS pod,
    round(avgIf(Value, MetricName = 'k8s.pod.cpu.utilization'), 2)               AS cpu,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'))              AS pool_active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.max'))                 AS pool_max,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'))             AS pool_pending
FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:10:59'
  AND ResourceAttributes['k8s.pod.name'] = failing_pod
GROUP BY minute
ORDER BY minute;
-- Mesuré : 52 ms · 139 264 lignes lues (6 Mo)
-- À observer : le pod ne travaille pas (CPU bas). Son pool est plein (active = max) et
-- des dizaines de requêtes attendent une connexion. Et le pool max vaut 10, pas 50.

-- ÉTAPE A4 · Retour aux logs : ce que le pod a dit au démarrage
--  Pourquoi 10 ? Le pod écrit la configuration de son pool au démarrage.
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00'
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE TraceId = tid AND StatusCode = 'Error'
       AND Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00') AS failing_pod
SELECT Timestamp, ResourceAttributes['service.version'] AS version, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:10:00'
  AND ResourceAttributes['k8s.pod.name'] = failing_pod
  AND hasAllTokens(lower(Body), ['maximumpoolsize']);
-- Mesuré : 46 ms · 90 112 lignes lues (4,6 Mo)
-- À observer : "maximumPoolSize=10", écrit par un pod v2.4.1 démarré quelques minutes
-- avant le ticket. Un identifiant de marchand a mené à la version qui a cassé les paiements.


-- =====================================================================
--  SCÉNARIO B · Alerte métrique → métrique → trace → log → changement
--  Une alerte sur graphique surveille hikaricp.connections.pending : "plus de 20 requêtes
--  attendent une connexion à la base sur un pod, sur une minute". Elle se déclenche. On
--  ne sait rien d'autre.
-- =====================================================================

-- ÉTAPE B1 · L'alerte : ce que ClickStack évalue chaque minute
--  Une alerte sur graphique est un GROUP BY sur un intervalle de temps avec un seuil :
--  les premières lignes sont les premières minutes où elle se déclenche.
SELECT
    toStartOfMinute(toDateTime(TimeUnix))          AS minute,
    count(DISTINCT ResourceAttributes['k8s.pod.name']) AS pods_over,
    argMax(ResourceAttributes['k8s.pod.name'], Value) AS worst_pod,
    max(Value)                                     AS max_pending
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'hikaricp.connections.pending'
  AND TimeUnix BETWEEN '2026-11-27 12:00:00' AND '2026-11-27 16:00:00'
  AND Value > 20
GROUP BY minute
ORDER BY minute
LIMIT 5;
-- Mesuré : 12 ms · 90 112 lignes lues (3,4 Mo)
-- À observer : elle se déclenche à 14h03, sur les 6 pods payment à la fois. Un problème
-- sur tous les pods en même temps est rarement une panne matérielle : pensez changement.

-- ÉTAPE B2 · La métrique en contexte : le pool de chaque version, avant et pendant
SELECT
    if(TimeUnix < '2026-11-27 13:58:00', 'before 13:58', 'at 14:03')               AS period,
    ResourceAttributes['service.version']                                          AS version,
    count(DISTINCT ResourceAttributes['k8s.pod.name'])                             AS pods,
    round(avgIf(Value, MetricName = 'hikaricp.connections.max'))                   AS pool_max,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'), 1)             AS pool_active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'), 1)            AS pool_pending
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName LIKE 'hikaricp.%'
  AND (TimeUnix BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 13:52:59'
       OR TimeUnix BETWEEN '2026-11-27 14:03:00' AND '2026-11-27 14:03:59')
GROUP BY period, version
ORDER BY period DESC, version;
-- Mesuré : 19 ms · 106 496 lignes lues (4,9 Mo)
-- À observer : v2.4.0 avait un pool de 50 et utilisait quelques connexions. v2.4.1 en a 10,
-- toutes occupées. La métrique désigne déjà la version ; les traces montrent l'effet.

-- ÉTAPE B3 · De la métrique aux traces : ce que le pire pod a servi pendant cette minute
--  ClickStack fait la même chose quand vous cliquez un point du graphique : même pod,
--  même minute.
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN '2026-11-27 14:03:00' AND '2026-11-27 14:03:59') AS worst_pod
SELECT
    worst_pod                                                      AS pod,
    SpanName,
    count()                                                        AS spans,
    countIf(StatusCode = 'Error')                                  AS errors,
    round(quantile(0.5)(Duration) / 1e6)                           AS p50_ms,
    round(max(Duration) / 1e6)                                     AS max_ms,
    argMinIf(TraceId, Timestamp, StatusCode = 'Error')             AS first_failed_trace
FROM payflow_otel.otel_traces
WHERE Timestamp BETWEEN '2026-11-27 14:03:00' AND '2026-11-27 14:03:59'
  AND ServiceName = 'payment' AND SpanKind = 'Server'
  AND ResourceAttributes['k8s.pod.name'] = worst_pod
GROUP BY SpanName
ORDER BY spans DESC;
-- Mesuré : 34 ms · 237 568 lignes lues (5,5 Mo)
-- À observer : une médiane au-dessus d'une seconde et des échecs à 3 secondes, le timeout
-- de HikariCP. first_failed_trace est l'identifiant de la trace à ouvrir.

-- ÉTAPE B4 · De la trace à ses logs : tout ce qui a été écrit pendant son traitement
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN '2026-11-27 14:03:00' AND '2026-11-27 14:03:59') AS worst_pod,
    (SELECT argMinIf(TraceId, Timestamp, StatusCode = 'Error') FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN '2026-11-27 14:03:00' AND '2026-11-27 14:03:59'
       AND ServiceName = 'payment' AND SpanKind = 'Server'
       AND ResourceAttributes['k8s.pod.name'] = worst_pod) AS tid
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE TraceId = tid
  AND Timestamp BETWEEN '2026-11-27 14:02:50' AND '2026-11-27 14:04:20'
ORDER BY Timestamp;
-- Mesuré : 37 ms · 81 920 lignes lues (5,9 Mo)
-- À observer : la même requête vue par trois services : payment expire sur le pool,
-- checkout signale une 503, le log d'accès de l'api-gateway renvoie la 503 au marchand.

-- ÉTAPE B5 · Qu'est-ce qui a changé sur ce pod ? Les événements Kubernetes
--  Le receiver k8sobjects du module 2 a écrit les événements du cluster dans otel_logs.
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN '2026-11-27 14:03:00' AND '2026-11-27 14:03:59') AS worst_pod
SELECT Timestamp, EventName, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events'
  AND Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:03:00'
  AND (LogAttributes['k8s.object.name'] = worst_pod OR EventName = 'ScalingReplicaSet')
ORDER BY Timestamp;
-- Mesuré : 31 ms · 2,7 M lignes lues (9,8 Mo) · 155,6 Mo de mémoire
-- À observer : "Scaled up replica set payment-5c8b7f9d21 (rolling update CHG-4117)",
-- puis le pod planifié, son image v2.4.1 téléchargée, démarré. De l'alerte au changement
-- en 5 requêtes.


-- =====================================================================
--  SCÉNARIO C · Trace → log → métriques → événements
--  14h25. Les erreurs HikariPool sont connues et un retour arrière (rollback) se prépare.
--  Mais une trace montre une erreur qui ne vient pas du pool. Un second problème ?
-- =====================================================================

-- ÉTAPE C1 · Les traces : quels messages d'erreur sont nouveaux depuis 14h15 ?
--  Le timeout du pool est connu depuis 14h00. Un message vu pour la première fois plus
--  tard est une nouvelle piste. Dans ClickStack : traces, StatusCode:Error, grouper par
--  StatusMessage.
SELECT ServiceName, SpanName, StatusMessage,
       count() AS error_spans, min(Timestamp) AS first_seen, max(Timestamp) AS last_seen
FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = '2026-11-27' AND Timestamp < '2026-11-27 14:25:00'
  AND StatusCode = 'Error' AND SpanKind = 'Server' AND StatusMessage != ''
GROUP BY ServiceName, SpanName, StatusMessage
HAVING first_seen >= '2026-11-27 14:15:00'
ORDER BY error_spans DESC;
-- Mesuré : 32 ms · 7,9 M lignes lues (20,5 Mo) · 56 Mo de mémoire
-- À observer : fraud.ScoreTransaction, "connect: connection refused", 290 spans en moins
-- d'une minute à partir de 14:21:07. Quelque chose sur fraud-scoring ne répond plus.

-- ÉTAPE C2 · Une de ces traces, span par span
WITH
    (SELECT argMin(TraceId, Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN '2026-11-27 14:15:00' AND '2026-11-27 14:25:00'
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS tid,
    (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS bounds
SELECT
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1) AS start_ms,
    round(Duration / 1e6, 1)                                                     AS duration_ms,
    ServiceName, SpanKind, SpanName, StatusCode, StatusMessage,
    ResourceAttributes['k8s.pod.name']                                           AS pod,
    ResourceAttributes['k8s.node.name']                                          AS node
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN bounds.1 AND bounds.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Mesuré : 131 ms · 180 224 lignes lues (6,5 Mo)
-- À observer : checkout appelle fraud-scoring, qui échoue aussitôt. Le pod et le nœud
-- de fraud-scoring sont les pistes suivantes.

-- ÉTAPE C3 · Les logs de ce pod dans les minutes précédentes, groupés par message
--  Pas les logs de la trace : ils ne font que répéter l'erreur. Ce que le pod a dit avant.
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN '2026-11-27 14:15:00' AND '2026-11-27 14:25:00'
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod
SELECT SeverityText, replaceRegexpAll(Body, '[0-9]+([.:/][0-9]+)*', '<n>') AS message,
       count() AS lines, min(Timestamp) AS first_seen
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:22:00'
  AND ResourceAttributes['k8s.pod.name'] = fraud_pod
  AND SeverityNumber >= 13
GROUP BY SeverityText, message
ORDER BY first_seen;
-- Mesuré : 64 ms · 3,5 M lignes lues (129,6 Mo) · 315,7 Mo de mémoire
-- À observer : la file grossit ("scoring slower than arrival rate"), le cache de features
-- atteint 1,9 Gio sur une limite de 2 Gio, puis un worker timeout FATAL à 14:21:07.

-- ÉTAPE C4 · Les métriques : pourquoi la file grossit, et la mémoire du pod
--  Le débit de requêtes de fraud-scoring (tiré des traces) et sa mémoire (kubeletstats).
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN '2026-11-27 14:15:00' AND '2026-11-27 14:25:00'
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod
SELECT
    m.minute,
    t.requests,
    m.memory_mb
FROM
(
    SELECT toStartOfFiveMinutes(toDateTime(TimeUnix)) AS minute,
           round(max(Value) / 1e6) AS memory_mb
    FROM payflow_otel.otel_metrics_gauge
    WHERE MetricName = 'k8s.pod.memory.working_set'
      AND TimeUnix BETWEEN '2026-11-27 13:40:00' AND '2026-11-27 14:34:59'
      AND ResourceAttributes['k8s.pod.name'] = fraud_pod
    GROUP BY minute
) AS m
LEFT JOIN
(
    SELECT toStartOfFiveMinutes(Timestamp) AS minute, count() AS requests
    FROM payflow_otel.otel_traces
    WHERE Timestamp BETWEEN '2026-11-27 13:40:00' AND '2026-11-27 14:34:59'
      AND ServiceName = 'fraud-scoring' AND SpanKind = 'Server'
    GROUP BY minute
) AS t ON t.minute = m.minute
ORDER BY m.minute;
-- Mesuré : 33 ms · 221 184 lignes lues (3,3 Mo)
-- À observer : les requêtes doublent à partir de 13h55 (checkout rejoue les paiements en
-- échec, et fait scorer chaque nouvel essai), la mémoire monte d'environ 750 Mo à 2,2 Go,
-- puis retombe à 900 Mo après 14h21 : le processus a été tué puis redémarré.

-- ÉTAPE C5 · Les événements Kubernetes le confirment
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN '2026-11-27 14:15:00' AND '2026-11-27 14:25:00'
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod,
    (SELECT any(ResourceAttributes['k8s.node.name']) FROM payflow_otel.otel_metrics_gauge
     WHERE TimeUnix BETWEEN '2026-11-27 14:20:00' AND '2026-11-27 14:20:59'
       AND ResourceAttributes['k8s.pod.name'] = fraud_pod) AS fraud_node
SELECT Timestamp, EventName, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events'
  AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:30:00'
  AND EventName != 'Unhealthy'
  AND (LogAttributes['k8s.object.name'] IN (fraud_pod, fraud_node) OR Body LIKE concat('%', fraud_node, '%')
       OR Body LIKE '%fraud-scoring%')
ORDER BY Timestamp;
-- Mesuré : 43 ms · 2,8 M lignes lues (10,2 Mo) · 152,4 Mo de mémoire
-- À observer : la pression mémoire sur le nœud à 14h19, l'OOM kill à 14:21:07, le
-- back-off du redémarrage, le nœud revenu à la normale à 14h23. Pas un second bug : une
-- conséquence du premier. Les nouveaux essais des paiements en échec ont surchargé
-- fraud-scoring jusqu'à épuiser sa mémoire. Corriger le pool (le rollback de 14h42)
-- règle les deux.


-- ÉTAPE D · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:15:00'
          AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') = 1, 'OK', 'KO')     AS a_log_found,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:10:00'
          AND ResourceAttributes['service.version'] = 'v2.4.1'
          AND hasAllTokens(lower(Body), ['maximumpoolsize'])) = 6, 'OK', 'KO')                               AS a_pool_config,
    if((SELECT min(toStartOfMinute(toDateTime(TimeUnix))) FROM payflow_otel.otel_metrics_gauge
        WHERE MetricName = 'hikaricp.connections.pending' AND Value > 20
          AND toDate(TimeUnix) = '2026-11-27') = '2026-11-27 14:03:00', 'OK', 'KO')                          AS b_alert_fires,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE ServiceName = 'k8s-events' AND EventName = 'ScalingReplicaSet'
          AND Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:03:00'
          AND Body LIKE '%CHG-4117%') = 1, 'OK', 'KO')                                                       AS b_change_found,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE ServiceName = 'k8s-events' AND EventName = 'OOMKilling'
          AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:30:00') >= 1, 'OK', 'KO')           AS c_oom_found
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 76 ms · 5,6 M lignes lues (9,4 Mo) · 126,2 Mo de mémoire
