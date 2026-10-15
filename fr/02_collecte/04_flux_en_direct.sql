-- =====================================================================
--  MODULE 2 · Collecte (4/4) : un flux en direct, et un interrupteur pour tout casser
-- =====================================================================
--  La journée du Black Friday est du passé : elle est datée du 27 novembre 2026. Le Live
--  tail de ClickStack, ses "last 15 minutes" et ses alertes ont besoin de données qui
--  arrivent MAINTENANT. Trois vues rafraîchissables rejouent chaque minute une minute de
--  trafic enregistré, décalée à l'heure courante (rejeu de trafic) :
--    · mode normal : une heure calme de la journée (de 10h00 à 11h00)
--    · mode panne : les pires minutes de l'incident (de 14h05 à 14h35), avec les pods
--      v2.4.1 défaillants, les timeouts HikariPool et les clients mécontents
--  Les trace ids reçoivent un suffixe par minute : logs et traces du flux restent liés.
--  REFRESH EVERY 1 MINUTE APPEND : chaque refresh ajoute des lignes, et les vues
--  matérialisées des modules suivants (agrégats RED, recherche de traces) les voient
--  comme n'importe quel insert.
--
--  Attention : une vue rafraîchie chaque minute empêche le service de se mettre en veille.
--  Le flux s'arrête seul après 8 heures ; arreter_flux_en_direct.sql l'arrête tout de suite.
-- =====================================================================


-- ÉTAPE 1 · L'interrupteur de panne
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


-- ÉTAPE 2 · Les trois vues de rejeu : spans, logs, métriques des pods et du pool
--  src = la minute enregistrée à rejouer, dst = la minute qui vient de se terminer.
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
    -- filtre en sous-requête : les alias REPLACE ci-dessus sont globaux, ils décaleraient le filtre
    SELECT * FROM payflow_otel.otel_traces
    WHERE Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND toDate(Timestamp) = '2026-11-27'      -- ne jamais rejouer les lignes déjà rejouées
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- lire ce que les autres répliques viennent d'écrire

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
    -- filtre en sous-requête : les alias REPLACE ci-dessus sont globaux, ils décaleraient le filtre
    SELECT * FROM payflow_otel.otel_logs
    WHERE Timestamp >= src AND Timestamp < src + INTERVAL 1 MINUTE
      AND toDate(Timestamp) = '2026-11-27'
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- lire ce que les autres répliques viennent d'écrire

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
    -- filtre en sous-requête : les alias REPLACE ci-dessus sont globaux, ils décaleraient le filtre
    SELECT * FROM payflow_otel.otel_metrics_gauge
    WHERE TimeUnix >= src AND TimeUnix < src + INTERVAL 1 MINUTE
      AND toDate(TimeUnix) = '2026-11-27'
      AND now() < live_until
)
SETTINGS select_sequential_consistency = 1;   -- lire ce que les autres répliques viennent d'écrire

SYSTEM WAIT VIEW payflow_sim.rmv_live_traces;
SYSTEM WAIT VIEW payflow_sim.rmv_live_logs;
SYSTEM WAIT VIEW payflow_sim.rmv_live_metrics;


-- ÉTAPE 3 · Est-ce que ça tourne en direct ?
SELECT 'spans' AS signal, count() AS last_minutes, max(Timestamp) AS latest FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()
UNION ALL
SELECT 'logs', count(), max(Timestamp) FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()
UNION ALL
SELECT 'metric points', count(), max(TimeUnix) FROM payflow_otel.otel_metrics_gauge WHERE TimeUnix BETWEEN now() - INTERVAL 5 MINUTE AND now();
-- Mesuré : 9 ms · 76 317 lignes lues (596,2 Ko)
-- À observer : une minute de trafic calme par minute (environ 9 000 spans et 3 000 lignes
-- de log), à l'heure courante. Dans ClickStack, "Last 15 minutes" montre maintenant du trafic
-- en direct.
-- Attention : la journée du Black Friday est datée dans le futur jusqu'au 27 novembre 2026.
-- Un filtre comme Timestamp > now() - INTERVAL 5 MINUTE l'attraperait aussi : bornez
-- toujours des deux côtés.

SELECT view, status, last_success_time, next_refresh_time, written_rows
FROM system.view_refreshes
WHERE database = 'payflow_sim';
-- Mesuré : 1 ms · 31 lignes lues (13,5 Ko)


-- ÉTAPE 4 · Checkpoint
SELECT
    if((SELECT count() FROM system.view_refreshes WHERE database = 'payflow_sim' AND status != 'Error') = 3, 'OK', 'KO') AS three_live_views,
    if((SELECT count() FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 500, 'OK', 'KO')  AS live_spans,
    if((SELECT count() FROM payflow_otel.otel_logs WHERE Timestamp BETWEEN now() - INTERVAL 5 MINUTE AND now()) > 200, 'OK', 'KO')    AS live_logs
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 30 ms · 73 745 lignes lues (589,4 Ko)

--  Pour casser la production (module 5), depuis n'importe quel onglet SQL :
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
--  Pour réparer :
--      INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
