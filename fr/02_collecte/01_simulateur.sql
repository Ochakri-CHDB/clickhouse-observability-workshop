-- =====================================================================
--  MODULE 2 · Collecte (1/4) : les applications et leurs agents, simulés en SQL
-- =====================================================================
--  Pas de générateur de charge, pas de collecteur à installer : toute la journée
--  est générée par ClickHouse lui-même, à partir de numbers() et de quelques
--  fonctions SQL. Tout est déterministe (cityHash64 au lieu de rand()) : chaque
--  participant obtient exactement les mêmes requêtes, les mêmes erreurs, les mêmes chiffres.
--
--  La journée : vendredi 27 novembre 2026, en UTC.
--    · le trafic suit la journée, avec une pointe en soirée à 19h30
--    · de 13h57 à 14h36 : une vente flash multiplie le trafic par 1,6
--    · 13h58 : déploiement progressif de payment v2.4.1 (pool de connexions de 50 à 10)
--    · à partir de 14h03 : le pool sature, les requêtes attendent, puis échouent après 3 s
--    · les clients réessaient : +25 % de trafic, fraud-scoring ralentit,
--      son pod sur le petit nœud ip-10-0-3-17 est OOMKilled à 14:21:07
--    · 14h42 : retour arrière vers v2.4.0, tout est revenu à la normale à 14h47
--
--  Le simulateur joue les applications (instrumentées avec un SDK OpenTelemetry) et
--  les collecteurs qui tournent sur les nœuds. Les fichiers 02 à 04 de ce module font
--  passer ce qu'il produit par la passerelle, jusque dans les tables OpenTelemetry.
-- =====================================================================


-- ÉTAPE 1 · Un hasard déterministe
--  pf_r(id, seed) renvoie un nombre dans [0, 1) qui ne dépend que de ses entrées.
--  Une même requête reçoit toujours les mêmes valeurs "aléatoires".
CREATE OR REPLACE FUNCTION pf_r AS (id, seed) -> cityHash64(id, seed) / 18446744073709551616.0;

--  Requêtes par seconde à la seconde s de la journée (0 à 86 399).
CREATE OR REPLACE FUNCTION pf_rate AS (s) ->
    30 * (0.25 + 0.75 * exp(-pow((s / 3600 - 19.5) / 5.5, 2)))     -- la forme de la journée, pointe à 19h30
       * if(s >= 50220 AND s < 52560, 1.6, 1.0)                      -- vente flash, de 13h57 à 14h36
       * if(s >= 50700 AND s < 53100, 1.25, 1.0);                    -- nouvelles tentatives des clients, de 14h05 à 14h45

--  Quelle version tourne sur un slot de pod payment à l'instant t (rollout d'un pod
--  toutes les 30 s, rollback d'un pod toutes les 20 s). C'est la cause de l'incident.
CREATE OR REPLACE FUNCTION pf_payment_version AS (slot, t) ->
    if(t >= toDateTime('2026-11-27 13:58:00', 'UTC') + toIntervalSecond(slot * 30)
       AND t < toDateTime('2026-11-27 14:42:00', 'UTC') + toIntervalSecond(slot * 20), 'v2.4.1', 'v2.4.0');

--  La zone de disponibilité est codée dans le nom du nœud : ip-10-0-<zone>-xx
CREATE OR REPLACE FUNCTION pf_zone AS (node) -> concat('eu-west-1', ['a', 'b', 'c'][toUInt8(splitByChar('-', node)[4])]);

--  Identifiants OpenTelemetry : 32 caractères hexadécimaux pour une trace, 16 pour un span.
CREATE OR REPLACE FUNCTION pf_trace_id AS (rid) -> lower(concat(hex(rid), hex(cityHash64(rid, 'trace'))));
CREATE OR REPLACE FUNCTION pf_span_id AS (rid, idx) -> lower(hex(cityHash64(rid, idx, 'span')));


