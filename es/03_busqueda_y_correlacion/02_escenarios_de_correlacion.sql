-- =====================================================================
--  MÓDULO 3 · Escenarios de correlación: tres entradas al mismo incidente
-- =====================================================================
--  Una investigación puede empezar por cualquier señal. El ingeniero de guardia rara vez elige:
--    · el escenario A empieza por un LOG: un comercio llama a soporte por un pago
--    · el escenario B empieza por una ALERTA DE MÉTRICA: el pool de conexiones de un pod se satura
--    · el escenario C empieza por una TRAZA: aparece un nuevo tipo de error en los waterfalls
--  Cada uno recorre las demás señales hasta llegar a una causa. Tres claves hacen el trabajo:
--    · TraceId une una línea de log con su traza (y al revés)
--    · los atributos de recurso (k8s.pod.name, k8s.node.name, service.version) unen
--      logs y trazas con las métricas del pod y del nodo
--    · el tiempo: cada consulta está acotada, y la tabla de búsqueda de trazas da los límites
--  El README de este módulo recorre los mismos tres caminos en ClickStack, a golpe de clic.
-- =====================================================================


-- =====================================================================
--  ESCENARIO A · Log → traza → métricas → log
--  14:12, un ticket: "comercio m_16523, un pago falló justo después de las 14:09". Solo
--  tienes un id de comercio. Los logs de checkout lo llevan como atributo.
-- =====================================================================

-- PASO A1 · La línea de log: buscar el id de comercio en los atributos del log
--  En ClickStack: LogAttributes.merchant_id:m_16523 SeverityText:ERROR
--  LogAttributeItems convierte cada par en 'clave=valor': su índice de texto resuelve el filtro.
SELECT Timestamp, ServiceName, Body, LogAttributes['payment_id'] AS payment_id, TraceId
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
  AND has(LogAttributeItems, 'merchant_id=m_16523')
  AND SeverityText = 'ERROR';
-- Medido: 20 ms · 65 537 filas leídas (2 MB)
-- Qué observar: una línea, "payment failed: payment service returned 503", y su TraceId.
-- checkout solo informa del error de otro servicio: el log no dice por qué.

-- PASO A2 · La traza: todos los spans de esa petición, en orden
--  La tabla de búsqueda de trazas (módulo 1) da el inicio y el fin de la traza, así que el
--  escaneo de otel_traces se limita a unos segundos en lugar del día entero.
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS bounds
SELECT
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1) AS start_ms,
    round(Duration / 1e6, 1)                                                     AS duration_ms,
    ServiceName, SpanKind, SpanName, StatusCode, StatusMessage,
    ResourceAttributes['k8s.pod.name']                                           AS pod
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN bounds.1 AND bounds.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Medido: 56 ms · 106 497 filas leídas (6 MB)
-- Qué observar: el error nace en payment, en INSERT payflow.payments: 3 segundos
-- esperando una conexión, "HikariPool-1 - Connection is not available". La columna pod
-- nombra el pod de payment que sirvió la petición: el siguiente paso mira sus métricas.

-- PASO A3 · Las métricas de ese pod, minuto a minuto
--  El mismo nombre de pod es un atributo de recurso de los gauges (kubeletstats y HikariCP).
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE TraceId = tid AND StatusCode = 'Error'
       AND Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')) AS failing_pod
SELECT
    toStartOfMinute(toDateTime(TimeUnix))                                        AS minute,
    failing_pod                                                                  AS pod,
    round(avgIf(Value, MetricName = 'k8s.pod.cpu.utilization'), 2)               AS cpu,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'))              AS pool_active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.max'))                 AS pool_max,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'))             AS pool_pending
FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix BETWEEN pf_at('14:05') AND pf_at('14:10:59')
  AND ResourceAttributes['k8s.pod.name'] = failing_pod
