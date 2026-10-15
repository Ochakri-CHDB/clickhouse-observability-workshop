-- =====================================================================
--  Detener el flujo en directo del módulo 2 (fichero 04), al final del día
-- =====================================================================
--  Las tres vistas de reproducción se refrescan cada minuto: mientras corren, el
--  servicio nunca entra en reposo. Ejecuta este fichero al terminar. Para reanudar:
--      SYSTEM START VIEW payflow_sim.rmv_live_traces;   (y las otras dos)
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;

SELECT view, status FROM system.view_refreshes WHERE database = 'payflow_sim';
