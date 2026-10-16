-- =====================================================================
--  MODULE 2 · Collecte (4/4) : jusqu'à maintenant, puis en direct, et un interrupteur pour tout casser
-- =====================================================================
--  Le mois simulé se termine par le Black Friday. Entre le Black Friday et aujourd'hui,
--  il reste quelques jours (de un à sept, selon le jour où vous lancez le workshop), et
--  le Live tail de ClickStack, ses "last 15 minutes" et ses alertes ont besoin de données
--  qui arrivent MAINTENANT. Le même simulateur fait les deux :
--    · rattrapage : les jours après le Black Friday, jusqu'à la minute courante (étape 1)
--    · flux en direct : des vues rafraîchissables exécutent le simulateur chaque minute,
--      pour les minutes pas encore écrites (étape 3). Quand un service en veille se
--      réveille, elles comblent le trou toutes seules (jusqu'à 2 heures).
--    · mode panne : trois autres vues rejouent à la place les pires minutes du Black
--      Friday (de 14h05 à 14h35), réduites au quart de leur trafic : les pods v2.4.1
--      défaillants, les timeouts HikariPool et les clients mécontents, maintenant
--  REFRESH EVERY 1 MINUTE APPEND : chaque refresh ajoute des lignes, et les vues
--  matérialisées des modules suivants (agrégats RED, recherche de traces) les voient
--  comme n'importe quel insert. Les logs vont dans la table d'atterrissage de la
--  passerelle : le flux en direct est parsé, enrichi et masqué comme l'historique.
--
--  Attention : réglez la mise en veille de votre service sur 1 heure ou plus. Les vues
--  ne le gardent pas éveillé. Le flux s'arrête seul après 8 heures ;
--  arreter_flux_en_direct.sql l'arrête tout de suite.
-- =====================================================================


-- ÉTAPE 1 · Rattrapage : du lendemain du Black Friday à la minute courante
--  Des fenêtres fixes, coupées à la minute courante : un samedi, les dernières sont
--  vides ; un vendredi, elles couvrent une semaine entière.
INSERT INTO payflow_ingest.agent_records
SELECT * FROM payflow_sim.raw_records(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = least(pf_day(5), toStartOfMinute(now())));
-- Mesuré : 20,7 s · 8 M lignes lues (2,7 Go) · 4,8 M lignes écrites · 5,7 Go de mémoire
INSERT INTO payflow_ingest.agent_records
SELECT * FROM payflow_sim.raw_records(from_t = least(pf_day(5), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Mesuré : 16,9 s · 5 M lignes lues (1,7 Go) · 3 M lignes écrites · 3,7 Go de mémoire

INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) REPLACE (mapUpdate(ResourceAttributes, map('service.team', dictGet('payflow_inventory.dict_service', 'team', ServiceName))) AS ResourceAttributes)
FROM payflow_sim.spans(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Mesuré : 22,9 s · 10,2 M lignes lues (444,3 Mo) · 10,2 M lignes écrites · 9,7 Go de mémoire

INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
SELECT * FROM payflow_sim.gauge_metrics(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Mesuré : 10 s · 37 275 lignes lues (304,3 Ko) · 6,1 M lignes écrites · 5,7 Go de mémoire

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
SELECT * FROM payflow_sim.sum_metrics(from_t = least(pf_day(1), toStartOfMinute(now())), to_t = toStartOfMinute(now()));
-- Mesuré : 2,34 s · 87 lignes lues (4,8 Ko) · 453 887 lignes écrites · 527,5 Mo de mémoire

SELECT toDate(Timestamp) AS day, toDayOfWeek(day) AS dow, count() AS spans
FROM payflow_otel.otel_traces
WHERE Timestamp >= pf_day(-2)
GROUP BY day
ORDER BY day;
-- Mesuré : 257 ms · 34,5 M lignes lues (263,3 Mo) · 202 Mo de mémoire
-- À observer : le Black Friday, puis chaque jour jusqu'à aujourd'hui, le dernier partiel.


-- ÉTAPE 2 · L'interrupteur de panne
--  Une ligne par changement. La dernière ligne gagne : enabled = 1 signifie panne.
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


-- ÉTAPE 3 · Le flux en direct : le simulateur, chaque minute
--  Le flux en direct passe par les tables d'atterrissage de la passerelle, comme de vrais
--  agents : les logs par agent_records (fichier 02), les spans et les métriques par trois
--  autres tables Null, le receiver OTLP de la passerelle, dont les vues transmettent aux
--  tables OpenTelemetry. Chaque refresh lit le dernier horodatage d'une table
--  OpenTelemetry pour savoir où il s'est arrêté ; une vue rafraîchissable ne peut pas
--  lire la table dans laquelle elle écrit, les tables d'atterrissage règlent aussi cela.
CREATE OR REPLACE TABLE payflow_ingest.otlp_spans AS payflow_otel.otel_traces ENGINE = Null;
CREATE OR REPLACE TABLE payflow_ingest.otlp_gauge AS payflow_otel.otel_metrics_gauge ENGINE = Null;
CREATE OR REPLACE TABLE payflow_ingest.otlp_sum AS payflow_otel.otel_metrics_sum ENGINE = Null;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_spans TO payflow_otel.otel_traces AS SELECT * FROM payflow_ingest.otlp_spans;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_gauge TO payflow_otel.otel_metrics_gauge AS SELECT * FROM payflow_ingest.otlp_gauge;
CREATE OR REPLACE MATERIALIZED VIEW payflow_ingest.mv_otlp_sum TO payflow_otel.otel_metrics_sum AS SELECT * FROM payflow_ingest.otlp_sum;

--  from_minute : la première minute pas encore écrite (le dernier horodatage de la table,
--  moins 30 s pour les spans et les lignes qui se terminent après leur minute), au plus
--  2 heures en arrière. to_minute : la minute courante, ou from_minute (rien) en mode panne.
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
SETTINGS select_sequential_consistency = 1;   -- lire ce que les autres répliques viennent d'écrire

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


-- ÉTAPE 4 · Mode panne : rejouer l'incident, maintenant
--  dst = la minute qui vient de se terminer, src = une minute de l'incident. Une trace
--  sur 4 est gardée (cityHash64(TraceId)) : des traces entières, trois fois le trafic
--  d'une journée ordinaire. Les trace ids reçoivent un suffixe par minute, logs et
--  traces d'une minute rejouée restent liés. Le filtre est dans une sous-requête : les
--  alias de REPLACE sont globaux et le décaleraient aussi.
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
    -- les applications écrivent la date dans la ligne elle-même : on la rejoue avec la date du jour
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


-- ÉTAPE 5 · Est-ce que ça tourne en direct ?
SELECT 'spans' AS signal, count() AS last_5_minutes, max(Timestamp) AS latest FROM payflow_otel.otel_traces WHERE Timestamp >= now() - INTERVAL 5 MINUTE
UNION ALL
SELECT 'logs', count(), max(Timestamp) FROM payflow_otel.otel_logs WHERE Timestamp >= now() - INTERVAL 5 MINUTE
UNION ALL
SELECT 'metric points', count(), max(TimeUnix) FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix >= now() - INTERVAL 5 MINUTE;
-- Mesuré : 12 ms · 726 010 lignes lues (5,5 Mo)
-- À observer : les minutes juste avant maintenant, horodatées à l'heure courante. Dans
-- ClickStack, "Last 15 minutes" montre le trafic en direct.

SELECT view, status, last_success_time, next_refresh_time, written_rows
FROM system.view_refreshes
WHERE database = 'payflow_sim'
ORDER BY view;
-- Mesuré : 2 ms · 31 lignes lues (13,5 Ko)


-- ÉTAPE 6 · Checkpoint
SELECT
    if((SELECT count() FROM system.view_refreshes WHERE database = 'payflow_sim' AND status != 'Error') = 7, 'OK', 'KO') AS seven_live_views,
    if((SELECT max(Timestamp) FROM payflow_otel.otel_traces) BETWEEN now() - INTERVAL 3 MINUTE AND now(), 'OK', 'KO')      AS up_to_now,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp >= now() - INTERVAL 5 MINUTE) > 100, 'OK', 'KO')     AS live_spans,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp >= now() - INTERVAL 5 MINUTE) > 50, 'OK', 'KO')        AS live_logs,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp > now() + INTERVAL 1 MINUTE) = 0, 'OK', 'KO')        AS nothing_in_the_future
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 101 ms · 316 246 lignes lues (2,4 Mo)

--  Pour casser la production (module 5), depuis n'importe quel onglet SQL :
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
--  Pour réparer :
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
