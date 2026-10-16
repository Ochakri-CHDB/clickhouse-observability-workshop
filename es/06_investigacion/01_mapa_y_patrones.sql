-- =====================================================================
--  MÓDULO 6 · Investigación (1/2): el mapa de servicios y los patrones de eventos, por dentro
-- =====================================================================
--  Dos vistas de ClickStack hacen la primera mitad de una investigación:
--    · Service Map: quién llama a quién, reconstruido a partir de los spans padre e hijo
--    · Event Patterns: millones de líneas de log agrupadas en unas pocas decenas de mensajes
--  ClickStack los calcula al consultar. Aquí los calculamos en SQL, para ver cómo,
--  y los guardamos por 5 o 10 minutos para dashboards y alertas. En el colector, el
--  conector servicegraph hace el primero, en memoria.
--  Las dos vistas solo leen el día de Black Friday: su coste no crece con el flujo.
-- =====================================================================


-- PASO 1 · El mapa de servicios, por 5 minutos
--  Aristas entre servicios: un span de servidor cuyo padre (el span de cliente del que
--  llama) vive en otro servicio. Así es también como los empareja el Service Map de ClickStack.
--  Aristas hacia dependencias: spans de cliente hacia postgres, redis y las redes de tarjetas.
CREATE OR REPLACE TABLE payflow_sre.service_map_5m
(
    bucket     DateTime('UTC'),
    caller     LowCardinality(String),
    callee     LowCardinality(String),
    calls      UInt64,
    errors     UInt64,
    p95_ms     Float64
)
ENGINE = MergeTree
ORDER BY (caller, callee, bucket);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_service_map
REFRESH EVERY 10 MINUTE
TO payflow_sre.service_map_5m AS
SELECT bucket, caller, callee, count() AS calls, countIf(failed) AS errors, round(quantile(0.95)(duration_ns) / 1e6, 1) AS p95_ms
FROM
(
    SELECT toStartOfFiveMinutes(toDateTime(c.Timestamp)) AS bucket, p.ServiceName AS caller, c.ServiceName AS callee,
           c.StatusCode = 'Error' AS failed, c.Duration AS duration_ns
    FROM payflow_otel.otel_traces AS c
    INNER JOIN
    (
        SELECT TraceId, SpanId, ServiceName FROM payflow_otel.otel_traces WHERE SpanKind IN ('Client', 'Producer') AND toDate(Timestamp) = pf_black_friday()
    ) AS p ON p.TraceId = c.TraceId AND p.SpanId = c.ParentSpanId
    WHERE c.SpanKind IN ('Server', 'Consumer') AND c.ParentSpanId != '' AND p.ServiceName != c.ServiceName
      AND toDate(c.Timestamp) = pf_black_friday()

    UNION ALL

    SELECT toStartOfFiveMinutes(toDateTime(Timestamp)), ServiceName,
           concat(SpanAttributes['db.system'] != '' ? SpanAttributes['db.system'] : 'https', ' ', SpanAttributes['server.address']),
           StatusCode = 'Error', Duration
    FROM payflow_otel.otel_traces
    WHERE SpanKind = 'Client' AND toDate(Timestamp) = pf_black_friday()
      AND SpanAttributes['rpc.system'] = ''   -- las llamadas a otro servicio se cuentan arriba, desde su span de servidor
)
GROUP BY bucket, caller, callee;

SYSTEM WAIT VIEW payflow_sre.rmv_service_map;

SELECT caller, callee, sum(calls) AS calls_per_day, round(100 * sum(errors) / sum(calls), 2) AS error_pct, max(p95_ms) AS worst_p95_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY caller, calls_per_day DESC;
-- Medido: 18 ms · 4 608 filas leídas (117,5 KB)
-- Qué observar: 16 aristas. Nadie ha dibujado este mapa: sale de las trazas.
-- La arista payment → postgres payments-db concentra los errores.


