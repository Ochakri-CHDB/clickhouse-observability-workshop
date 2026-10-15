-- =====================================================================
--  RESET · Removes everything the workshop created, and nothing else
-- =====================================================================
--  Only objects named payflow_* (databases, user, roles, policies) and the
--  pf_* SQL functions. Other databases of the service are not touched.

-- Row policies and roles survive DROP DATABASE: remove them first
DROP ROW POLICY IF EXISTS pf_payments_logs ON payflow_otel.otel_logs;
DROP ROW POLICY IF EXISTS pf_payments_traces ON payflow_otel.otel_traces;
DROP ROLE IF EXISTS payflow_team_payments;
DROP ROLE IF EXISTS payflow_agent_role;
DROP SETTINGS PROFILE IF EXISTS payflow_agent_profile;

-- No SYNC: the billion-line table of module 6 takes minutes to delete from object
-- storage. Without SYNC the drop returns at once and the files are removed in the
-- background; the databases can be created again immediately.
DROP DATABASE IF EXISTS payflow_sre;
DROP DATABASE IF EXISTS payflow_otel;
DROP DATABASE IF EXISTS payflow_raw;
DROP DATABASE IF EXISTS payflow_sim;
DROP DATABASE IF EXISTS payflow_ref;
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
