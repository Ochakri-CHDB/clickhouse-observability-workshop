-- =====================================================================
--  MÓDULO 7 · Escala y coste (1/3): de un día a mil millones de líneas de log
-- =====================================================================
--  PayFlow funciona en 8 regiones. Dos semanas al ritmo de Black Friday, para todas
--  ellas, son casi mil millones de líneas de log. Construimos esa tabla y medimos lo
--  que ClickHouse hace con ella: almacenamiento, búsqueda de texto completo, búsqueda
--  de trazas, proyecciones, 3 réplicas.
--
--  La tabla XL conserva las columnas que importan para buscar (tiempo, servicio,
--  severidad, body, trace id, pod, nodo, cluster). El esquema OpenTelemetry completo,
--  con sus maps y sus 8 índices, cuesta unas 10 veces más de escribir: conviene
--  saberlo al dimensionar un pipeline de ingesta.
-- =====================================================================


-- PASO 1 · La tabla XL: un índice de texto sobre el body, un bloom filter sobre el trace id
--  La proyección preagrega los errores por servicio y minuto: los dashboards la
--  leen en lugar de los mil millones de filas. Se declara en el CREATE para que
--  se construya al insertar (MATERIALIZE PROJECTION sobre una tabla llena es lento).
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
SETTINGS min_bytes_for_wide_part = 0;   -- un fichero por columna incluso en parts pequeñas, para leer tamaños por columna (paso 3)


-- PASO 2 · 8 regiones x 14 días, una región por instrucción
--  Cada instrucción copia Black Friday 14 veces (desplazado d días) para una región,
--  con trace ids nuevos. max_insert_threads = 16 escribe en paralelo.
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(0 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-eu-west', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 1/8: eu-west
-- Medido: 27,5 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 10,3 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(1 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-eu-central', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 2/8: eu-central
-- Medido: 27 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 9,6 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(2 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-us-east', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 3/8: us-east
-- Medido: 31,6 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 9 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(3 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-us-west', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 4/8: us-west
-- Medido: 28,5 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 9,1 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(4 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ap-south', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 5/8: ap-south
-- Medido: 28,5 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 9 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(5 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ap-northeast', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 6/8: ap-northeast
-- Medido: 31,3 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 8,4 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(6 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-sa-east', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 7/8: sa-east
-- Medido: 29,1 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 9,4 GB de memoria
INSERT INTO payflow_otel.logs_xl
SELECT addDays(Timestamp, -d), if(TraceId = '', '', concat(substring(TraceId, 1, 24), leftPad(lower(hex(toUInt32(7 * 16 + d))), 8, '0'))),
       SeverityText, ServiceName, Body, 'payflow-prod-ca-central', ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.node.name']
FROM payflow_otel.otel_logs ARRAY JOIN range(0, 14) AS d
WHERE toDate(Timestamp) = pf_black_friday()
SETTINGS max_insert_threads = 16;   -- región 8/8: ca-central
-- Medido: 30,2 s · 7,8 M filas leídas (1,1 GB) · 109 M filas escritas · 9,2 GB de memoria


-- PASO 3 · Lo que cuestan en disco mil millones de líneas de log
SELECT
    formatReadableQuantity(sum(rows))                                       AS log_lines,
    formatReadableSize(sum(data_uncompressed_bytes))                        AS raw,
    formatReadableSize(sum(data_compressed_bytes))                          AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1)     AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 1)                        AS bytes_per_line
FROM system.parts
WHERE database = 'payflow_otel' AND table = 'logs_xl' AND active;
-- Medido: 4 ms · 257 filas leídas (15,1 KB)

SELECT column,
       formatReadableSize(sum(column_data_compressed_bytes))   AS on_disk,
       round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'payflow_otel' AND table = 'logs_xl' AND active AND column NOT LIKE '\\_%'
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- Medido: 12 ms · 2 237 filas leídas (149,7 KB)
-- Qué observar: Body es la mayor parte del almacenamiento. Las columnas LowCardinality
-- (servicio, pod, nodo, cluster) no cuestan casi nada. Los timestamps se comprimen bien con Delta.


-- PASO 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.logs_xl) > 850000000, 'OK', 'KO') AS billion_scale,
    if((SELECT uniqExact(Cluster) FROM payflow_otel.logs_xl) = 8, 'OK', 'KO') AS regions
SETTINGS select_sequential_consistency = 1;
-- Medido: 2,63 s · 875 M filas leídas (834,1 MB) · 262,8 MB de memoria
