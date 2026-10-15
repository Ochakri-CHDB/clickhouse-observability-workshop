-- =====================================================================
--  Stop the live stream of module 2 (file 04), at the end of the day
-- =====================================================================
--  The three replay views refresh every minute: as long as they run, the service
--  never idles. Run this file when you are done. To start again:
--      SYSTEM START VIEW payflow_sim.rmv_live_traces;   (and the two others)
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;

SELECT view, status FROM system.view_refreshes WHERE database = 'payflow_sim';
