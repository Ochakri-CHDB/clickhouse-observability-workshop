-- =====================================================================
--  MÓDULO 7 · Escala y coste (2/3): buscar en mil millones de líneas de log
-- =====================================================================
--  Las consultas de observabilidad buscan agujas en pajares: un mensaje de error, un
--  trace id, un pod. ClickHouse solo lee lo que necesita:
--    · el índice primario (ORDER BY) salta por servicio y tiempo
--    · el índice de texto salta los gránulos que no contienen un token
--    · el bloom filter salta los gránulos que no pueden contener un trace id
--    · la proyección responde a los agregados desde una copia preagregada
--  Cada consulta se ejecuta con y sin su ayuda. Compara las líneas "Medido":
--  el tiempo y, sobre todo, las filas leídas.
--  Atención: dos cachés harían instantánea la segunda ejecución de una consulta. Aquí
--  están desactivadas para que cada tiempo sea una lectura real (los pasos 6 y 7 las muestran):
--    · la query cache guarda resultados completos
--    · la query condition cache recuerda qué gránulos cumplieron una cláusula WHERE
-- =====================================================================

SET use_query_cache = 0;
SET use_query_condition_cache = 0;


-- PASO 1 · Búsqueda de texto completo: una palabra rara en 875 millones de líneas
--  hasToken(lower(Body), 'oomkilled') usa idx_lower_body, construido con la misma
--  expresión lower(Body) y el mismo tokenizer (splitByNonAlpha).
SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled');
-- Medido: 774 ms · 286 720 filas leídas (280 KB)

SELECT count() FROM payflow_otel.logs_xl WHERE hasToken(lower(Body), 'oomkilled')
SETTINGS use_skip_indexes = 0;   -- la misma consulta, índice desactivado: se lee cada Body
-- Medido: 4,27 s · 875 M filas leídas (52,5 GB) · 448 MB de memoria

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%oomkilled%'
SETTINGS use_skip_indexes = 0;   -- lo que haría un grep
-- Medido: 2,98 s · 875 M filas leídas (52,5 GB) · 462 MB de memoria
-- Qué observar: con el índice, unos cientos de miles de filas leídas en lugar de 875 millones.


-- PASO 2 · Una palabra frecuente: los errores HikariPool de todas las regiones
SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster;
-- Medido: 367 ms · 9,7 M filas leídas (18,4 MB) · 110,2 MB de memoria

SELECT Cluster, count() AS errors
FROM payflow_otel.logs_xl
WHERE hasToken(lower(Body), 'hikaripool')
GROUP BY Cluster
ORDER BY Cluster
SETTINGS use_skip_indexes = 0;
-- Medido: 3,09 s · 875 M filas leídas (52,6 GB) · 365,1 MB de memoria
-- Qué observar: la mejora se reduce cuando la palabra está por todas partes, pero sigue
-- siendo grande: el índice sigue saltando todos los gránulos sin la palabra.


-- PASO 3 · Un trace id entre 875 millones de líneas
--  El bloom filter por sí solo ya salta la mayoría de los gránulos. Acotar también el
--  tiempo deja que el índice primario y las particiones hagan el resto: por eso las
--  herramientas de trazas buscan primero el rango temporal de una traza (paso 5).
SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN pf_at('10:00:00') - INTERVAL 6 DAY AND pf_at('10:00:10') - INTERVAL 6 DAY AND TraceId != '');
-- Medido: 2,96 s · 1,2 M filas leídas (31,5 MB) · 91,4 MB de memoria

SELECT count() FROM payflow_otel.logs_xl
WHERE TraceId = (SELECT any(TraceId) FROM payflow_otel.logs_xl WHERE Cluster = 'payflow-prod-us-east' AND Timestamp BETWEEN pf_at('10:00:00') - INTERVAL 6 DAY AND pf_at('10:00:10') - INTERVAL 6 DAY AND TraceId != '')
  AND Timestamp BETWEEN pf_at('09:59:00') - INTERVAL 6 DAY AND pf_at('10:01:00') - INTERVAL 6 DAY;
-- Medido: 22 ms · 368 641 filas leídas (3,7 MB)
-- Qué observar: la segunda consulta responde en unos milisegundos: el rango temporal deja
-- que el índice primario salte todos los demás días, solo se leen los gránulos de esa ventana.


