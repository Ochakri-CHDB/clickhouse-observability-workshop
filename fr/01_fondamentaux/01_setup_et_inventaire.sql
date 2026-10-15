-- =====================================================================
--  MODULE 1 · Fondamentaux : bases, MergeTree et inventaire de la plateforme
-- =====================================================================
--  PayFlow est une plateforme de paiement (fictive). Elle tourne sur un cluster
--  Kubernetes, "payflow-prod-eu", réparti sur 3 zones de disponibilité.
--  Ce fichier crée les 5 bases du workshop et l'inventaire auquel chaque
--  signal (logs, traces, métriques) sera joint :
--    payflow_ref  → nœuds, services, historique des déploiements, pods, marchands
--    payflow_raw  → lignes de log brutes des conteneurs, telles que l'agent les envoie (bronze)
--    payflow_otel → logs, traces et métriques au schéma OpenTelemetry (silver)
--    payflow_sre  → métriques RED, SLO, carte des services, alertes (gold)
--    payflow_sim  → le générateur de données du workshop
--
--  Une "base" ClickHouse n'est qu'un espace de noms : elle ne coûte rien et
--  sert à ranger les tables et à donner des droits par couche.
-- =====================================================================


-- ÉTAPE 1 · Les bases (une par couche)
CREATE DATABASE IF NOT EXISTS payflow_ref;
CREATE DATABASE IF NOT EXISTS payflow_raw;
CREATE DATABASE IF NOT EXISTS payflow_otel;
CREATE DATABASE IF NOT EXISTS payflow_sre;
CREATE DATABASE IF NOT EXISTS payflow_sim;


-- ÉTAPE 2 · Un utilisateur technique pour les dictionnaires (module 4)
--  Dans la console Cloud, un dictionnaire qui lit une table locale doit
--  déclarer un utilisateur et un mot de passe. On reste minimal : connexion
--  locale uniquement, lecture seule sur l'inventaire et le simulateur.
CREATE USER IF NOT EXISTS payflow_dict IDENTIFIED BY 'PayFlow_Dict_2026!' HOST LOCAL;
GRANT SELECT ON payflow_ref.* TO payflow_dict;
GRANT SELECT ON payflow_sim.* TO payflow_dict;


-- ÉTAPE 3 · Les nœuds du cluster : notre première table MergeTree
--  MergeTree est le moteur central de ClickHouse. Deux choses à retenir :
--    · ORDER BY fixe l'ordre physique des lignes sur disque ET l'index
--      primaire. On le choisit d'après les filtres les plus fréquents
--      (règle schema-pk-plan-before-creation).
--    · chaque colonne est stockée et compressée à part (stockage colonne) :
--      une requête ne lit que les colonnes qu'elle utilise.
--  LowCardinality(String) stocke une seule fois un dictionnaire des valeurs
--  distinctes, puis de petits entiers : idéal sous ~10 000 valeurs distinctes.
CREATE OR REPLACE TABLE payflow_ref.node
(
    node_name      String,
    zone           LowCardinality(String),
    instance_type  LowCardinality(String),
    cpu_cores      UInt8,
    memory_gib     UInt16
)
ENGINE = MergeTree
ORDER BY node_name;

INSERT INTO payflow_ref.node VALUES
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


-- ÉTAPE 4 · Les services et leurs équipes
--  9 services dans 3 namespaces. slo_target est l'objectif de disponibilité
--  du service (99,9 % = 43 minutes d'erreurs permises par mois).
CREATE OR REPLACE TABLE payflow_ref.service
(
    service     LowCardinality(String),
    namespace   LowCardinality(String),
    team        LowCardinality(String),
    language    LowCardinality(String),
    replicas    UInt8,
    tier        LowCardinality(String),   -- critical / standard (valeurs)
    slo_target  Float32                   -- objectif de disponibilité, en %
)
ENGINE = MergeTree
ORDER BY service;

INSERT INTO payflow_ref.service VALUES
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
--  nouveaux noms de pods. Le Black Friday à 13h58 UTC, l'équipe payments livre
--  payment v2.4.1. Retour arrière (rollback) à 14h42. Gardez ces deux heures
--  en tête pour le module 7.
CREATE OR REPLACE TABLE payflow_ref.deployment_history
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

INSERT INTO payflow_ref.deployment_history
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
    FROM payflow_ref.service
    WHERE service != 'payment'
) AS s;
-- Mesuré : 80 ms · 9 lignes lues · 8 lignes écrites

INSERT INTO payflow_ref.deployment_history VALUES
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-20 09:00:00', '2026-11-27 13:57:59', 'CHG-4005', 'release-bot', 'weekly release'),
    ('payment', 'v2.4.1', '5c8b7f9d21', '2026-11-27 13:58:00', '2026-11-27 14:41:59', 'CHG-4117', 'j.martin',    'connection pool tuning for Black Friday (pool size 50 to 10, see review)'),
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-27 14:42:00', '2099-12-31 00:00:00', 'CHG-4118', 'oncall-payments', 'rollback of CHG-4117');

