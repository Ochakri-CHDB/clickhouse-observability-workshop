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
--
--  Le workshop n'a pas de date fixe. Ses données couvrent toujours le dernier mois,
--  jusqu'à aujourd'hui, et le Black Friday est le dernier vendredi avant le jour où
--  vous le lancez. L'étape 2 enregistre ce calendrier une fois pour toutes ; chaque
--  requête du workshop le lit via trois petites fonctions : pf_black_friday(),
--  pf_day(n) et pf_at('14:05').
-- =====================================================================


-- ÉTAPE 1 · Les bases
CREATE DATABASE IF NOT EXISTS payflow_inventory;
CREATE DATABASE IF NOT EXISTS payflow_ingest;
CREATE DATABASE IF NOT EXISTS payflow_otel;
CREATE DATABASE IF NOT EXISTS payflow_sre;
CREATE DATABASE IF NOT EXISTS payflow_sim;


-- ÉTAPE 2 · Le calendrier : un mois d'historique qui se termine toujours aujourd'hui
--  Le Black Friday est le dernier vendredi strictement avant aujourd'hui (il y a une
--  semaine si nous sommes vendredi). L'historique simulé couvre les 30 jours qui se
--  terminent par lui ; le module 2 rejoue ensuite le trafic de la semaine passée
--  jusqu'à maintenant. Le calendrier est écrit une seule fois : si le workshop
--  déborde après minuit, chaque requête pointe toujours vers le même Black Friday.
CREATE OR REPLACE TABLE payflow_sim.calendar
(
    loaded_at      DateTime('UTC'),
    workshop_day   Date,
    black_friday   Date,
    history_start  Date
)
ENGINE = MergeTree
ORDER BY loaded_at;

INSERT INTO payflow_sim.calendar
SELECT now(), today(), today() - 1 - ((toDayOfWeek(today() - 1) + 2) % 7) AS black_friday, black_friday - 29;
-- Mesuré : 132 ms · 1 ligne lue · 1 ligne écrite

