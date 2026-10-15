-- =====================================================================
--  MÓDULO 1 · El modelo de datos: la plataforma y su catálogo de servicios
-- =====================================================================
--  PayFlow es una plataforma de pagos (ficticia). Corre en un clúster de
--  Kubernetes, "payflow-prod-eu", repartido en 3 zonas de disponibilidad.
--  La observabilidad empieza por saber qué observas: qué servicios existen,
--  de quién son, dónde corren, qué versión está en producción. Este fichero
--  crea ese catálogo de servicios (una pequeña CMDB) y las 5 bases de datos
--  del taller, que siguen el camino de la telemetría:
--    payflow_sim        → las aplicaciones y sus agentes (simulados en SQL)
--    payflow_ingest     → las tablas de aterrizaje de la pasarela (gateway) del colector
--    payflow_otel       → logs, trazas, métricas, tal como los escribe el exportador ClickHouse
--    payflow_sre        → lo que calculan los conectores y el alerting: RED, SLO, alertas, Service Map
--    payflow_inventory  → el catálogo de servicios: nodos, servicios, despliegues, pods, comercios
--
--  Una "base de datos" de ClickHouse es solo un espacio de nombres: no cuesta
--  nada y sirve para organizar las tablas y conceder permisos (módulo 8).
-- =====================================================================


-- PASO 1 · Las bases de datos
CREATE DATABASE IF NOT EXISTS payflow_inventory;
CREATE DATABASE IF NOT EXISTS payflow_ingest;
CREATE DATABASE IF NOT EXISTS payflow_otel;
CREATE DATABASE IF NOT EXISTS payflow_sre;
CREATE DATABASE IF NOT EXISTS payflow_sim;


-- PASO 2 · Un usuario técnico para los diccionarios (paso 8)
--  En la consola Cloud, un diccionario que lee una tabla local debe
--  declarar un usuario y una contraseña. Lo mínimo: solo conexión local,
--  solo lectura sobre el inventario y el simulador.
CREATE USER IF NOT EXISTS payflow_dict IDENTIFIED BY 'PayFlow_Dict_2026!' HOST LOCAL;
GRANT SELECT ON payflow_inventory.* TO payflow_dict;
GRANT SELECT ON payflow_sim.* TO payflow_dict;


-- PASO 3 · Los nodos del clúster: nuestra primera tabla MergeTree
--  MergeTree es el motor central de ClickHouse. Dos cosas que recordar:
--    · ORDER BY fija el orden físico de las filas en disco Y el índice
--      primario. Elígelo a partir de los filtros más frecuentes
--      (regla schema-pk-plan-before-creation).
--    · cada columna se almacena y se comprime por separado (almacenamiento
--      columnar): una consulta solo lee las columnas que usa.
--  LowCardinality(String) guarda una vez un diccionario de los valores
--  distintos y luego enteros pequeños: ideal por debajo de ~10 000 valores.
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
    ('ip-10-0-3-17', 'eu-west-1c', 'm7i.xlarge',  4, 16),   -- el nodo más pequeño: recuérdalo
    ('ip-10-0-3-18', 'eu-west-1c', 'r7i.2xlarge', 8, 64);


