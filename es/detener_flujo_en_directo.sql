-- =====================================================================
--  Detener el flujo en directo del módulo 2 (fichero 04), al final del día
-- =====================================================================
--  Las siete vistas en directo se refrescan cada minuto y ejecutan el simulador:
--  detenlas al terminar, y el servicio entrará en reposo con normalidad. Para reanudar:
--      SYSTEM START VIEW payflow_sim.rmv_live_traces;   (y las otras seis)
--  Una vez reanudadas, las vistas rellenan los minutos que se perdieron, hasta 2 horas.
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
SYSTEM STOP VIEW payflow_sim.rmv_live_sums;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_traces;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_logs;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_metrics;

SELECT view, status FROM system.view_refreshes WHERE database = 'payflow_sim' ORDER BY view;