--  pf_black_friday() : la date. pf_day(n) : minuit UTC, n jours après le Black Friday
--  (pf_day(-7) est le vendredi d'avant). pf_at('14:05') : une heure du jour du Black Friday.
--  La sous-requête scalaire est calculée une fois par requête : ClickHouse voit une
--  constante, et la clé primaire et les partitions écartent toujours ce qui est hors plage.
CREATE OR REPLACE FUNCTION pf_black_friday AS () -> assumeNotNull((SELECT argMax(black_friday, loaded_at) FROM payflow_sim.calendar));
CREATE OR REPLACE FUNCTION pf_day AS (n) -> toDateTime(pf_black_friday() + n, 'UTC');
CREATE OR REPLACE FUNCTION pf_at AS (hms) -> parseDateTimeBestEffort(concat(toString(pf_black_friday()), ' ', hms), 'UTC');

SELECT
    today()                        AS workshop_day,
    pf_black_friday()              AS black_friday,
    toDayOfWeek(pf_black_friday()) AS day_of_week,   -- 5 = vendredi
    pf_day(-29)                    AS history_start,
    pf_at('13:58')                 AS faulty_release;
-- Mesuré : 4 ms · 2 lignes lues
-- À observer : notez la date du Black Friday. Dans ClickStack, vous taperez la plage
-- de l'incident à la main : cette date, de 13h45 à 15h00 UTC.


-- ÉTAPE 3 · Un utilisateur technique pour les dictionnaires (étape 9)
--  Dans la console Cloud, un dictionnaire qui lit une table locale doit déclarer
--  un utilisateur et un mot de passe. On reste minimal : connexion locale
--  uniquement, lecture seule sur l'inventaire et le simulateur.
CREATE USER IF NOT EXISTS payflow_dict IDENTIFIED BY 'PayFlow_Dict_2026!' HOST LOCAL;
GRANT SELECT ON payflow_inventory.* TO payflow_dict;
GRANT SELECT ON payflow_sim.* TO payflow_dict;


-- ÉTAPE 4 · Les nœuds du cluster : notre première table MergeTree
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


-- ÉTAPE 5 · Les services et leurs propriétaires
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


-- ÉTAPE 6 · L'historique des déploiements : quelle version tournait quand
--  Chaque déploiement progressif (rollout) crée un nouveau ReplicaSet, donc de
--  nouveaux noms de pods. Au fil du mois, les équipes livrent leurs versions
--  hebdomadaires ; le jour du Black Friday à 13h58 UTC, l'équipe payments livre
--  payment v2.4.1. Retour arrière (rollback) à 14h42. Gardez ces deux heures en tête
--  pour le module 6. Les dates sont relatives au Black Friday : pf_day(-10), c'est
--  dix jours avant.
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
WITH changes AS
(
    -- la version de chaque service il y a six semaines, puis les changements du mois
    SELECT service AS deployment,
           ['3.8.1', '1.12.0', '5.1.3', '2.9.0', '1.3.7', '2.3.9', '4.2.0', '3.0.5', '1.7.2'][indexOf(
           ['api-gateway', 'auth', 'checkout', 'fraud-scoring', 'currency', 'payment', 'card-network-adapter', 'ledger', 'notification'], service)] AS v,
           pf_day(-45) + INTERVAL 9 HOUR                           AS t,
           concat('CHG-', toString(3990 + rowNumberInAllBlocks())) AS change_id,
           'release-bot'                                           AS author,
           'weekly release'                                        AS note
    FROM payflow_inventory.service
    UNION ALL
    SELECT c.1, c.2, c.3, c.4, c.5, c.6
    FROM
    (
        SELECT arrayJoin([
            ('api-gateway',   '3.8.2', pf_day(-24) + INTERVAL 10 HOUR,                      'CHG-4061', 'release-bot',     'weekly release'),
            ('checkout',      '5.1.4', pf_day(-17) + INTERVAL 10 HOUR,                      'CHG-4078', 'release-bot',     'weekly release'),
            ('payment',       '2.4.0', pf_day(-10) + INTERVAL 10 HOUR + INTERVAL 15 MINUTE, 'CHG-4090', 'release-bot',     'weekly release'),
            ('fraud-scoring', '2.9.1', pf_day(-9) + INTERVAL 11 HOUR,                       'CHG-4093', 'release-bot',     'model refresh'),
            ('notification',  '1.7.3', pf_day(-3) + INTERVAL 14 HOUR,                       'CHG-4109', 'release-bot',     'weekly release'),
            ('payment',       '2.4.1', pf_at('13:58:00'),                                   'CHG-4117', 'j.martin',        'connection pool tuning for Black Friday (pool size 50 to 10, see review)'),
            ('payment',       '2.4.0', pf_at('14:42:00'),                                   'CHG-4118', 'oncall-payments', 'rollback of CHG-4117')]) AS c
    )
)
SELECT
    deployment,
    concat('v', v),
    -- les ReplicaSets de payment gardent des noms fixes : vous les retrouverez dans chaque module
    multiIf(deployment = 'payment' AND v = '2.4.1', '5c8b7f9d21', deployment = 'payment' AND v = '2.4.0', '7d9f8c6b54',
            substring(lower(hex(cityHash64(deployment, v))), 1, 10)),
    t,
    -- valable jusqu'au changement suivant du même déploiement
    if(next_t > t, next_t - INTERVAL 1 SECOND, toDateTime('2099-12-31 00:00:00', 'UTC')),
    change_id,
    author,
    note
FROM
(
    SELECT *, leadInFrame(t) OVER (PARTITION BY deployment ORDER BY t ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) AS next_t
    FROM changes
);
-- Mesuré : 102 ms · 11 lignes lues · 16 lignes écrites

SELECT deployment, version, change_id, valid_from, valid_to, note
FROM payflow_inventory.deployment_history
WHERE valid_from >= pf_day(-29)
ORDER BY valid_from;
-- Mesuré : 5 ms · 17 lignes lues (1 Ko)
-- À observer : cinq livraisons ordinaires pendant le mois, puis deux changements le jour
-- du Black Friday. La note de CHG-4117 donne déjà un indice.


-- ÉTAPE 7 · Les pods
--  Un nom de pod a la forme "<deployment>-<replicaset>-<5 caractères>". Chaque
--  slot d'un déploiement garde son pod jusqu'à ce qu'un rollout le remplace.
--  Pendant un rollout, Kubernetes remplace les pods un par un : ici un toutes les
--  30 s, et un toutes les 20 s pour un rollback (14h42 le jour du Black Friday).
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
        -- une génération par (déploiement, période de version) ; payment en a 4
        SELECT
            h.deployment, h.version, h.replicaset, h.valid_from, h.valid_to,
            row_number() OVER w - 1                                         AS gen,
            if(h.note LIKE 'rollback%', 20, 30)                             AS spacing,
            if(leadInFrame(h.note) OVER w LIKE 'rollback%', 20, 30)         AS next_spacing,
            s.namespace, s.replicas
        FROM payflow_inventory.deployment_history AS h
        INNER JOIN payflow_inventory.service AS s ON s.service = h.deployment
        WINDOW w AS (PARTITION BY h.deployment ORDER BY h.valid_from ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
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
    -- rollout : le slot k d'une nouvelle génération démarre k x 30 s (20 s pour un rollback) après le changement
    if(g.gen = 0, g.valid_from, g.valid_from + toIntervalSecond(slot * g.spacing))         AS started_at,
    if(g.valid_to >= toDateTime('2099-01-01', 'UTC'), g.valid_to,
       g.valid_to + toIntervalSecond(slot * g.next_spacing))                               AS stopped_at
FROM generations AS g
ARRAY JOIN range(toUInt8(g.replicas)) AS slot;
-- Mesuré : 87 ms · 25 lignes lues (1,3 Ko) · 74 lignes écrites

SELECT deployment, count() AS pods, uniqExact(node_name) AS nodes
FROM payflow_inventory.pod
GROUP BY deployment
ORDER BY deployment;
-- Mesuré : 3 ms · 74 lignes lues
-- À observer : 74 pods sur le mois. payment en a 24 : 4 générations de 6.

SELECT pod_name, version, node_name, started_at, stopped_at
FROM payflow_inventory.pod
WHERE deployment = 'payment' AND slot = 0
ORDER BY started_at;
-- Mesuré : 3 ms · 74 lignes lues (3,5 Ko)
-- À observer : le pod du slot 0 change trois fois de nom. Une ligne de log ne porte
-- que le nom du pod : sans cette table, personne ne sait quelle version l'a écrite.


-- ÉTAPE 8 · Les marchands
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
-- Mesuré : 84 ms · 20 000 lignes lues (156,2 Ko) · 20 000 lignes écrites

SELECT tier, count() AS merchants, round(avg(avg_basket), 1) AS avg_basket_eur
FROM payflow_inventory.merchant
GROUP BY tier
ORDER BY merchants;
-- Mesuré : 3 ms · 20 000 lignes lues (97,7 Ko)


-- ÉTAPE 9 · Le catalogue en mémoire : les dictionnaires
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
    dictGet('payflow_inventory.dict_pod', ('deployment', 'version', 'node_name'), 'payment-5c8b7f9d21-50d24')        AS pod_metadata,
    dictGet('payflow_inventory.dict_node', 'zone', 'ip-10-0-3-17')                                                    AS zone,
    dictGet('payflow_inventory.dict_service', 'team', 'payment')                                                      AS team,
    dictGet('payflow_inventory.dict_deployment', 'change_id', 'payment', pf_at('14:15'))                            AS change_at_14h15;
-- Mesuré : 3 ms · 2 lignes lues
-- À observer : à partir du seul nom d'un pod, le déploiement, sa version, son nœud et
-- sa zone, l'équipe propriétaire, et le changement en ligne à 14h15 (CHG-4117).


-- ÉTAPE 10 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_inventory.node) = 12, 'OK', 'KO')                         AS nodes,
    if((SELECT count() FROM payflow_inventory.service) = 9, 'OK', 'KO')                       AS services,
    if(toDayOfWeek(pf_black_friday()) = 5 AND pf_black_friday() < today(), 'OK', 'KO')       AS calendar,
    if((SELECT count() FROM payflow_inventory.deployment_history) = 16, 'OK', 'KO')           AS history,
    if((SELECT count() FROM payflow_inventory.pod) = 74, 'OK', 'KO')                          AS pods,
    if((SELECT groupUniqArray(node_name) FROM payflow_inventory.pod WHERE deployment = 'fraud-scoring' AND slot = 2) = ['ip-10-0-3-17'], 'OK', 'KO') AS fraud_pod_node,
    if((SELECT count() FROM payflow_inventory.merchant) = 20000, 'OK', 'KO')                  AS merchants,
    if(dictGet('payflow_inventory.dict_deployment', 'change_id', 'payment', pf_at('14:15')) = 'CHG-4117', 'OK', 'KO') AS dictionaries
SETTINGS select_sequential_consistency = 1;   -- lire la dernière version, quelle que soit la réplique
-- Mesuré : 51 ms · 81 lignes lues
