-- =====================================================================
--  MODULE 4 · Dictionnaires : enrichir des milliards de signaux en mémoire
-- =====================================================================
--  Une ligne de log connaît son pod. Un span connaît l'id de son marchand. Aucun ne
--  connaît l'équipe responsable, la taille du node, le niveau du marchand ni le
--  changement déployé à ce moment-là. Les dictionnaires apportent ce contexte : une table
--  de référence chargée en mémoire, lue avec dictGet() à la vitesse d'une table de
--  hachage, sans JOIN (règle query-join-use-dictionaries).
--  SOURCE dit où lire, LAYOUT comment l'organiser en mémoire,
--  LIFETIME à quelle fréquence la recharger.
-- =====================================================================


-- ÉTAPE 1 · Services, nodes et marchands : clé simple → attributs
CREATE OR REPLACE DICTIONARY payflow_ref.dict_service
(
    service     String,
    namespace   String,
    team        String,
    language    String,
    tier        String,
    slo_target  Float32
)
PRIMARY KEY service
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'service' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

CREATE OR REPLACE DICTIONARY payflow_ref.dict_node
(
    node_name      String,
    zone           String,
    instance_type  String,
    memory_gib     UInt16
)
PRIMARY KEY node_name
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'node' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

CREATE OR REPLACE DICTIONARY payflow_ref.dict_merchant
(
    merchant_id  String,
    name         String,
    country      String,
    category     String,
    tier         String
)
PRIMARY KEY merchant_id
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'merchant' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);


-- ÉTAPE 2 · "Quel changement tournait à ce moment-là ?" : un dictionnaire à plages
--  Clé = deployment, plage = [valid_from, valid_to]. dictGet avec un horodatage
--  renvoie la version, le change id et son auteur à cet instant.
--  Ce seul dictionnaire répond à la première question de chaque post-mortem.
CREATE OR REPLACE DICTIONARY payflow_ref.dict_deployment
(
    deployment  String,
    valid_from  DateTime,
    valid_to    DateTime,
    version     String,
    change_id   String,
    author      String,
    note        String
)
PRIMARY KEY deployment
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'deployment_history' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 300 MAX 600);

SELECT
    t,
    dictGet('payflow_ref.dict_deployment', ('version', 'change_id', 'author'), 'payment', t) AS running
FROM (SELECT arrayJoin([toDateTime('2026-11-27 13:00:00', 'UTC'), toDateTime('2026-11-27 14:15:00', 'UTC'),
                        toDateTime('2026-11-27 15:00:00', 'UTC')]) AS t);
-- Mesuré : 2 ms · 1 ligne lue
-- À observer : v2.4.0, puis v2.4.1 (CHG-4117 par j.martin), puis de nouveau v2.4.0.


-- ÉTAPE 3 · Erreurs par équipe et par minute, autour de l'incident
--  Le span ne connaît que son service : l'équipe vient du dictionnaire.
SELECT
    toStartOfFiveMinutes(toDateTime(Timestamp))                         AS t,
    dictGet('payflow_ref.dict_service', 'team', ServiceName)            AS team,
    countIf(StatusCode = 'Error')                                       AS error_spans
FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 13:45:00' AND Timestamp < '2026-11-27 15:00:00' AND SpanKind = 'Server'
GROUP BY t, team
HAVING error_spans > 0
ORDER BY t, error_spans DESC;
-- Mesuré : 41 ms · 1,4 M lignes lues (9,8 Mo) · 66 Mo de mémoire
-- À observer : l'équipe "payments" porte la plupart des erreurs, "checkout" et "platform"
-- ne font que les propager. Réveiller d'abord la bonne équipe fait gagner des minutes.


-- ÉTAPE 4 · Chaque span en erreur, marqué du changement qui était en production
SELECT
    ServiceName,
    dictGet('payflow_ref.dict_deployment', 'version', ServiceName, toDateTime(Timestamp))    AS version,
    dictGet('payflow_ref.dict_deployment', 'change_id', ServiceName, toDateTime(Timestamp))  AS change_id,
    count()                                                                                   AS error_spans
FROM payflow_otel.otel_traces
WHERE StatusCode = 'Error' AND ServiceName = 'payment'
GROUP BY ServiceName, version, change_id
ORDER BY error_spans DESC;
-- Mesuré : 199 ms · 3,6 M lignes lues (15,7 Mo) · 88,9 Mo de mémoire
-- À observer : presque toutes les erreurs de payment ont eu lieu sous CHG-4117.
-- Attention : pendant un déploiement progressif (rollout), deux versions tournent côte à
-- côte. Le dictionnaire donne le changement du deployment, la version propre du pod est
-- dans ResourceAttributes['service.version'].


-- ÉTAPE 5 · dictGet contre JOIN : CA par niveau de marchand, sur tous les paiements du jour
--  Les deux requêtes renvoient les mêmes chiffres. Comparez durée et mémoire dans system.query_log.
SELECT
    dictGet('payflow_ref.dict_merchant', 'tier', SpanAttributes['merchant.id'])  AS tier,
    count()                                                                      AS payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                      AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'authorized'
GROUP BY tier
ORDER BY amount_eur DESC;
-- Mesuré : 302 ms · 1,1 M lignes lues (32,6 Mo) · 173,2 Mo de mémoire

SELECT
    m.tier                                                                       AS tier,
    count()                                                                      AS payments,
    round(sum(toFloat64(t.SpanAttributes['payment.amount'])))                    AS amount_eur
FROM payflow_otel.otel_traces AS t
INNER JOIN payflow_ref.merchant AS m ON m.merchant_id = t.SpanAttributes['merchant.id']
WHERE t.ServiceName = 'payment' AND t.SpanName = 'payment.AuthorizePayment' AND t.SpanAttributes['payment.status'] = 'authorized'
GROUP BY tier
ORDER BY amount_eur DESC;
-- Mesuré : 65 ms · 1,1 M lignes lues (32,8 Mo) · 174,3 Mo de mémoire


-- ÉTAPE 6 · Logs par zone de disponibilité et taille de node
SELECT
    dictGet('payflow_ref.dict_node', 'zone', ResourceAttributes['k8s.node.name'])           AS zone,
    dictGet('payflow_ref.dict_node', 'instance_type', ResourceAttributes['k8s.node.name'])  AS instance_type,
    count()                                                                                  AS log_records,
    countIf(SeverityNumber >= 17)                                                            AS errors
FROM payflow_otel.otel_logs
WHERE ServiceName != 'k8s-events'
GROUP BY zone, instance_type
ORDER BY zone, instance_type;
-- Mesuré : 319 ms · 8,1 M lignes lues (131,8 Mo) · 266,4 Mo de mémoire


-- ÉTAPE 7 · Ce que coûtent les dictionnaires en mémoire
SELECT name, status, element_count, formatReadableSize(bytes_allocated) AS memory, loading_duration
FROM system.dictionaries
WHERE database IN ('payflow_ref', 'payflow_sim')
ORDER BY bytes_allocated DESC;
-- Mesuré : 4 ms · 36 lignes lues (17,3 Ko)


-- ÉTAPE 8 · Checkpoint
SELECT
    if(dictGet('payflow_ref.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC')) = 'CHG-4117', 'OK', 'KO') AS range_dict,
    if(dictGet('payflow_ref.dict_service', 'team', 'payment') = 'payments', 'OK', 'KO')                                               AS dict_service,
    if((SELECT element_count FROM system.dictionaries WHERE database = 'payflow_ref' AND name = 'dict_merchant') = 20000, 'OK', 'KO')  AS dict_merchant
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 6 ms · 37 lignes lues (17,3 Ko)
