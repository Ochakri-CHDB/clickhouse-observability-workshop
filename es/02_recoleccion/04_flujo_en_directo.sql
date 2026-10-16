-- =====================================================================
--  MÓDULO 2 · Recolección (4/4): hasta ahora, luego en directo, y un interruptor para romperlo todo
-- =====================================================================
--  El mes simulado termina con Black Friday. Entre Black Friday y hoy quedan
--  unos días más (de uno a siete, según el día en que hagas el taller), y el
--  live tail de ClickStack, sus "últimos 15 minutos" y sus alertas necesitan datos
--  que lleguen AHORA. El mismo simulador hace las dos cosas:
--    · puesta al día: los días posteriores a Black Friday, hasta el minuto actual (paso 1)
--    · flujo en directo: vistas materializadas refrescables ejecutan el simulador cada
--      minuto, para los minutos aún no escritos (paso 3). Cuando un servicio en reposo
--      se despierta, rellenan el hueco por sí solas (hasta 2 horas).
--    · modo caos: otras tres vistas reproducen en su lugar los peores minutos de Black
--      Friday (de 14:05 a 14:35), reducidos a una cuarta parte de su tráfico: los pods
--      v2.4.1 defectuosos, los timeouts de HikariPool y los clientes enfadados, ahora
--  REFRESH EVERY 1 MINUTE APPEND: cada refresco añade filas, y las vistas materializadas
--  de los módulos siguientes (agregados RED, búsqueda de trazas) las ven como cualquier
--  insert. Los logs van a la tabla de aterrizaje de la pasarela: el flujo en directo se
--  parsea, se enriquece y se enmascara como el historial.
--
--  Atención: pon el reposo (idling) de tu servicio a 1 hora o más. Las vistas no lo
--  mantienen despierto. El flujo se detiene solo a las 8 horas; detener_flujo_en_directo.sql
--  lo para al instante.
-- =====================================================================