-- ÉTAPE 2 · Quel pod tournait où, à un instant donné
--  Un dictionnaire à plages : clé (deployment, slot), plage [started_at, stopped_at].
--  dictGet(..., (deployment, slot), t) renvoie le pod qui servait ce slot à l'instant t.
--  Le simulateur en a besoin pour marquer chaque span et chaque ligne de log du bon pod.
CREATE OR REPLACE DICTIONARY payflow_sim.dict_pod
(
    deployment  String,
    slot        UInt8,
    started_at  DateTime,
    stopped_at  DateTime,
    pod_name    String,
    pod_uid     String,
    namespace   String,
    version     String,
    node_name   String
)
PRIMARY KEY deployment, slot
SOURCE(CLICKHOUSE(
    QUERY 'SELECT deployment, slot, started_at, stopped_at, pod_name, pod_uid, namespace, version, node_name FROM payflow_inventory.pod'
    USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_RANGE_HASHED())
RANGE(MIN started_at MAX stopped_at)
LIFETIME(0);

SELECT
    dictGet('payflow_sim.dict_pod', 'pod_name', ('payment', toUInt8(0)), toDateTime('2026-11-27 13:00:00', 'UTC')) AS at_13h,
    dictGet('payflow_sim.dict_pod', 'pod_name', ('payment', toUInt8(0)), toDateTime('2026-11-27 14:10:00', 'UTC')) AS at_14h10,
    dictGet('payflow_sim.dict_pod', 'pod_name', ('payment', toUInt8(0)), toDateTime('2026-11-27 15:00:00', 'UTC')) AS at_15h;
-- Mesuré : 1 ms · 1 ligne lue
-- À observer : trois noms de pods différents pour le même slot.


-- ÉTAPE 3 · Les requêtes
--  Une vue paramétrée : on l'appelle comme une fonction de table, avec la plage
--  de secondes à générer. Une ligne par requête HTTP qui arrive sur l'api-gateway.
--  Chaque valeur d'une requête (type, marchand, montant, pods, erreurs, durées)
--  est dérivée de son identifiant, rid.
CREATE OR REPLACE VIEW payflow_sim.requests AS
SELECT
    sec,
    cityHash64(sec, i) AS rid,   -- un id par (seconde, rang de la requête dans la seconde)
    fromUnixTimestamp64Nano(toInt64(1795737600000000000 + sec * 1000000000 + toUInt64(pf_r(rid, 'ns') * 1e9)), 'UTC') AS ts,
    multiIf(pf_r(rid, 'kind') < 0.72, 'POST /v1/payments',
            pf_r(rid, 'kind') < 0.87, 'GET /v1/payments/{id}',
            pf_r(rid, 'kind') < 0.95, 'POST /v1/refunds',
            'GET /v1/merchants/{id}/balance')                                                   AS route,
    concat('m_', leftPad(toString(toUInt32(20000 * pow(pf_r(rid, 'merchant'), 3))), 5, '0'))   AS merchant_id,
    concat('pay_', substring(lower(hex(cityHash64(rid, 'pid'))), 1, 14))                        AS payment_id,
    round(5 + 295 * pow(pf_r(rid, 'amount'), 2), 2)                                             AS amount,
    multiIf(pf_r(rid, 'cur') < 0.70, 'EUR', pf_r(rid, 'cur') < 0.82, 'GBP', pf_r(rid, 'cur') < 0.88, 'SEK',
            pf_r(rid, 'cur') < 0.94, 'PLN', 'USD')                                              AS currency,
    multiIf(pf_r(rid, 'brand') < 0.55, 'visa', pf_r(rid, 'brand') < 0.93, 'mastercard', 'amex') AS card_brand,
    -- un slot de pod par service, choisi par un hash de la requête (round robin)
    toUInt8(cityHash64(rid, 'gw') % 6)   AS slot_gw,
    toUInt8(cityHash64(rid, 'au') % 3)   AS slot_auth,
    toUInt8(cityHash64(rid, 'co') % 6)   AS slot_checkout,
    toUInt8(cityHash64(rid, 'fr') % 4)   AS slot_fraud,
    toUInt8(cityHash64(rid, 'cu') % 2)   AS slot_currency,
    toUInt8(cityHash64(rid, 'pa') % 6)   AS slot_payment,
    toUInt8(cityHash64(rid, 'cn') % 4)   AS slot_card,
    toUInt8(cityHash64(rid, 'le') % 3)   AS slot_ledger,
    toUInt8(cityHash64(rid, 'no') % 3)   AS slot_notif,
    pf_payment_version(slot_payment, toDateTime(ts))                                             AS payment_version,
    pf_rate(sec)                                                                                 AS rate,
    -- l'incident : v2.4.1 a 10 connexions au lieu de 50. Sous charge, les requêtes attendent
    -- une connexion ; au-delà de 3 s, HikariCP abandonne. Plus la charge monte, plus ça échoue.
    payment_version = 'v2.4.1'                                                                   AS bad_version,
    bad_version AND pf_r(rid, 'pgfail') < least(0.30, greatest(0.02, (rate - 15) / 60))
                    * if(route IN ('POST /v1/payments', 'POST /v1/refunds'), 1, 0.5)            AS pool_timeout,
    toUInt32(multiIf(pool_timeout, 3000000 + pf_r(rid, 'pgt') * 40000,
                     bad_version,  120000 + 2600000 * pow(pf_r(rid, 'pgw'), 2.5),
                     2500 + 5500 * pf_r(rid, 'pgn')))                                            AS db_us,
    sec >= 50700 AND sec < 53100                                                                 AS retry_storm,
    slot_fraud = 2 AND sec >= 51667 AND sec < 51712                                              AS fraud_down,   -- OOMKilled, en redémarrage
    pf_r(rid, 'declined') < 0.035                                                                AS declined,
    pf_r(rid, 'cardto') < 0.0012                                                                 AS card_timeout
FROM
(
    SELECT number AS sec,
           toUInt32(round(pf_rate(number) * (0.85 + 0.3 * pf_r(number, 'n')))) AS n_req
    FROM numbers({from_s:UInt32}, {to_s:UInt32} - {from_s:UInt32})
)
ARRAY JOIN range(n_req) AS i;

SELECT
    toStartOfFiveMinutes(toDateTime(ts)) AS minute,
    count() AS requests,
    round(count() / 300, 1) AS per_second,
    countIf(bad_version) AS on_v241,
    countIf(pool_timeout) AS timeouts
FROM payflow_sim.requests(from_s = 49800, to_s = 54000)
GROUP BY minute
ORDER BY minute;
-- Mesuré : 59 ms · 4 200 lignes lues (32,8 Ko)
-- À observer : de 13h55 à 15h00, par tranches de cinq minutes. La part des requêtes
-- servies par v2.4.1 monte de 13h58 à 14h01, les timeouts suivent la charge, tout
-- s'arrête à 14h42.


-- ÉTAPE 4 · Les spans de chaque requête (tracing distribué)
--  Une trace est l'arbre des spans d'une requête. Pour un paiement :
--  Chaque appel entre deux services est une paire : un span Client chez l'appelant, un
--  span Server chez l'appelé (la service map de ClickStack apparie ces paires).
--    api-gateway POST /v1/payments
--     ├─ auth.ValidateToken
--     └─ checkout.CreatePayment
--         ├─ fraud.ScoreTransaction ── redis GET
--         ├─ currency.GetRate            (paiements hors EUR seulement)
--         └─ payment.AuthorizePayment
--             ├─ INSERT payflow.payments  (postgres, attend une connexion du pool)
--             ├─ card.Authorize ── POST card network
--             ├─ ledger.PostEntry ── INSERT payflow.ledger_entries
--             └─ payment.events publish (kafka) ── notification consumer
--  Chaque span est un tuple (rang, parent, service, slot de pod, nom, kind, décalage de
--  début et durée en microsecondes, indicateur d'erreur, message d'erreur, attributs,
--  gardé ou non). Les durées sont construites de bas en haut : un parent couvre toujours
--  ses enfants. Les colonnes de sortie suivent exactement le schéma de l'exporteur
--  ClickHouse d'OpenTelemetry.
CREATE OR REPLACE VIEW payflow_sim.spans AS
WITH
    -- durées, en microsecondes
    toUInt32(2000 + 3000 * pf_r(rid, 'd_auth'))                                       AS d_auth,
    toUInt32(1000 + 2000 * pf_r(rid, 'd_redis'))                                      AS d_redis,
    toUInt32(if(fraud_down, 1500, (d_redis + 6000 + 9000 * pf_r(rid, 'd_fraud')) * if(retry_storm, 3, 1))) AS d_fraud,
    toUInt32(if(currency = 'EUR', 0, 2000 + 4000 * pf_r(rid, 'd_cur')))               AS d_cur,
    NOT pool_timeout                                                                  AS db_ok,
    db_ok AND NOT card_timeout AND NOT declined                                       AS booked,
    toUInt32(if(NOT db_ok, 0, if(card_timeout, 5000000, 60000 + 190000 * pf_r(rid, 'd_card')))) AS d_card,
    toUInt32(if(booked, 3000 + 3000 * pf_r(rid, 'd_lpg'), 0))                         AS d_lpg,
    toUInt32(if(booked, d_lpg + 3000 + 5000 * pf_r(rid, 'd_led'), 0))                 AS d_ledger,
    toUInt32(if(db_ok AND NOT card_timeout, 1000 + 2000 * pf_r(rid, 'd_kafka'), 0))   AS d_kafka,
    toUInt32(d_db_wait + d_card + d_ledger + d_kafka + 4000 + 6000 * pf_r(rid, 'd_pay')) AS d_pay,
    toUInt32(d_fraud + d_cur + d_pay + 3000 + 5000 * pf_r(rid, 'd_co'))              AS d_co,
    toUInt32(d_auth + d_co + 3000 + 3000 * pf_r(rid, 'd_gw'))                         AS d_gw,
    db_us                                                                             AS d_db_wait,
    -- décalages de début, en microsecondes après l'arrivée de la requête sur l'api-gateway
    toUInt32(2000 + d_auth)                       AS o_co,
    o_co + 1000                                   AS o_fraud,
    o_fraud + d_fraud + 500                       AS o_cur,
    o_cur + d_cur + 500                           AS o_pay,
    o_pay + 1000                                  AS o_db,
    o_db + d_db_wait + 500                        AS o_card,
    o_card + d_card + 500                         AS o_ledger,
    o_ledger + d_ledger + 500                     AS o_kafka,
    toUInt32(o_kafka + d_kafka + 20000 + 380000 * pf_r(rid, 'lag') * rate / 30) AS o_notif,
    toUInt32(5000 + 25000 * pf_r(rid, 'd_notif')) AS d_notif,
    multiIf(pool_timeout, '503', card_timeout, '502', declined, '402', '201') AS http_status,
    'HikariPool-1 - Connection is not available, request timed out after 3000ms.' AS pool_msg,
    -- le solde d'un marchand est lu par ledger, qui a sa propre base : pas touché
    route = 'GET /v1/merchants/{id}/balance'                                          AS is_balance,
    toUInt32(if(is_balance, 2000 + 4000 * pf_r(rid, 'd_bal'), d_db_wait))             AS d_other_db,
    pool_timeout AND NOT is_balance                                                   AS other_fail,
    -- la liste des spans de chaque route. Le type du tuple est déclaré une fois et réutilisé.
    'Array(Tuple(idx UInt8, parent Int8, svc String, slot UInt8, name String, kind String, off UInt32, dur UInt32, err Bool, msg String, attrs Map(String, String), keep Bool))' AS span_list,
    CAST([
        (0, -1, 'api-gateway', slot_gw, 'POST /v1/payments', 'Server', 0, d_gw, pool_timeout OR card_timeout, '',
            map('http.request.method', 'POST', 'http.route', '/v1/payments', 'http.response.status_code', http_status, 'merchant.id', merchant_id), true),
        (20, 0, 'api-gateway', slot_gw, 'auth.ValidateToken', 'Client', 800, toUInt32(d_auth + 400), false, '', map('rpc.system', 'grpc', 'server.address', 'auth.edge.svc.cluster.local'), true),
        (1, 20, 'auth', slot_auth, 'auth.ValidateToken', 'Server', 1000, d_auth, false, '', map('rpc.system', 'grpc'), true),
        (21, 0, 'api-gateway', slot_gw, 'checkout.CreatePayment', 'Client', toUInt32(o_co - 200), toUInt32(d_co + 400), pool_timeout OR card_timeout,
            if(pool_timeout OR card_timeout, 'upstream returned an error', ''), map('rpc.system', 'grpc', 'server.address', 'checkout.payments.svc.cluster.local'), true),
        (2, 21, 'checkout', slot_checkout, 'checkout.CreatePayment', 'Server', o_co, d_co, pool_timeout OR card_timeout,
            if(pool_timeout, 'payment service returned 503', if(card_timeout, 'payment service returned 502', '')),
            map('rpc.system', 'grpc', 'merchant.id', merchant_id, 'payment.id', payment_id, 'payment.amount', toString(amount), 'payment.currency', currency), true),
        (22, 2, 'checkout', slot_checkout, 'fraud.ScoreTransaction', 'Client', toUInt32(o_fraud - 200), toUInt32(d_fraud + 400), fraud_down,
            if(fraud_down, 'connect: connection refused', ''), map('rpc.system', 'grpc', 'server.address', 'fraud-scoring.risk.svc.cluster.local'), true),
        (3, 22, 'fraud-scoring', slot_fraud, 'fraud.ScoreTransaction', 'Server', o_fraud, d_fraud, fraud_down,
            if(fraud_down, 'connect: connection refused', ''), map('fraud.score', toString(round(pf_r(rid, 'score') * 0.6, 3))), true),
        (4, 3, 'fraud-scoring', slot_fraud, 'GET', 'Client', o_fraud + 1000, d_redis, false, '',
            map('db.system', 'redis', 'db.operation', 'GET', 'server.address', 'risk-cache.payflow.internal'), NOT fraud_down),
        (23, 2, 'checkout', slot_checkout, 'currency.GetRate', 'Client', toUInt32(o_cur - 200), toUInt32(d_cur + 400), false, '', map('rpc.system', 'grpc', 'server.address', 'currency.payments.svc.cluster.local'), currency != 'EUR'),
        (5, 23, 'currency', slot_currency, 'currency.GetRate', 'Server', o_cur, d_cur, false, '', map('payment.currency', currency), currency != 'EUR'),
        (24, 2, 'checkout', slot_checkout, 'payment.AuthorizePayment', 'Client', toUInt32(o_pay - 200), toUInt32(d_pay + 400), pool_timeout OR card_timeout,
            if(pool_timeout OR card_timeout, 'upstream returned an error', ''), map('rpc.system', 'grpc', 'server.address', 'payment.payments.svc.cluster.local'), true),
        (6, 24, 'payment', slot_payment, 'payment.AuthorizePayment', 'Server', o_pay, d_pay, pool_timeout OR card_timeout,
            if(pool_timeout, pool_msg, if(card_timeout, 'card network timeout', '')),
            map('payment.id', payment_id, 'merchant.id', merchant_id, 'payment.amount', toString(amount), 'payment.currency', currency,
                'payment.status', multiIf(pool_timeout OR card_timeout, 'failed', declined, 'declined', 'authorized')), true),
        (7, 6, 'payment', slot_payment, 'INSERT payflow.payments', 'Client', o_db, d_db_wait, pool_timeout, if(pool_timeout, pool_msg, ''),
            map('db.system', 'postgresql', 'db.name', 'payflow', 'db.operation', 'INSERT', 'server.address', 'payments-db.payflow.internal'), true),
        (25, 6, 'payment', slot_payment, 'card.Authorize', 'Client', toUInt32(o_card - 200), toUInt32(d_card + 400), card_timeout, if(card_timeout, 'deadline exceeded', ''),
            map('rpc.system', 'grpc', 'server.address', 'card-network-adapter.payments.svc.cluster.local'), db_ok),
        (8, 25, 'card-network-adapter', slot_card, 'card.Authorize', 'Server', o_card, d_card, card_timeout, if(card_timeout, 'card network timeout', ''),
            map('card.brand', card_brand, 'payment.status', if(declined, 'declined', 'approved')), db_ok),
        (9, 8, 'card-network-adapter', slot_card, 'POST', 'Client', o_card + 500, toUInt32(greatest(d_card, 1500) - 1000), card_timeout, if(card_timeout, 'read timeout', ''),
            map('http.request.method', 'POST', 'server.address', concat(card_brand, '.network.example'), 'http.response.status_code', if(card_timeout, '', '200')), db_ok),
        (26, 6, 'payment', slot_payment, 'ledger.PostEntry', 'Client', toUInt32(o_ledger - 200), toUInt32(d_ledger + 400), false, '',
            map('rpc.system', 'grpc', 'server.address', 'ledger.payments.svc.cluster.local'), booked),
        (10, 26, 'ledger', slot_ledger, 'ledger.PostEntry', 'Server', o_ledger, d_ledger, false, '', map('payment.id', payment_id), booked),
        (11, 10, 'ledger', slot_ledger, 'INSERT payflow.ledger_entries', 'Client', o_ledger + 1000, d_lpg, false, '',
            map('db.system', 'postgresql', 'db.name', 'payflow', 'db.operation', 'INSERT', 'server.address', 'ledger-db.payflow.internal'), booked),
        (12, 6, 'payment', slot_payment, 'payment.events publish', 'Producer', o_kafka, d_kafka, false, '',
            map('messaging.system', 'kafka', 'messaging.destination.name', 'payment.events'), d_kafka > 0),
        (13, 12, 'notification', slot_notif, 'payment.events process', 'Consumer', o_notif, d_notif, false, '',
            map('messaging.system', 'kafka', 'messaging.destination.name', 'payment.events', 'messaging.consumer.group.name', 'notification'), d_kafka > 0)
    ], span_list) AS spans_payment,
    -- les autres routes : lire un paiement, rembourser un paiement, lire le solde d'un marchand
    CAST([
        (0, -1, 'api-gateway', slot_gw, route, 'Server', 0, toUInt32(d_auth + d_other_db + 9000), other_fail, '',
            map('http.request.method', splitByChar(' ', route)[1], 'http.route', splitByChar(' ', route)[2],
                'http.response.status_code', if(other_fail, '503', if(route = 'POST /v1/refunds', '201', '200')), 'merchant.id', merchant_id), true),
        (20, 0, 'api-gateway', slot_gw, 'auth.ValidateToken', 'Client', 800, toUInt32(d_auth + 400), false, '', map('rpc.system', 'grpc', 'server.address', 'auth.edge.svc.cluster.local'), true),
        (1, 20, 'auth', slot_auth, 'auth.ValidateToken', 'Server', 1000, d_auth, false, '', map('rpc.system', 'grpc'), true),
        (21, 0, 'api-gateway', slot_gw,
            multiIf(route = 'GET /v1/payments/{id}', 'payment.GetPayment', route = 'POST /v1/refunds', 'payment.RefundPayment', 'ledger.GetBalance'),
            'Client', toUInt32(o_co - 200), toUInt32(d_other_db + 5400), other_fail, if(other_fail, 'upstream returned an error', ''),
            map('rpc.system', 'grpc', 'server.address', if(is_balance, 'ledger.payments.svc.cluster.local', 'payment.payments.svc.cluster.local')), true),
        (2, 21, if(is_balance, 'ledger', 'payment'), if(is_balance, slot_ledger, slot_payment),
            multiIf(route = 'GET /v1/payments/{id}', 'payment.GetPayment', route = 'POST /v1/refunds', 'payment.RefundPayment', 'ledger.GetBalance'),
            'Server', o_co, toUInt32(d_other_db + 5000), other_fail, if(other_fail, pool_msg, ''),
            map('merchant.id', merchant_id, 'payment.id', payment_id), true),
        (3, 2, if(is_balance, 'ledger', 'payment'), if(is_balance, slot_ledger, slot_payment),
            multiIf(route = 'GET /v1/payments/{id}', 'SELECT payflow.payments', route = 'POST /v1/refunds', 'UPDATE payflow.payments', 'SELECT payflow.ledger_entries'),
            'Client', o_co + 1000, d_other_db, other_fail, if(other_fail, pool_msg, ''),
            map('db.system', 'postgresql', 'db.name', 'payflow', 'db.operation', if(route = 'POST /v1/refunds', 'UPDATE', 'SELECT'),
                'server.address', if(is_balance, 'ledger-db.payflow.internal', 'payments-db.payflow.internal')), true)
    ], span_list) AS spans_other
SELECT
    addMicroseconds(ts, sp.off)                                                              AS Timestamp,
    pf_trace_id(rid)                                                                         AS TraceId,
    pf_span_id(rid, sp.idx)                                                                  AS SpanId,
    if(sp.parent < 0, '', pf_span_id(rid, toUInt8(sp.parent)))                               AS ParentSpanId,
    ''                                                                                       AS TraceState,
    sp.name                                                                                  AS SpanName,
    sp.kind                                                                                  AS SpanKind,
    sp.svc                                                                                   AS ServiceName,
    dictGet('payflow_sim.dict_pod', ('pod_name', 'pod_uid', 'namespace', 'version', 'node_name'), (sp.svc, sp.slot), toDateTime(ts)) AS pod,
    map('service.name', sp.svc, 'service.version', pod.4, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', pod.3, 'k8s.deployment.name', sp.svc, 'k8s.pod.name', pod.1, 'k8s.pod.uid', pod.2,
        'k8s.node.name', pod.5, 'cloud.availability_zone', pf_zone(pod.5),
        'deployment.environment.name', 'production')                                         AS ResourceAttributes,
    'io.opentelemetry.auto'                                                                  AS ScopeName,
    '2.10.0'                                                                                 AS ScopeVersion,
    sp.attrs                                                                                 AS SpanAttributes,
    toUInt64(sp.dur) * 1000                                                                  AS Duration,     -- nanosecondes
    if(sp.err, 'Error', 'Unset')                                                             AS StatusCode,
    sp.msg                                                                                   AS StatusMessage,
    if(sp.err, [addMicroseconds(ts, sp.off + sp.dur)], [])                                   AS `Events.Timestamp`,
    if(sp.err, ['exception'], [])                                                            AS `Events.Name`,
    if(sp.err, [map('exception.type', if(sp.msg LIKE 'HikariPool%', 'java.sql.SQLTransientConnectionException', 'Error'),
                    'exception.message', sp.msg)], [])                                       AS `Events.Attributes`,
    CAST([], 'Array(String)')                                                                AS `Links.TraceId`,
    CAST([], 'Array(String)')                                                                AS `Links.SpanId`,
    CAST([], 'Array(String)')                                                                AS `Links.TraceState`,
    CAST([], 'Array(Map(String, String))')                                                   AS `Links.Attributes`
FROM payflow_sim.requests(from_s = {from_s:UInt32}, to_s = {to_s:UInt32})
ARRAY JOIN if(route = 'POST /v1/payments', spans_payment, spans_other) AS sp
WHERE sp.keep;

SELECT ServiceName, SpanName, count() AS spans, round(quantile(0.99)(Duration) / 1e6, 1) AS p99_ms, countIf(StatusCode = 'Error') AS errors
FROM payflow_sim.spans(from_s = 51000, to_s = 51060)   -- une minute à 14h10
GROUP BY ServiceName, SpanName
ORDER BY spans DESC;
-- Mesuré : 245 ms · 60 lignes lues
-- À observer : une minute de l'incident. INSERT payflow.payments a un p99 de 3 secondes
-- et des centaines d'erreurs ; tout ce qui est au-dessus hérite de la latence.


-- ÉTAPE 5 · Formats d'horodatage : chaque langage logue à sa façon
CREATE OR REPLACE FUNCTION pf_ts_iso AS (t) ->
    concat(formatDateTime(t, '%Y-%m-%dT%H:%i:%s', 'UTC'), '.', leftPad(toString(toUnixTimestamp64Nano(t) % 1000000000), 9, '0'), 'Z');
CREATE OR REPLACE FUNCTION pf_ts_java AS (t) ->
    concat(formatDateTime(t, '%Y-%m-%d %H:%i:%s', 'UTC'), '.', leftPad(toString(toUnixTimestamp64Milli(t) % 1000), 3, '0'));
CREATE OR REPLACE FUNCTION pf_ts_nginx AS (t) -> formatDateTime(t, '%d/%b/%Y:%H:%i:%s +0000', 'UTC');
--  Un numéro de carte tel qu'un log de debug négligent l'afficherait (plages de test uniquement)
CREATE OR REPLACE FUNCTION pf_pan AS (id, brand) ->
    multiIf(brand = 'amex', concat('3782', leftPad(toString(cityHash64(id, 'pan') % 100000000000), 11, '0')),
            brand = 'mastercard', concat('5555', leftPad(toString(cityHash64(id, 'pan') % 1000000000000), 12, '0')),
            concat('4111', leftPad(toString(cityHash64(id, 'pan') % 1000000000000), 12, '0')));


-- ÉTAPE 6 · Les lignes de log applicatives, dérivées des spans
--  Chaque span serveur écrit la ligne de log de son service, à la fin du span.
--  La ligne porte le même trace id que le span : c'est ce qui permet de passer
--  d'un log à sa trace (module 3, ClickStack).
--  Un bug est caché ici : le pod card-network-adapter du slot 1 est resté en DEBUG
--  et affiche des numéros de carte complets. La passerelle du module 2 les masque à l'entrée (PCI DSS).
CREATE OR REPLACE VIEW payflow_sim.app_log_lines AS
SELECT
    addNanoseconds(Timestamp, Duration)                       AS t,
    ServiceName                                               AS svc,
    ResourceAttributes                                        AS res,
    TraceId                                                   AS tid,
    SpanId                                                    AS sid,
    line
FROM payflow_sim.spans(from_s = {from_s:UInt32}, to_s = {to_s:UInt32})
ARRAY JOIN multiIf(
    -- access log nginx : texte brut, le code de statut donne la sévérité
    ServiceName = 'api-gateway',
        [concat('10.', toString(cityHash64(TraceId, 'ip1') % 255), '.', toString(cityHash64(TraceId, 'ip2') % 255), '.', toString(cityHash64(TraceId, 'ip3') % 255),
                ' - - [', pf_ts_nginx(Timestamp), '] "', SpanName, ' HTTP/1.1" ', SpanAttributes['http.response.status_code'], ' ',
                toString(180 + cityHash64(TraceId, 'bytes') % 400), ' "-" "merchant-sdk/3.2" rt=', toString(round(Duration / 1e9, 3)),
                ' trace_id=', TraceId)],
    -- services Go : un objet JSON par ligne
    SpanName = 'checkout.CreatePayment',
        [concat('{"level":"', if(StatusCode = 'Error', 'error', 'info'), '","ts":"', pf_ts_iso(Timestamp),
                '","caller":"checkout/handler.go:142","msg":"', if(StatusCode = 'Error', 'payment failed', 'payment created'),
                '","payment_id":"', SpanAttributes['payment.id'], '","merchant_id":"', SpanAttributes['merchant.id'],
                '","amount":', SpanAttributes['payment.amount'], ',"currency":"', SpanAttributes['payment.currency'], '"',
                if(StatusCode = 'Error', concat(',"error":"', StatusMessage, '"'), ''),
                ',"trace_id":"', TraceId, '","span_id":"', SpanId, '"}')],
    SpanName = 'payment.events process',
        [concat('{"level":"info","ts":"', pf_ts_iso(Timestamp), '","caller":"notification/consumer.go:88","msg":"receipt email queued","topic":"payment.events","trace_id":"', TraceId, '","span_id":"', SpanId, '"}')],
    -- services Java : pattern logback, avec le trace id dans le MDC
    ServiceName = 'payment' AND SpanKind = 'Server',
        [concat(pf_ts_java(Timestamp), if(StatusCode = 'Error', ' ERROR', '  INFO'), ' 1 --- [nio-8080-exec-', toString(1 + cityHash64(SpanId) % 50), '] ',
                if(StatusCode = 'Error' AND StatusMessage LIKE 'HikariPool%', 'com.zaxxer.hikari.pool.HikariPool', 'c.p.payment.PaymentService'),
                ' [trace_id=', TraceId, ',span_id=', SpanId, '] : ',
                if(StatusCode = 'Error', StatusMessage,
                   concat(SpanName, ' ok payment=', SpanAttributes['payment.id'], ' status=', if(SpanAttributes['payment.status'] = '', 'ok', SpanAttributes['payment.status']),
                          ' took=', toString(intDiv(Duration, 1000000)), 'ms')))],
    SpanName = 'card.Authorize',
        arrayConcat(
            if(ResourceAttributes['k8s.pod.name'] = dictGet('payflow_sim.dict_pod', 'pod_name', ('card-network-adapter', toUInt8(1)), toDateTime(Timestamp)),
               [concat(pf_ts_java(Timestamp), ' DEBUG 1 --- [card-io-', toString(1 + cityHash64(SpanId) % 8), '] c.p.card.NetworkClient [trace_id=', TraceId,
                       ',span_id=', SpanId, '] : authorize request pan=', pf_pan(TraceId, SpanAttributes['card.brand']), ' exp=',
                       leftPad(toString(1 + cityHash64(TraceId, 'm') % 12), 2, '0'), '/', toString(27 + cityHash64(TraceId, 'y') % 5))],
               CAST([], 'Array(String)')),
            [concat(pf_ts_java(Timestamp), if(StatusCode = 'Error', ' ERROR', '  INFO'), ' 1 --- [card-io-', toString(1 + cityHash64(SpanId) % 8),
                    '] c.p.card.NetworkClient [trace_id=', TraceId, ',span_id=', SpanId, '] : ',
                    if(StatusCode = 'Error', 'Read timed out after 5000 ms', concat('authorization ', SpanAttributes['payment.status'], ' brand=', SpanAttributes['card.brand'])))]),
    SpanName = 'ledger.PostEntry',
        [concat(pf_ts_java(Timestamp), '  INFO 1 --- [ledger-', toString(1 + cityHash64(SpanId) % 16), '] c.p.ledger.EntryService [trace_id=', TraceId,
                ',span_id=', SpanId, '] : entry posted payment=', SpanAttributes['payment.id'])],
    -- Python : le format par défaut du module logging
    SpanName = 'fraud.ScoreTransaction',
        [if(StatusCode = 'Error',
            concat('ERROR:fraud.api:upstream connect error reason=', StatusMessage, ' trace_id=', TraceId),
            concat(if(toFloat64(SpanAttributes['fraud.score']) > 0.5, 'WARNING', 'INFO'), ':fraud.scorer:score=', SpanAttributes['fraud.score'],
                   ' decision=', if(toFloat64(SpanAttributes['fraud.score']) > 0.5, 'review', 'approve'),
                   ' latency_ms=', toString(intDiv(Duration, 1000000)), ' trace_id=', TraceId))],
    CAST([], 'Array(String)')) AS line
WHERE SpanKind IN ('Server', 'Consumer');


-- ÉTAPE 7 · Les logs d'infrastructure : health checks, démarrages de pods, OOM
--  · chaque pod répond à un health check du kubelet toutes les 10 s (du bruit, mais du vrai volume)
--  · chaque nouveau pod logue son démarrage. Lisez attentivement les lignes de payment v2.4.1.
--  · le worker fraud-scoring tué par le noyau à 14:21:07, et son redémarrage
CREATE OR REPLACE VIEW payflow_sim.infra_log_lines AS
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT t, svc, res, '' AS tid, '' AS sid, line
FROM
(
    -- health checks : une ligne par pod toutes les 10 secondes
    SELECT
        addSeconds(day0, s) + toIntervalMillisecond(cityHash64(p.pod_name, s) % 1000)               AS t,
        p.deployment                                                                                  AS svc,
        map('service.name', p.deployment, 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
            'k8s.namespace.name', p.namespace, 'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name,
            'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name, 'cloud.availability_zone', pf_zone(p.node_name),
            'deployment.environment.name', 'production')                                              AS res,
        multiIf(p.deployment = 'api-gateway', concat('10.0.', splitByChar('-', p.node_name)[4], '.1 - - [', pf_ts_nginx(t), '] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.31"'),
                p.deployment IN ('payment', 'card-network-adapter', 'ledger'), concat(pf_ts_java(t), ' DEBUG 1 --- [nio-8080-exec-1] o.s.b.a.health.HealthEndpoint : health status UP'),
                p.deployment = 'fraud-scoring', 'INFO:gunicorn.access:"GET /healthz HTTP/1.1" 200 2',
                concat('{"level":"debug","ts":"', pf_ts_iso(t), '","msg":"health check","path":"/healthz","status":200}')) AS line
    FROM payflow_inventory.pod AS p
    ARRAY JOIN range(intDiv({from_s:UInt32} + 9, 10) * 10, {to_s:UInt32}, 10) AS s
    WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) < p.stopped_at

    UNION ALL

    -- logs de démarrage des pods qui démarrent pendant la fenêtre
    SELECT
        addMilliseconds(toDateTime64(p.started_at, 9, 'UTC'), toUInt32(step.1))                      AS t,
        p.deployment, map('service.name', p.deployment, 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
            'k8s.namespace.name', p.namespace, 'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name,
            'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name, 'cloud.availability_zone', pf_zone(p.node_name),
            'deployment.environment.name', 'production'),
        concat(pf_ts_java(t), '  INFO 1 --- [           main] ', step.2)
    FROM payflow_inventory.pod AS p
    ARRAY JOIN [
        (1200, concat('c.p.payment.PaymentApplication : Starting PaymentApplication ', p.version, ' using Java 21.0.5')),
        (5400, 'com.zaxxer.hikari.HikariDataSource : HikariPool-1 - Starting...'),
        (5600, concat('com.zaxxer.hikari.HikariConfig : HikariPool-1 - configuration: maximumPoolSize=',
                      if(p.version = 'v2.4.1', '10', '50'), ' connectionTimeout=3000ms jdbcUrl=jdbc:postgresql://payments-db.payflow.internal:5432/payflow')),
        (6100, 'com.zaxxer.hikari.HikariDataSource : HikariPool-1 - Start completed.'),
        (7900, 'c.p.payment.PaymentApplication : Started PaymentApplication in 7.9 seconds (process running for 8.6)')] AS step
    WHERE p.deployment = 'payment'
      AND p.started_at >= addSeconds(day0, {from_s:UInt32}) AND p.started_at < addSeconds(day0, {to_s:UInt32})

    UNION ALL

    -- le worker fraud-scoring du petit nœud : sa mémoire grossit avec les retries, le noyau le tue
    SELECT
        toDateTime64(e.1, 9, 'UTC'), 'fraud-scoring',
        map('service.name', 'fraud-scoring', 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
            'k8s.namespace.name', p.namespace, 'k8s.deployment.name', 'fraud-scoring', 'k8s.pod.name', p.pod_name,
            'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name, 'cloud.availability_zone', pf_zone(p.node_name),
            'deployment.environment.name', 'production'),
        e.2
    FROM payflow_inventory.pod AS p
    ARRAY JOIN [
        (toDateTime('2026-11-27 14:18:40', 'UTC'), 'WARNING:fraud.scorer:request queue depth 412, scoring slower than arrival rate'),
        (toDateTime('2026-11-27 14:20:15', 'UTC'), 'WARNING:fraud.model:feature cache 1.9 GiB, close to the container memory limit (2 GiB)'),
        (toDateTime('2026-11-27 14:21:07', 'UTC'), 'CRITICAL:gunicorn.error:WORKER TIMEOUT (pid:4211)'),
        (toDateTime('2026-11-27 14:21:52', 'UTC'), 'INFO:gunicorn.error:Booting worker with pid: 77'),
        (toDateTime('2026-11-27 14:21:58', 'UTC'), 'INFO:fraud.model:model fraud-gbm-2026-11 loaded in 5.8 s')] AS e
    WHERE p.deployment = 'fraud-scoring' AND p.slot = 2
      AND e.1 >= addSeconds(day0, {from_s:UInt32}) AND e.1 < addSeconds(day0, {to_s:UInt32})
);


