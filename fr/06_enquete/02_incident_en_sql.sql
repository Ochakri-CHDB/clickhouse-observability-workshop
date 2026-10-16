-- =====================================================================
--  MODULE 6 · Enquête (2/2) : de la page à la cause racine, en SQL
-- =====================================================================
--  14h00 UTC, Black Friday. L'ingénieur d'astreinte reçoit une page : "POST /v1/payments:
--  error budget burning 19x faster than allowed". Dix questions, dix requêtes.
--  Toutes les réponses viennent de la même base : pas de changement d'outil, pas de copie
--  de données entre un outil de logs, un outil de traces et un outil de métriques.
-- =====================================================================


-- Q1 · Qu'est-ce qui a sonné, et quand ?
SELECT ts, rule, service, state, summary
FROM payflow_sre.alerts
WHERE ts BETWEEN pf_at('13:50') AND pf_at('15:00')
ORDER BY ts;
-- Mesuré : 31 ms · 12 lignes lues (1 Ko)


-- Q2 · C'est grave à quel point ? Erreurs et latence par service, maintenant et 1 h avant
SELECT
    service,
    round(100 * sumIf(errors, minute >= pf_at('14:05') AND minute < pf_at('14:15'))
              / sumIf(requests, minute >= pf_at('14:05') AND minute < pf_at('14:15')), 2)          AS error_pct_now,
    round(100 * sumIf(errors, minute >= pf_at('13:05') AND minute < pf_at('13:15'))
              / sumIf(requests, minute >= pf_at('13:05') AND minute < pf_at('13:15')), 2)          AS error_pct_before,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency, minute >= pf_at('14:05') AND minute < pf_at('14:15'))[3] / 1e6) AS p99_ms_now,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency, minute >= pf_at('13:05') AND minute < pf_at('13:15'))[3] / 1e6) AS p99_ms_before
FROM payflow_sre.red_1m
GROUP BY service
ORDER BY error_pct_now DESC;
-- Mesuré : 139 ms · 721 414 lignes lues (102,8 Mo) · 337,8 Mo de mémoire
-- À observer : trois services échouent (api-gateway, checkout, payment). Qui est la cause,
-- qui ne fait que relayer l'erreur ?


-- Q3 · Où naît l'erreur ? Le span en échec le plus profond de chaque trace en échec
--  Un span en échec dont aucun enfant n'a échoué, c'est là que l'erreur est née.
SELECT ServiceName, SpanName, StatusMessage, count() AS failed_traces
FROM payflow_otel.otel_traces AS s
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND StatusCode = 'Error'
  AND SpanId NOT IN
  (
      SELECT ParentSpanId FROM payflow_otel.otel_traces
      WHERE Timestamp BETWEEN pf_at('14:04') AND pf_at('14:16') AND StatusCode = 'Error'
  )
GROUP BY ServiceName, SpanName, StatusMessage
ORDER BY failed_traces DESC
LIMIT 5;
-- Mesuré : 705 ms · 1,6 M lignes lues (17,3 Mo) · 66 Mo de mémoire
-- À observer : l'appel à la base de payment, "Connection is not available,
-- request timed out after 3000ms". Les autres sont des victimes.


-- Q4 · Une trace en échec, sous forme d'arbre (une CTE récursive)
--  WITH RECURSIVE descend du span racine vers ses enfants, niveau par niveau.
WITH RECURSIVE
    (SELECT TraceId FROM payflow_otel.otel_traces
     WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments' AND StatusCode = 'Error'
       AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:01') LIMIT 1) AS tid,
    spans AS
    (
        SELECT SpanId, ParentSpanId, ServiceName, SpanName, Timestamp, Duration, StatusCode
        FROM payflow_otel.otel_traces
        WHERE TraceId = tid AND Timestamp BETWEEN pf_at('14:09:55') AND pf_at('14:10:10')
    ),
    tree AS
    (
        SELECT SpanId, ServiceName, SpanName, Timestamp, Duration, StatusCode, 0 AS depth
        FROM spans WHERE ParentSpanId = ''
        UNION ALL
        SELECT s.SpanId, s.ServiceName, s.SpanName, s.Timestamp, s.Duration, s.StatusCode, t.depth + 1
        FROM spans AS s INNER JOIN tree AS t ON s.ParentSpanId = t.SpanId
    )
SELECT
    concat(repeat('   ', depth), SpanName)                                                    AS span,
    ServiceName                                                                                AS service,
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1)                 AS start_ms,
    round(Duration / 1e6, 1)                                                                   AS duration_ms,
    StatusCode                                                                                 AS status
