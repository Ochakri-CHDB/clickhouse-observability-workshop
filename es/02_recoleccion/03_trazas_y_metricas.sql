-- =====================================================================
--  MÓDULO 2 · Recolección (3/4): trazas y métricas por OTLP
-- =====================================================================
--  Las trazas y las métricas salen de las aplicaciones ya estructuradas: el SDK
--  OpenTelemetry las envía por OTLP (gRPC 4317, HTTP 4318) a la pasarela y el exportador
--  ClickHouse las escribe en otel_traces y otel_metrics_*. No hace falta parsear nada.
--  La pasarela solo añade contexto (el equipo, como con los logs del fichero 02).
--  Las métricas vienen de tres sitios, todos simulados aquí:
--    · el receptor kubeletstats de los agentes: CPU, memoria y disco de cada pod y nodo
--    · el receptor k8s_cluster: fases de pods y namespaces, disponibilidad de nodos, reinicios
--    · la propia aplicación: el pool de conexiones HikariCP, el lag del consumidor Kafka
--  La tabla de búsqueda de trace ids (módulo 1, fichero 02) se rellena sola con su vista.
-- =====================================================================


-- PASO 1 · Los spans del mes: 3 lotes de días ordinarios, y luego Black Friday
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_day(-29), to_t = pf_day(-19));
-- Medido: 32 s · 16,5 M filas leídas (720,5 MB) · 16,6 M filas escritas · 10,5 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_day(-19), to_t = pf_day(-9));
-- Medido: 30,5 s · 16,4 M filas leídas (719,7 MB) · 16,6 M filas escritas · 10,2 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_day(-9), to_t = pf_day(0));
-- Medido: 29,4 s · 15,1 M filas leídas (661,6 MB) · 15,2 M filas escritas · 10,5 GB de memoria
--  Black Friday
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_at('00:00'), to_t = pf_at('12:00'));
-- Medido: 10,7 s · 5,5 M filas leídas (248,8 MB) · 5,8 M filas escritas · 9,2 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_at('12:00'), to_t = pf_at('18:00'));
-- Medido: 13 s · 7,1 M filas leídas (321,8 MB) · 7,5 M filas escritas · 9,5 GB de memoria
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = pf_at('18:00'), to_t = pf_day(1));
-- Medido: 16,3 s · 9,1 M filas leídas (415,1 MB) · 9,6 M filas escritas · 10 GB de memoria

SELECT if(toDate(Timestamp) = pf_black_friday(), 'Black Friday', 'ordinary days') AS days,
       uniqExact(toDate(Timestamp)) AS day_count,
       count() AS spans, uniqExact(TraceId) AS traces, round(count() / uniqExact(TraceId), 1) AS spans_per_trace
FROM payflow_otel.otel_traces
GROUP BY days;
-- Medido: 1,19 s · 67 M filas leídas (2,7 GB) · 844 MB de memoria


-- PASO 2 · Los generadores de métricas, como vistas parametrizadas
--  Siguen los nombres de los receptores OpenTelemetry, que es lo que buscan el
--  dashboard Kubernetes y la pestaña Infrastructure de ClickStack:
--    · kubeletstats: k8s.pod.cpu.utilization, k8s.pod.memory.usage, sus
--      *_limit_utilization, k8s.pod.filesystem.available, lo mismo para cada nodo
--    · k8s_cluster: k8s.pod.phase, k8s.container.restarts, k8s.node.condition_ready,
--      k8s.namespace.phase
--  Cada 30 s, el intervalo por defecto de los gráficos Infrastructure de ClickStack.
--    · la aplicación: el pool de conexiones HikariCP, el lag del consumidor Kafka
--  La carga sigue al tráfico de cada momento (pf_rate_at). Hay historias escondidas en estas cifras:
--    · los pods payment v2.4.1 usan MENOS CPU: sus hilos esperan una conexión
--    · el pod fraud-scoring de ip-10-0-3-17 crece desde las 14:05 (reintentos) hasta su
--      límite de 2 GiB, lo matan a las 14:21:07 y reinicia a las 14:21:52; su nodo pequeño
--      se queda sin memoria al mismo tiempo
--  ts es un punto cada 30 s, s su segundo del día, bf indica si es Black Friday.

--  Cada pod en ejecución, cada 30 s: CPU, memoria, disco, fase, reinicios
CREATE OR REPLACE VIEW payflow_sim.pod_metrics AS
SELECT
    map('service.name', p.deployment, 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name)                                          AS ResourceAttributes,
    p.deployment                                                                                          AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    m.3                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    toDateTime64(t, 9, 'UTC')                                                                             AS StartTimeUnix,
    toDateTime64(t, 9, 'UTC')                                                                             AS TimeUnix,
    m.4                                                                                                   AS Value
