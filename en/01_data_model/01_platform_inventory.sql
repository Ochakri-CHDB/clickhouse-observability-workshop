-- =====================================================================
--  MODULE 1 · The data model: the platform and its service catalog
-- =====================================================================
--  PayFlow is a (fictional) payment platform. It runs on one Kubernetes
--  cluster, "payflow-prod-eu", spread over 3 availability zones.
--  Observability starts with knowing what you observe: which services exist,
--  who owns them, where they run, which version is live. This file creates
--  that service catalog (a small CMDB), and the 5 databases of the workshop,
--  named after the path of the telemetry:
--    payflow_sim        → the applications and their agents (simulated in SQL)
--    payflow_ingest     → the landing tables of the collector gateway
--    payflow_otel       → logs, traces, metrics, as the ClickHouse exporter writes them
--    payflow_sre        → what the connectors and the alerting compute: RED, SLOs, alerts, service map
--    payflow_inventory  → the service catalog: nodes, services, deployments, pods, merchants
--
--  A ClickHouse "database" is only a namespace: it costs nothing and is used
--  to organise tables and to grant rights (module 8).
-- =====================================================================


-- STEP 1 · The databases
CREATE DATABASE IF NOT EXISTS payflow_inventory;
CREATE DATABASE IF NOT EXISTS payflow_ingest;
CREATE DATABASE IF NOT EXISTS payflow_otel;
CREATE DATABASE IF NOT EXISTS payflow_sre;
CREATE DATABASE IF NOT EXISTS payflow_sim;


-- STEP 2 · A technical user for the dictionaries (step 8)
--  In the Cloud console, a dictionary that reads a local table must
--  declare a user and a password. We keep it minimal: local connection
--  only, read-only on the inventory and the simulator.
CREATE USER IF NOT EXISTS payflow_dict IDENTIFIED BY 'PayFlow_Dict_2026!' HOST LOCAL;
GRANT SELECT ON payflow_inventory.* TO payflow_dict;
GRANT SELECT ON payflow_sim.* TO payflow_dict;


-- STEP 3 · The nodes of the cluster: our first MergeTree table
--  MergeTree is the core ClickHouse engine. Two things to remember:
--    · ORDER BY sets the physical order of rows on disk AND the primary
--      index. Choose it from the most frequent filters
--      (rule schema-pk-plan-before-creation).
--    · each column is stored and compressed separately (columnar storage):
--      a query only reads the columns it uses.
--  LowCardinality(String) stores a dictionary of the distinct values once,
--  then small integers: ideal below ~10,000 distinct values.
CREATE OR REPLACE TABLE payflow_inventory.node
(
    node_name      String,
    zone           LowCardinality(String),
    instance_type  LowCardinality(String),
    cpu_cores      UInt8,
    memory_gib     UInt16
)
ENGINE = MergeTree
ORDER BY node_name;