-- PASO 2 · El mapa durante el incidente frente a una hora antes
SELECT caller, callee,
       sumIf(calls, bucket >= pf_at('12:45') AND bucket < pf_at('13:45'))                AS calls_before,
       sumIf(calls, bucket >= pf_at('14:00') AND bucket < pf_at('15:00'))                AS calls_during,
       maxIf(p95_ms, bucket >= pf_at('12:45') AND bucket < pf_at('13:45'))               AS p95_before_ms,
       maxIf(p95_ms, bucket >= pf_at('14:00') AND bucket < pf_at('14:40'))               AS p95_during_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 6;
-- Medido: 9 ms · 4 609 filas leídas (99,5 KB)
-- Qué observar: las aristas cuya latencia se ha disparado. La de la base de datos va
-- primera, fraud-scoring la sigue: los reintentos también la ralentizan (un segundo
-- fuego, más pequeño).


-- PASO 3 · Patrones de log por servicio, cada 10 minutos
--  replaceRegexpAll convierte ids y números en <*>: millones de líneas, unas decenas de patrones.
CREATE OR REPLACE FUNCTION pf_log_pattern AS (body) ->
    replaceRegexpAll(replaceRegexpAll(body, '(pay|m)_[0-9a-f]+|[0-9a-f]{16,}|\\*{6}', '<*>'), '[0-9]+([.:/][0-9]+)*', '<*>');

CREATE OR REPLACE TABLE payflow_sre.log_patterns_10m
(
    bucket    DateTime('UTC'),
    service   LowCardinality(String),
    severity  LowCardinality(String),
    pattern   String,
    n         UInt64,
    example   String
)
ENGINE = MergeTree
ORDER BY (service, severity, bucket);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_log_patterns
REFRESH EVERY 10 MINUTE
TO payflow_sre.log_patterns_10m AS
SELECT
    toStartOfTenMinutes(toDateTime(Timestamp)) AS bucket,
    ServiceName                                AS service,
    SeverityText                               AS severity,
    pf_log_pattern(Body)                       AS pattern,
    count()                                    AS n,
    any(Body)                                  AS example
FROM payflow_otel.otel_logs
WHERE ServiceName NOT IN ('api-gateway', 'k8s-events')   -- los logs de acceso se leen mejor como métricas (status, duración)
  AND toDate(Timestamp) = pf_black_friday()
GROUP BY bucket, service, severity, pattern;

SYSTEM WAIT VIEW payflow_sre.rmv_log_patterns;

SELECT uniqExact(pattern) AS patterns, sum(n) AS log_lines
FROM payflow_sre.log_patterns_10m;
-- Medido: 17 ms · 2 760 filas leídas (133,1 KB)


-- PASO 4 · Los patrones que solo aparecen durante el incidente
--  Comparamos 14:00-14:40 con los mismos 40 minutos una hora antes.
SELECT service, severity, pattern,
       sumIf(n, bucket >= pf_at('14:00') AND bucket < pf_at('14:40')) AS during,
       sumIf(n, bucket >= pf_at('12:50') AND bucket < pf_at('13:30')) AS before
FROM payflow_sre.log_patterns_10m
GROUP BY service, severity, pattern
HAVING during > 10 * greatest(before, 1)
ORDER BY during DESC
LIMIT 10;
-- Medido: 8 ms · 2 761 filas leídas (149,5 KB)
-- Qué observar: el timeout de HikariPool va primero, de lejos. Después los errores de
-- checkout que solo lo repiten, los avisos de fraud-scoring y su OOM. La causa raíz
-- es el patrón NUEVO más frecuente del servicio con fallos más arriba en la cadena.


-- PASO 5 · Checkpoint
SELECT
    if((SELECT uniqExact(caller, callee) FROM payflow_sre.service_map_5m) >= 12, 'OK', 'KO')                            AS service_map,
    if((SELECT argMax(pattern, n) FROM (SELECT pattern, sum(n) AS n FROM payflow_sre.log_patterns_10m
        WHERE severity = 'ERROR' GROUP BY pattern)) LIKE 'HikariPool%', 'OK', 'KO')                                    AS top_error_pattern
SETTINGS select_sequential_consistency = 1;
-- Medido: 40 ms · 7 369 filas leídas (145,4 KB)
