-- =====================================================================
--  Stop the live stream of module 2 (file 04), at the end of the day
-- =====================================================================
--  The seven live views refresh every minute and run the simulator: stop them when
--  you are done, the service then idles normally. To start again:
--      SYSTEM START VIEW payflow_sim.rmv_live_traces;   (and the six others)
--  Once started, the views fill the minutes they missed, up to 2 hours.
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
SYSTEM STOP VIEW payflow_sim.rmv_live_sums;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_traces;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_logs;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_metrics;

SELECT view, status FROM system.view_refreshes WHERE database = 'payflow_sim' ORDER BY view;
