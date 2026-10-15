-- =====================================================================
--  MODULE 7 · Échelle et coût (3/3) : agrégats, rétention, échantillonnage
-- =====================================================================
--  Trois leviers décident du coût d'une plateforme d'observabilité :
--    · les agrégats (rollups) : garder des minutes pré-agrégées des mois, les événements
--      bruts quelques jours
--    · la rétention : supprimer les vieilles données par partitions entières (TTL),
--      compacter ce que l'on garde
--    · l'échantillonnage : garder moins de traces, mais les bonnes
--  La position de ClickStack est de tout garder quand c'est possible ("priced on
--  infrastructure, not events") : la compression le rend abordable. Ce fichier mesure
--  ce que chaque levier fait économiser sur PayFlow.
-- =====================================================================


-- ÉTAPE 1 · Un agrégat (rollup) que ClickStack sait utiliser tout seul
--  ClickStack peut répondre à un graphique, une tuile de dashboard ou une alerte depuis une
--  vue matérialisée plutôt que depuis les spans bruts, si la vue suit sa convention :
--  AggregatingMergeTree, un Timestamp à granularité fixe, les colonnes de regroupement, et
--  des colonnes d'agrégat nommées <fonction>__<colonne>. On la déclare ensuite sur la
--  source de traces (README). C'est l'exemple de la documentation ClickStack, appliqué à PayFlow.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_1m
(
    `Timestamp`            DateTime,
    `ServiceName`          LowCardinality(String),
    `SpanName`             LowCardinality(String),
    `StatusCode`           LowCardinality(String),
    `count`                SimpleAggregateFunction(sum, UInt64),
    `avg__Duration`        AggregateFunction(avg, UInt64),
    `max__Duration`        SimpleAggregateFunction(max, UInt64),
    `quantiles__Duration`  AggregateFunction(quantiles(0.95, 0.99), UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (Timestamp, ServiceName, SpanName, StatusCode);

CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.otel_traces_1m_mv TO payflow_otel.otel_traces_1m AS
SELECT
    toStartOfMinute(Timestamp)            AS Timestamp,
    ServiceName,
    SpanName,
    StatusCode,
    count()                               AS count,
    avgState(Duration)                    AS avg__Duration,
    maxSimpleState(Duration)              AS max__Duration,
    quantilesState(0.95, 0.99)(Duration)  AS quantiles__Duration
FROM payflow_otel.otel_traces
GROUP BY Timestamp, ServiceName, SpanName, StatusCode;

--  Une vue ne voit que les nouvelles insertions : on charge une fois l'historique du Black Friday
INSERT INTO payflow_otel.otel_traces_1m
SELECT toStartOfMinute(Timestamp), ServiceName, SpanName, StatusCode, count(),
       avgState(Duration), maxSimpleState(Duration), quantilesState(0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = '2026-11-27'
GROUP BY 1, 2, 3, 4;
-- Mesuré : 2,7 s · 21,5 M lignes lues (390 Mo) · 53 926 lignes écrites · 1,2 Go de mémoire

SELECT
    (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = '2026-11-27') AS spans,
    (SELECT count() FROM payflow_otel.otel_traces_1m WHERE toDate(Timestamp) = '2026-11-27') AS rollup_rows,
    round(spans / rollup_rows)                                                              AS spans_per_row;
-- Mesuré : 8 ms · 4 lignes lues

SELECT Timestamp, sum(count) AS requests, round(avgMerge(avg__Duration) / 1e6) AS avg_ms
FROM payflow_otel.otel_traces_1m
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN '2026-11-27 13:55:00' AND '2026-11-27 14:05:00'
GROUP BY Timestamp
ORDER BY Timestamp;
-- Mesuré : 5 ms · 6 740 lignes lues (250,9 Ko)


-- ÉTAPE 2 · Ce que coûte chaque signal par jour
--  Les partitions sont journalières : system.parts donne la taille brute et compressée
--  de chaque jour.
SELECT
    table,
    formatReadableQuantity(sum(rows))                                       AS rows_per_day,
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw,
    formatReadableSize(sum(data_compressed_bytes))                          AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1)     AS ratio
FROM system.parts
WHERE database = 'payflow_otel' AND active AND partition = '2026-11-27'
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;
-- Mesuré : 6 ms · 216 lignes lues (16,7 Ko)
-- À observer : logs et traces font l'essentiel du volume, métriques et agrégats sont petits.
-- Une année de PayFlow à ce rythme, c'est le chiffre on_disk journalier fois 365.


-- ÉTAPE 3 · Rétention : quoi garder, et combien de temps
--  Chaque table OpenTelemetry supprime déjà des partitions journalières entières après
--  son TTL (ttl_only_drop_parts = 1 : ni réécriture, ni mutation). Une politique de prod :
--      ALTER TABLE payflow_otel.otel_traces  MODIFY TTL toDate(Timestamp) + INTERVAL 15 DAY;
--      ALTER TABLE payflow_otel.otel_logs    MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;
--      ALTER TABLE payflow_otel.otel_traces_1m MODIFY TTL Timestamp + INTERVAL 13 MONTH;   -- les agrégats vivent longtemps
--  Deux outils plus fins existent : un TTL sur une colonne (supprimer Body après 7 jours,
--  garder les attributs), et TTL ... RECOMPRESS CODEC(ZSTD(3)) pour compresser plus fort
--  les parts anciennes.
--  Attention : les données du workshop sont datées de novembre 2026. Ne les appliquez pas
--  après cette date plus le TTL : ClickHouse supprimerait les données. Par défaut,
--  ClickStack garde 3 jours.
SELECT table, engine_full LIKE '%TTL%' AS has_ttl, extract(engine_full, 'TTL ([^S]+) SETTINGS') AS ttl
FROM system.tables
WHERE database = 'payflow_otel' AND name LIKE 'otel\\_%' AND engine LIKE '%MergeTree'
ORDER BY name;
-- Mesuré : 3 ms · 7 lignes lues (2,3 Ko)


-- ÉTAPE 4 · Échantillonnage : garder 10 % des traces, et voir ce que l'on perd
--  Le head sampling (probabilistic_sampler dans le collecteur) garde une trace si un hash
--  de son id tombe sous le seuil : la même décision pour chaque span d'une trace.
SELECT
    countIf(SpanName = 'POST /v1/payments')                                          AS all_requests,
    countIf(SpanName = 'POST /v1/payments' AND cityHash64(TraceId) % 10 = 0) * 10   AS estimated_from_10pct,
    round(100 * countIf(SpanName = 'POST /v1/payments' AND StatusCode = 'Error') / all_requests, 2) AS error_pct,
    round(100 * countIf(SpanName = 'POST /v1/payments' AND StatusCode = 'Error' AND cityHash64(TraceId) % 10 = 0)
              / countIf(SpanName = 'POST /v1/payments' AND cityHash64(TraceId) % 10 = 0), 2)       AS error_pct_from_10pct
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND toDate(Timestamp) = '2026-11-27';
-- Mesuré : 199 ms · 4,1 M lignes lues (181,6 Mo) · 195,1 Mo de mémoire
-- À observer : les taux survivent à l'échantillonnage, les comptages doivent être remultipliés
-- (ClickStack le fait avec la Sample Rate Expression de la source). Ce que l'on perd, c'est
-- la trace rare dont on avait besoin : des 12 timeouts du réseau de cartes de l'incident,
-- 1 ou 2 seulement sont gardés.

--  Échantillonnage à la rétention : tout garder quelques jours, et ne garder des mois que
--  les traces qui le méritent (une erreur, ou plus lente que 1 s). La décision voit la
--  trace entière.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_kept AS payflow_otel.otel_traces;

INSERT INTO payflow_otel.otel_traces_kept
SELECT * FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = '2026-11-27'
  AND TraceId IN
  (
      SELECT TraceId FROM payflow_otel.otel_traces
      WHERE toDate(Timestamp) = '2026-11-27' AND (StatusCode = 'Error' OR Duration > 1000000000)
  );
-- Mesuré : 3,42 s · 43,1 M lignes lues (7,7 Go) · 602 753 lignes écrites · 1,6 Go de mémoire

SELECT
    (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = '2026-11-27')   AS all_spans,
    (SELECT count() FROM payflow_otel.otel_traces_kept)                                     AS kept_spans,
    round(100 * kept_spans / all_spans, 1)                                                   AS kept_pct;
-- Mesuré : 6 ms · 4 lignes lues
-- À observer : quelques pourcents des spans, et toutes les traces de l'incident sont là.


-- ÉTAPE 5 · Dimensionnement : la règle empirique de ClickStack
--  Ingestion : environ 1 vCPU par 10 Mo/s de données brutes. Requêtes : environ 1 vCPU par
--  requête par seconde sur 10 Mo/s. On calcule le débit d'ingestion de PayFlow sur la journée.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw_per_day,
    formatReadableSize(sum(data_uncompressed_bytes) / 86400)                AS raw_per_second,
    round(sum(data_uncompressed_bytes) / 86400 / 1e7, 2)                    AS ingest_vcpu_needed
FROM system.parts
WHERE database = 'payflow_otel' AND active AND partition = '2026-11-27'
  AND table IN ('otel_logs', 'otel_traces', 'otel_metrics_gauge', 'otel_metrics_sum', 'otel_metrics_histogram');
-- Mesuré : 3 ms · 23 lignes lues (1,5 Ko)
-- À observer : PayFlow est une petite plateforme pour ClickHouse : une fraction de vCPU
-- d'ingestion. Les 3 répliques du workshop sont dimensionnées pour le module du milliard
-- de lignes.


-- ÉTAPE 6 · Checkpoint
SELECT
    if((SELECT sum(count) FROM payflow_otel.otel_traces_1m WHERE toDate(Timestamp) = '2026-11-27')
       = (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = '2026-11-27'), 'OK', 'KO') AS rollup_complete,
    if((SELECT count() FROM payflow_otel.otel_traces_kept) BETWEEN 100000 AND 2000000, 'OK', 'KO')       AS retention_sampling
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 42 ms · 53 930 lignes lues (632 Ko)