-- PASO 1 · Puesta al día: desde el día siguiente a Black Friday hasta el minuto actual
--  Ventanas fijas, recortadas al minuto actual: un sábado las últimas están
--  vacías, un viernes cubren una semana entera.
INSERT INTO payflow_ingest.agent_records
SELECT * FROM payflow_sim.raw_records(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = least(pf_day(5), toStartOfMinute(now())));
-- Medido: 20,7 s · 8 M filas leídas (2,7 GB) · 4,8 M filas escritas · 5,7 GB de memoria
INSERT INTO payflow_ingest.agent_records
SELECT * FROM payflow_sim.raw_records(from_t = least(pf_day(5), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Medido: 16,9 s · 5 M filas leídas (1,7 GB) · 3 M filas escritas · 3,7 GB de memoria

INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Medido: 22,9 s · 10,2 M filas leídas (444,3 MB) · 10,2 M filas escritas · 9,7 GB de memoria

INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Medido: 10 s · 37 275 filas leídas (304,3 KB) · 6,1 M filas escritas · 5,7 GB de memoria

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
SELECT * FROM payflow_sim.sum_metrics(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Medido: 2,34 s · 87 filas leídas (4,8 KB) · 453 887 filas escritas · 527,5 MB de memoria

SELECT toDate(Timestamp) AS day, toDayOfWeek(day) AS dow, count() AS spans
FROM payflow_otel.otel_traces
WHERE Timestamp >= pf_day(-2)
GROUP BY day
ORDER BY day;
-- Medido: 257 ms · 34,5 M filas leídas (263,3 MB) · 202 MB de memoria
-- Qué observar: Black Friday, y luego cada día hasta hoy, el último incompleto.


-- PASO 2 · El interruptor
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


-- PASO 3 · El flujo en directo: el simulador, cada minuto
--  El flujo en directo pasa por tablas de aterrizaje de la pasarela, como agentes reales:
--  los logs por agent_records (fichero 02), los spans y las métricas por otras tres tablas
--  Null, el receptor OTLP de la pasarela, cuyas vistas los reenvían a las tablas
--  OpenTelemetry. Cada refresco lee la última marca de tiempo de una tabla OpenTelemetry
--  para saber dónde se quedó; una vista refrescable no puede leer la tabla en la que
--  escribe, y las tablas de aterrizaje resuelven también eso.
CREATE OR REPLACE TABLE payflow_ingest.otlp_spans AS payflow_otel.otel_traces ENGINE = Null;
CREATE OR REPLACE TABLE payflow_ingest.otlp_gauge AS payflow_otel.otel_metrics_gauge ENGINE = Null;
CREATE OR REPLACE TABLE payflow_ingest.otlp_sum AS payflow_otel.otel_metrics_sum ENGINE = Null;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_spans TO payflow_otel.otel_traces AS SELECT * FROM payflow_ingest.otlp_spans;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_gauge TO payflow_otel.otel_metrics_gauge AS SELECT * FROM payflow_ingest.otlp_gauge;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_sum TO payflow_otel.otel_metrics_sum AS SELECT * FROM payflow_ingest.otlp_sum;

--  from_minute: el primer minuto aún no escrito (la última marca de tiempo de la tabla,
--  menos 30 s para los spans y las líneas que terminan después de su minuto), como mucho
--  2 horas atrás. to_minute: el minuto actual, o from_minute (nada) en modo caos.
CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_logs
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.agent_records AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(Timestamp) - INTERVAL 30 SECOND) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 3 HOUR AND now()), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(chaos = 0 AND now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * FROM payflow_sim.raw_records(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;   -- leer lo que las otras réplicas acaban de escribir

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_traces
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.otlp_spans AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(Timestamp) - INTERVAL 30 SECOND) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 3 HOUR AND now()), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(chaos = 0 AND now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_metrics
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.otlp_gauge AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(TimeUnix)) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix BETWEEN now() - INTERVAL 3 HOUR AND now()
          AND MetricName = 'k8s.node.condition_ready'), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(chaos = 0 AND now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * FROM payflow_sim.gauge_metrics(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_live_sums
REFRESH EVERY 1 MINUTE APPEND TO payflow_ingest.otlp_sum AS
WITH
    (SELECT argMax(live_until, changed_at) FROM payflow_sim.chaos)   AS live_until,
    toStartOfMinute(now())                                           AS until_minute,
    greatest(until_minute - INTERVAL 2 HOUR, ifNull((SELECT toStartOfMinute(max(TimeUnix)) + INTERVAL 1 MINUTE
        FROM payflow_otel.otel_metrics_sum WHERE TimeUnix BETWEEN now() - INTERVAL 3 HOUR AND now()), until_minute - INTERVAL 2 HOUR)) AS from_minute,
    if(now() < live_until, greatest(from_minute, until_minute), from_minute) AS to_minute
SELECT * FROM payflow_sim.sum_metrics(from_t = from_minute, to_t = to_minute)
SETTINGS select_sequential_consistency = 1;


-- PASO 4 · Modo caos: reproducir el incidente, ahora
--  dst = el minuto que acaba de terminar, src = un minuto del incidente. Se conserva una
--  traza de cada 4 (cityHash64(TraceId)): trazas enteras, tres veces el tráfico de un día
--  ordinario. Los trace ids reciben un sufijo por minuto: logs y trazas de un minuto
--  reproducido siguen enlazados.
--  El filtro va en una subconsulta: los alias del REPLACE son globales y también lo desplazarían.
CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_chaos_traces
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_traces AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    pf_at('14:05') + toIntervalMinute(toMinute(dst) % 30)            AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    concat(substring(TraceId, 1, 24), salt)                          AS TraceId,
    arrayMap(x -> addSeconds(x, shift), `Events.Timestamp`)          AS `Events.Timestamp`)
FROM
(
    SELECT * FROM payflow_otel.otel_traces
    WHERE chaos = 1 AND Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE AND cityHash64(TraceId) % 4 = 0
)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_chaos_logs
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_logs AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    pf_at('14:05') + toIntervalMinute(toMinute(dst) % 30)            AS src,
    dateDiff('second', src, dst)                                     AS shift,
    leftPad(lower(hex(toUInt32(toUnixTimestamp(dst)))), 8, '0')      AS salt
SELECT * REPLACE (
    addSeconds(Timestamp, shift)                                     AS Timestamp,
    if(TraceId = '', '', concat(substring(TraceId, 1, 24), salt))    AS TraceId,
    -- las aplicaciones imprimen la fecha en la propia línea: se reproduce con la fecha de hoy
    replaceAll(replaceAll(Body, toString(toDate(src)), toString(toDate(dst))),
               formatDateTime(src, '%d/%b/%Y'), formatDateTime(dst, '%d/%b/%Y')) AS Body)
FROM
(
    SELECT * FROM payflow_otel.otel_logs
    WHERE chaos = 1 AND Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND ServiceName != 'k8s-events' AND (TraceId = '' OR cityHash64(TraceId) % 4 = 0)
)
SETTINGS select_sequential_consistency = 1;

CREATE OR REPLACE MATERIALIZED VIEW payflow_sim.rmv_chaos_metrics
REFRESH EVERY 1 MINUTE APPEND TO payflow_otel.otel_metrics_gauge AS
WITH
    (SELECT argMax(enabled, changed_at) FROM payflow_sim.chaos)      AS chaos,
    toStartOfMinute(now()) - INTERVAL 1 MINUTE                       AS dst,
    pf_at('14:05') + toIntervalMinute(toMinute(dst) % 30)            AS src,
    dateDiff('second', src, dst)                                     AS shift
SELECT * REPLACE (
    addSeconds(StartTimeUnix, shift)                                 AS StartTimeUnix,
    addSeconds(TimeUnix, shift)                                      AS TimeUnix)
FROM
(
    SELECT * FROM payflow_otel.otel_metrics_gauge
    WHERE chaos = 1 AND TimeUnix >= src AND TimeUnix < src + INTERVAL 1 MINUTE
)
SETTINGS select_sequential_consistency = 1;

SYSTEM WAIT VIEW payflow_sim.rmv_live_logs;
SYSTEM WAIT VIEW payflow_sim.rmv_live_traces;
SYSTEM WAIT VIEW payflow_sim.rmv_live_metrics;
SYSTEM WAIT VIEW payflow_sim.rmv_live_sums;


-- PASO 5 · ¿Está en directo?
SELECT 'spans' AS signal, count() AS last_5_minutes, max(Timestamp) AS latest FROM payflow_otel.otel_traces WHERE Timestamp >= now() - INTERVAL 5 MINUTE
UNION ALL
SELECT 'logs', count(), max(Timestamp) FROM payflow_otel.otel_logs WHERE Timestamp >= now() - INTERVAL 5 MINUTE
UNION ALL
SELECT 'metric points', count(), max(TimeUnix) FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix >= now() - INTERVAL 5 MINUTE;
-- Medido: 12 ms · 726 010 filas leídas (5,5 MB)
-- Qué observar: los minutos justo antes de ahora, con la hora actual. En
-- ClickStack, "Last 15 minutes" muestra tráfico en directo.

SELECT view, status, last_success_time, next_refresh_time, written_rows
FROM system.view_refreshes
WHERE database = 'payflow_sim'
ORDER BY view;
-- Medido: 2 ms · 31 filas leídas (13,5 KB)


-- PASO 6 · Checkpoint
SELECT
    if((SELECT count() FROM system.view_refreshes WHERE database = 'payflow_sim' AND status != 'Error') = 7, 'OK', 'KO') AS seven_live_views,
    if((SELECT max(Timestamp) FROM payflow_otel.otel_traces) BETWEEN now() - INTERVAL 3 MINUTE AND now(), 'OK', 'KO')      AS up_to_now,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp >= now() - INTERVAL 5 MINUTE) > 100, 'OK', 'KO')     AS live_spans,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp >= now() - INTERVAL 5 MINUTE) > 50, 'OK', 'KO')        AS live_logs,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp > now() + INTERVAL 1 MINUTE) = 0, 'OK', 'KO')        AS nothing_in_the_future
SETTINGS select_sequential_consistency = 1;
-- Medido: 101 ms · 316 246 filas leídas (2,4 MB)

--  Para romper producción (módulo 5), desde cualquier pestaña SQL:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
--  Para arreglarlo:
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