FROM tree
ORDER BY Timestamp;
-- Mesuré : 1,66 s · 638 999 lignes lues (34,2 Mo)
-- À observer : la cascade (waterfall) du module 3, en SQL pur. 3 secondes d'attente
-- dans INSERT payflow.payments ; réseau de cartes, ledger et notification ne sont jamais appelés.


-- Q5 · Qu'est-ce qui a changé ? Le changement en place pour chaque erreur, et les déploiements
--  Le dictionnaire à plages du module 1 associe à chaque span en erreur le changement en
--  place à cette seconde ; l'équipe vient du catalogue de services.
SELECT
    dictGet('payflow_inventory.dict_service', 'team', ServiceName)                            AS team,
    ServiceName,
    dictGet('payflow_inventory.dict_deployment', 'change_id', ServiceName, toDateTime(Timestamp)) AS change_live,
    count()                                                                                    AS error_spans
FROM payflow_otel.otel_traces
WHERE StatusCode = 'Error' AND SpanKind = 'Client' AND SpanAttributes['rpc.system'] = '' AND toDate(Timestamp) = pf_black_friday()
GROUP BY team, ServiceName, change_live
ORDER BY error_spans DESC
LIMIT 5;
-- Mesuré : 227 ms · 21,5 M lignes lues (62 Mo) · 146,4 Mo de mémoire
-- À observer : l'équipe payments, changement CHG-4117. Alerter d'abord la bonne équipe.

SELECT deployment, version, change_id, author, valid_from, note
FROM payflow_inventory.deployment_history
WHERE valid_from BETWEEN pf_at('12:00') AND pf_at('16:00')
ORDER BY valid_from;
-- Mesuré : 6 ms · 17 lignes lues (1,2 Ko)

SELECT
    ResourceAttributes['service.version']           AS pod_version,
    count()                                         AS db_calls,
    round(100 * countIf(StatusCode = 'Error') / count(), 2) AS error_pct,
    round(quantile(0.99)(Duration) / 1e6)           AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
  AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:42')
GROUP BY pod_version;
-- Mesuré : 142 ms · 65 537 lignes lues (1,6 Mo)
-- À observer : pendant le déploiement progressif (rollout), les deux versions servent le
-- trafic côte à côte. Seule v2.4.1 échoue. Même base, même trafic : la version est la cause.


-- Q6 · Pourquoi v2.4.1 échoue ? Le pool de connexions, vu par les métriques
SELECT
    toStartOfFiveMinutes(toDateTime(TimeUnix))                                          AS t,
    ResourceAttributes['service.version']                                                AS version,
    maxIf(Value, MetricName = 'hikaricp.connections.max')                                AS pool_size,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'), 1)                   AS active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'), 1)                  AS waiting
FROM payflow_otel.otel_metrics_gauge
WHERE ServiceName = 'payment' AND MetricName LIKE 'hikaricp.%'
  AND TimeUnix BETWEEN pf_at('13:40') AND pf_at('15:00')
GROUP BY t, version
ORDER BY t, version;
-- Mesuré : 200 ms · 49 153 lignes lues (2,5 Mo)
-- À observer : v2.4.1 a 10 connexions, toutes occupées, et des dizaines de threads en attente.


-- Q7 · ... et vu par les logs : la ligne de démarrage d'un pod v2.4.1
SELECT Timestamp, ResourceAttributes['k8s.pod.name'] AS pod, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND hasToken(lower(Body), 'maximumpoolsize')
  AND Timestamp BETWEEN pf_at('13:55') AND pf_at('14:50')
ORDER BY Timestamp
LIMIT 4;
-- Mesuré : 699 ms · 40 961 lignes lues (1,5 Mo)
-- À observer : maximumPoolSize=10 à 13h58, maximumPoolSize=50 après le retour arrière
-- (rollback). La note du changement disait "pool size 50 to 10" : la revue a oublié
-- la charge du Black Friday.


-- Q8 · Le second feu : fraud-scoring sur le petit nœud
--  Les nouvelles tentatives ajoutent de la charge, fraud-scoring ralentit, sa mémoire
--  grimpe jusqu'à ce que le noyau le tue.
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE (ServiceName = 'k8s-events' AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17'
       AND SeverityText = 'WARN' AND EventName != 'Unhealthy')
   OR (ServiceName = 'fraud-scoring' AND SeverityNumber >= 13 AND Body NOT LIKE 'score=%')
ORDER BY Timestamp
LIMIT 20;
-- Mesuré : 970 ms · 25,1 M lignes lues (2 Go) · 401,9 Mo de mémoire

