-- =====================================================================
--  MODULE 1 · Le modèle de données : la plateforme et son catalogue de services
-- =====================================================================
--  PayFlow est une plateforme de paiement (fictive). Elle tourne sur un seul
--  cluster Kubernetes, "payflow-prod-eu", réparti sur 3 zones de disponibilité.
--  L'observabilité commence par savoir ce que l'on observe : quels services
--  existent, à qui ils appartiennent, où ils tournent, quelle version est en ligne.
--  Ce fichier crée ce catalogue de services (une petite CMDB) et les 5 bases du
--  workshop, nommées d'après le chemin de la télémétrie :
--    payflow_sim        → les applications et leurs agents (simulés en SQL)
--    payflow_ingest     → les tables d'atterrissage de la passerelle (gateway) du collecteur
--    payflow_otel       → logs, traces, métriques, tels que l'exporteur ClickHouse les écrit
--    payflow_sre        → calculs des connecteurs et de l'alerting : RED, SLO, alertes, service map
--    payflow_inventory  → le catalogue de services : nœuds, services, déploiements, pods, marchands
--
--  Une "database" ClickHouse n'est qu'un espace de noms : elle ne coûte rien et sert
--  à organiser les tables et à attribuer des droits (module 8).
-- =====================================================================


-- ÉTAPE 1 · Les bases
CREATE DATABASE IF NOT EXISTS payflow_inventory;
CREATE DATABASE IF NOT EXISTS payflow_ingest;
CREATE DATABASE IF NOT EXISTS payflow_otel;
CREATE DATABASE IF NOT EXISTS payflow_sre;
CREATE DATABASE IF NOT EXISTS payflow_sim;


-- ÉTAPE 2 · Un utilisateur technique pour les dictionnaires (étape 8)
--  Dans la console Cloud, un dictionnaire qui lit une table locale doit déclarer
--  un utilisateur et un mot de passe. On reste minimal : connexion locale
--  uniquement, lecture seule sur l'inventaire et le simulateur.
CREATE USER IF NOT EXISTS payflow_dict IDENTIFIED BY 'PayFlow_Dict_2026!' HOST LOCAL;
GRANT SELECT ON payflow_inventory.* TO payflow_dict;
GRANT SELECT ON payflow_sim.* TO payflow_dict;


-- ÉTAPE 3 · Les nœuds du cluster : notre première table MergeTree
--  MergeTree est le moteur central de ClickHouse. Deux choses à retenir :
--    · ORDER BY fixe l'ordre physique des lignes sur disque ET l'index
--      primaire. Choisissez-le à partir des filtres les plus fréquents
--      (règle schema-pk-plan-before-creation).
--    · chaque colonne est stockée et compressée à part (stockage colonne) :
--      une requête ne lit que les colonnes qu'elle utilise.
--  LowCardinality(String) stocke une seule fois le dictionnaire des valeurs
--  distinctes, puis de petits entiers : idéal sous ~10 000 valeurs distinctes.
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
    ('ip-10-0-3-17', 'eu-west-1c', 'm7i.xlarge',  4, 16),   -- le plus petit nœud : retenez-le
    ('ip-10-0-3-18', 'eu-west-1c', 'r7i.2xlarge', 8, 64);


