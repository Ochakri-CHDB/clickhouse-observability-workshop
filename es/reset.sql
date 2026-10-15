-- =====================================================================
--  RESET · Borra todo lo que creó el taller, y nada más
-- =====================================================================
--  Solo los objetos llamados payflow_* (bases de datos, usuario, roles, policies) y
--  las funciones SQL pf_*. Las vistas del flujo en directo viven en payflow_sim:
--  borrarla las detiene. Las demás bases de datos del servicio no se tocan.

-- Las row policies y los roles sobreviven a DROP DATABASE: se borran primero
DROP ROW POLICY IF EXISTS pf_payments_logs ON payflow_otel.otel_logs;
DROP ROW POLICY IF EXISTS pf_payments_traces ON payflow_otel.otel_traces;
DROP ROLE IF EXISTS payflow_team_payments;
DROP ROLE IF EXISTS payflow_agent_role;
DROP SETTINGS PROFILE IF EXISTS payflow_agent_profile;

-- Sin SYNC: la tabla de mil millones de líneas del módulo 7 tarda minutos en borrarse
-- del almacenamiento de objetos. Sin SYNC el DROP vuelve al instante y los ficheros se
-- borran en segundo plano; las bases de datos se pueden volver a crear enseguida.
-- payflow_sim primero: contiene las vistas del flujo en directo que escriben en las demás
DROP DATABASE IF EXISTS payflow_sim;
DROP DATABASE IF EXISTS payflow_sre;
DROP DATABASE IF EXISTS payflow_otel;
DROP DATABASE IF EXISTS payflow_ingest;
DROP DATABASE IF EXISTS payflow_inventory;
DROP USER IF EXISTS payflow_dict;

DROP FUNCTION IF EXISTS pf_r;
DROP FUNCTION IF EXISTS pf_rate;
DROP FUNCTION IF EXISTS pf_payment_version;
DROP FUNCTION IF EXISTS pf_zone;
DROP FUNCTION IF EXISTS pf_trace_id;
DROP FUNCTION IF EXISTS pf_span_id;
DROP FUNCTION IF EXISTS pf_ts_iso;
DROP FUNCTION IF EXISTS pf_ts_java;
DROP FUNCTION IF EXISTS pf_ts_nginx;
DROP FUNCTION IF EXISTS pf_pan;
DROP FUNCTION IF EXISTS pf_log_severity;
DROP FUNCTION IF EXISTS pf_severity_number;
DROP FUNCTION IF EXISTS pf_log_trace_id;
DROP FUNCTION IF EXISTS pf_log_span_id;
DROP FUNCTION IF EXISTS pf_log_body;
DROP FUNCTION IF EXISTS pf_log_scope;
DROP FUNCTION IF EXISTS pf_log_attributes;
DROP FUNCTION IF EXISTS pf_mask_pan;
DROP FUNCTION IF EXISTS pf_log_pattern;
DROP FUNCTION IF EXISTS pf_pod_from_path;
DROP FUNCTION IF EXISTS pf_k8s_resource;
DROP FUNCTION IF EXISTS pf_is_health_check;