GROUP BY minute
ORDER BY minute;
-- Medido: 59 ms · 190 913 filas leídas (9,7 MB)
-- Qué observar: el pod no está ocupado (CPU baja). Su pool está lleno (active = max) y
-- decenas de peticiones esperan una conexión. Y el máximo del pool es 10, no 50.

-- PASO A4 · Vuelta a los logs: lo que dijo el pod al arrancar
--  ¿Por qué 10? El pod escribe en el log la configuración de su pool al arrancar.
WITH
    (SELECT min(TraceId) FROM payflow_otel.otel_logs
     WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
       AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') AS tid,
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE TraceId = tid AND StatusCode = 'Error'
       AND Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')) AS failing_pod
SELECT Timestamp, ResourceAttributes['service.version'] AS version, Body
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('13:50') AND pf_at('14:10')
  AND ResourceAttributes['k8s.pod.name'] = failing_pod
  AND hasAllTokens(lower(Body), ['maximumpoolsize']);
-- Medido: 52 ms · 90 113 filas leídas (4,8 MB)
-- Qué observar: "maximumPoolSize=10", escrito por un pod v2.4.1 arrancado unos minutos
-- antes del ticket. Un id de comercio ha llevado a la release que rompió los pagos.


-- =====================================================================
--  ESCENARIO B · Alerta de métrica → métrica → traza → log → cambio
--  Una alerta de gráfico vigila hikaricp.connections.pending: "más de 20 peticiones esperan
--  una conexión a la base de datos en un pod, durante un minuto". Salta. No se sabe nada más.
-- =====================================================================

-- PASO B1 · La alerta: lo que ClickStack evalúa cada minuto
--  Una alerta de gráfico es un GROUP BY sobre un intervalo de tiempo con un umbral: las
--  primeras filas son los primeros minutos en los que salta.
SELECT
    toStartOfMinute(toDateTime(TimeUnix))          AS minute,
    count(DISTINCT ResourceAttributes['k8s.pod.name']) AS pods_over,
    argMax(ResourceAttributes['k8s.pod.name'], Value) AS worst_pod,
    max(Value)                                     AS max_pending
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName = 'hikaricp.connections.pending'
  AND TimeUnix BETWEEN pf_at('12:00') AND pf_at('16:00')
  AND Value > 20
GROUP BY minute
ORDER BY minute
LIMIT 5;
-- Medido: 16 ms · 114 689 filas leídas (3,4 MB)
-- Qué observar: salta a las 14:03, en los 6 pods de payment a la vez. Un problema en todos
-- los pods al mismo tiempo rara vez es un fallo de hardware: piensa en un cambio.

-- PASO B2 · La métrica en contexto: el pool de cada versión, antes y durante
SELECT
    if(TimeUnix < pf_at('13:58'), 'before 13:58', 'at 14:03')               AS period,
    ResourceAttributes['service.version']                                          AS version,
    count(DISTINCT ResourceAttributes['k8s.pod.name'])                             AS pods,
    round(avgIf(Value, MetricName = 'hikaricp.connections.max'))                   AS pool_max,
    round(avgIf(Value, MetricName = 'hikaricp.connections.active'), 1)             AS pool_active,
    round(avgIf(Value, MetricName = 'hikaricp.connections.pending'), 1)            AS pool_pending
FROM payflow_otel.otel_metrics_gauge
WHERE MetricName LIKE 'hikaricp.%'
  AND (TimeUnix BETWEEN pf_at('13:50') AND pf_at('13:52:59')
       OR TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59'))
GROUP BY period, version
ORDER BY period DESC, version;
-- Medido: 25 ms · 131 073 filas leídas (5,3 MB)
-- Qué observar: v2.4.0 tenía un pool de 50 y usaba pocas conexiones. v2.4.1 tiene 10,
-- todas ocupadas. La métrica ya señala la versión; las trazas muestran el efecto.

-- PASO B3 · De la métrica a las trazas: lo que sirvió el peor pod en ese minuto
--  ClickStack hace lo mismo cuando haces clic en un punto del gráfico: mismo pod, mismo minuto.
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59')) AS worst_pod
SELECT
    worst_pod                                                      AS pod,
    SpanName,
    count()                                                        AS spans,
    countIf(StatusCode = 'Error')                                  AS errors,
    round(quantile(0.5)(Duration) / 1e6)                           AS p50_ms,
    round(max(Duration) / 1e6)                                     AS max_ms,
    argMinIf(TraceId, Timestamp, StatusCode = 'Error')             AS first_failed_trace
FROM payflow_otel.otel_traces
WHERE Timestamp BETWEEN pf_at('14:03') AND pf_at('14:03:59')
  AND ServiceName = 'payment' AND SpanKind = 'Server'
  AND ResourceAttributes['k8s.pod.name'] = worst_pod
GROUP BY SpanName
ORDER BY spans DESC;
-- Medido: 34 ms · 253 953 filas leídas (5,1 MB)
-- Qué observar: una mediana de más de un segundo y fallos a los 3 segundos, el timeout de
-- HikariCP. first_failed_trace es el id de la traza que hay que abrir.

-- PASO B4 · De la traza a sus logs: todo lo escrito mientras se servía
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59')) AS worst_pod,
    (SELECT argMinIf(TraceId, Timestamp, StatusCode = 'Error') FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:03') AND pf_at('14:03:59')
       AND ServiceName = 'payment' AND SpanKind = 'Server'
       AND ResourceAttributes['k8s.pod.name'] = worst_pod) AS tid
SELECT Timestamp, ServiceName, SeverityText, Body
FROM payflow_otel.otel_logs
WHERE TraceId = tid
  AND Timestamp BETWEEN pf_at('14:02:50') AND pf_at('14:04:20')
ORDER BY Timestamp;
-- Medido: 35 ms · 49 153 filas leídas (3,9 MB)
-- Qué observar: la misma petición vista por tres servicios: payment agota el tiempo en el
-- pool, checkout informa de un 503, el log de acceso de api-gateway devuelve el 503 al comercio.

-- PASO B5 · ¿Qué cambió en ese pod? Los eventos de Kubernetes
--  El receptor k8sobjects del módulo 2 escribió los eventos del clúster en otel_logs.
WITH
    (SELECT argMax(ResourceAttributes['k8s.pod.name'], Value) FROM payflow_otel.otel_metrics_gauge
     WHERE MetricName = 'hikaricp.connections.pending'
       AND TimeUnix BETWEEN pf_at('14:03') AND pf_at('14:03:59')) AS worst_pod
SELECT Timestamp, EventName, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events'
  AND Timestamp BETWEEN pf_at('13:50') AND pf_at('14:03')
  AND (LogAttributes['k8s.object.name'] = worst_pod OR EventName = 'ScalingReplicaSet')
ORDER BY Timestamp;
-- Medido: 34 ms · 2,9 M filas leídas (7,4 MB) · 179,2 MB de memoria
-- Qué observar: "Scaled up replica set payment-5c8b7f9d21 (rolling update CHG-4117)",
-- luego el pod planificado, su imagen v2.4.1 descargada, arrancado. De la alerta al cambio
-- en 5 consultas.


-- =====================================================================
--  ESCENARIO C · Traza → log → métricas → eventos
--  14:25. Los errores de HikariPool ya se conocen y se prepara una marcha atrás (rollback).
--  Pero una traza muestra un error que no es el pool. ¿Es un segundo problema?
-- =====================================================================

-- PASO C1 · Las trazas: ¿qué mensajes de error son nuevos desde las 14:15?
--  El timeout del pool se conoce desde las 14:00. Un mensaje visto por primera vez más tarde
--  es una pista nueva. En ClickStack: trazas, StatusCode:Error, agrupar por StatusMessage.
SELECT ServiceName, SpanName, StatusMessage,
       count() AS error_spans, min(Timestamp) AS first_seen, max(Timestamp) AS last_seen
FROM payflow_otel.otel_traces
WHERE toDate(Timestamp) = pf_black_friday() AND Timestamp < pf_at('14:25')
  AND StatusCode = 'Error' AND SpanKind = 'Server' AND StatusMessage != ''
GROUP BY ServiceName, SpanName, StatusMessage
HAVING first_seen >= pf_at('14:15')
ORDER BY error_spans DESC;
-- Medido: 35 ms · 7,9 M filas leídas (21,1 MB)
-- Qué observar: fraud.ScoreTransaction, "connect: connection refused", 290 spans en
-- menos de un minuto a partir de las 14:21:07. Algo en fraud-scoring dejó de responder.

-- PASO C2 · Una de esas trazas, span a span
WITH
    (SELECT argMin(TraceId, Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS tid,
    (SELECT (min(Start), max(End)) FROM payflow_otel.otel_traces_trace_id_ts WHERE TraceId = tid) AS bounds
SELECT
    round(dateDiff('microsecond', min(Timestamp) OVER (), Timestamp) / 1000, 1) AS start_ms,
    round(Duration / 1e6, 1)                                                     AS duration_ms,
    ServiceName, SpanKind, SpanName, StatusCode, StatusMessage,
    ResourceAttributes['k8s.pod.name']                                           AS pod,
    ResourceAttributes['k8s.node.name']                                          AS node
FROM payflow_otel.otel_traces
WHERE TraceId = tid AND Timestamp BETWEEN bounds.1 AND bounds.2 + INTERVAL 1 SECOND
ORDER BY Timestamp;
-- Medido: 54 ms · 172 033 filas leídas (7,4 MB)
-- Qué observar: checkout llama a fraud-scoring, que falla al instante. El pod y el
-- nodo de fraud-scoring son las siguientes pistas.

-- PASO C3 · Los logs de ese pod en los minutos previos, agrupados por mensaje
--  No los logs de la traza: esos solo repiten el error. Lo que dijo el pod antes.
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod
SELECT SeverityText, replaceRegexpAll(Body, '[0-9]+([.:/][0-9]+)*', '<n>') AS message,
       count() AS lines, min(Timestamp) AS first_seen
FROM payflow_otel.otel_logs
WHERE Timestamp BETWEEN pf_at('14:10') AND pf_at('14:22')
  AND ResourceAttributes['k8s.pod.name'] = fraud_pod
  AND SeverityNumber >= 13
GROUP BY SeverityText, message
ORDER BY first_seen;
-- Medido: 82 ms · 4 M filas leídas (142,9 MB) · 284,1 MB de memoria
-- Qué observar: la cola crece ("scoring slower than arrival rate"), la caché de features
-- llega a 1,9 GiB de un límite de 2 GiB, luego un worker timeout FATAL a las 14:21:07.

-- PASO C4 · Las métricas: por qué crece la cola, y la memoria del pod
--  El ritmo de peticiones de fraud-scoring (desde las trazas) y su memoria (desde kubeletstats).
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod
SELECT
    m.minute,
    t.requests,
    m.memory_mb
FROM
(
    SELECT toStartOfFiveMinutes(toDateTime(TimeUnix)) AS minute,
           round(max(Value) / 1e6) AS memory_mb
    FROM payflow_otel.otel_metrics_gauge
    WHERE MetricName = 'k8s.pod.memory.usage'
      AND TimeUnix BETWEEN pf_at('13:40') AND pf_at('14:34:59')
      AND ResourceAttributes['k8s.pod.name'] = fraud_pod
    GROUP BY minute
) AS m
LEFT JOIN
(
    SELECT toStartOfFiveMinutes(Timestamp) AS minute, count() AS requests
    FROM payflow_otel.otel_traces
    WHERE Timestamp BETWEEN pf_at('13:40') AND pf_at('14:34:59')
      AND ServiceName = 'fraud-scoring' AND SpanKind = 'Server'
    GROUP BY minute
) AS t ON t.minute = m.minute
ORDER BY m.minute;
-- Medido: 29 ms · 204 801 filas leídas (2 MB)
-- Qué observar: las peticiones se duplican desde las 13:55 (checkout reintenta los pagos
-- fallidos y puntúa de nuevo cada reintento), la memoria sube de unos 750 MB a 2,2 GB y luego
-- baja a 900 MB después de las 14:21: el proceso fue matado y reiniciado.

-- PASO C5 · Los eventos de Kubernetes lo confirman
WITH
    (SELECT argMin(ResourceAttributes['k8s.pod.name'], Timestamp) FROM payflow_otel.otel_traces
     WHERE Timestamp BETWEEN pf_at('14:15') AND pf_at('14:25')
       AND ServiceName = 'fraud-scoring' AND StatusCode = 'Error') AS fraud_pod,
    (SELECT any(ResourceAttributes['k8s.node.name']) FROM payflow_otel.otel_metrics_gauge
     WHERE TimeUnix BETWEEN pf_at('14:20') AND pf_at('14:20:59')
       AND ResourceAttributes['k8s.pod.name'] = fraud_pod) AS fraud_node
SELECT Timestamp, EventName, Body
FROM payflow_otel.otel_logs
WHERE ServiceName = 'k8s-events'
  AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:30')
  AND EventName != 'Unhealthy'
  AND (LogAttributes['k8s.object.name'] IN (fraud_pod, fraud_node) OR Body LIKE concat('%', fraud_node, '%')
       OR Body LIKE '%fraud-scoring%')
ORDER BY Timestamp;
-- Medido: 60 ms · 3 M filas leídas (9,2 MB) · 179,6 MB de memoria
-- Qué observar: presión de memoria en el nodo a las 14:19, el OOM kill a las 14:21:07, el
-- back-off del reinicio, el nodo de vuelta a la normalidad a las 14:23. No es un segundo bug:
-- es una consecuencia del primero. Los reintentos de los pagos fallidos sobrecargaron
-- fraud-scoring hasta quedarse sin memoria. Arreglar el pool (el rollback de las 14:42)
-- arregla ambos.


-- PASO D · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE Timestamp BETWEEN pf_at('14:00') AND pf_at('14:15')
          AND has(LogAttributeItems, 'merchant_id=m_16523') AND SeverityText = 'ERROR') = 1, 'OK', 'KO')     AS a_log_found,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE Timestamp BETWEEN pf_at('13:50') AND pf_at('14:10')
          AND ResourceAttributes['service.version'] = 'v2.4.1'
          AND hasAllTokens(lower(Body), ['maximumpoolsize'])) = 6, 'OK', 'KO')                               AS a_pool_config,
    if((SELECT min(toStartOfMinute(toDateTime(TimeUnix))) FROM payflow_otel.otel_metrics_gauge
        WHERE MetricName = 'hikaricp.connections.pending' AND Value > 20
          AND toDate(TimeUnix) = pf_black_friday()) = pf_at('14:03'), 'OK', 'KO')                          AS b_alert_fires,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE ServiceName = 'k8s-events' AND EventName = 'ScalingReplicaSet'
          AND Timestamp BETWEEN pf_at('13:50') AND pf_at('14:03')
          AND Body LIKE '%CHG-4117%') = 1, 'OK', 'KO')                                                       AS b_change_found,
    if((SELECT count() FROM payflow_otel.otel_logs
        WHERE ServiceName = 'k8s-events' AND EventName = 'OOMKilling'
          AND Timestamp BETWEEN pf_at('14:10') AND pf_at('14:30')) >= 1, 'OK', 'KO')           AS c_oom_found
SETTINGS select_sequential_consistency = 1;
-- Medido: 149 ms · 6 M filas leídas (3,9 MB) · 129,1 MB de memoria