INSERT INTO payflow_inventory.node VALUES
    ('ip-10-0-1-11', 'eu-west-1a', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-1-12', 'eu-west-1a', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-1-13', 'eu-west-1a', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-1-14', 'eu-west-1a', 'r7i.2xlarge', 8, 64),
    ('ip-10-0-2-21', 'eu-west-1b', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-2-22', 'eu-west-1b', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-2-23', 'eu-west-1b', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-2-24', 'eu-west-1b', 'r7i.2xlarge', 8, 64),
    ('ip-10-0-3-15', 'eu-west-1c', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-3-16', 'eu-west-1c', 'm7i.2xlarge', 8, 32),
    ('ip-10-0-3-17', 'eu-west-1c', 'm7i.xlarge',  4, 16),   -- the smallest node: remember it
    ('ip-10-0-3-18', 'eu-west-1c', 'r7i.2xlarge', 8, 64);


-- STEP 4 · The services and their owners
--  9 services in 3 namespaces. slo_target is the availability objective
--  of the service (99.9% = 43 minutes of errors allowed per month).
CREATE OR REPLACE TABLE payflow_inventory.service
(
    service     LowCardinality(String),
    namespace   LowCardinality(String),
    team        LowCardinality(String),
    language    LowCardinality(String),
    replicas    UInt8,
    tier        LowCardinality(String),   -- critical / standard
    slo_target  Float32                   -- availability objective, in %
)
ENGINE = MergeTree
ORDER BY service;

INSERT INTO payflow_inventory.service VALUES
    ('api-gateway',          'edge',     'platform', 'nginx',  6, 'critical', 99.95),
    ('auth',                 'edge',     'identity', 'go',     3, 'critical', 99.95),
    ('checkout',             'payments', 'checkout', 'go',     6, 'critical', 99.9),
    ('fraud-scoring',        'risk',     'risk',     'python', 4, 'critical', 99.5),
    ('currency',             'payments', 'checkout', 'go',     2, 'standard', 99.5),
    ('payment',              'payments', 'payments', 'java',   6, 'critical', 99.9),
    ('card-network-adapter', 'payments', 'payments', 'java',   4, 'critical', 99.9),
    ('ledger',               'payments', 'ledger',   'java',   3, 'critical', 99.9),
    ('notification',         'payments', 'checkout', 'go',     3, 'standard', 99.0);


-- STEP 5 · The deployment history: which version ran when
--  Every rollout creates a new ReplicaSet, hence new pod names.
--  On Black Friday at 13:58 UTC the payments team ships payment v2.4.1.
--  It is rolled back at 14:42. Keep these two times in mind for module 6.
CREATE OR REPLACE TABLE payflow_inventory.deployment_history
(
    deployment   LowCardinality(String),
    version      LowCardinality(String),
    replicaset   String,                  -- the hash Kubernetes puts in pod names
    valid_from   DateTime('UTC'),
    valid_to     DateTime('UTC'),
    change_id    String,
    author       String,
    note         String
)
ENGINE = MergeTree
ORDER BY (deployment, valid_from);

INSERT INTO payflow_inventory.deployment_history
SELECT
    s.service,
    concat('v', s.base_version),
    substring(lower(hex(cityHash64(s.service, s.base_version))), 1, 10),   -- 10 characters, like Kubernetes
    toDateTime('2026-11-20 09:00:00', 'UTC'),
    toDateTime('2099-12-31 00:00:00', 'UTC'),
    concat('CHG-', toString(4000 + rowNumberInAllBlocks())),
    'release-bot',
    'weekly release'
FROM
(
    SELECT service,
           ['3.8.2', '1.12.0', '5.1.4', '2.9.1', '1.3.7', '2.4.0', '4.2.0', '3.0.5', '1.7.3'][indexOf(
           ['api-gateway', 'auth', 'checkout', 'fraud-scoring', 'currency', 'payment', 'card-network-adapter', 'ledger', 'notification'], service)] AS base_version
    FROM payflow_inventory.service
    WHERE service != 'payment'
) AS s;
-- Measured: 85 ms · 9 rows read · 8 rows written

INSERT INTO payflow_inventory.deployment_history VALUES
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-20 09:00:00', '2026-11-27 13:57:59', 'CHG-4005', 'release-bot', 'weekly release'),
    ('payment', 'v2.4.1', '5c8b7f9d21', '2026-11-27 13:58:00', '2026-11-27 14:41:59', 'CHG-4117', 'j.martin',    'connection pool tuning for Black Friday (pool size 50 to 10, see review)'),
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-27 14:42:00', '2099-12-31 00:00:00', 'CHG-4118', 'oncall-payments', 'rollback of CHG-4117');

SELECT deployment, version, replicaset, valid_from, valid_to, change_id, note
FROM payflow_inventory.deployment_history
WHERE deployment = 'payment'
ORDER BY valid_from;
-- Measured: 2 ms
-- What to look for: three rows for payment. The middle one is the version
-- that will cause the incident. The note already gives a clue.


-- STEP 6 · The pods
--  A pod name is "<deployment>-<replicaset>-<5 characters>". Each slot of a
--  deployment keeps its pod until a rollout replaces it. During a rollout,
--  Kubernetes replaces pods one by one: here one every 30 s on the way in
--  (13:58) and one every 20 s on the way back (14:42).
--  The pods are spread over the 12 nodes. fraud-scoring slot 2 lands on
--  ip-10-0-3-17, the smallest node.
CREATE OR REPLACE TABLE payflow_inventory.pod
(
    pod_name     String,
    pod_uid      String,
    deployment   LowCardinality(String),
    namespace    LowCardinality(String),
    slot         UInt8,
    version      LowCardinality(String),
    node_name    LowCardinality(String),
    started_at   DateTime('UTC'),
    stopped_at   DateTime('UTC')
)
ENGINE = MergeTree
ORDER BY (deployment, slot, started_at);

INSERT INTO payflow_inventory.pod
WITH
    ['ip-10-0-1-11', 'ip-10-0-1-12', 'ip-10-0-1-13', 'ip-10-0-1-14', 'ip-10-0-2-21', 'ip-10-0-2-22',
     'ip-10-0-2-23', 'ip-10-0-2-24', 'ip-10-0-3-15', 'ip-10-0-3-16', 'ip-10-0-3-17', 'ip-10-0-3-18'] AS nodes,
    generations AS
    (
        -- one generation per (deployment, version period); payment has 3, the others 1
        SELECT
            h.deployment, h.version, h.replicaset, h.valid_from, h.valid_to,
            row_number() OVER (PARTITION BY h.deployment ORDER BY h.valid_from) - 1 AS gen,
            s.namespace, s.replicas
        FROM payflow_inventory.deployment_history AS h
        INNER JOIN payflow_inventory.service AS s ON s.service = h.deployment
    )
SELECT
    concat(g.deployment, '-', g.replicaset, '-',
           substring(lower(hex(cityHash64(g.deployment, g.gen, slot))), 1, 5))              AS pod_name,
    lower(hex(cityHash64(g.deployment, g.gen, slot, 'uid')))::String                       AS pod_uid,
    g.deployment,
    g.namespace,
    slot,
    g.version,
    if(g.deployment = 'fraud-scoring' AND slot = 2, 'ip-10-0-3-17',
       nodes[1 + cityHash64(g.deployment, slot, 'node') % 12])                            AS node_name,
    -- rollout: slot k of a new generation starts k x 30 s (or 20 s for the rollback) after the change
    if(g.gen = 0, g.valid_from,
       g.valid_from + toIntervalSecond(slot * if(g.gen = 1, 30, 20)))                       AS started_at,
    if(g.valid_to >= toDateTime('2099-01-01', 'UTC'), g.valid_to,
       g.valid_to + 1 + toIntervalSecond(slot * if(g.gen = 0, 30, 20)) - 1)                 AS stopped_at
FROM generations AS g
ARRAY JOIN range(toUInt8(g.replicas)) AS slot;
-- Measured: 76 ms · 20 rows read · 49 rows written

SELECT deployment, count() AS pods, uniqExact(node_name) AS nodes
FROM payflow_inventory.pod
GROUP BY deployment
ORDER BY deployment;
-- Measured: 3 ms · 49 rows read
-- What to look for: one pod per replica, 49 in total. payment has 18: 3 generations of 6.

SELECT pod_name, version, node_name, started_at, stopped_at
FROM payflow_inventory.pod
WHERE deployment = 'payment' AND slot = 0
ORDER BY started_at;
-- Measured: 3 ms · 49 rows read (2.5 KB)
-- What to look for: the pod of slot 0 changes name twice. A log line only
-- carries the pod name: without this table, nobody knows which version wrote it.


-- STEP 7 · The merchants
--  PayFlow processes payments for 20,000 merchants. Each span of a payment
--  carries the merchant id: this is what links observability to business
--  (module 6: how much revenue did the incident cost, and to whom).
CREATE OR REPLACE TABLE payflow_inventory.merchant
(
    merchant_id   String,
    name          String,
    country       LowCardinality(String),
    mcc           LowCardinality(String),   -- merchant category code
    category      LowCardinality(String),
    tier          LowCardinality(String),   -- enterprise / mid-market / small
    avg_basket    Float32                   -- average amount, in EUR
)
ENGINE = MergeTree
ORDER BY merchant_id;

INSERT INTO payflow_inventory.merchant
SELECT
    concat('m_', leftPad(toString(number), 5, '0'))                                           AS merchant_id,
    concat(['Nordic', 'Atlas', 'Blue', 'Urban', 'Prime', 'Green', 'Silver', 'Alpine', 'Coastal', 'Metro',
            'Bright', 'Royal', 'Golden', 'Iron', 'Oak', 'Swift', 'Lumen', 'Vertex', 'Nova', 'Summit'][1 + cityHash64(number, 'w1') % 20],
           ' ',
           ['Outdoor', 'Fashion', 'Electronics', 'Books', 'Coffee', 'Travel', 'Sports', 'Home', 'Beauty', 'Games',
            'Bikes', 'Pets', 'Music', 'Toys', 'Garden', 'Wine', 'Shoes', 'Tech', 'Foods', 'Studio'][1 + cityHash64(number, 'w2') % 20],
           ' ', ['Ltd', 'GmbH', 'SAS', 'BV', 'SL', 'AB', 'SpA', 'Oy'][1 + cityHash64(number, 'w3') % 8])     AS name,
    ['DE', 'FR', 'GB', 'ES', 'IT', 'NL', 'SE', 'PL', 'BE', 'IE'][1 + cityHash64(number, 'country') % 10]          AS country,
    ['5651', '5732', '5942', '5814', '4722', '5941', '5712', '5977', '5816', '5999'][1 + cityHash64(number, 'mcc') % 10] AS mcc,
    ['Clothing', 'Electronics', 'Books', 'Restaurants', 'Travel', 'Sporting goods', 'Furniture', 'Cosmetics',
     'Digital goods', 'Retail'][indexOf(['5651', '5732', '5942', '5814', '4722', '5941', '5712', '5977', '5816', '5999'], mcc)] AS category,
    multiIf(cityHash64(number, 'tier') % 100 < 2, 'enterprise', cityHash64(number, 'tier') % 100 < 20, 'mid-market', 'small') AS tier,
    toFloat32(round(15 + (cityHash64(number, 'basket') % 1000) / 10.0 * if(category = 'Travel', 6, 1), 2))       AS avg_basket
FROM numbers(20000);
-- Measured: 91 ms · 20,000 rows read (156.2 KB) · 20,000 rows written

SELECT tier, count() AS merchants, round(avg(avg_basket), 1) AS avg_basket_eur
FROM payflow_inventory.merchant
GROUP BY tier
ORDER BY merchants;
-- Measured: 3 ms · 20,000 rows read (97.7 KB)


-- STEP 8 · The catalog in memory: dictionaries
--  The collector enriches every record with Kubernetes metadata (the k8sattributes
--  processor asks the Kubernetes API). Here the gateway of module 2 does it in SQL:
--  a dictionary is a reference table loaded in memory, read with dictGet() at the
--  speed of a hash lookup, without a JOIN (rule query-join-use-dictionaries).
--  SOURCE says where to read, LAYOUT how to organise it in memory, LIFETIME how often to reload.
CREATE OR REPLACE DICTIONARY payflow_inventory.dict_pod
(
    pod_name    String,
    deployment  String,
    namespace   String,
    version     String,
    node_name   String,
    pod_uid     String
)
PRIMARY KEY pod_name
SOURCE(CLICKHOUSE(DB 'payflow_inventory' TABLE 'pod' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 60 MAX 120);

CREATE OR REPLACE DICTIONARY payflow_inventory.dict_service
(
    service     String,
    namespace   String,
    team        String,
    language    String,
    tier        String,
    slo_target  Float32
)
PRIMARY KEY service
SOURCE(CLICKHOUSE(DB 'payflow_inventory' TABLE 'service' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

CREATE OR REPLACE DICTIONARY payflow_inventory.dict_node
(
    node_name      String,
    zone           String,
    instance_type  String,
    memory_gib     UInt16
)
PRIMARY KEY node_name
SOURCE(CLICKHOUSE(DB 'payflow_inventory' TABLE 'node' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

CREATE OR REPLACE DICTIONARY payflow_inventory.dict_merchant
(
    merchant_id  String,
    name         String,
    country      String,
    category     String,
    tier         String
)
PRIMARY KEY merchant_id
SOURCE(CLICKHOUSE(DB 'payflow_inventory' TABLE 'merchant' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

--  "Which change was live at that moment?": a range dictionary. Key = deployment,
--  range = [valid_from, valid_to]. The first question of every incident review (module 6).
CREATE OR REPLACE DICTIONARY payflow_inventory.dict_deployment
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
SOURCE(CLICKHOUSE(DB 'payflow_inventory' TABLE 'deployment_history' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 300 MAX 600);

SELECT
    dictGet('payflow_inventory.dict_pod', ('deployment', 'version', 'node_name'), 'payment-5c8b7f9d21-dbec8')        AS pod_metadata,
    dictGet('payflow_inventory.dict_node', 'zone', 'ip-10-0-3-17')                                                    AS zone,
    dictGet('payflow_inventory.dict_service', 'team', 'payment')                                                      AS team,
    dictGet('payflow_inventory.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC'))   AS change_at_14h15;
-- Measured: 2 ms · 1 row read
-- What to look for: from a pod name alone, the deployment, its version, its node and
-- zone, the owning team, and the change that was live at 14:15 (CHG-4117).


-- STEP 9 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_inventory.node) = 12, 'OK', 'KO')                         AS nodes,
    if((SELECT count() FROM payflow_inventory.service) = 9, 'OK', 'KO')                       AS services,
    if((SELECT count() FROM payflow_inventory.deployment_history) = 11, 'OK', 'KO')           AS history,
    if((SELECT count() FROM payflow_inventory.pod) = 49, 'OK', 'KO')                          AS pods,
    if((SELECT node_name FROM payflow_inventory.pod WHERE deployment = 'fraud-scoring' AND slot = 2) = 'ip-10-0-3-17', 'OK', 'KO') AS fraud_pod_node,
    if((SELECT count() FROM payflow_inventory.merchant) = 20000, 'OK', 'KO')                  AS merchants,
    if(dictGet('payflow_inventory.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC')) = 'CHG-4117', 'OK', 'KO') AS dictionaries
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whatever the replica
-- Measured: 69 ms · 55 rows read
