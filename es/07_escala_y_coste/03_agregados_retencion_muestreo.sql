-- =====================================================================
--  MÓDULO 7 · Escala y coste (3/3): agregados (rollups), retención, muestreo
-- =====================================================================
--  Tres palancas deciden lo que cuesta una plataforma de observabilidad:
--    · agregados: guardar minutos preagregados durante meses, eventos brutos durante días
--    · retención: borrar los datos antiguos por particiones enteras (TTL), reducir lo que se guarda
--    · muestreo: guardar menos trazas, pero las correctas
--  La postura de ClickStack es guardarlo todo cuando se puede ("priced on
--  infrastructure, not events"): la compresión lo hace asequible. Este fichero
--  mide lo que ahorra cada palanca en PayFlow.
-- =====================================================================


-- PASO 1 · Un agregado que ClickStack puede usar por sí solo
--  ClickStack puede responder a un gráfico, un tile de dashboard o una alerta desde una
--  vista materializada en lugar de los spans brutos, si la vista sigue su convención:
--  AggregatingMergeTree, un Timestamp con granularidad fija, las columnas de agrupación y
--  columnas de agregado llamadas <función>__<columna>. Después se registra en la fuente
--  de trazas (README). Es el ejemplo de la documentación de ClickStack, aplicado a PayFlow.
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

--  Una vista solo ve los inserts nuevos: hacemos una vez el backfill del día de Black Friday
INSERT INTO payflow_otel.otel_traces_1m
SELECT toStartOfMinute(Timestamp), ServiceName, SpanName, StatusCode, count(),
       avgState(Duration), maxSimpleState(Duration), quantilesState(0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = '2026-11-27'
GROUP BY 1, 2, 3, 4;
-- Medido: 2,7 s · 21,5 M filas leídas (390 MB) · 53 926 filas escritas · 1,2 GB de memoria

SELECT
    (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = '2026-11-27') AS spans,
    (SELECT count() FROM payflow_otel.otel_traces_1m WHERE toDate(Timestamp) = '2026-11-27') AS rollup_rows,
    round(spans / rollup_rows)                                                              AS spans_per_row;
-- Medido: 8 ms · 4 filas leídas

SELECT Timestamp, sum(count) AS requests, round(avgMerge(avg__Duration) / 1e6) AS avg_ms
FROM payflow_otel.otel_traces_1m
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN '2026-11-27 13:55:00' AND '2026-11-27 14:05:00'
GROUP BY Timestamp
ORDER BY Timestamp;
-- Medido: 5 ms · 6 740 filas leídas (250,9 KB)


-- PASO 2 · Lo que cuesta cada señal por día
--  Las particiones son diarias: system.parts da el tamaño bruto y comprimido de cada día.
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
-- Medido: 6 ms · 216 filas leídas (16,7 KB)
-- Qué observar: logs y trazas son la mayor parte del volumen, métricas y agregados son pequeños.
-- Un año de PayFlow a este ritmo es la cifra diaria de on_disk por 365.


-- PASO 3 · Retención: qué guardar, y durante cuánto tiempo
--  Cada tabla OpenTelemetry ya borra particiones diarias enteras tras su TTL
--  (ttl_only_drop_parts = 1: sin reescritura, sin mutación). Una política de producción:
--      ALTER TABLE payflow_otel.otel_traces  MODIFY TTL toDate(Timestamp) + INTERVAL 15 DAY;
--      ALTER TABLE payflow_otel.otel_logs    MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;
--      ALTER TABLE payflow_otel.otel_traces_1m MODIFY TTL Timestamp + INTERVAL 13 MONTH;   -- los agregados viven mucho
--  Existen dos herramientas más finas: un TTL sobre una columna (borrar Body a los 7 días,
--  conservar los atributos) y TTL ... RECOMPRESS CODEC(ZSTD(3)) para comprimir más las parts antiguas.
--  Atención: los datos del taller están fechados en noviembre de 2026. No apliques esto pasada
--  esa fecha más el TTL: ClickHouse borraría los datos. El valor por defecto de ClickStack es 3 días.
SELECT table, engine_full LIKE '%TTL%' AS has_ttl, extract(engine_full, 'TTL ([^S]+) SETTINGS') AS ttl
FROM system.tables
WHERE database = 'payflow_otel' AND name LIKE 'otel\\_%' AND engine LIKE '%MergeTree'
ORDER BY name;
-- Medido: 3 ms · 7 filas leídas (2,3 KB)


-- PASO 4 · Muestreo: guardar el 10 % de las trazas, y ver lo que se pierde
--  El muestreo en cabeza (probabilistic_sampler en el colector) guarda una traza si un hash
--  de su id cae por debajo del umbral: la misma decisión para todos los spans de una traza.
SELECT
    countIf(SpanName = 'POST /v1/payments')                                          AS all_requests,
    countIf(SpanName = 'POST /v1/payments' AND cityHash64(TraceId) % 10 = 0) * 10   AS estimated_from_10pct,
    round(100 * countIf(SpanName = 'POST /v1/payments' AND StatusCode = 'Error') / all_requests, 2) AS error_pct,
    round(100 * countIf(SpanName = 'POST /v1/payments' AND StatusCode = 'Error' AND cityHash64(TraceId) % 10 = 0)
              / countIf(SpanName = 'POST /v1/payments' AND cityHash64(TraceId) % 10 = 0), 2)       AS error_pct_from_10pct
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND toDate(Timestamp) = '2026-11-27';
-- Medido: 199 ms · 4,1 M filas leídas (181,6 MB) · 195,1 MB de memoria
-- Qué observar: las tasas sobreviven al muestreo, los recuentos hay que volver a multiplicarlos
-- (ClickStack lo hace con la Sample Rate Expression de la fuente). Lo que se pierde es la traza
-- rara que necesitabas: de los 12 timeouts de la red de tarjetas del incidente, quedan 1 o 2.

--  Muestreo de retención: guardarlo todo unos días y guardar durante meses solo las
--  trazas que merecen la pena (un error, o más lentas de 1 s). La decisión ve la traza entera.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_kept AS payflow_otel.otel_traces;

INSERT INTO payflow_otel.otel_traces_kept
SELECT * FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = '2026-11-27'
  AND TraceId IN
  (
      SELECT TraceId FROM payflow_otel.otel_traces
      WHERE toDate(Timestamp) = '2026-11-27' AND (StatusCode = 'Error' OR Duration > 1000000000)
  );
-- Medido: 3,42 s · 43,1 M filas leídas (7,7 GB) · 602 753 filas escritas · 1,6 GB de memoria

SELECT
    (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = '2026-11-27')   AS all_spans,
    (SELECT count() FROM payflow_otel.otel_traces_kept)                                     AS kept_spans,
    round(100 * kept_spans / all_spans, 1)                                                   AS kept_pct;
-- Medido: 6 ms · 4 filas leídas
-- Qué observar: un pequeño porcentaje de los spans, y todas las trazas del incidente están ahí.


-- PASO 5 · Dimensionamiento: la regla práctica de ClickStack
--  Ingesta: alrededor de 1 vCPU por cada 10 MB/s de datos brutos. Consulta: alrededor de
--  1 vCPU por consulta por segundo sobre 10 MB/s. Calcula el ritmo de ingesta de PayFlow a partir del día.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw_per_day,
    formatReadableSize(sum(data_uncompressed_bytes) / 86400)                AS raw_per_second,
    round(sum(data_uncompressed_bytes) / 86400 / 1e7, 2)                    AS ingest_vcpu_needed
FROM system.parts
WHERE database = 'payflow_otel' AND active AND partition = '2026-11-27'
  AND table IN ('otel_logs', 'otel_traces', 'otel_metrics_gauge', 'otel_metrics_sum', 'otel_metrics_histogram');
-- Medido: 3 ms · 23 filas leídas (1,5 KB)
-- Qué observar: PayFlow es una plataforma pequeña para ClickHouse: una fracción de vCPU de
-- ingesta. Las 3 réplicas del taller están dimensionadas para el módulo de los mil millones de líneas.


-- PASO 6 · Checkpoint
SELECT
    if((SELECT sum(count) FROM payflow_otel.otel_traces_1m WHERE toDate(Timestamp) = '2026-11-27')
       = (SELECT count() FROM payflow_otel.otel_traces WHERE toDate(Timestamp) = '2026-11-27'), 'OK', 'KO') AS rollup_complete,
    if((SELECT count() FROM payflow_otel.otel_traces_kept) BETWEEN 100000 AND 2000000, 'OK', 'KO')       AS retention_sampling
SETTINGS select_sequential_consistency = 1;
-- Medido: 42 ms · 53 930 filas leídas (632 KB)
