-- =====================================================================
--  Arrêter le flux en direct du module 2 (fichier 04), en fin de journée
-- =====================================================================
--  Les trois vues de rejeu se rafraîchissent chaque minute : tant qu'elles tournent,
--  le service ne se met jamais en veille. Lancez ce fichier quand vous avez fini.
--  Pour relancer :
--      SYSTEM START VIEW payflow_sim.rmv_live_traces;   (et les deux autres)
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;

SELECT view, status FROM system.view_refreshes WHERE database = 'payflow_sim';
