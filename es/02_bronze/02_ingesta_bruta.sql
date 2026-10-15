-- =====================================================================
--  MÓDULO 2 · Bronze: guardar los registros brutos, sin tocarlos
-- =====================================================================
--  Bronze guarda exactamente lo que enviaron los agentes: una fila por registro,
--  el JSON como cadena. No se parsea nada, no se pierde nada. Si una regla de
--  parseo está mal en silver, se vuelve a procesar desde aquí (módulo 7).
--  Aquí los registros los genera el simulador; en producción vienen del
--  collector OpenTelemetry, de Kafka o de ClickPipes.
--
--  Ahora cargamos el día de 00:00 a 20:00. La noche (20:00 a 24:00) llegará
--  en el módulo 3, cuando existan las vistas materializadas: servirá para ver
--  el flujo continuo.
-- =====================================================================


-- PASO 1 · La tabla bronze
--  ORDER BY (source, received_at): bronze se lee por fuente y por rango de tiempo.
--  ZSTD(3) en el payload: los logs JSON son muy repetitivos (claves, nombres de pod,
--  mensajes), se comprimen muchísimo.
CREATE OR REPLACE TABLE payflow_raw.log_records
(
    received_at  DateTime64(3, 'UTC'),
    source       LowCardinality(String),       -- fluent-bit (logs de contenedores) o k8s-events
    payload      String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toDate(received_at)
ORDER BY (source, received_at);


-- PASO 2 · Cargar el día, de 00:00 a 20:00, en 4 lotes
--  Cada lote queda muy por debajo del límite de 60 s de la consola SQL.
--  Nota: generar los registros cuesta más que escribirlos. ClickHouse
--  escribe varios millones de filas por segundo en una sola réplica.
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 0, to_s = 21600);       -- 00:00 a 06:00
-- Medido: 4,7 s · 21 947 filas leídas (181,8 KB) · 1 M filas escritas · 1,3 GB de memoria
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 21600, to_s = 43200);   -- 06:00 a 12:00
-- Medido: 5,21 s · 21 947 filas leídas (181,8 KB) · 1,1 M filas escritas · 1,4 GB de memoria
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 43200, to_s = 57600);   -- 12:00 a 16:00
-- Medido: 6,18 s · 14 747 filas leídas (130,6 KB) · 1,5 M filas escritas · 1,7 GB de memoria
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 57600, to_s = 72000);   -- 16:00 a 20:00
-- Medido: 8,49 s · 14 747 filas leídas (125,6 KB) · 2,3 M filas escritas · 2 GB de memoria


-- PASO 3 · ¿Qué hemos guardado, y cuánto ocupa?
SELECT
    source,
    count()                                                         AS records,
    formatReadableSize(sum(length(payload)))                        AS raw_json
FROM payflow_raw.log_records
GROUP BY source;
-- Medido: 34 ms · 6 M filas leídas (51,5 MB) · 169,8 MB de memoria

SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                AS uncompressed,
    formatReadableSize(sum(data_compressed_bytes))                  AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'payflow_raw' AND table = 'log_records' AND active;
-- Medido: 3 ms · 7 filas leídas
-- Qué observar: el ratio. Los logs son el mejor caso para la compresión columnar.


-- PASO 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_raw.log_records WHERE source = 'fluent-bit') > 5000000, 'OK', 'KO') AS container_logs,
    if((SELECT count() FROM payflow_raw.log_records WHERE source = 'k8s-events') > 300, 'OK', 'KO')     AS k8s_events,
    if((SELECT max(received_at) FROM payflow_raw.log_records) < toDateTime64('2026-11-27 20:00:05', 3, 'UTC'), 'OK', 'KO') AS stops_at_20h
SETTINGS select_sequential_consistency = 1;
-- Medido: 27 ms · 8 677 filas leídas (8,8 KB)