-- ÉTAPE 8 · Les événements Kubernetes
--  Le cluster lui-même parle : rollouts, scheduling, probes, pression mémoire, OOM kills.
--  Ils viennent de l'API Kubernetes, avec leur propre format JSON.
CREATE OR REPLACE VIEW payflow_sim.k8s_events AS
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT t, kind_obj, ns, obj, type, reason, message, component, host
FROM
(
    -- rollout et rollback de payment : l'ancien pod est tué, le nouveau planifié puis démarré
    SELECT toDateTime64(p.started_at, 9, 'UTC') + toIntervalMillisecond(ev.1) AS t, 'Pod' AS kind_obj, p.namespace AS ns, p.pod_name AS obj,
           'Normal' AS type, ev.2 AS reason, ev.3 AS message, ev.4 AS component, p.node_name AS host
    FROM payflow_inventory.pod AS p
    ARRAY JOIN [
        (0,    'Scheduled', concat('Successfully assigned payments/', p.pod_name, ' to ', p.node_name), 'default-scheduler'),
        (600,  'Pulled',    concat('Container image "registry.payflow.internal/payment:', p.version, '" already present on machine'), 'kubelet'),
        (900,  'Created',   'Created container: payment', 'kubelet'),
        (1100, 'Started',   'Started container payment', 'kubelet')] AS ev
    WHERE p.deployment = 'payment' AND p.started_at > toDateTime('2026-11-27 00:00:00', 'UTC')

    UNION ALL

    SELECT toDateTime64(p.stopped_at, 9, 'UTC') + toIntervalMillisecond(500), 'Pod', p.namespace, p.pod_name, 'Normal', 'Killing',
           'Stopping container payment', 'kubelet', p.node_name
    FROM payflow_inventory.pod AS p
    WHERE p.deployment = 'payment' AND p.stopped_at < toDateTime('2099-01-01', 'UTC')

    UNION ALL

    SELECT toDateTime64(h.valid_from, 9, 'UTC'), 'Deployment', 'payments', 'payment', 'Normal', 'ScalingReplicaSet',
           concat('Scaled up replica set payment-', h.replicaset, ' to 6 (rolling update ', h.change_id, ')'), 'deployment-controller', ''
    FROM payflow_inventory.deployment_history AS h
    WHERE h.deployment = 'payment' AND h.valid_from > toDateTime('2026-11-27 00:00:00', 'UTC')

    UNION ALL

    -- les pods v2.4.1 répondent lentement à leur readiness probe : le pool est plein
    SELECT addSeconds(toDateTime64(p.started_at, 9, 'UTC'), toUInt32(300 + k * 45 + cityHash64(p.pod_name, k) % 20)), 'Pod', p.namespace, p.pod_name,
           'Warning', 'Unhealthy', 'Readiness probe failed: Get "http://10.2.4.17:8080/actuator/health/readiness": context deadline exceeded (Client.Timeout exceeded while awaiting headers)',
           'kubelet', p.node_name
    FROM payflow_inventory.pod AS p
    ARRAY JOIN range(48) AS k
    WHERE p.version = 'v2.4.1' AND addSeconds(p.started_at, 300 + k * 45) < p.stopped_at

    UNION ALL

    -- le petit nœud manque de mémoire
    SELECT toDateTime64(e.1, 9, 'UTC'), e.2, e.3, e.4, 'Warning', e.5, e.6, e.7, 'ip-10-0-3-17'
    FROM
    (
        SELECT arrayJoin([
            (toDateTime('2026-11-27 14:19:31', 'UTC'), 'Node', '', 'ip-10-0-3-17', 'NodeHasInsufficientMemory',
             'Node ip-10-0-3-17 status is now: NodeHasInsufficientMemory', 'kubelet'),
            (toDateTime('2026-11-27 14:21:07', 'UTC'), 'Node', '', 'ip-10-0-3-17', 'OOMKilling',
             'Memory cgroup out of memory: Killed process 4211 (gunicorn) total-vm:2541604kB, anon-rss:2096128kB', 'kernel-monitor'),
            (toDateTime('2026-11-27 14:21:08', 'UTC'), 'Pod', 'risk', (SELECT pod_name FROM payflow_inventory.pod WHERE deployment = 'fraud-scoring' AND slot = 2), 'BackOff',
             'Back-off restarting failed container fraud-scoring (OOMKilled, exit code 137)', 'kubelet'),
            (toDateTime('2026-11-27 14:23:40', 'UTC'), 'Node', '', 'ip-10-0-3-17', 'NodeHasSufficientMemory',
             'Node ip-10-0-3-17 status is now: NodeHasSufficientMemory', 'kubelet')]) AS e
    )
)
WHERE t >= addSeconds(day0, {from_s:UInt32}) AND t < addSeconds(day0, {to_s:UInt32});


