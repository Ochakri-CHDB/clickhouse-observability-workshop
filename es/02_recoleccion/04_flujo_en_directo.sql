-- =====================================================================
--  MÓDULO 2 · Recolección (4/4): un flujo en directo, y un interruptor de caos
-- =====================================================================
--  El día del Black Friday ya es historia: está fechado el 27 de noviembre de 2026. El
--  Live tail de ClickStack, sus "últimos 15 minutos" y sus alertas necesitan datos que
--  lleguen AHORA. Tres vistas materializadas refrescables reproducen cada minuto un
--  minuto de tráfico grabado, desplazado a la hora actual (traffic replay):
--    · modo normal: una hora tranquila del día (de 10:00 a 11:00)
--    · modo caos: los peores minutos del incidente (de 14:05 a 14:35), con los pods
--      v2.4.1 defectuosos, los timeouts de HikariPool y los clientes enfadados
--  Los trace ids reciben un sufijo por minuto: logs y trazas del flujo siguen enlazados.
--  REFRESH EVERY 1 MINUTE APPEND: cada refresco añade filas, y las vistas materializadas
--  de los módulos siguientes (agregados RED, búsqueda de trazas) las ven como cualquier insert.
--
--  Atención: una vista que se refresca cada minuto mantiene el servicio despierto (sin
--  reposo). El flujo se detiene solo a las 8 horas; detener_flujo_en_directo.sql lo para
--  al instante.
-- =====================================================================


-- PASO 1 · El interruptor
--  Una fila por cambio. Gana la última fila: enabled = 1 significa caos.
CREATE OR REPLACE TABLE payflow_sim.chaos
(
    changed_at   DateTime('UTC') DEFAULT now(),
    enabled      UInt8,
    live_until   DateTime('UTC') DEFAULT now() + INTERVAL 8 HOUR,
    note         String
)
ENGINE = MergeTree
ORDER BY changed_at;

INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'normal traffic');


-- PASO 2 · Las tres vistas de reproducción: spans, logs, métricas de pods y del pool
--  src = el minuto grabado que se reproduce, dst = el minuto que acaba de terminar.
CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_traces
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_traces AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    if(chaos = 1, toDateTime('2026-11-27 14:05:00', 'UTC') + toIntervalMinute(toMinute(now()) % 30),
                  toDateTime('2026-11-27 10:00:00', 'UTC') + toIntervalMinute(toMinute(now()) % 60)) AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    concat(substring(TraceId, 1, 24), salt)                          AS TraceId,
    arrayMap(x -> addSeconds(x, shift), `Events.Timestamp`)          AS `Events.Timestamp`)
FROM
(
    -- filtro en subconsulta: los alias del REPLACE son globales y desplazarían el filtro
    SELECT * FROM payflow_otel.otel_traces
    WHERE Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND toDate(Timestamp) = '2026-11-27'      -- no reproducir nunca las filas ya reproducidas
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- leer lo que las otras réplicas acaban de escribir

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_logs
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_logs AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    if(chaos = 1, toDateTime('2026-11-27 14:05:00', 'UTC') + toIntervalMinute(toMinute(now()) % 30),
                  toDateTime('2026-11-27 10:00:00', 'UTC') + toIntervalMinute(toMinute(now()) % 60)) AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    if(TraceId = '', '', concat(substring(TraceId, 1, 24), salt))    AS TraceId)
FROM
(
    -- filtro en subconsulta: los alias del REPLACE son globales y desplazarían el filtro
    SELECT * FROM payflow_otel.otel_logs
    WHERE Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND toDate(Timestamp) = '2026-11-27'
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- leer lo que las otras réplicas acaban de escribir

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_metrics
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_metrics_gauge AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    if(chaos = 1, toDateTime('2026-11-27 14:05:00', 'UTC') + toIntervalMinute(toMinute(now()) % 30),
                  toDateTime('2026-11-27 10:00:00', 'UTC') + toIntervalMinute(toMinute(now()) % 60)) AS src,
    dateDiff('second', src, dst)                                     AS shift
SELECT * REPLACE (
    addSeconds(StartTimeUnix, shift)                                 AS StartTimeUnix,
    addSeconds(TimeUnix, shift)                                      AS TimeUnix)
FROM
(
    -- filtro en subconsulta: los alias del REPLACE son globales y desplazarían el filtro
    SELECT * FROM payflow_otel.otel_metrics_gauge
    WHERE TimeUnix >= src AND TimeUnix < src + INTERVAL 1 MINUTE
      AND toDate(TimeUnix) = '2026-11-27'
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- leer lo que las otras réplicas acaban de escribir

SYSTEM WAIT VIEW payflow_sim.rmv_live_traces;
SYSTEM WAIT VIEW payflow_sim.rmv_live_logs;
SYSTEM WAIT VIEW payflow_sim.rmv_live_metrics;


-- PASO 3 · ¿Está en directo?
SELECT 'spans' AS signal, count() AS last_minutes, max(Timestamp) AS latest FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()
UNION ALL
SELECT 'logs', count(), max(Timestamp) FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()
UNION ALL
SELECT 'metric points', count(), max(TimeUnix) FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix BETWEEN now() - INTERVAL 5 MINUTE AND now();
-- Medido: 9 ms · 76 317 filas leídas (596,2 KB)
-- Qué observar: un minuto tranquilo de tráfico por minuto (unos 9 000 spans y 3 000 líneas
-- de log), con la hora actual. En ClickStack, "Last 15 minutes" muestra ya tráfico en directo.
-- Atención: el día del Black Friday está fechado en el futuro hasta el 27 de noviembre de
-- 2026. Un filtro como Timestamp > now() - INTERVAL 5 MINUTE también lo capturaría: acota
-- siempre los dos extremos.

SELECT view, status, last_success_time, next_refresh_time, written_rows
FROM system.view_refreshes
WHERE database = 'payflow_sim';
-- Medido: 1 ms · 31 filas leídas (13,5 KB)


-- PASO 4 · Checkpoint
SELECT
    if((SELECT count() FROM system.view_refreshes WHERE database = 'payflow_sim' AND status != 'Error') = 3, 'OK', 'KO') AS three_live_views,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 500, 'OK', 'KO')  AS live_spans,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 200, 'OK', 'KO')    AS live_logs
SETTINGS select_sequential_consistency = 1;
-- Medido: 30 ms · 73 745 filas leídas (589,4 KB)

--  Para romper producción (módulo 5), desde cualquier pestaña SQL:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
--  Para arreglarlo:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
