-- =====================================================================
--  MODULE 4 · Dictionaries: enrich billions of signals in memory
-- =====================================================================
--  A log line knows its pod. A span knows its merchant id. Neither knows
--  the owning team, the node size, the merchant tier or which change was
--  deployed at that moment. Dictionaries bring this context: a reference
--  table loaded in memory, read with dictGet() at the speed of a hash lookup,
--  without a JOIN (rule query-join-use-dictionaries).
--  SOURCE says where to read, LAYOUT how to organise it in memory,
--  LIFETIME how often to reload it.
-- =====================================================================


-- STEP 1 · Services, nodes and merchants: simple key → attributes
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


-- STEP 2 · "Which change was running at that moment?": a range dictionary
--  Key = deployment, range = [valid_from, valid_to]. dictGet with a timestamp
--  returns the version, the change id and its author at that instant.
--  This one dictionary answers the first question of every incident review.
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
-- Measured: 2 ms · 1 row read
-- What to look for: v2.4.0, then v2.4.1 (CHG-4117 by j.martin), then v2.4.0 again.


-- STEP 3 · Errors per team and per minute, around the incident
--  The span only knows its service: the team comes from the dictionary.
SELECT
    toStartOfFiveMinutes(toDateTime(Timestamp))                         AS t,
    dictGet('payflow_ref.dict_service', 'team', ServiceName)            AS team,
    countIf(StatusCode = 'Error')                                       AS error_spans
FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 13:45:00' AND Timestamp < '2026-11-27 15:00:00' AND SpanKind = 'Server'
GROUP BY t, team
HAVING error_spans > 0
ORDER BY t, error_spans DESC;
-- Measured: 41 ms · 1.4 M rows read (9.8 MB) · 66 MB memory
-- What to look for: the "payments" team owns most errors, "checkout" and "platform"
-- only propagate them. Paging the right team first saves minutes.


-- STEP 4 · Every error span, stamped with the change that was live
SELECT
    ServiceName,
    dictGet('payflow_ref.dict_deployment', 'version', ServiceName, toDateTime(Timestamp))    AS version,
    dictGet('payflow_ref.dict_deployment', 'change_id', ServiceName, toDateTime(Timestamp))  AS change_id,
    count()                                                                                   AS error_spans
FROM payflow_otel.otel_traces
WHERE StatusCode = 'Error' AND ServiceName = 'payment'
GROUP BY ServiceName, version, change_id
ORDER BY error_spans DESC;
-- Measured: 199 ms · 3.6 M rows read (15.7 MB) · 88.9 MB memory
-- What to look for: almost every payment error happened under CHG-4117.
-- Watch out: during a rollout two versions run side by side. The dictionary gives
-- the change of the deployment; the pod's own version is in ResourceAttributes['service.version'].


-- STEP 5 · dictGet versus JOIN: revenue per merchant tier, on all the payments of the day
--  Both queries return the same numbers. Compare time and memory in system.query_log.
SELECT
    dictGet('payflow_ref.dict_merchant', 'tier', SpanAttributes['merchant.id'])  AS tier,
    count()                                                                      AS payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                      AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'authorized'
GROUP BY tier
ORDER BY amount_eur DESC;
-- Measured: 302 ms · 1.1 M rows read (32.6 MB) · 173.2 MB memory

SELECT
    m.tier                                                                       AS tier,
    count()                                                                      AS payments,
    round(sum(toFloat64(t.SpanAttributes['payment.amount'])))                    AS amount_eur
FROM payflow_otel.otel_traces AS t
INNER JOIN payflow_ref.merchant AS m ON m.merchant_id = t.SpanAttributes['merchant.id']
WHERE t.ServiceName = 'payment' AND t.SpanName = 'payment.AuthorizePayment' AND t.SpanAttributes['payment.status'] = 'authorized'
GROUP BY tier
ORDER BY amount_eur DESC;
-- Measured: 65 ms · 1.1 M rows read (32.8 MB) · 174.3 MB memory


-- STEP 6 · Logs per availability zone and node size
SELECT
    dictGet('payflow_ref.dict_node', 'zone', ResourceAttributes['k8s.node.name'])           AS zone,
    dictGet('payflow_ref.dict_node', 'instance_type', ResourceAttributes['k8s.node.name'])  AS instance_type,
    count()                                                                                  AS log_records,
    countIf(SeverityNumber >= 17)                                                            AS errors
FROM payflow_otel.otel_logs
WHERE ServiceName != 'k8s-events'
GROUP BY zone, instance_type
ORDER BY zone, instance_type;
-- Measured: 319 ms · 8.1 M rows read (131.8 MB) · 266.4 MB memory


-- STEP 7 · What the dictionaries cost in memory
SELECT name, status, element_count, formatReadableSize(bytes_allocated) AS memory, loading_duration
FROM system.dictionaries
WHERE database IN ('payflow_ref', 'payflow_sim')
ORDER BY bytes_allocated DESC;
-- Measured: 4 ms · 36 rows read (17.3 KB)


-- STEP 8 · Checkpoint
SELECT
    if(dictGet('payflow_ref.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC')) = 'CHG-4117', 'OK', 'KO') AS range_dict,
    if(dictGet('payflow_ref.dict_service', 'team', 'payment') = 'payments', 'OK', 'KO')                                               AS dict_service,
    if((SELECT element_count FROM system.dictionaries WHERE database = 'payflow_ref' AND name = 'dict_merchant') = 20000, 'OK', 'KO')  AS dict_merchant
SETTINGS select_sequential_consistency = 1;
-- Measured: 6 ms · 37 rows read (17.3 KB)
