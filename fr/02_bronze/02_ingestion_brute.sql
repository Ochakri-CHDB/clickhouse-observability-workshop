-- =====================================================================
--  MODULE 2 · Bronze : stocker les enregistrements bruts, sans y toucher
-- =====================================================================
--  Bronze garde exactement ce que les agents ont envoyé : une ligne par enregistrement,
--  le JSON en chaîne. Rien n'est parsé, rien n'est perdu. Si une règle de parsing est
--  fausse en silver, on rejoue depuis ici (module 7).
--  Ici les enregistrements sont générés par le simulateur ; en production ils viennent
--  du collecteur OpenTelemetry, de Kafka ou de ClickPipes.
--
--  On charge maintenant la journée de 00h00 à 20h00. La soirée (20h00 à 24h00)
--  arrivera au module 3, une fois les vues matérialisées en place : elle montrera
--  le flux continu.
-- =====================================================================


-- ÉTAPE 1 · La table bronze
--  ORDER BY (source, received_at) : bronze se lit par source et par plage de temps.
--  ZSTD(3) sur le payload : les logs JSON sont très répétitifs (clés, noms de pods,
--  messages), ils se compressent extrêmement bien.
CREATE OR REPLACE TABLE payflow_raw.log_records
(
    received_at  DateTime64(3, 'UTC'),
    source       LowCardinality(String),       -- fluent-bit (logs des conteneurs) ou k8s-events
    payload      String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toDate(received_at)
ORDER BY (source, received_at);


-- ÉTAPE 2 · Charger la journée, de 00h00 à 20h00, en 4 lots
--  Chaque lot reste bien sous la limite de 60 s de la console SQL.
--  Note : générer les enregistrements coûte plus cher que les écrire. ClickHouse
--  écrit plusieurs millions de lignes par seconde sur une seule réplique.
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 0, to_s = 21600);       -- 00h00 à 06h00
-- Mesuré : 4,7 s · 21 947 lignes lues (181,8 Ko) · 1 M de lignes écrites · 1,3 Go de mémoire
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 21600, to_s = 43200);   -- 06h00 à 12h00
-- Mesuré : 5,21 s · 21 947 lignes lues (181,8 Ko) · 1,1 M de lignes écrites · 1,4 Go de mémoire
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 43200, to_s = 57600);   -- 12h00 à 16h00
-- Mesuré : 6,18 s · 14 747 lignes lues (130,6 Ko) · 1,5 M de lignes écrites · 1,7 Go de mémoire
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 57600, to_s = 72000);   -- 16h00 à 20h00
-- Mesuré : 8,49 s · 14 747 lignes lues (125,6 Ko) · 2,3 M de lignes écrites · 2 Go de mémoire


-- ÉTAPE 3 · Qu'a-t-on stocké, et à quel point est-ce compact ?
SELECT
    source,
    count()                                                         AS records,
    formatReadableSize(sum(length(payload)))                        AS raw_json
FROM payflow_raw.log_records
GROUP BY source;
-- Mesuré : 34 ms · 6 M de lignes lues (51,5 Mo) · 169,8 Mo de mémoire

SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                AS uncompressed,
    formatReadableSize(sum(data_compressed_bytes))                  AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'payflow_raw' AND table = 'log_records' AND active;
-- Mesuré : 3 ms · 7 lignes lues
-- À observer : le ratio. Les logs sont le cas idéal pour la compression en colonnes.


-- ÉTAPE 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_raw.log_records WHERE source = 'fluent-bit') > 5000000, 'OK', 'KO') AS container_logs,
    if((SELECT count() FROM payflow_raw.log_records WHERE source = 'k8s-events') > 300, 'OK', 'KO')     AS k8s_events,
    if((SELECT max(received_at) FROM payflow_raw.log_records) < toDateTime64('2026-11-27 20:00:05', 3, 'UTC'), 'OK', 'KO') AS stops_at_20h
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 27 ms · 8 677 lignes lues (8,8 Ko)
