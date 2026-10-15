-- =====================================================================
--  MÓDULO 6 · Buscar en mil millones de líneas de log: índices, proyecciones, réplicas
-- =====================================================================
--  Las consultas de observabilidad buscan una aguja en un pajar: un mensaje de
--  error, un trace id, un pod. ClickHouse solo lee lo que necesita:
--    · el índice primario (ORDER BY) salta por servicio y por tiempo
--    · el índice de texto salta los gránulos que no contienen un token
--    · el bloom filter salta los gránulos que no pueden contener un trace id
--    · la proyección responde a los agregados desde una copia preagregada
--  Cada consulta se ejecuta con y sin su ayuda. Compara las líneas "Medido":
--  el tiempo y, sobre todo, las filas leídas.
--  Atención: dos cachés harían instantánea la segunda ejecución de una consulta.
--  Aquí están desactivadas para que cada tiempo sea una lectura real (los pasos 6
--  y 7 las enseñan):
--    · la caché de consultas (query cache) guarda resultados completos
--    · la query condition cache recuerda qué gránulos cumplieron un WHERE
-- =====================================================================

SET use_query_cache = 0;
SET use_query_condition_cache = 0;


-- PASO 1 · Búsqueda de texto completo: una palabra rara en 910 millones de líneas
--  hasToken(lower(Body), 'oomkilled') usa idx_lower_body, construido con la misma
--  expresión lower(Body) y el mismo tokenizador (splitByNonAlpha).
SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled');
-- Medido: 461 ms · 311 296 filas leídas (304 KB)

SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled')
SETTINGS use_skip_indexes = 0;   -- la misma consulta con el índice desactivado: se lee cada Body
-- Medido: 3,45 s · 910 M filas leídas (53,6 GB) · 447,4 MB de memoria

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%oomkilled%'
SETTINGS use_skip_indexes = 0;   -- lo que haría un grep
-- Medido: 2,93 s · 910 M filas leídas (53,6 GB) · 462,9 MB de memoria
-- Qué observar: con el índice se leen unos cientos de miles de filas en lugar de 910 millones.


-- PASO 2 · Una palabra frecuente: los errores HikariPool de todas las regiones
SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster;
-- Medido: 333 ms · 9,5 M filas leídas (18,1 MB)

SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster
SETTINGS use_skip_indexes = 0;
-- Medido: 2,97 s · 910 M filas leídas (53,6 GB) · 355 MB de memoria
-- Qué observar: la mejora se reduce cuando la palabra está por todas partes, pero sigue
-- siendo grande: el índice sigue saltando cada gránulo que no contiene la palabra.


-- PASO 3 · Un trace id entre 910 millones de líneas
--  El bloom filter solo ya salta la mayoría de los gránulos. Si además acotamos
--  el tiempo, el índice primario y las particiones hacen el resto: por eso las
--  herramientas de trazas buscan primero el rango de tiempo de una traza (paso 5).
SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN '2026-11-21 10:00:00' AND '2026-11-21 10:00:10' AND TraceId != '');
-- Medido: 2,73 s · 1,8 M filas leídas (34,4 MB) · 94,8 MB de memoria

SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN '2026-11-21 10:00:00' AND '2026-11-21 10:00:10' AND TraceId != '')
  AND Timestamp BETWEEN '2026-11-21 09:59:00' AND '2026-11-21 10:01:00';
-- Medido: 18 ms · 835 584 filas leídas (4,3 MB) · 86,5 MB de memoria
-- Qué observar: la segunda consulta responde en unos milisegundos: el rango de tiempo permite
-- al índice primario descartar todos los demás días, solo se leen los gránulos de esa ventana.


-- PASO 4 · Errores por minuto para un dashboard: la proyección
--  p_errors_per_minute se construyó al insertar. La consulta no la menciona:
--  ClickHouse la elige porque puede responder a partir de ella.
SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5;
-- Medido: 115 ms · 593 063 filas leídas (12,4 MB)

SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Medido: 890 ms · 910 M filas leídas (3 GB) · 244,9 MB de memoria
-- Qué observar: los mismos 5 minutos (las 14:21 de cada día: las copias del Black Friday),
-- a partir de unas 600 000 filas en lugar de 910 millones.

EXPLAIN indexes = 1, projections = 1
SELECT toStartOfMinute(Timestamp) AS minute, count()
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute;
-- Medido: 5 ms · 14 filas leídas


-- PASO 5 · La tabla de búsqueda por trace id (el patrón que usan las interfaces de trazas)
--  Una tabla pequeña, ordenada por TraceId, guarda el inicio y el fin de cada traza.
--  La alimenta una vista materializada: una búsqueda da el rango de tiempo y la
--  consulta real lee después una ventana de tiempo estrecha de otel_traces.
CREATE OR REPLACE TABLE payflow_otel.otel_traces_trace_id_ts
(
    TraceId  String CODEC(ZSTD(1)),
    Start    SimpleAggregateFunction(min, DateTime64(9)),
    End      SimpleAggregateFunction(max, DateTime64(9))
)
ENGINE = AggregatingMergeTree
ORDER BY TraceId;

CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_trace_id_ts TO payflow_otel.otel_traces_trace_id_ts AS
SELECT TraceId, min(Timestamp) AS Start, max(Timestamp) AS End
FROM payflow_otel.otel_traces
GROUP BY TraceId;

INSERT INTO payflow_otel.otel_traces_trace_id_ts
SELECT TraceId, min(Timestamp), max(Timestamp) FROM payflow_otel.otel_traces GROUP BY TraceId;
-- Medido: 1,41 s · 14,6 M filas leídas (597,4 MB) · 1,4 M filas escritas · 1,1 GB de memoria

WITH (SELECT any(TraceId) FROM payflow_otel.otel_traces WHERE ServiceName = 'payment' AND StatusCode = 'Error'
      AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01') AS tid,
     (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS range
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN range.1 - INTERVAL 1 SECOND AND range.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Medido: 28 ms · 188 416 filas leídas (4,1 MB)
-- Qué observar: una traza completa, leída en una ventana de pocos segundos.


-- PASO 6 · La caché de consultas (query cache)
--  El resultado de una consulta pesada se guarda en memoria: la segunda ejecución
--  responde en ~1 ms.
--  Atención: la caché es por réplica y los inserts no la invalidan.
--  Sirve para dashboards que refrescan muchos usuarios, no para alertas.
SYSTEM DROP QUERY CACHE;

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Medido: 6,89 s · 910 M filas leídas (53,7 GB) · 298 MB de memoria

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Medido: 1 ms · 1 fila leída


-- PASO 7 · La query condition cache: se recuerda el filtro, no el resultado
--  Para cada part, ClickHouse recuerda qué gránulos cumplieron una condición WHERE.
--  Si repites la misma búsqueda, aunque cambie la lista del SELECT, los gránulos
--  que no cumplían se saltan sin leerlos. Activada por defecto desde la 25.3.
SET use_query_condition_cache = 1;

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
SETTINGS use_skip_indexes = 0;
-- Medido: 1,71 s · 593 M filas leídas (34,9 GB) · 461,4 MB de memoria

SELECT Cluster, count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
GROUP BY Cluster
SETTINGS use_skip_indexes = 0;
-- Medido: 13 ms · 540 672 filas leídas (23,7 MB) · 112,2 MB de memoria
-- Qué observar: la primera ejecución lo lee todo, la segunda casi nada.

SET use_query_condition_cache = 0;


-- PASO 8 · Tres réplicas sobre el mismo scan
--  El mismo scan completo, primero en una réplica y luego repartido entre las 3
--  réplicas del servicio (parallel replicas). El almacenamiento es compartido:
--  no se mueve ningún dato.
SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null;
-- Medido: 6,8 s · 910 M filas leídas (57 GB) · 405,2 MB de memoria

SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null
SETTINGS enable_parallel_replicas = 1;
-- Medido: 3,77 s · 910 M filas leídas (57 GB) · 258,2 MB de memoria
-- Qué observar: más o menos el doble de rápido con 3 réplicas, sin cambiar el SQL.
