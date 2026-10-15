-- =====================================================================
--  MÓDULO 5 · Gold: métricas RED, actualizadas en cada insert
-- =====================================================================
--  RED = Rate, Errors, Duration: las tres cifras que vigila un SRE en cada
--  servicio. Calcularlas a partir de 14 millones de spans en cada refresco de
--  dashboard sería un despilfarro. Una vista materializada incremental las guarda
--  por minuto, como estados de agregación parciales: AggregatingMergeTree fusiona
--  los estados en segundo plano y la consulta termina la agregación con -Merge.
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


-- PASO 3 · Backfill del día: la vista solo ve los inserts nuevos
INSERT INTO payflow_sre.red_1m
SELECT
    toStartOfMinute(toDateTime(Timestamp)), ServiceName, SpanName,
    count(), countIf(StatusCode = 'Error'), quantilesTDigestState(0.5, 0.95, 0.99)(Duration)
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY 1, 2, 3;
-- Medido: 1,25 s · 14,6 M filas leídas (186,7 MB) · 20 165 filas escritas · 308,1 MB de memoria

SELECT count() AS rows_gold, (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server') AS server_spans
FROM payflow_sre.red_1m;
-- Medido: 12 ms · 14,6 M filas leídas (13,9 MB) · 89,1 MB de memoria
-- Qué observar: unas decenas de miles de filas resumen millones de spans.


-- PASO 4 · RED del punto de entrada, minuto a minuto, en torno al incidente
SELECT
    minute,
    sum(requests)                                                       AS n_requests,   -- no "AS requests": un alias es global
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[1] / 1e6)     AS p50_ms,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:55:00'
GROUP BY minute
ORDER BY minute;
-- Medido: 27 ms · 8 192 filas leídas (1,2 MB)
-- Qué observar: el p99 salta de ~300 ms a 3 s a las 13:58 (el rollout), los errores suben
-- a ~30 % en el pico de la venta flash y ambos bajan a las 14:44. El dashboard del módulo 8
-- es esta consulta.


-- PASO 5 · Las mismas cifras directamente desde los spans, para comparar el coste
SELECT
    toStartOfMinute(toDateTime(Timestamp))                              AS minute,
    count()                                                             AS n_requests,
    round(100 * countIf(StatusCode = 'Error') / count(), 2)             AS error_pct,
    round(quantileTDigest(0.99)(Duration) / 1e6)                        AS p99_ms
FROM payflow_otel.otel_traces
WHERE ServiceName = 'api-gateway' AND SpanName = 'POST /v1/payments'
  AND Timestamp BETWEEN '2026-11-27 13:50:00' AND '2026-11-27 14:55:59'
GROUP BY minute
ORDER BY minute;
-- Medido: 39 ms · 81 920 filas leídas (1,5 MB)
-- Qué observar: la misma curva, con 10 veces más filas leídas desde los spans. Aquí los spans
-- están ordenados por servicio y nombre de span, así que la consulta en bruto sigue siendo barata.
-- Gold marca la diferencia en rangos largos (un mes: 20 000 filas en lugar de 400 millones de
-- spans) y en dashboards que agregan todos los servicios a la vez.


-- PASO 6 · Checkpoint
SELECT
    if((SELECT sum(requests) FROM payflow_sre.red_1m) = (SELECT count() FROM payflow_otel.otel_traces WHERE SpanKind = 'Server'), 'OK', 'KO') AS no_span_lost,
    if((SELECT max(errors) FROM payflow_sre.red_1m WHERE service = 'payment') > 300, 'OK', 'KO')                                                AS incident_visible
SETTINGS select_sequential_consistency = 1;
-- Medido: 39 ms · 11,3 M filas leídas (11 MB) · 84,3 MB de memoria