FROM payflow_inventory.pod AS p
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30) * 30, toUnixTimestamp({to_t:DateTime}), 30) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t
ARRAY JOIN [toUInt32(ts % 86400)] AS s
ARRAY JOIN [toDate(t) = pf_black_friday()] AS bf
ARRAY JOIN [multiIf(p.deployment = 'fraud-scoring', 2048, p.deployment IN ('payment', 'card-network-adapter', 'ledger'), 2560, 512)] AS limit_mib
ARRAY JOIN [least(0.98, (0.08 + 0.5 * pf_rate_at(t) / 40 * if(p.version = 'v2.4.1', 0.45, 1)
                   * if(p.deployment = 'fraud-scoring' AND bf AND s >= 50700 AND s < 53100, 2.2, 1)) * (0.9 + 0.2 * pf_r(cityHash64(p.pod_name), ts)))] AS cpu
ARRAY JOIN [multiIf(p.deployment = 'fraud-scoring' AND p.slot = 2 AND bf AND s >= 50700 AND s < 51667,
                        (900 + (s - 50700) / 967 * 1240) * 1048576,                        -- de 900 MiB a 2,1 GiB en 16 minutos
                    p.deployment = 'fraud-scoring' AND p.slot = 2 AND bf AND s >= 51667 AND s < 51712, 0,   -- matado, reiniciando
                    p.deployment = 'fraud-scoring' AND p.slot = 2 AND bf AND s >= 51712,
                        (700 + 200 * least(1, (s - 51712) / 600.0)) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), ts)),
                    p.deployment = 'fraud-scoring', 900 * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), ts)),
                    p.deployment IN ('payment', 'card-network-adapter', 'ledger'),
                        (1400 + 300 * pf_rate_at(t) / 40) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), ts)),
                    (180 + 60 * pf_rate_at(t) / 40) * 1048576 * (0.95 + 0.1 * pf_r(cityHash64(p.pod_name), ts)))] AS mem
ARRAY JOIN [
    ('k8s.pod.cpu.utilization',          'CPU used, in cores', '1', cpu),
    ('k8s.pod.cpu_limit_utilization',    'CPU used, as a share of the pod limit (1 core)', '1', cpu),
    ('k8s.pod.memory.usage',             'Memory used by the pod', 'By', mem),
    ('k8s.pod.memory_limit_utilization', 'Memory used, as a share of the pod limit', '1', mem / (limit_mib * 1048576)),
    ('k8s.pod.phase',                    'Pod phase: 1 Pending, 2 Running, 3 Succeeded, 4 Failed', '1', 2),
    ('k8s.pod.filesystem.available',     'Free space on the pod volume', 'By', (8192 - 300 * pf_r(p.pod_name, toDate(t))) * 1048576),
    ('k8s.container.restarts',           'Restarts of the container since the pod started', '{restart}',
        toFloat64(p.deployment = 'fraud-scoring' AND p.slot = 2 AND pf_at('14:21:52') BETWEEN p.started_at AND p.stopped_at
                  AND t >= pf_at('14:21:52')))] AS m
WHERE t >= p.started_at AND t <= p.stopped_at;

--  Cada nodo, a partir de los pods que ejecuta: CPU (núcleos usados / núcleos), memoria (sistema + pods)
--  El nodo más pequeño, ip-10-0-3-17, va muy justo: el sistema y los agentes del nodo ocupan
--  10,3 GiB de sus 16 GiB, por eso es el primero en quedarse sin memoria.
CREATE OR REPLACE VIEW payflow_sim.node_metrics AS
SELECT
    map('k8s.cluster.name', 'payflow-prod-eu', 'k8s.node.name', node, 'cloud.availability_zone', pf_zone(node)) AS ResourceAttributes,
    ''                                                                                                    AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    m.3                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    TimeUnix                                                                                              AS StartTimeUnix,
    TimeUnix,
    m.4                                                                                                   AS Value
FROM
(
    SELECT ResourceAttributes['k8s.node.name'] AS node, TimeUnix,
           sumIf(Value, MetricName = 'k8s.pod.cpu.utilization')  AS pods_cpu,
           sumIf(Value, MetricName = 'k8s.pod.memory.usage')     AS pods_mem
    FROM payflow_sim.pod_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
    WHERE MetricName IN ('k8s.pod.cpu.utilization', 'k8s.pod.memory.usage')
    GROUP BY node, TimeUnix
)
ARRAY JOIN [dictGet('payflow_inventory.dict_node', 'memory_gib', node)] AS mem_gib
ARRAY JOIN [toUInt8(if(node = 'ip-10-0-3-17', 4, 8))] AS cores
ARRAY JOIN [
    ('k8s.node.cpu.utilization',      'CPU used, as a share of the node', '1', least(0.97, (0.3 + pods_cpu) / cores)),
    ('k8s.node.memory.usage',         'Memory used on the node', 'By',
        (if(node = 'ip-10-0-3-17', 10.3, mem_gib * 0.25) * 1073741824 + pods_mem)),
    ('k8s.node.filesystem.available', 'Free space on the node disk', 'By', (61440 - 2000 * pf_r(node, toDate(TimeUnix))) * 1048576),
    ('k8s.node.condition_ready',      'Node is Ready (1) or not (0)', '1', 1)] AS m;