-- ÉTAPE 9 · Ce qu'envoient les agents des nœuds
--  Sur chaque nœud, un collecteur OpenTelemetry dans le rôle d'agent (un DaemonSet) fait tourner :
--    · le receiver filelog : il suit /var/log/pods/*/*/*.log et son opérateur "container"
--      transforme chaque ligne en enregistrement. Le seul contexte Kubernetes dont il
--      dispose est le chemin du fichier : /var/log/pods/<namespace>_<pod>_<pod uid>/<container>/0.log
--    · le receiver k8sobjects (une instance par cluster) : les événements Kubernetes
--  Tout le reste (déploiement, version, nœud, équipe) est ajouté par la passerelle au
--  module 2, fichier 02, comme le ferait le processeur k8sattributes.
CREATE OR REPLACE VIEW payflow_sim.raw_records AS
SELECT received_at, source, payload
FROM
(
    SELECT
        toDateTime64(l.t, 3, 'UTC') + toIntervalMillisecond(200 + cityHash64(l.line) % 1800)   AS received_at,   -- délai d'envoi de l'agent
        'filelog'                                                                                AS source,
        toJSONString(CAST((pf_ts_iso(l.t), 'stdout', l.line,
                           concat('/var/log/pods/', l.res['k8s.namespace.name'], '_', l.res['k8s.pod.name'], '_',
                                  l.res['k8s.pod.uid'], '/', l.svc, '/0.log')),
             'Tuple(time String, stream String, log String, `log.file.path` String)'))           AS payload
    FROM
    (
        SELECT t, svc, res, line FROM payflow_sim.app_log_lines(from_s = {from_s:UInt32}, to_s = {to_s:UInt32})
        UNION ALL
        SELECT t, svc, res, line FROM payflow_sim.infra_log_lines(from_s = {from_s:UInt32}, to_s = {to_s:UInt32})
    ) AS l

    UNION ALL

    SELECT
        toDateTime64(e.t, 3, 'UTC') + toIntervalMillisecond(150),
        'k8sobjects',
        toJSONString(CAST(('Event', e.type, e.reason, e.message, (e.kind_obj, e.ns, e.obj), (e.component, e.host), pf_ts_iso(e.t), 1),
             'Tuple(kind String, type String, reason String, message String, involvedObject Tuple(kind String, namespace String, name String), source Tuple(component String, host String), firstTimestamp String, count UInt32)'))
    FROM payflow_sim.k8s_events(from_s = {from_s:UInt32}, to_s = {to_s:UInt32}) AS e
);