-- PASO 4 · Los servicios y sus responsables
--  9 servicios en 3 namespaces. slo_target es el objetivo de disponibilidad
--  del servicio (99,9 % = 43 minutos de errores permitidos al mes).
CREATE OR REPLACE TABLE payflow_inventory.service
(
    service     LowCardinality(String),
    namespace   LowCardinality(String),
    team        LowCardinality(String),
    language    LowCardinality(String),
    replicas    UInt8,
    tier        LowCardinality(String),   -- critical / standard
    slo_target  Float32                   -- objetivo de disponibilidad, en %
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


-- PASO 5 · El historial de despliegues: qué versión corría y cuándo
--  Cada despliegue progresivo (rollout) crea un ReplicaSet nuevo, y por tanto
--  nombres de pod nuevos. En Black Friday a las 13:58 UTC el equipo de pagos
--  publica payment v2.4.1. Se hace marcha atrás (rollback) a las 14:42.
--  Recuerda estas dos horas para el módulo 6.
CREATE OR REPLACE TABLE payflow_inventory.deployment_history
(
    deployment   LowCardinality(String),
    version      LowCardinality(String),
    replicaset   String,                  -- el hash que Kubernetes pone en los nombres de pod
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
    substring(lower(hex(cityHash64(s.service, s.base_version))), 1, 10),   -- 10 caracteres, como Kubernetes
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
-- Medido: 85 ms · 9 filas leídas · 8 filas escritas

INSERT INTO payflow_inventory.deployment_history VALUES
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-20 09:00:00', '2026-11-27 13:57:59', 'CHG-4005', 'release-bot', 'weekly release'),
    ('payment', 'v2.4.1', '5c8b7f9d21', '2026-11-27 13:58:00', '2026-11-27 14:41:59', 'CHG-4117', 'j.martin',    'connection pool tuning for Black Friday (pool size 50 to 10, see review)'),
    ('payment', 'v2.4.0', '7d9f8c6b54', '2026-11-27 14:42:00', '2099-12-31 00:00:00', 'CHG-4118', 'oncall-payments', 'rollback of CHG-4117');

SELECT deployment, version, replicaset, valid_from, valid_to, change_id, note
FROM payflow_inventory.deployment_history
WHERE deployment = 'payment'
ORDER BY valid_from;
-- Medido: 2 ms
-- Qué observar: tres filas para payment. La del medio es la versión que
-- provocará el incidente. La nota ya da una pista.


-- PASO 6 · Los pods
--  Un nombre de pod es "<deployment>-<replicaset>-<5 caracteres>". Cada slot de
--  un deployment conserva su pod hasta que un rollout lo sustituye. Durante un
--  rollout, Kubernetes sustituye los pods uno a uno: aquí uno cada 30 s a la ida
--  (13:58) y uno cada 20 s a la vuelta (14:42).
--  Los pods se reparten entre los 12 nodos. El slot 2 de fraud-scoring cae en
--  ip-10-0-3-17, el nodo más pequeño.
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
        -- una generación por (deployment, periodo de versión); payment tiene 3, los demás 1
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
    -- rollout: el slot k de una generación nueva arranca k x 30 s (20 s en rollback) después
    if(g.gen = 0, g.valid_from,
       g.valid_from + toIntervalSecond(slot * if(g.gen = 1, 30, 20)))                       AS started_at,
    if(g.valid_to >= toDateTime('2099-01-01', 'UTC'), g.valid_to,
       g.valid_to + 1 + toIntervalSecond(slot * if(g.gen = 0, 30, 20)) - 1)                 AS stopped_at
FROM generations AS g
ARRAY JOIN range(toUInt8(g.replicas)) AS slot;
-- Medido: 76 ms · 20 filas leídas · 49 filas escritas

SELECT deployment, count() AS pods, uniqExact(node_name) AS nodes
FROM payflow_inventory.pod
GROUP BY deployment
ORDER BY deployment;
-- Medido: 3 ms · 49 filas leídas
-- Qué observar: un pod por réplica, 49 en total. payment tiene 18: 3 generaciones de 6.

SELECT pod_name, version, node_name, started_at, stopped_at
FROM payflow_inventory.pod
WHERE deployment = 'payment' AND slot = 0
ORDER BY started_at;
-- Medido: 3 ms · 49 filas leídas (2,5 KB)
-- Qué observar: el pod del slot 0 cambia de nombre dos veces. Una línea de log solo
-- lleva el nombre del pod: sin esta tabla, nadie sabe qué versión la escribió.


-- PASO 7 · Los comercios
--  PayFlow procesa pagos para 20 000 comercios. Cada span de un pago lleva el
--  id del comercio: es lo que une la observabilidad con el negocio
--  (módulo 6: cuánta facturación costó el incidente, y a quién).
CREATE OR REPLACE TABLE payflow_inventory.merchant
(
    merchant_id   String,
    name          String,
    country       LowCardinality(String),
    mcc           LowCardinality(String),   -- código de categoría del comercio (MCC)
    category      LowCardinality(String),
    tier          LowCardinality(String),   -- enterprise / mid-market / small
    avg_basket    Float32                   -- importe medio, en EUR
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
-- Medido: 91 ms · 20 000 filas leídas (156,2 KB) · 20 000 filas escritas

SELECT tier, count() AS merchants, round(avg(avg_basket), 1) AS avg_basket_eur
FROM payflow_inventory.merchant
GROUP BY tier
ORDER BY merchants;
-- Medido: 3 ms · 20 000 filas leídas (97,7 KB)


-- PASO 8 · El catálogo en memoria: los diccionarios
--  El colector enriquece cada registro con metadatos de Kubernetes (el procesador
--  k8sattributes consulta la API de Kubernetes). Aquí la pasarela del módulo 2 lo hace
--  en SQL: un diccionario es una tabla de referencia cargada en memoria, que se lee con
--  dictGet() a la velocidad de una búsqueda en hash, sin JOIN (regla
--  query-join-use-dictionaries). SOURCE dice dónde leer, LAYOUT cómo organizarlo en
--  memoria, LIFETIME cada cuánto recargarlo.
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

--  "¿Qué cambio estaba en producción en ese momento?": un diccionario de rangos.
--  Clave = deployment, rango = [valid_from, valid_to]. La primera pregunta de toda
--  revisión de incidente (módulo 6).
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
-- Medido: 2 ms · 1 fila leída
-- Qué observar: solo con un nombre de pod, el deployment, su versión, su nodo y su
-- zona, el equipo responsable y el cambio en producción a las 14:15 (CHG-4117).


-- PASO 9 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_inventory.node) = 12, 'OK', 'KO')                         AS nodes,
    if((SELECT count() FROM payflow_inventory.service) = 9, 'OK', 'KO')                       AS services,
    if((SELECT count() FROM payflow_inventory.deployment_history) = 11, 'OK', 'KO')           AS history,
    if((SELECT count() FROM payflow_inventory.pod) = 49, 'OK', 'KO')                          AS pods,
    if((SELECT node_name FROM payflow_inventory.pod WHERE deployment = 'fraud-scoring' AND slot = 2) = 'ip-10-0-3-17', 'OK', 'KO') AS fraud_pod_node,
    if((SELECT count() FROM payflow_inventory.merchant) = 20000, 'OK', 'KO')                  AS merchants,
    if(dictGet('payflow_inventory.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC')) = 'CHG-4117', 'OK', 'KO') AS dictionaries
SETTINGS select_sequential_consistency = 1;   -- leer la última versión, sea cual sea la réplica
-- Medido: 69 ms · 55 filas leídas
