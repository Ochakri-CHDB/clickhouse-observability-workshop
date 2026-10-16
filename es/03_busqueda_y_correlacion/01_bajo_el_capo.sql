-- =====================================================================
--  MÓDULO 3 · Búsqueda y correlación: lo que ClickStack ejecuta por debajo
-- =====================================================================
--  La barra de búsqueda de ClickStack habla Lucene (ServiceName:payment "HikariPool") o SQL.
--  En ambos casos se convierte en una consulta ClickHouse sobre otel_logs u otel_traces.
--  Este fichero ejecuta esas consultas a mano, para ver por qué son rápidas:
--    · la clave primaria salta por tiempo y por servicio
--    · el índice de texto sobre lower(Body) resuelve la búsqueda de texto (hasToken, hasAllTokens)
--    · los índices de texto sobre los items de atributos resuelven filtros clave=valor en los maps
--    · TraceId une un log con su traza, los atributos de recurso unen ambos con las métricas
--  El README de este módulo hace lo mismo en la interfaz de ClickStack.
-- =====================================================================


-- PASO 1 · Una búsqueda: errores de payment que mencionan HikariPool, hacia las 14:10
--  En ClickStack: ServiceName:payment SeverityText:ERROR "HikariPool"
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND ServiceName = 'payment' AND SeverityText = 'ERROR'
  AND hasAllTokens(lower(Body), ['hikaripool'])
ORDER BY Timestamp DESC
LIMIT 5;
-- Medido: 741 ms · 172 033 filas leídas (2,9 MB)

--  ¿Qué índices ha usado? Partes y gránulos descartados en cada paso.
EXPLAIN indexes = 1
SELECT count()
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
  AND hasAllTokens(lower(Body), ['hikaripool']);
-- Medido: 8 ms · 33 filas leídas (1,3 KB)
-- Qué observar: la partición y la clave primaria dejan un día y diez minutos,
-- luego idx_lower_body solo conserva los gránulos que contienen la palabra.


-- PASO 2 · Un filtro sobre un atributo: service.version, sin columna propia
--  Los atributos de recurso son un Map. ResourceAttributeItems es un ALIAS que convierte cada
--  par en 'clave=valor'; su índice de texto resuelve el filtro sin leer el map.
SELECT ResourceAttributes['k8s.pod.name'] AS pod, count() AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:45')
  AND has(ResourceAttributeItems, 'service.version=v2.4.1')
  AND SeverityText = 'ERROR'
GROUP BY pod
ORDER BY errors DESC;
-- Medido: 509 ms · 163 841 filas leídas (39,1 MB)

--  Las columnas materializadas: el exportador promociona los atributos más usados
SELECT name, type, default_expression
FROM system.columns
WHERE database = 'payflow_otel' AND table = 'otel_logs' AND default_kind = 'MATERIALIZED';
-- Medido: 2 ms · 27 filas leídas (3,5 KB)


-- PASO 3 · Correlación: de una línea de log a su traza, y luego a las métricas del pod
WITH (SELECT any(TraceId) FROM payflow_otel.otel_logs
      WHERE ServiceName = 'checkout' AND SeverityText = 'ERROR'
        AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:10:05')) AS tid
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode, ResourceAttributes['k8s.pod.name'] AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN pf_at('14:09:55') AND pf_at('14:10:15')
ORDER BY Timestamp;
-- Medido: 1,87 s · 3,3 M filas leídas (19,4 MB) · 132,3 MB de memoria
-- Qué observar: la traza del pago fallido. En ClickStack, un clic en la línea de log
-- abre esta cascada (waterfall), y la pestaña Infrastructure muestra las métricas del pod.

SELECT toStartOfMinute(toDateTime(TimeUnix)) AS minute, MetricName, round(avg(Value), 2) AS value
FROM payflow_otel.otel_metrics_gauge
WHERE ResourceAttributes['k8s.pod.name'] = 'payment-5c8b7f9d21-50d24'
  AND MetricName IN ('k8s.pod.cpu.utilization', 'hikaricp.connections.pending')
  AND TimeUnix BETWEEN pf_at('14:05') AND pf_at('14:10')
GROUP BY minute, MetricName
ORDER BY minute, MetricName;
-- Medido: 23 ms · 24 577 filas leídas (1,7 MB)
-- Qué observar: el pod no está ocupado (CPU baja), espera (decenas de conexiones pendientes).


-- PASO 4 · Live tail: las últimas líneas del flujo
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN now() - INTERVAL 2 MINUTE AND now()
ORDER BY Timestamp DESC
LIMIT 10;
-- Medido: 8 ms · 137 436 filas leídas (1,4 MB)


-- PASO 5 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN pf_at('14:05') AND pf_at('14:15')
        AND hasAllTokens(lower(Body), ['hikaripool'])) > 1000, 'OK', 'KO')                                   AS full_text_search,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 0, 'OK', 'KO') AS live_tail
SETTINGS select_sequential_consistency = 1;
-- Medido: 84 ms · 295 287 filas leídas (2,4 MB)
