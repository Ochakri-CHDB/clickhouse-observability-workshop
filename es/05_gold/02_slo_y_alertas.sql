-- =====================================================================
--  MÓDULO 5 · Gold: SLO, tasa de consumo (burn rate) del presupuesto de errores y alertas
-- =====================================================================
--  Un SLO convierte "¿funciona?" en una cifra. El gateway promete un 99,95 %
--  de pagos correctos: el presupuesto de errores es el 0,05 % de las peticiones.
--  La tasa de consumo (burn rate) dice a qué velocidad se gasta: 1 = justo dentro
--  del presupuesto en el mes, 14,4 = el presupuesto de todo el mes gastado en 2 días.
--  Alertas multiventana (Google SRE workbook): aviso (page) cuando TANTO la última
--  hora COMO los últimos 5 minutos consumen más rápido que 14,4. La ventana de 1 h
--  evita avisar por un pico aislado, la de 5 min apaga la alerta en cuanto se arregla.
--
--  Las vistas materializadas refrescables recalculan estas tablas según una
--  programación (REFRESH EVERY 1 MINUTE): la herramienta adecuada para ventanas
--  y joins que una vista incremental no puede expresar.
-- =====================================================================


-- PASO 1 · La tasa de consumo, minuto a minuto, para cada ruta del gateway
CREATE OR REPLACE TABLE payflow_sre.slo_burn
(
    minute        DateTime('UTC'),
    route         LowCardinality(String),
    requests      UInt64,
    errors        UInt64,
    slo_target    Float32,
    burn_5m       Float64,
    burn_1h       Float64,
    fast_burn     Bool
)
ENGINE = MergeTree
ORDER BY (route, minute);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_slo_burn
REFRESH EVERY 1 MINUTE
TO payflow_sre.slo_burn AS
WITH dictGet('payflow_ref.dict_service', 'slo_target', 'api-gateway') AS target
SELECT
    minute, route, n_req AS requests, n_err AS errors, target AS slo_target,
    sum(n_err) OVER w5 / greatest(sum(n_req) OVER w5, 1) / (1 - target / 100)   AS burn_5m,
    sum(n_err) OVER w60 / greatest(sum(n_req) OVER w60, 1) / (1 - target / 100) AS burn_1h,
    burn_5m > 14.4 AND burn_1h > 14.4                                             AS fast_burn
FROM
(
    SELECT minute, operation AS route, sum(requests) AS n_req, sum(errors) AS n_err
    FROM payflow_sre.red_1m
    WHERE service = 'api-gateway'
    GROUP BY minute, route
)
WINDOW w5  AS (PARTITION BY route ORDER BY minute ROWS BETWEEN 4 PRECEDING AND CURRENT ROW),
       w60 AS (PARTITION BY route ORDER BY minute ROWS BETWEEN 59 PRECEDING AND CURRENT ROW);

SYSTEM WAIT VIEW payflow_sre.rmv_slo_burn;   -- esperar al primer refresco antes de leer (y antes de las vistas que dependen de ella)

SELECT minute, requests, errors, round(burn_5m, 1) AS burn_5m, round(burn_1h, 1) AS burn_1h, fast_burn
FROM payflow_sre.slo_burn
WHERE route = 'POST /v1/payments' AND minute BETWEEN '2026-11-27 13:56:00' AND '2026-11-27 14:06:00'
ORDER BY minute;
-- Medido: 15 ms · 5 760 filas leídas (208,7 KB)
-- Qué observar: la ventana de 5 min cruza 14,4 a las 13:58, la de 1 h un poco más
-- tarde. La alerta salta cuando ambas lo superan: tiempo de detección, en minutos.