--  El pool de conexiones HikariCP de cada pod payment (la prueba del delito)
--  max es el tamaño configurado: 50 en v2.4.0, 10 en v2.4.1. Cuando el pool está
--  lleno, las peticiones hacen cola (pending) y se rinden a los 3 s.
CREATE OR REPLACE VIEW payflow_sim.pool_metrics AS
SELECT
    map('service.name', 'payment', 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', 'payment', 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name)                                          AS ResourceAttributes,
    'payment'                                                                                             AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    '{connection}'                                                                                        AS MetricUnit,
    map('pool', 'HikariPool-1')                                                                           AS Attributes,
    toDateTime64(t, 9, 'UTC')                                                                             AS StartTimeUnix,
    toDateTime64(t, 9, 'UTC')                                                                             AS TimeUnix,
    m.3                                                                                                   AS Value
FROM payflow_inventory.pod AS p
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30) * 30, toUnixTimestamp({to_t:DateTime}), 30) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t
ARRAY JOIN [
    ('hikaricp.connections.max',     'Configured pool size', toFloat64(if(p.version = 'v2.4.1', 10, 50))),
    ('hikaricp.connections.active',  'Connections in use',
        if(p.version = 'v2.4.1' AND t >= pf_at('14:03'), 10, round(1 + pf_rate_at(t) / 8 + 2 * pf_r(cityHash64(p.pod_name), ts)))),
    ('hikaricp.connections.pending', 'Threads waiting for a connection',
        if(p.version = 'v2.4.1' AND t >= pf_at('14:03'), round(pf_rate_at(t) * 1.4 * (0.8 + 0.4 * pf_r(cityHash64(p.pod_name, 'p'), ts))), 0))] AS m
WHERE p.deployment = 'payment' AND t >= p.started_at AND t <= p.stopped_at;

--  Todo lo que va a otel_metrics_gauge, en una vista: pods, nodos, pools,
--  namespaces (k8s_cluster) y el lag del consumidor Kafka de notification
CREATE OR REPLACE VIEW payflow_sim.gauge_metrics AS
SELECT * FROM payflow_sim.pod_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
UNION ALL
SELECT * FROM payflow_sim.node_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
UNION ALL
SELECT * FROM payflow_sim.pool_metrics(from_t = {from_t:DateTime}, to_t = {to_t:DateTime})
UNION ALL
SELECT map('k8s.cluster.name', 'payflow-prod-eu', 'k8s.namespace.name', ns), '', 'k8s.namespace.phase',
       'Namespace phase: 1 Active, 0 Terminating', '1', map(), toDateTime64(t, 9, 'UTC'), toDateTime64(t, 9, 'UTC'), 1
FROM numbers(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30), greatest(0, intDiv(toUnixTimestamp({to_t:DateTime}) + 29, 30) - intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30)))
ARRAY JOIN [toDateTime(number * 30, 'UTC')] AS t
ARRAY JOIN ['edge', 'payments', 'risk'] AS ns
UNION ALL
SELECT map('service.name', 'notification', 'k8s.cluster.name', 'payflow-prod-eu'), 'notification',
       'kafka.consumer.lag', 'Messages not yet processed by the consumer group', '{message}',
       map('messaging.destination.name', 'payment.events', 'messaging.consumer.group.name', 'notification'),
       toDateTime64(t, 9, 'UTC'), toDateTime64(t, 9, 'UTC'),
       round(pf_rate_at(t) * 4 * (0.5 + pf_r(toInt64(number) - intDiv(toInt64(toUnixTimestamp(pf_day(0))), 30), 'lag')))
FROM numbers(intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30), greatest(0, intDiv(toUnixTimestamp({to_t:DateTime}) + 29, 30) - intDiv(toUnixTimestamp({from_t:DateTime}) + 29, 30)))
ARRAY JOIN [toDateTime(number * 30, 'UTC')] AS t;

