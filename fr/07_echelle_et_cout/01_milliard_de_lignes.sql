-- =====================================================================
--  MODULE 7 · Échelle et coût (1/3) : d'une journée à un milliard de lignes de log
-- =====================================================================
--  PayFlow tourne dans 8 régions. Deux semaines au rythme du Black Friday, pour toutes,
--  c'est près d'un milliard de lignes de log. On construit cette table, puis on mesure
--  ce que ClickHouse en fait : stockage, recherche plein texte, accès par trace,
--  projections, 3 répliques.
--
--  La table XL garde les colonnes utiles à la recherche (temps, service, sévérité,
--  corps, trace id, pod, nœud, cluster). Le schéma OpenTelemetry complet, avec ses
--  maps et ses 8 index, coûte environ 10 fois plus cher à écrire : bon à savoir pour
--  dimensionner un pipeline d'ingestion.
-- =====================================================================


-- ÉTAPE 1 · La table XL : un index texte sur le corps, un bloom filter sur le trace id
--  La projection pré-agrège les erreurs par service et par minute : les dashboards
--  la lisent au lieu du milliard de lignes. Elle est déclarée dans le CREATE pour être
--  construite pendant l'insertion (MATERIALIZE PROJECTION sur une table pleine est lent).
CREATE OR REPLACE TABLE payflow_otel.logs_xl
(
    Timestamp     DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    TraceId       String CODEC(ZSTD(1)),
    SeverityText  LowCardinality(String),
    ServiceName   LowCardinality(String),
    Body          String CODEC(ZSTD(1)),
    Cluster       LowCardinality(String),
    PodName       LowCardinality(String),
    NodeName      LowCardinality(String),
    INDEX idx_lower_body lower(Body) TYPE text(tokenizer = 'splitByNonAlpha'),
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    PROJECTION p_errors_per_minute
    (
        SELECT Cluster, ServiceName, SeverityText, toStartOfMinute(Timestamp), count()
        GROUP BY Cluster, ServiceName, SeverityText, toStartOfMinute(Timestamp)
    )
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (ServiceName, Timestamp)
SETTINGS min_bytes_for_wide_part = 0;   -- un fichier par colonne même pour les petites parts, pour lire la taille par colonne (étape 3)


-- ÉTAPE 2 · 8 régions x 14 jours, une région par instruction
--  Chaque instruction copie le Black Friday 14 fois (décalé de d jours) pour une région,
--  avec de nouveaux trace ids. max_insert_threads = 16 écrit en parallèle.
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(0 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-eu-west', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 1/8 : eu-west
-- Mesuré : 27,5 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 10,3 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(1 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-eu-central', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 2/8 : eu-central
-- Mesuré : 27 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 9,6 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(2 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-us-east', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 3/8 : us-east
-- Mesuré : 31,6 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 9 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(3 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-us-west', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 4/8 : us-west
-- Mesuré : 28,5 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 9,1 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(4 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ap-south', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 5/8 : ap-south
-- Mesuré : 28,5 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 9 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(5 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ap-northeast', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 6/8 : ap-northeast
-- Mesuré : 31,3 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 8,4 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(6 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-sa-east', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 7/8 : sa-east
-- Mesuré : 29,1 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 9,4 Go de mémoire
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(7 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ca-central', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- région 8/8 : ca-central
-- Mesuré : 30,2 s · 7,8 M lignes lues (1,1 Go) · 109 M lignes écrites · 9,2 Go de mémoire


-- ÉTAPE 3 · Ce que coûte un milliard de lignes de log sur disque
SELECT
    formatReadableQuantity(sum(rows))                                       AS log_lines,
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw,
    formatReadableSize(sum(data_compressed_bytes))                          AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1)     AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 1)                        AS bytes_per_line
FROM system.parts
WHERE database = 'payflow_otel' AND table = 'logs_xl' AND active;
-- Mesuré : 4 ms · 257 lignes lues (15,1 Ko)

SELECT column,
       formatReadableSize(sum(column_data_compressed_bytes))   AS on_disk,
       round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'payflow_otel' AND table = 'logs_xl' AND active AND column NOT LIKE '\\_%'
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- Mesuré : 12 ms · 2 237 lignes lues (149,7 Ko)
-- À observer : Body représente l'essentiel du stockage. Les colonnes LowCardinality
-- (service, pod, nœud, cluster) ne coûtent presque rien. Les horodatages se compressent
-- bien avec Delta.


-- ÉTAPE 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.logs_xl) > 850000000, 'OK', 'KO') AS billion_scale,
    if((SELECT uniqExact(Cluster) FROM payflow_otel.logs_xl) = 8, 'OK', 'KO') AS regions
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 2,63 s · 875 M lignes lues (834,1 Mo) · 262,8 Mo de mémoire