-- PASO 2 · Las reglas de alerta, evaluadas cada minuto
--  Cuatro reglas, una tabla. Cada regla produce FIRING cuando su condición se cumple
--  y RESOLVED cuando deja de cumplirse (lagInFrame compara un minuto con el anterior).
--    · consumo rápido del SLO (fast burn) en una ruta del gateway
--    · latencia p99 de payment.AuthorizePayment por encima de 1 s durante 3 minutos seguidos
--    · un contenedor se ha reiniciado (el contador k8s.container.restarts ha subido)
--    · un nodo informa de presión de memoria (evento de Kubernetes)
CREATE OR REPLACE TABLE payflow_sre.alerts
(
    ts        DateTime('UTC'),
    rule      LowCardinality(String),
    severity  LowCardinality(String),
    service   LowCardinality(String),
    state     LowCardinality(String),    -- FIRING / RESOLVED
    summary   String
)
ENGINE = MergeTree
ORDER BY (ts, rule);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.rmv_alerts
REFRESH EVERY 1 MINUTE
DEPENDS ON payflow_sre.rmv_slo_burn
TO payflow_sre.alerts AS
SELECT ts, rule, severity, service, state, summary
FROM
(
    -- regla 1: consumo rápido (fast burn), por ruta
    SELECT minute AS ts, 'slo_fast_burn' AS rule, 'page' AS severity, 'api-gateway' AS service,
           if(fast_burn, 'FIRING', 'RESOLVED') AS state,
           if(fast_burn, concat(route, ': error budget burning ', toString(round(burn_1h)), 'x faster than allowed (1 h window)'),
                         concat(route, ': back under the threshold on the 5 min window (burn ', toString(round(burn_5m, 1)), ')')) AS summary,
           fast_burn != lagInFrame(fast_burn, 1, false) OVER (PARTITION BY route ORDER BY minute) AS changed
    FROM payflow_sre.slo_burn

    UNION ALL

    -- regla 2: p99 por encima de 1 s durante 3 minutos consecutivos
    SELECT minute, 'p99_latency', 'ticket', 'payment', if(slow3, 'FIRING', 'RESOLVED'),
           concat('payment.AuthorizePayment p99 = ', toString(round(p99_ms)), ' ms'),
           slow3 != lagInFrame(slow3, 1, false) OVER (ORDER BY minute)
    FROM
    (
        SELECT minute, p99_ms,
               min(p99_ms) OVER (ORDER BY minute ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) > 1000 AS slow3
        FROM
        (
            SELECT minute, quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 AS p99_ms
            FROM payflow_sre.red_1m
            WHERE service = 'payment' AND operation = 'payment.AuthorizePayment'
            GROUP BY minute
        )
    )

    UNION ALL

    -- regla 3: reinicios de contenedor (el contador solo sube)
    SELECT toDateTime(TimeUnix), 'container_restart', 'ticket', ServiceName, 'FIRING',
           concat(ResourceAttributes['k8s.pod.name'], ' restarted on ', ResourceAttributes['k8s.node.name']),
           Value > lagInFrame(Value, 1, Value) OVER (PARTITION BY ResourceAttributes['k8s.pod.name'] ORDER BY TimeUnix)
    FROM payflow_otel.otel_metrics_sum
    WHERE MetricName = 'k8s.container.restarts'

    UNION ALL

    -- regla 4: presión de memoria del nodo, directamente desde los eventos de Kubernetes
    SELECT toDateTime(Timestamp), 'node_memory_pressure', 'ticket', 'kubernetes',
           if(EventName = 'NodeHasInsufficientMemory', 'FIRING', 'RESOLVED'), Body, true
    FROM payflow_otel.otel_logs
    WHERE ServiceName = 'k8s-events' AND EventName IN ('NodeHasInsufficientMemory', 'NodeHasSufficientMemory')
)
WHERE changed;

SYSTEM WAIT VIEW payflow_sre.rmv_alerts;

SELECT ts, rule, severity, service, state, summary
FROM payflow_sre.alerts
ORDER BY ts;
-- Medido: 26 ms · 11 filas leídas (1 KB)
-- Qué observar: todo el incidente en una docena de líneas. El primer aviso (page), el
-- ticket de latencia, la presión de memoria del nodo, el reinicio por OOM y las líneas RESOLVED.


-- PASO 3 · Tiempo medio de detección
SELECT
    toDateTime('2026-11-27 13:58:00', 'UTC')                                                  AS deployed,
    (SELECT min(ts) FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'FIRING') AS first_page,
    dateDiff('minute', deployed, first_page)                                                   AS minutes_to_detect;
-- Medido: 4 ms · 12 filas leídas


-- PASO 4 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'FIRING') >= 1, 'OK', 'KO') AS page_fired,
    if((SELECT count() FROM payflow_sre.alerts WHERE rule = 'container_restart') = 1, 'OK', 'KO')                    AS restart_alert,
    if((SELECT max(ts) FROM payflow_sre.alerts WHERE rule = 'slo_fast_burn' AND state = 'RESOLVED') > '2026-11-27 14:40:00', 'OK', 'KO') AS resolved
SETTINGS select_sequential_consistency = 1;
-- Medido: 23 ms · 34 filas leídas
