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
WHERE Timestamp BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:15:00'
  AND ServiceName = 'payment' AND SeverityText = 'ERROR'
  AND hasAllTokens(lower(Body), ['hikaripool'])
ORDER BY Timestamp DESC
LIMIT 5;
-- Medido: 24 ms · 172 032 filas leídas (2,9 MB)

--  ¿Qué índices ha usado? Partes y gránulos descartados en cada paso.
EXPLAIN indexes = 1
SELECT count()
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:15:00'
  AND hasAllTokens(lower(Body), ['hikaripool']);
-- Medido: 4 ms · 32 filas leídas (1,3 KB)
-- Qué observar: la partición y la clave primaria dejan un día y diez minutos,
-- luego idx_lower_body solo conserva los gránulos que contienen la palabra.


-- PASO 2 · Un filtro sobre un atributo: service.version, sin columna propia
--  Los atributos de recurso son un Map. ResourceAttributeItems es un ALIAS que convierte cada
--  par en 'clave=valor'; su índice de texto resuelve el filtro sin leer el map.
SELECT ResourceAttributes['k8s.pod.name'] AS pod, count() AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN '2026-11-27 14:00:00' AND '2026-11-27 14:45:00'
  AND has(ResourceAttributeItems, 'service.version=v2.4.1')
  AND SeverityText = 'ERROR'
GROUP BY pod
ORDER BY errors DESC;
-- Medido: 21 ms · 163 840 filas leídas (39,1 MB)

--  Las columnas materializadas: el exportador promociona los atributos más usados
SELECT name, type, default_expression
FROM system.columns
WHERE database = 'payflow_otel' AND table = 'otel_logs' AND default_kind = 'MATERIALIZED';
-- Medido: 2 ms · 27 filas leídas (3,5 KB)


-- PASO 3 · Correlación: de una línea de log a su traza, y luego a las métricas del pod
WITH (SELECT any(TraceId) FROM payflow_otel.otel_logs
      WHERE ServiceName = 'checkout' AND SeverityText = 'ERROR'
        AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:05') AS tid
SELECT ServiceName, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode, ResourceAttributes['k8s.pod.name'] AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN '2026-11-27 14:09:55' AND '2026-11-27 14:10:15'
ORDER BY Timestamp;
-- Medido: 520 ms · 3 M filas leídas (18,3 MB) · 146,4 MB de memoria
-- Qué observar: la traza del pago fallido. En ClickStack, un clic en la línea de log
-- abre esta cascada (waterfall), y la pestaña Infrastructure muestra las métricas del pod.

SELECT toStartOfMinute(toDateTime(TimeUnix)) AS minute, MetricName, round(avg(Value), 2) AS value
FROM payflow_otel.otel_metrics_gauge
WHERE ResourceAttributes['k8s.pod.name'] = 'payment-5c8b7f9d21-dbec8'
  AND MetricName IN ('k8s.pod.cpu.utilization', 'hikaricp.connections.pending')
  AND TimeUnix BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:10:00'
GROUP BY minute, MetricName
ORDER BY minute, MetricName;
-- Medido: 193 ms · 32 768 filas leídas (1,6 MB)
-- Qué observar: el pod no está ocupado (CPU baja), espera (decenas de conexiones pendientes).


-- PASO 4 · Live tail: las últimas líneas del flujo
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN now() - INTERVAL 2 MINUTE AND now()
ORDER BY Timestamp DESC
LIMIT 10;
-- Medido: 5 ms · 6 536 filas leídas (262,3 KB)


-- PASO 5 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN '2026-11-27 14:05:00' AND '2026-11-27 14:15:00'
        AND hasAllTokens(lower(Body), ['hikaripool'])) > 1000, 'OK', 'KO')                                   AS full_text_search,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 0, 'OK', 'KO') AS live_tail
SETTINGS select_sequential_consistency = 1;
-- Medido: 22 ms · 167 109 filas leídas (1,4 MB)