SELECT deployment, version, replicaset, valid_from, valid_to, change_id, note
FROM payflow_ref.deployment_history
WHERE deployment = 'payment'
ORDER BY valid_from;
-- Mesuré : 2 ms
-- À observer : trois lignes pour payment. Celle du milieu est la version
-- qui va provoquer l'incident. La note donne déjà un indice.


-- ÉTAPE 6 · Les pods
--  Un nom de pod a la forme "<deployment>-<replicaset>-<5 caractères>". Chaque
--  slot d'un deployment garde son pod jusqu'à ce qu'un rollout le remplace.
--  Pendant un rollout, Kubernetes remplace les pods un par un : ici un toutes les
--  30 s à l'aller (13h58) et un toutes les 20 s au retour (14h42).
--  Les pods sont répartis sur les 12 nœuds. Le slot 2 de fraud-scoring atterrit
--  sur ip-10-0-3-17, le plus petit nœud.
CREATE OR REPLACE TABLE payflow_ref.pod
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

INSERT INTO payflow_ref.pod
WITH
    ['ip-10-0-1-11', 'ip-10-0-1-12', 'ip-10-0-1-13', 'ip-10-0-1-14', 'ip-10-0-2-21', 'ip-10-0-2-22',
     'ip-10-0-2-23', 'ip-10-0-2-24', 'ip-10-0-3-15', 'ip-10-0-3-16', 'ip-10-0-3-17', 'ip-10-0-3-18'] AS nodes,
    generations AS
    (
        -- une génération par (deployment, période de version) ; 3 pour payment, 1 pour les autres
        SELECT
            h.deployment, h.version, h.replicaset, h.valid_from, h.valid_to,
            row_number() OVER (PARTITION BY h.deployment ORDER BY h.valid_from) - 1 AS gen,
            s.namespace, s.replicas
        FROM payflow_ref.deployment_history AS h
        INNER JOIN payflow_ref.service AS s ON s.service = h.deployment
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
-- Mesuré : 86 ms · 20 lignes lues · 49 lignes écrites

SELECT deployment, count() AS pods, uniqExact(node_name) AS nodes
FROM payflow_ref.pod
GROUP BY deployment
ORDER BY deployment;
-- Mesuré : 2 ms · 49 lignes lues
-- À observer : un pod par réplique, 49 au total. payment en a 18 : 3 générations de 6.

SELECT pod_name, version, node_name, started_at, stopped_at
FROM payflow_ref.pod
WHERE deployment = 'payment' AND slot = 0
ORDER BY started_at;
-- Mesuré : 3 ms · 49 lignes lues (2,5 Ko)
-- À observer : le pod du slot 0 change deux fois de nom. Une ligne de log ne porte
-- que le nom du pod : sans cette table, impossible de savoir quelle version l'a écrite.


-- ÉTAPE 7 · Les marchands
--  PayFlow traite les paiements de 20 000 marchands. Chaque span d'un paiement
--  porte l'identifiant du marchand : c'est le lien entre observabilité et métier
--  (module 7 : combien de chiffre d'affaires l'incident a coûté, et à qui).
CREATE OR REPLACE TABLE payflow_ref.merchant
(
    merchant_id   String,
    name          String,
    country       LowCardinality(String),
    mcc           LowCardinality(String),   -- code catégorie marchand (MCC)
    category      LowCardinality(String),
    tier          LowCardinality(String),   -- enterprise / mid-market / small
    avg_basket    Float32                   -- montant moyen, en EUR
)
ENGINE = MergeTree
ORDER BY merchant_id;

INSERT INTO payflow_ref.merchant
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
-- Mesuré : 103 ms · 20 000 lignes lues (156,2 Ko) · 20 000 lignes écrites

SELECT tier, count() AS merchants, round(avg(avg_basket), 1) AS avg_basket_eur
FROM payflow_ref.merchant
GROUP BY tier
ORDER BY merchants;
-- Mesuré : 3 ms · 20 000 lignes lues (97,7 Ko)


-- ÉTAPE 8 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_ref.node) = 12, 'OK', 'KO')                         AS nodes,
    if((SELECT count() FROM payflow_ref.service) = 9, 'OK', 'KO')                       AS services,
    if((SELECT count() FROM payflow_ref.deployment_history) = 11, 'OK', 'KO')           AS history,
    if((SELECT count() FROM payflow_ref.pod) = 49, 'OK', 'KO')                          AS pods,
    if((SELECT node_name FROM payflow_ref.pod WHERE deployment = 'fraud-scoring' AND slot = 2) = 'ip-10-0-3-17', 'OK', 'KO') AS fraud_pod_node,
    if((SELECT count() FROM payflow_ref.merchant) = 20000, 'OK', 'KO')                  AS merchants
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
-- Mesuré : 57 ms · 55 lignes lues
