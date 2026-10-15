-- =====================================================================
--  RESET · Supprime tout ce que le workshop a créé, et rien d'autre
-- =====================================================================
--  Uniquement les objets nommés payflow_* (bases, utilisateur, rôles, policies) et les
--  fonctions SQL pf_*. Les autres bases du service ne sont pas touchées.

-- Row policies et rôles survivent au DROP DATABASE : on les supprime d'abord
DROP ROW POLICY IF EXISTS pf_payments_logs ON payflow_otel.otel_logs;
DROP ROW POLICY IF EXISTS pf_payments_traces ON payflow_otel.otel_traces;
DROP ROLE IF EXISTS payflow_team_payments;
DROP ROLE IF EXISTS payflow_agent_role;
DROP SETTINGS PROFILE IF EXISTS payflow_agent_profile;

-- Pas de SYNC : la table d'un milliard de lignes du module 6 met plusieurs minutes à
-- disparaître du stockage objet. Sans SYNC, le DROP rend la main tout de suite et les
-- fichiers sont supprimés en arrière-plan ; les bases peuvent être recréées aussitôt.
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
