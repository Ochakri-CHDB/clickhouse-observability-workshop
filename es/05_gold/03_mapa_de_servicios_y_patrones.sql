-- =====================================================================
--  MÓDULO 5 · Gold: el mapa de servicios y los patrones de logs
-- =====================================================================
--  Dos cosas que nadie declara pero que los datos saben:
--    · quién llama a quién: cada span apunta a su padre. Unir los spans hijos con
--      su padre entre servicios distintos da el grafo de dependencias, con el
--      tráfico, los errores y la latencia de cada arista.
--    · qué dicen los logs: millones de líneas, pero unas pocas decenas de mensajes.
--      Sustituye las partes variables (ids, números) por <*> y cuenta los patrones.
-- =====================================================================


-- PASO 1 · El mapa de servicios, por tramos de 5 minutos
--  Aristas entre servicios: un span de servidor cuyo padre vive en otro servicio.
--  Aristas hacia las dependencias: spans cliente hacia postgres, redis y las redes de tarjetas.
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
        SELECT TraceId, SpanId, ServiceName FROM payflow_otel.otel_traces WHERE SpanKind IN ('Server', 'Producer')
    ) AS p ON p.TraceId = c.TraceId AND p.SpanId = c.ParentSpanId
    WHERE c.SpanKind IN ('Server', 'Consumer') AND c.ParentSpanId != '' AND p.ServiceName != c.ServiceName

    UNION ALL

    SELECT toStartOfFiveMinutes(toDateTime(Timestamp)), ServiceName,
           concat(SpanAttributes['db.system'] != '' ? SpanAttributes['db.system'] : 'https', ' ', SpanAttributes['server.address']),
           StatusCode = 'Error', Duration
    FROM payflow_otel.otel_traces
    WHERE SpanKind = 'Client'
)
GROUP BY bucket, caller, callee;

SYSTEM WAIT VIEW payflow_sre.rmv_service_map;

SELECT caller, callee, sum(calls) AS calls_per_day, round(100 * sum(errors) / sum(calls), 2) AS error_pct, max(p95_ms) AS worst_p95_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY caller, calls_per_day DESC;
-- Medido: 36 ms · 4 618 filas leídas (117,8 KB)
-- Qué observar: 16 aristas. Nadie ha dibujado este mapa: sale de las trazas.
-- La arista payment → postgres payments-db es la que lleva los errores.


-- PASO 2 · El mapa durante el incidente frente a una hora antes
SELECT caller, callee,
       sumIf(calls, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00')                AS calls_before,
       sumIf(calls, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 15:00:00')                AS calls_during,
       maxIf(p95_ms, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00')               AS p95_before_ms,
       maxIf(p95_ms, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00')               AS p95_during_ms
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 6;
-- Medido: 4 ms · 4 618 filas leídas (99,7 KB)
-- Qué observar: las aristas cuya latencia se ha disparado. La de la base de datos va primera,
-- fraud-scoring la sigue: los reintentos también la ralentizan (un segundo fuego, más pequeño).


-- PASO 3 · Patrones de logs por servicio, cada 10 minutos
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
WHERE ServiceName NOT IN ('api-gateway', 'k8s-events')   -- los access logs se leen mejor como métricas (status, duración)
GROUP BY bucket, service, severity, pattern;

SYSTEM WAIT VIEW payflow_sre.rmv_log_patterns;

SELECT uniqExact(pattern) AS patterns, sum(n) AS log_lines
FROM payflow_sre.log_patterns_10m;
-- Medido: 12 ms · 3 920 filas leídas (163,7 KB)


-- PASO 4 · Los patrones que solo aparecen durante el incidente
--  Compara 14:00-14:40 con los mismos 40 minutos una hora antes.
SELECT service, severity, pattern,
       sumIf(n, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS during,
       sumIf(n, bucket >= '2026-11-27 12:50:00' AND bucket < '2026-11-27 13:30:00') AS before
FROM payflow_sre.log_patterns_10m
GROUP BY service, severity, pattern
HAVING during > 10 * greatest(before, 1)
ORDER BY during DESC
LIMIT 10;
-- Medido: 5 ms · 3 920 filas leídas (186,9 KB)
-- Qué observar: el timeout de HikariPool va primero, con diferencia. Después los errores
-- de checkout que solo lo retransmiten, los warnings de fraud-scoring y su OOM. La causa
-- raíz es el patrón NUEVO más frecuente del servicio en fallo situado más arriba en la cadena.


-- PASO 5 · Checkpoint
SELECT
    if((SELECT uniqExact(caller, callee) FROM payflow_sre.service_map_5m) >= 12, 'OK', 'KO')                            AS service_map,
    if((SELECT argMax(pattern, n) FROM (SELECT pattern, sum(n) AS n FROM payflow_sre.log_patterns_10m
        WHERE severity = 'ERROR' GROUP BY pattern)) LIKE 'HikariPool%', 'OK', 'KO')                                    AS top_error_pattern
SETTINGS select_sequential_consistency = 1;
-- Medido: 90 ms · 8 539 filas leídas (177,2 KB)