-- ÉTAPE 4 · Les services et leurs propriétaires
--  9 services dans 3 namespaces. slo_target est l'objectif de disponibilité
--  du service (99,9 % = 43 minutes d'erreurs autorisées par mois).
CREATE OR REPLACE TABLE payflow_inventory.service
(
    service     LowCardinality(String),
    namespace   LowCardinality(String),
    team        LowCardinality(String),
    language    LowCardinality(String),
    replicas    UInt8,
    tier        LowCardinality(String),   -- critical / standard
    slo_target  Float32                   -- objectif de disponibilité, en %
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


-- ÉTAPE 5 · L'historique des déploiements : quelle version tournait quand
--  Chaque déploiement progressif (rollout) crée un nouveau ReplicaSet, donc de
--  nouveaux noms de pods. Le jour du Black Friday à 13h58 UTC, l'équipe payments
--  livre payment v2.4.1. Retour arrière (rollback) à 14h42. Gardez ces deux
--  heures en tête pour le module 6.
CREATE OR REPLACE TABLE payflow_inventory.deployment_history
(
    deployment   LowCardinality(String),
    version      LowCardinality(String),
    replicaset   String,                  -- le hash que Kubernetes met dans les noms de pods
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
    substring(lower(hex(cityHash64(s.service, s.base_version))), 1, 10),   -- 10 caractères, comme Kubernetes
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
-- Mesuré : 85 ms · 9 lignes lues · 8 lignes écrites

INSERT INTO payflow_inventory.deployment_history VALUES
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-20 09:00:00', '2026-11-27 13:57:59', 'CHG-4005', 'release-bot', 'weekly release'),
    ('payment', 'v2.4.1', '5c8b7f9d21', '2026-11-27 13:58:00', '2026-11-27 14:41:59', 'CHG-4117', 'j.martin',    'connection pool tuning for Black Friday (pool size 50 to 10, see review)'),
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-27 14:42:00', '2099-12-31 00:00:00', 'CHG-4118', 'oncall-payments', 'rollback of CHG-4117');

SELECT deployment, version, replicaset, valid_from, valid_to, change_id, note
FROM payflow_inventory.deployment_history
WHERE deployment = 'payment'
ORDER BY valid_from;
-- Mesuré : 2 ms
-- À observer : trois lignes pour payment. Celle du milieu est la version qui
-- va provoquer l'incident. La note donne déjà un indice.


-- ÉTAPE 6 · Les pods
--  Un nom de pod a la forme "<deployment>-<replicaset>-<5 caractères>". Chaque
--  slot d'un déploiement garde son pod jusqu'à ce qu'un rollout le remplace.
--  Pendant un rollout, Kubernetes remplace les pods un par un : ici un toutes les
--  30 s à l'aller (13h58) et un toutes les 20 s au retour (14h42).
--  Les pods sont répartis sur les 12 nœuds. Le slot 2 de fraud-scoring atterrit
--  sur ip-10-0-3-17, le plus petit nœud.
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
        -- une génération par (déploiement, période de version) ; payment en a 3, les autres 1
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
    -- rollout : le slot k d'une nouvelle génération démarre k x 30 s (20 s au rollback) après le changement
    if(g.gen = 0, g.valid_from,
       g.valid_from + toIntervalSecond(slot * if(g.gen = 1, 30, 20)))                       AS started_at,
    if(g.valid_to >= toDateTime('2099-01-01', 'UTC'), g.valid_to,
       g.valid_to + 1 + toIntervalSecond(slot * if(g.gen = 0, 30, 20)) - 1)                 AS stopped_at
FROM generations AS g
ARRAY JOIN range(toUInt8(g.replicas)) AS slot;
-- Mesuré : 76 ms · 20 lignes lues · 49 lignes écrites

SELECT deployment, count() AS pods, uniqExact(node_name) AS nodes
FROM payflow_inventory.pod
GROUP BY deployment
ORDER BY deployment;
-- Mesuré : 3 ms · 49 lignes lues
-- À observer : un pod par réplique, 49 au total. payment en a 18 : 3 générations de 6.

SELECT pod_name, version, node_name, started_at, stopped_at
FROM payflow_inventory.pod
WHERE deployment = 'payment' AND slot = 0
ORDER BY started_at;
-- Mesuré : 3 ms · 49 lignes lues (2,5 Ko)
-- À observer : le pod du slot 0 change deux fois de nom. Une ligne de log ne porte
-- que le nom du pod : sans cette table, personne ne sait quelle version l'a écrite.


-- ÉTAPE 7 · Les marchands
--  PayFlow traite les paiements de 20 000 marchands. Chaque span d'un paiement
--  porte l'identifiant du marchand : c'est ce qui relie l'observabilité au métier
--  (module 6 : combien de chiffre d'affaires l'incident a coûté, et à qui).
CREATE OR REPLACE TABLE payflow_inventory.merchant
(
    merchant_id   String,
    name          String,
    country       LowCardinality(String),
    mcc           LowCardinality(String),   -- merchant category code (code catégorie du marchand)
    category      LowCardinality(String),
    tier          LowCardinality(String),   -- enterprise / mid-market / small
    avg_basket    Float32                   -- panier moyen, en EUR
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
-- Mesuré : 91 ms · 20 000 lignes lues (156,2 Ko) · 20 000 lignes écrites

SELECT tier, count() AS merchants, round(avg(avg_basket), 1) AS avg_basket_eur
FROM payflow_inventory.merchant
GROUP BY tier
ORDER BY merchants;
-- Mesuré : 3 ms · 20 000 lignes lues (97,7 Ko)


-- ÉTAPE 8 · Le catalogue en mémoire : les dictionnaires
--  Le collecteur enrichit chaque enregistrement avec les métadonnées Kubernetes (le
--  processeur k8sattributes interroge l'API Kubernetes). Ici, la passerelle du module 2
--  le fait en SQL : un dictionnaire est une table de référence chargée en mémoire, lue
--  avec dictGet() à la vitesse d'une recherche par hash, sans JOIN
--  (règle query-join-use-dictionaries). SOURCE dit où lire, LAYOUT comment l'organiser
--  en mémoire, LIFETIME à quelle fréquence le recharger.
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

--  "Quel changement était en ligne à ce moment-là ?" : un dictionnaire à plages. Clé =
--  deployment, plage = [valid_from, valid_to]. La première question de toute revue
--  d'incident (module 6).
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
-- Mesuré : 2 ms · 1 ligne lue
-- À observer : à partir du seul nom d'un pod, le déploiement, sa version, son nœud et
-- sa zone, l'équipe propriétaire, et le changement en ligne à 14h15 (CHG-4117).


-- ÉTAPE 9 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_inventory.node) = 12, 'OK', 'KO')                         AS nodes,
    if((SELECT count() FROM payflow_inventory.service) = 9, 'OK', 'KO')                       AS services,
    if((SELECT count() FROM payflow_inventory.deployment_history) = 11, 'OK', 'KO')           AS history,
    if((SELECT count() FROM payflow_inventory.pod) = 49, 'OK', 'KO')                          AS pods,
    if((SELECT node_name FROM payflow_inventory.pod WHERE deployment = 'fraud-scoring' AND slot = 2) = 'ip-10-0-3-17', 'OK', 'KO') AS fraud_pod_node,
    if((SELECT count() FROM payflow_inventory.merchant) = 20000, 'OK', 'KO')                  AS merchants,
    if(dictGet('payflow_inventory.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC')) = 'CHG-4117', 'OK', 'KO') AS dictionaries
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
-- Mesuré : 69 ms · 55 lignes lues