SELECT
    toStartOfMinute(toDateTime(TimeUnix))                         AS minute,
    round(max(Value) / 1048576)                                   AS memory_mib
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'k8s.pod.memory.usage'
  AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17' AND ServiceName = 'fraud-scoring'
  AND TimeUnix BETWEEN pf_at('14:00') AND pf_at('14:30')
GROUP BY minute
ORDER BY minute WITH FILL STEP INTERVAL 1 MINUTE;
-- Mesuré : 98 ms · 8 193 lignes lues (466,7 Ko)
-- À observer : la mémoire monte jusqu'à 2 Gio, tombe à 0 à 14h21 (tué), redémarre.


-- Q9 · L'impact métier : paiements échoués, montant, marchands
SELECT
    count()                                                                            AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                            AS amount_eur,
    uniqExact(SpanAttributes['merchant.id'])                                           AS merchants_hit
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:50');
-- Mesuré : 144 ms · 73 729 lignes lues (2,8 Mo)

SELECT
    dictGet('payflow_inventory.dict_merchant', 'name', SpanAttributes['merchant.id'])          AS merchant,
    dictGet('payflow_inventory.dict_merchant', 'tier', SpanAttributes['merchant.id'])          AS tier,
    count()                                                                              AS failed_payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                              AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'failed'
  AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:50')
GROUP BY merchant, tier
ORDER BY amount_eur DESC
LIMIT 10;
-- Mesuré : 42 ms · 73 729 lignes lues (2,8 Mo)
-- À observer : les chiffres côté clients pour le rapport d'incident.
-- Les responsables de compte savent qui appeler en premier.


-- Q10 · La chronologie de l'incident, à partir de tous les signaux à la fois
SELECT ts, source, what
FROM
(
    SELECT valid_from AS ts, 'deploy' AS source, concat(deployment, ' ', version, ' (', change_id, ', ', author, ')') AS what
    FROM payflow_inventory.deployment_history WHERE valid_from BETWEEN pf_at('13:00') AND pf_at('15:00')
    UNION ALL
    SELECT ts, concat('alert ', state), concat(rule, ': ', summary) FROM payflow_sre.alerts WHERE ts BETWEEN pf_at('13:00') AND pf_at('15:00')
    UNION ALL
    SELECT min(toDateTime(Timestamp)), 'first error log', any(Body) FROM payflow_otel.otel_logs
    WHERE hasToken(lower(Body), 'hikaripool') AND SeverityText = 'ERROR' AND toDate(Timestamp) = pf_black_friday()
    UNION ALL
    SELECT max(toDateTime(Timestamp)), 'last error log', any(Body) FROM payflow_otel.otel_logs
    WHERE hasToken(lower(Body), 'hikaripool') AND SeverityText = 'ERROR' AND toDate(Timestamp) = pf_black_friday()
    UNION ALL
    SELECT toDateTime(Timestamp), 'k8s', concat(EventName, ': ', Body) FROM payflow_otel.otel_logs
    WHERE ServiceName = 'k8s-events' AND SeverityText = 'WARN' AND EventName != 'Unhealthy'
      AND Timestamp BETWEEN pf_at('13:00') AND pf_at('15:00')
)
ORDER BY ts;
-- Mesuré : 76 ms · 3,2 M lignes lues (31,4 Mo) · 184,5 Mo de mémoire
-- À observer : déploiement 13h58, première erreur 13h58, page 14h00, OOM 14h21,
-- retour arrière 14h42, dernière erreur 14h44, résolu 14h47. Temps de détection : 2 minutes.
-- Temps de mitigation : 44 minutes. Le postmortem s'écrit tout seul.


-- Checkpoint
SELECT
    if((SELECT argMax(SpanName, c) FROM (SELECT SpanName, count() AS c FROM payflow_otel.otel_traces
        WHERE StatusCode = 'Error' AND Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15') AND SpanKind = 'Client'
          AND SpanAttributes['rpc.system'] = ''
        GROUP BY SpanName)) = 'INSERT payflow.payments', 'OK', 'KO')                                                   AS root_cause_span,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE hasToken(lower(Body), 'maximumpoolsize') AND Body LIKE '%maximumPoolSize=10%') = 6, 'OK', 'KO') AS startup_clue,
    if((SELECT countIf(StatusCode = 'Error') FROM payflow_otel.otel_traces
        WHERE ServiceName = 'payment' AND SpanName = 'INSERT payflow.payments'
          AND ResourceAttributes['service.version'] = 'v2.4.0' AND Timestamp BETWEEN pf_at('13:58') AND pf_at('14:42')) = 0, 'OK', 'KO') AS only_v241_fails
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 509 ms · 901 152 lignes lues (6,1 Mo) · 64,9 Mo de mémoire