SELECT source, count() AS records, formatReadableSize(sum(length(payload))) AS json
FROM payflow_sim.raw_records(from_s = 50400, to_s = 54000)   -- de 14h00 à 15h00
GROUP BY source;
-- Mesuré : 2,86 s · 3 947 lignes lues (46,3 Ko) · 832,2 Mo de mémoire
-- À observer : une heure d'incident, environ 530 000 lignes de log de conteneurs
-- (à peu près 200 Mo de JSON) et quelques centaines d'événements Kubernetes.


-- ÉTAPE 10 · Regarder ce qui arrive, avant d'écrire la moindre règle
--  ClickHouse lit le JSON sur place : JSONExtract* sur une String, ou le type JSON.
SELECT
    JSONExtractString(payload, 'log.file.path')     AS file,
    JSONExtractString(payload, 'log')               AS line
FROM payflow_sim.raw_records(from_s = 51000, to_s = 51001)
WHERE source = 'filelog'
LIMIT 5;
-- Mesuré : 847 ms · 198 lignes lues (8,3 Ko)

--  Quatre services, quatre formats : texte nginx, JSON Go, logback Java, logging Python
SELECT
    splitByChar('/', JSONExtractString(payload, 'log.file.path'))[6]   AS container,
    any(JSONExtractString(payload, 'log'))                              AS example
