-- =====================================================================
--  Arrêter le flux en direct du module 2 (fichier 04), en fin de journée
-- =====================================================================
--  Les sept vues du direct se rafraîchissent chaque minute et exécutent le simulateur :
--  arrêtez-les quand vous avez fini, le service se met alors en veille normalement.
--  Pour relancer :
--      SYSTEM START VIEW payflow_sim.rmv_live_traces;   (et les six autres)
--  Une fois relancées, les vues comblent les minutes manquées, jusqu'à 2 heures.
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
SYSTEM STOP VIEW payflow_sim.rmv_live_sums;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_traces;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_logs;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_metrics;

SELECT view, status FROM system.view_refreshes WHERE database = 'payflow_sim' ORDER BY view;
