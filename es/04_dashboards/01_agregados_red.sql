-- =====================================================================
--  MÓDULO 4 · Dashboards: los agregados (rollups) RED que hay detrás
-- =====================================================================
--  RED = Rate, Errors, Duration: las tres cifras de cualquier servicio, y la primera
--  fila de cualquier dashboard. En el colector, el conector spanmetrics las calcula
--  a partir de los spans. En ClickHouse, una vista materializada incremental hace lo
--  mismo al insertar, de forma exacta y sin balanceador delante de los colectores:
--  estados de agregación parciales, fusionados en segundo plano por AggregatingMergeTree,
--  y terminados por la consulta con -Merge. La documentación de ClickStack lo dice claro:
--  las vistas materializadas pasan el coste del momento de la consulta al de la inserción.
--  Dos salidas:
--    · payflow_sre.red_1m, para los paneles SQL, los SLO y las alertas (módulos 4 y 5)
--    · el histograma spanmetrics en otel_metrics_histogram, tal como lo escribiría el
--      colector, con un exemplar: desde un gráfico de latencia, un clic hasta la traza más lenta
-- =====================================================================


-- PASO 1 · La tabla destino: una fila por servicio, operación y minuto
--  quantilesTDigestState guarda un pequeño resumen de la distribución de latencias:
--  cuantiles de cuantiles serían incorrectos, t-digests fusionados son correctos.
CREATE OR REPLACE TABLE payflow_sre.red_1m
(
    minute       DateTime('UTC'),
    service      LowCardinality(String),
    operation    LowCardinality(String),
    requests     SimpleAggregateFunction(sum, UInt64),
    errors       SimpleAggregateFunction(sum, UInt64),
    latency      AggregateFunction(quantilesTDigest(0.5, 0.95, 0.99), UInt64)   -- nanosegundos
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(minute)
ORDER BY (service, operation, minute);


-- PASO 2 · La vista materializada incremental, a partir de los spans de servidor
CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.mv_red_1m TO payflow_sre.red_1m AS
SELECT
    toStartOfMinute(toDateTime(Timestamp))                AS minute,
    ServiceName                                           AS service,
    SpanName                                              AS operation,
    count()                                               AS requests,
    countIf(StatusCode = 'Error')                         AS errors,
    quantilesTDigestState(0.5, 0.95, 0.99)(Duration)      AS latency
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY minute, service, operation;


-- PASO 3 · Rellenar el mes (backfill): la vista solo ve las inserciones nuevas
--  El flujo en directo sigue escribiendo mientras lees esto. Corte: el minuto anterior
--  a la creación de la vista. Los spans más antiguos vienen de este backfill, los más
--  recientes de la vista: ninguno se cuenta dos veces (como mucho falta un minuto en
--  directo en el agregado).
INSERT INTO payflow_sre.red_1m
SELECT
    toStartOfMinute(toDateTime(Timestamp)), ServiceName, SpanName,
    count(), countIf(StatusCode = 'Error'), quantilesTDigestState(0.5, 0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
  AND Timestamp < (SELECT toStartOfMinute(metadata_modification_time) - INTERVAL 1 MINUTE
                   FROM system.tables WHERE database = 'payflow_sre' AND name = 'mv_red_1m')
GROUP BY 1, 2, 3;
-- Medido: 11,7 s · 76,7 M filas leídas (914,3 MB) · 721 413 filas escritas · 1,6 GB de memoria

SELECT count() AS rollup_rows, (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server' AND toDate(Timestamp) = pf_black_friday()) AS server_spans
FROM payflow_sre.red_1m
WHERE toDate(minute) = pf_black_friday();
-- Medido: 38 ms · 21,5 M filas leídas (86,6 MB) · 67,7 MB de memoria
-- Qué observar: 20 000 filas resumen 8 millones de spans de servidor.


-- PASO 4 · RED del punto de entrada, minuto a minuto, alrededor del incidente
SELECT
    minute,
    sum(requests)                                                       AS n_requests,   -- no "AS requests": un alias es global
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[1] / 1e6)     AS p50_ms,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN pf_at('13:50') AND pf_at('14:55')
GROUP BY minute
ORDER BY minute;
-- Medido: 46 ms · 8 193 filas leídas (1,2 MB)
-- Qué observar: el p99 salta de ~300 ms a 3 s a las 13:58 (el rollout), los errores suben a ~30 %
-- en el pico de la venta flash, y ambos vuelven a bajar a las 14:44. El dashboard del
-- README es esta consulta.


-- PASO 5 · Las mismas cifras directamente desde los spans, para comparar el coste
SELECT
    toStartOfMinute(toDateTime(Timestamp))                              AS minute,
    count()                                                             AS n_requests,
    round(100 * countIf(StatusCode = 'Error') / count(), 2)             AS error_pct,
    round(quantileTDigest(0.99)(Duration) / 1e6)                        AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN pf_at('13:50') AND pf_at('14:55:59')
GROUP BY minute
ORDER BY minute;
-- Medido: 20 ms · 81 921 filas leídas (1,5 MB)
-- Qué observar: la misma curva, 10 veces más filas leídas desde los spans. Aquí los spans
-- están ordenados por servicio y nombre de span, así que la consulta en bruto sigue siendo
-- barata. El agregado marca la diferencia en rangos largos (el mes: 720 000 filas en vez de
-- 30 millones de spans de servidor) y en dashboards que agregan todos los servicios a la vez.


-- PASO 6 · El histograma spanmetrics, legible por ClickStack como una métrica
--  Un histograma OpenTelemetry guarda, para cada intervalo, el recuento por bucket
--  (BucketCounts) para unos límites fijos (ExplicitBounds), más count, sum, min y max.
--  El exemplar guarda el trace id de la petición más lenta del minuto: desde un gráfico
--  de latencia saltas directamente a la traza culpable (README de este módulo).
INSERT INTO payflow_otel.otel_metrics_histogram
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix,
     Count, Sum, BucketCounts, ExplicitBounds, `Exemplars.FilteredAttributes`, `Exemplars.TimeUnix`, `Exemplars.Value`,
     `Exemplars.SpanId`, `Exemplars.TraceId`, Min, Max, AggregationTemporality)
WITH [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] AS bounds
SELECT
    map('service.name', ServiceName, 'k8s.cluster.name', 'payflow-prod-eu')                            AS ResourceAttributes,
    ServiceName,
    'traces.span.metrics.duration'                                                                     AS MetricName,   -- el nombre que usa el conector
    'Duration of server spans, computed from the traces'                                               AS MetricDescription,
    's'                                                                                                AS MetricUnit,
    map('span.name', SpanName, 'span.kind', 'SPAN_KIND_SERVER', 'status.code', if(StatusCode = 'Error', 'STATUS_CODE_ERROR', 'STATUS_CODE_UNSET')) AS Attributes,
    toDateTime64(minute, 9, 'UTC')                                                                     AS StartTimeUnix,
    toDateTime64(minute + 60, 9, 'UTC')                                                                AS TimeUnix,
    count()                                                                                            AS Count,
    sum(Duration / 1e9)                                                                                AS Sum,
    sumForEach(arrayMap(b -> toUInt64(b = arrayFirstIndex(x -> Duration / 1e9 <= x, bounds)), range(1, 13))) AS BucketCounts,
    bounds                                                                                             AS ExplicitBounds,
    [map()]                                                                                            AS `Exemplars.FilteredAttributes`,
    [argMax(Timestamp, Duration)]                                                                      AS `Exemplars.TimeUnix`,
    [max(Duration) / 1e9]                                                                              AS `Exemplars.Value`,
    [argMax(SpanId, Duration)]                                                                         AS `Exemplars.SpanId`,
    [argMax(TraceId, Duration)]                                                                        AS `Exemplars.TraceId`,
    min(Duration / 1e9)                                                                                AS Min,
    max(Duration / 1e9)                                                                                AS Max,
    1                                                                                                  AS AggregationTemporality   -- delta: cada fila cubre su propio minuto
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server' AND Timestamp < toStartOfMinute(now())   -- el mes hasta ahora
GROUP BY ServiceName, SpanName, StatusCode, toStartOfMinute(toDateTime(Timestamp)) AS minute;
-- Medido: 7,4 s · 76,7 M filas leídas (2,7 GB) · 735 932 filas escritas · 2 GB de memoria
-- Atención: arrayFirstIndex devuelve 0 cuando el valor supera el último límite: en ese caso
-- ningún b de 1..12 coincide. Aquí ningún span dura más de 10 s, así que todos caen en un bucket.


-- PASO 7 · Checkpoint
SELECT
    if((SELECT sum(requests) FROM payflow_sre.red_1m WHERE toDate(minute) = pf_black_friday()) = (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server' AND toDate(Timestamp) = pf_black_friday()), 'OK', 'KO') AS no_span_lost,
    if((SELECT count() FROM payflow_otel.otel_metrics_histogram WHERE MetricName = 'traces.span.metrics.duration') > 10000, 'OK', 'KO') AS spanmetrics_histogram,
    if((SELECT max(errors) FROM payflow_sre.red_1m WHERE service = 'payment') > 300, 'OK', 'KO')                                                AS incident_visible
SETTINGS select_sequential_consistency = 1;
-- Medido: 147 ms · 9,9 M filas leídas (96,4 MB) · 76,8 MB de memoria