-- PASO 4 · Errores por minuto para un dashboard: la proyección
--  p_errors_per_minute se construyó al insertar. La consulta no la menciona:
--  ClickHouse la elige porque puede responder desde ella.
SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5;
-- Medido: 712 ms · 465 928 filas leídas (9,8 MB)

SELECT toStartOfMinute(Timestamp) AS minute, count() AS errors
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute
ORDER BY errors DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;
-- Medido: 1,08 s · 875 M filas leídas (2,9 GB) · 241,9 MB de memoria
-- Qué observar: los mismos 5 minutos (las 14:21 de cada día: las copias de Black Friday),
-- a partir de unas 600 000 filas en lugar de 875 millones.

EXPLAIN indexes = 1, projections = 1
SELECT toStartOfMinute(Timestamp) AS minute, count()
FROM payflow_otel.logs_xl
WHERE SeverityText = 'ERROR' AND Cluster = 'payflow-prod-eu-west'
GROUP BY minute;
-- Medido: 5 ms · 14 filas leídas


-- PASO 5 · La tabla de búsqueda de trazas en acción
--  otel_traces_trace_id_ts (módulo 1) guarda el inicio y el fin de cada traza. Una búsqueda
--  da el rango temporal y la consulta real lee luego una ventana estrecha de otel_traces.
--  Es lo que hace ClickStack cuando abres una traza.
WITH (SELECT any(TraceId) FROM payflow_otel.otel_traces WHERE ServiceName = 'payment' AND StatusCode = 'Error'
      AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:01')) AS tid,
     (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS range
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN range.1 - INTERVAL 1 SECOND AND range.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Medido: 454 ms · 245 761 filas leídas (5,5 MB)
-- Qué observar: una traza entera, leída desde una ventana de unos segundos.


-- PASO 6 · La query cache
--  El resultado de una consulta pesada se guarda en memoria: la segunda ejecución responde en ~1 ms.
--  Atención: la caché es por réplica y los inserts no la invalidan.
--  Sirve para dashboards que refrescan muchos usuarios, no para alertas.
SYSTEM DROP QUERY CACHE;

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Medido: 6,99 s · 875 M filas leídas (52,7 GB) · 302,6 MB de memoria

SELECT ServiceName, count() AS lines, round(avg(toUInt32OrZero(extract(Body, 'took=([0-9]+)ms')))) AS avg_ms
FROM payflow_otel.logs_xl
WHERE match(Body, 'took=[0-9]+ms')
GROUP BY ServiceName
SETTINGS use_query_cache = 1;
-- Medido: 1 ms · 1 fila leída


-- PASO 7 · La query condition cache: se recuerda el filtro, no el resultado
--  Para cada part, ClickHouse recuerda qué gránulos cumplieron una condición WHERE.
--  Repite la misma búsqueda, incluso con otra lista de SELECT: los gránulos que no
--  la cumplieron se saltan sin leerlos. Activada por defecto desde la 25.3.
SET use_query_condition_cache = 1;

SELECT count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
SETTINGS use_skip_indexes = 0;
-- Medido: 2,94 s · 875 M filas leídas (52,5 GB) · 462 MB de memoria

SELECT Cluster, count() FROM payflow_otel.logs_xl WHERE lower(Body) LIKE '%connection refused%'
GROUP BY Cluster
SETTINGS use_skip_indexes = 0;
-- Medido: 14 ms · 745 472 filas leídas (32,5 MB) · 99,9 MB de memoria
-- Qué observar: la primera ejecución lo lee todo, la segunda casi nada.

SET use_query_condition_cache = 0;


-- PASO 8 · Tres réplicas sobre el mismo scan
--  El mismo scan completo, primero en una réplica y después repartido entre las 3 réplicas
--  del servicio (parallel replicas). El almacenamiento es compartido: no se mueve ningún dato.
SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null;
-- Medido: 7,03 s · 875 M filas leídas (55,8 GB) · 398,4 MB de memoria

SELECT Cluster, ServiceName, SeverityText, count() AS lines, uniq(PodName) AS pods, sum(length(Body)) AS body_bytes
FROM payflow_otel.logs_xl
GROUP BY ALL
FORMAT Null
SETTINGS enable_parallel_replicas = 1;
-- Medido: 3,56 s · 875 M filas leídas (55,8 GB) · 261 MB de memoria
-- Qué observar: unas dos veces más rápido con 3 réplicas, sin cambiar el SQL.