--  Contadores acumulados para otel_metrics_sum: cuánto tiempo lleva arriba cada pod y cada nodo
CREATE OR REPLACE VIEW payflow_sim.sum_metrics AS
SELECT
    map('service.name', p.deployment, 'k8s.cluster.name', 'payflow-prod-eu', 'k8s.namespace.name', p.namespace,
        'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name, 'k8s.pod.uid', p.pod_uid,
        'k8s.node.name', p.node_name)                                                                     AS ResourceAttributes,
    p.deployment                                                                                          AS ServiceName,
    'k8s.pod.uptime'                                                                                      AS MetricName,
    'Time since the pod started'                                                                          AS MetricDescription,
    's'                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    toDateTime64(p.started_at, 9, 'UTC')                                                                  AS StartTimeUnix,
    toDateTime64(t, 9, 'UTC')                                                                             AS TimeUnix,
    toFloat64(dateDiff('second', p.started_at, t))                                                        AS Value,
    2                                                                                                     AS AggregationTemporality,   -- acumulado
    true                                                                                                  AS IsMonotonic
FROM payflow_inventory.pod AS p
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 59, 60) * 60, toUnixTimestamp({to_t:DateTime}), 60) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t
WHERE t >= p.started_at AND t <= p.stopped_at
UNION ALL
SELECT map('k8s.cluster.name', 'payflow-prod-eu', 'k8s.node.name', n.node_name), '', 'k8s.node.uptime',
       'Time since the node started', 's', map(), toDateTime64(pf_day(-45), 9, 'UTC'), toDateTime64(t, 9, 'UTC'),
       toFloat64(dateDiff('second', pf_day(-45), t)), 2, true
FROM payflow_inventory.node AS n
ARRAY JOIN range(intDiv(toUnixTimestamp({from_t:DateTime}) + 59, 60) * 60, toUnixTimestamp({to_t:DateTime}), 60) AS ts
ARRAY JOIN [toDateTime(ts, 'UTC')] AS t;


-- PASO 3 · Enviar las métricas del mes
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = pf_day(-29), to_t = pf_day(-19));
-- Medido: 15,2 s · 57 823 filas leídas (464,8 KB) · 9,5 M filas escritas · 9,5 GB de memoria
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = pf_day(-19), to_t = pf_day(-9));
-- Medido: 14,8 s · 57 823 filas leídas (464,8 KB) · 9,5 M filas escritas · 9,7 GB de memoria
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = pf_day(-9), to_t = pf_day(1));
-- Medido: 14,9 s · 57 823 filas leídas (464,8 KB) · 9,5 M filas escritas · 9,4 GB de memoria

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
SELECT * FROM payflow_sim.sum_metrics(from_t = pf_day(-29), to_t = pf_day(1));
-- Medido: 6,53 s · 87 filas leídas (4,8 KB) · 2,1 M filas escritas · 2,4 GB de memoria

SELECT MetricName, count() AS points, round(min(Value), 2) AS min_value, round(max(Value), 2) AS max_value
FROM payflow_otel.otel_metrics_gauge
GROUP BY MetricName
ORDER BY MetricName;
-- Medido: 228 ms · 28,4 M filas leídas (949,5 MB) · 300,6 MB de memoria


-- PASO 4 · Las tres señales, una junto a otra, durante un minuto del incidente
SELECT 'logs' AS signal, count() AS records FROM payflow_otel.otel_logs
WHERE Timestamp >= pf_at('14:10') AND Timestamp < pf_at('14:11')
UNION ALL
SELECT 'spans', count() FROM payflow_otel.otel_traces
WHERE Timestamp >= pf_at('14:10') AND Timestamp < pf_at('14:11')
UNION ALL
SELECT 'metric points', count() FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix >= pf_at('14:10') AND TimeUnix < pf_at('14:11');
-- Medido: 56 ms · 5,4 M filas leídas (41,4 MB) · 61,2 MB de memoria


-- PASO 5 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_traces) > 60000000, 'OK', 'KO')                                   AS spans,
    if((SELECT count() FROM (SELECT toDate(Timestamp) AS d FROM payflow_otel.otel_traces WHERE Timestamp < pf_day(1) GROUP BY d HAVING count() > 1000000)) = 30, 'OK', 'KO') AS thirty_days,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'hikaricp.connections.pending') > 20, 'OK', 'KO') AS pool_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'k8s.container.restarts') = 1, 'OK', 'KO')       AS restart_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'k8s.node.memory.usage'
        AND ResourceAttributes['k8s.node.name'] = 'ip-10-0-3-17') > 16 * 1073741824, 'OK', 'KO')                              AS node_pressure,
    -- toda línea de log con trace id apunta a un span que existe
    if((SELECT count() FROM (SELECT TraceId FROM payflow_otel.otel_logs WHERE TraceId != '' AND Timestamp BETWEEN pf_at('14:10:00') AND pf_at('14:10:10') LIMIT 1000)
        WHERE TraceId NOT IN (SELECT TraceId FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN pf_at('14:09:50') AND pf_at('14:10:20'))) = 0, 'OK', 'KO') AS logs_to_traces
SETTINGS select_sequential_consistency = 1;
-- Medido: 652 ms · 84,2 M filas leídas (966,6 MB) · 235,9 MB de memoria