FROM payflow_sim.raw_records(from_s = 51000, to_s = 51010)
WHERE source = 'filelog' AND payload NOT LIKE '%health%'
GROUP BY container
ORDER BY container;
-- Mesuré : 555 ms · 207 lignes lues (8,3 Ko)
-- À observer : le niveau d'erreur s'écrit "error", " ERROR ", "ERROR:" ou seulement sous
-- forme de statut HTTP. La passerelle va normaliser cela une fois, pour toutes les lignes.

--  Le type JSON : on navigue avec des points. Un chemin est Dynamic : castez-le pour grouper.
SELECT j.involvedObject.kind::String AS object_kind, j.reason::String AS reason, count() AS events
FROM (SELECT payload::JSON AS j FROM payflow_sim.raw_records(from_s = 50400, to_s = 54000) WHERE source = 'k8sobjects')
GROUP BY object_kind, reason
ORDER BY events DESC;
-- Mesuré : 568 ms · 3 800 lignes lues (36,6 Ko)


-- ÉTAPE 11 · Un problème de sécurité, avant même de stocker quoi que ce soit
--  PCI DSS interdit de stocker un numéro de carte complet (PAN). Un pod les affiche.
SELECT
    splitByChar('_', splitByChar('/', JSONExtractString(payload, 'log.file.path'))[5])[2]  AS pod,
    count()                                                                                AS lines_with_pan,
    any(extract(JSONExtractString(payload, 'log'), 'pan=[0-9]+'))                          AS example
FROM payflow_sim.raw_records(from_s = 50400, to_s = 54000)
WHERE source = 'filelog' AND match(payload, 'pan=[0-9]{13,19}')
GROUP BY pod;
-- Mesuré : 3,03 s · 3 797 lignes lues (39,4 Ko) · 830,9 Mo de mémoire
-- À observer : un seul pod, resté en DEBUG, affiche des numéros de carte complets. Le
-- processeur redaction du collecteur devrait les masquer à la source ; la passerelle du
-- fichier 02 les masque à nouveau, et sa table d'atterrissage ne stocke rien : aucun
-- numéro de carte n'atteint jamais le disque.


-- ÉTAPE 12 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_sim.requests(from_s = 0, to_s = 86400)) > 1300000, 'OK', 'KO') AS one_day_of_requests,
    if((SELECT count() FROM payflow_sim.raw_records(from_s = 51667, to_s = 51668) WHERE source = 'k8sobjects') >= 1, 'OK', 'KO') AS oom_event
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 523 ms · 86 602 lignes lues (681 Ko)
