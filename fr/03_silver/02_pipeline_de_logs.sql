-- =====================================================================
--  MODULE 3 · Silver : des logs bruts de conteneurs aux logs OpenTelemetry
-- =====================================================================
--  Un seul pipeline de parsing, écrit une fois, appliqué à chaque ligne à l'ingestion :
--    · détecter la sévérité, quel que soit le langage (nginx, Go, Java, Python)
--    · extraire le trace id et le span id, pour relier chaque log à sa trace
--    · garder le message dans Body, transformer les champs utiles en LogAttributes
--    · masquer les numéros de carte (PCI DSS) AVANT que la ligne soit stockée en silver
--  Des vues matérialisées font ce travail à chaque INSERT dans bronze : pas de batch,
--  pas de stream processor, c'est la base qui s'en charge (règle mv-incremental).
-- =====================================================================


-- ÉTAPE 1 · Les règles de parsing, sous forme de fonctions SQL
--  Écrites une fois, utilisées par la vue matérialisée ET par le backfill plus bas.
--  Sévérité : Go écrit {"level":"error"}, Java " ERROR ", Python "ERROR:",
--  nginx seulement un statut HTTP. On normalise vers les noms OpenTelemetry.
CREATE OR REPLACE FUNCTION pf_log_severity AS (line) ->
    replaceRegexpOne(replaceRegexpOne(upper(multiIf(
        startsWith(line, '{'),                       JSONExtractString(line, 'level'),
        match(line, '^\\d{4}-\\d{2}-\\d{2} '),       extract(line, '^\\S+ \\S+\\s+([A-Z]+) '),
        match(line, '^[A-Z]+:'),                     extract(line, '^([A-Z]+):'),
        match(line, '" \\d{3} '),                    multiIf(extract(line, '" (\\d)\\d{2} ') = '5', 'ERROR', extract(line, '" (\\d)\\d{2} ') = '4', 'WARN', 'INFO'),
        'INFO')), '^WARNING$', 'WARN'), '^CRITICAL$', 'FATAL');

CREATE OR REPLACE FUNCTION pf_severity_number AS (sev) ->
    toUInt8(multiIf(sev = 'TRACE', 1, sev = 'DEBUG', 5, sev = 'INFO', 9, sev = 'WARN', 13, sev = 'ERROR', 17, sev = 'FATAL', 21, 0));

--  Trace id et span id : tous les formats les écrivent en trace_id=..., "trace_id":"..."
CREATE OR REPLACE FUNCTION pf_log_trace_id AS (line) -> extract(line, 'trace_id[=":]+([0-9a-f]{32})');
CREATE OR REPLACE FUNCTION pf_log_span_id  AS (line) -> extract(line, 'span_id[=":]+([0-9a-f]{16})');

--  Le message : le champ "msg" en JSON, le texte après " : " en Java,
--  après le logger en Python, la ligne entière pour nginx.
CREATE OR REPLACE FUNCTION pf_log_body AS (line) ->
    multiIf(startsWith(line, '{'), concat(JSONExtractString(line, 'msg'),
                                          if(JSONHas(line, 'error'), concat(': ', JSONExtractString(line, 'error')), '')),
            match(line, '^\\d{4}-\\d{2}-\\d{2} '), substring(line, position(line, ' : ') + 3),   -- Java : le texte après " : "
            match(line, '^[A-Z]+:[a-z._]+:'), replaceRegexpOne(replaceRegexpOne(line, '^[A-Z]+:[a-z._]+:', ''), ' trace_id=[0-9a-f]+$', ''),
            line);

--  Le logger ("scope" OpenTelemetry) : classe Java, logger Python, caller Go
CREATE OR REPLACE FUNCTION pf_log_scope AS (line) ->
    multiIf(startsWith(line, '{'), JSONExtractString(line, 'caller'),
            match(line, '^\\d{4}-\\d{2}-\\d{2} '), extract(line, '\\] ([A-Za-z0-9_.$]+) '),
            match(line, '^[A-Z]+:[a-z._]+:'), extract(line, '^[A-Z]+:([a-z._]+):'),
            'nginx.access');

--  Champs structurés : toutes les clés d'une ligne JSON, les paires clé=valeur ailleurs,
--  et les champs de l'access log pour nginx. extractKeyValuePairs fait le travail k=v.
CREATE OR REPLACE FUNCTION pf_log_attributes AS (line) ->
    multiIf(startsWith(line, '{'),
                mapFilter((k, v) -> k NOT IN ('level', 'ts', 'msg', 'error', 'caller', 'trace_id', 'span_id'),
                          mapFromArrays(arrayMap(x -> x.1, JSONExtractKeysAndValuesRaw(line)),
                                        arrayMap(x -> trim(BOTH '"' FROM x.2), JSONExtractKeysAndValuesRaw(line)))),
            match(line, '" \\d{3} '),
                map('client.address', extract(line, '^(\\S+) '),
                    'http.request.method', extract(line, '"([A-Z]+) '),
                    'url.path', extract(line, '"[A-Z]+ (\\S+) '),
                    'http.response.status_code', extract(line, '" (\\d{3}) '),
                    'http.server.request.duration', extract(line, 'rt=([0-9.]+)'),
                    'user_agent.original', extract(line, '"[^"]*" "([^"]*)"')),
            mapFilter((k, v) -> k NOT IN ('trace_id', 'span_id'), extractKeyValuePairs(pf_log_body(line), '=', ' ,', '"')));

--  PCI DSS : garder les 6 premiers et les 4 derniers chiffres de tout nombre de 13 à 19 chiffres
CREATE OR REPLACE FUNCTION pf_mask_pan AS (s) -> replaceRegexpAll(s, '\\b([0-9]{6})[0-9]{3,9}([0-9]{4})\\b', '\\1******\\2');

SELECT
    line,
    pf_log_severity(line) AS severity,
    pf_log_trace_id(line) AS trace_id,
    pf_mask_pan(pf_log_body(line)) AS body,
    pf_log_scope(line) AS scope,
    pf_log_attributes(line) AS attributes
FROM
(
    SELECT JSONExtractString(payload, 'log') AS line
    FROM payflow_raw.log_records
    WHERE source = 'fluent-bit' AND received_at BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:01'
      AND payload NOT LIKE '%health%'
    LIMIT 1 BY JSONExtractString(payload, 'kubernetes', 'labels', 'app'), pf_log_severity(JSONExtractString(payload, 'log'))
)
FORMAT Vertical;
-- Mesuré : 14 ms · 8 192 lignes lues (3,9 Mo)
-- À observer : une ligne par service et par sévérité. Cinq formats en entrée, un seul modèle
-- en sortie.


-- ÉTAPE 2 · Les vues matérialisées : bronze → silver, à chaque insert
--  Une vue matérialisée est un trigger : chaque bloc inséré dans payflow_raw.log_records
--  passe par ce SELECT, et le résultat est écrit dans otel_logs.
--  Deux vues, une par source, écrivent dans la même table.
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_container_logs TO payflow_otel.otel_logs AS
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC')   AS Timestamp,
    pf_log_trace_id(line)                                                     AS TraceId,
    pf_log_span_id(line)                                                      AS SpanId,
    toUInt8(TraceId != '')                                                    AS TraceFlags,
    pf_log_severity(line)                                                     AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')                 AS ServiceName,
    pf_mask_pan(pf_log_body(line))                                            AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    map('service.name', ServiceName,
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', ServiceName,
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production')                          AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    pf_log_scope(line)                                                        AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))          AS LogAttributes,
    ''                                                                        AS EventName
FROM payflow_raw.log_records
WHERE source = 'fluent-bit';

--  Les événements Kubernetes deviennent aussi des log records, avec la raison en EventName
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_k8s_events TO payflow_otel.otel_logs AS
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'firstTimestamp'), 9, 'UTC') AS Timestamp,
    ''                                                                        AS TraceId,
    ''                                                                        AS SpanId,
    toUInt8(0)                                                                AS TraceFlags,
    if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO')        AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    'k8s-events'                                                              AS ServiceName,
    JSONExtractString(payload, 'message')                                     AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    map('k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'involvedObject', 'namespace'),
        'k8s.node.name', JSONExtractString(payload, 'source', 'host'),
        'k8s.pod.name', if(JSONExtractString(payload, 'involvedObject', 'kind') = 'Pod', JSONExtractString(payload, 'involvedObject', 'name'), ''),
        'deployment.environment.name', 'production')                          AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    'k8sobjects'                                                              AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    map('k8s.event.reason', JSONExtractString(payload, 'reason'),
        'k8s.event.type', JSONExtractString(payload, 'type'),
        'k8s.object.kind', JSONExtractString(payload, 'involvedObject', 'kind'),
        'k8s.object.name', JSONExtractString(payload, 'involvedObject', 'name'),
        'k8s.event.source', JSONExtractString(payload, 'source', 'component'))    AS LogAttributes,
    JSONExtractString(payload, 'reason')                                      AS EventName
FROM payflow_raw.log_records
WHERE source = 'k8s-events';


-- ÉTAPE 3 · Backfill : les vues ne voient que les NOUVEAUX inserts
--  Bronze contient déjà la journée jusqu'à 20h00, chargée avant la création des vues.
--  On la rejoue une fois avec les mêmes règles, en deux lots (chacun sous 60 s).
--  Le SELECT est celui de la vue : écrit avec les fonctions, il reste court.
INSERT INTO payflow_otel.otel_logs
    (Timestamp, TraceId, SpanId, TraceFlags, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes)
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC'),
    pf_log_trace_id(line), pf_log_span_id(line), toUInt8(pf_log_trace_id(line) != ''),
    pf_log_severity(line), pf_severity_number(pf_log_severity(line)),
    JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
    pf_mask_pan(pf_log_body(line)),
    map('service.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production'),
    pf_log_scope(line),
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND received_at < '2026-11-27 12:00:00';
-- Mesuré : 4,86 s · 2,1 M lignes lues (1000,3 Mo) · 2,1 M lignes écrites · 6,2 Go de mémoire

INSERT INTO payflow_otel.otel_logs
    (Timestamp, TraceId, SpanId, TraceFlags, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes)
WITH JSONExtractString(payload, 'log') AS line
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC'),
    pf_log_trace_id(line), pf_log_span_id(line), toUInt8(pf_log_trace_id(line) != ''),
    pf_log_severity(line), pf_severity_number(pf_log_severity(line)),
    JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
    pf_mask_pan(pf_log_body(line)),
    map('service.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'service.version', JSONExtractString(payload, 'kubernetes', 'labels', 'version'),
        'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'kubernetes', 'namespace_name'),
        'k8s.deployment.name', JSONExtractString(payload, 'kubernetes', 'labels', 'app'),
        'k8s.pod.name', JSONExtractString(payload, 'kubernetes', 'pod_name'),
        'k8s.pod.uid', JSONExtractString(payload, 'kubernetes', 'pod_id'),
        'k8s.container.name', JSONExtractString(payload, 'kubernetes', 'container_name'),
        'k8s.node.name', JSONExtractString(payload, 'kubernetes', 'host'),
        'deployment.environment.name', 'production'),
    pf_log_scope(line),
    mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line))
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND received_at >= '2026-11-27 12:00:00';
-- Mesuré : 7,88 s · 3,9 M lignes lues (1,8 Go) · 3,9 M lignes écrites · 7,5 Go de mémoire

--  Les événements Kubernetes : quelques centaines de lignes
INSERT INTO payflow_otel.otel_logs
    (Timestamp, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, ScopeName, LogAttributes, EventName)
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'firstTimestamp'), 9, 'UTC'),
    if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO'),
    pf_severity_number(if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO')),
    'k8s-events',
    JSONExtractString(payload, 'message'),
    map('k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', JSONExtractString(payload, 'involvedObject', 'namespace'),
        'k8s.node.name', JSONExtractString(payload, 'source', 'host'),
        'k8s.pod.name', if(JSONExtractString(payload, 'involvedObject', 'kind') = 'Pod', JSONExtractString(payload, 'involvedObject', 'name'), ''),
        'deployment.environment.name', 'production'),
    'k8sobjects',
    map('k8s.event.reason', JSONExtractString(payload, 'reason'),
        'k8s.event.type', JSONExtractString(payload, 'type'),
        'k8s.object.kind', JSONExtractString(payload, 'involvedObject', 'kind'),
        'k8s.object.name', JSONExtractString(payload, 'involvedObject', 'name'),
        'k8s.event.source', JSONExtractString(payload, 'source', 'component')),
    JSONExtractString(payload, 'reason')
FROM payflow_raw.log_records
WHERE source = 'k8s-events';
-- Mesuré : 68 ms · 4 334 lignes lues (1,6 Mo) · 354 lignes écrites


-- ÉTAPE 4 · Le flux continu : la soirée arrive
--  À partir de maintenant, plus rien à faire : on insère la soirée dans bronze,
--  les deux vues remplissent silver dans la même transaction.
INSERT INTO payflow_raw.log_records SELECT * FROM payflow_sim.raw_records(from_s = 72000, to_s = 86400);   -- 20h00 à 24h00
-- Mesuré : 18,7 s · 4,3 M lignes lues (2 Go) · 4,3 M lignes écrites · 4,8 Go de mémoire

SELECT toStartOfHour(Timestamp) AS hour, count() AS log_records, countIf(SeverityText = 'ERROR') AS errors
FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 18:00:00'
GROUP BY hour
ORDER BY hour;
-- Mesuré : 37 ms · 6 M lignes lues (49 Mo) · 145,8 Mo de mémoire
-- À observer : les heures de 20h00 à 23h00 ont été écrites par les vues, sans aucun job.


-- ÉTAPE 5 · Le masquage a-t-il fonctionné ?
SELECT
    countIf(match(Body, '\\b[0-9]{13,19}\\b'))       AS full_pans_in_silver,
    countIf(Body LIKE '%pan=%******%')                AS masked_pans,
    any(if(Body LIKE '%pan=%', Body, NULL))           AS example
FROM payflow_otel.otel_logs
WHERE ServiceName = 'card-network-adapter';
-- Mesuré : 63 ms · 5,7 M lignes lues (373,3 Mo) · 308,8 Mo de mémoire
-- À observer : aucun numéro de carte complet en silver, tous sont masqués.


-- ÉTAPE 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_logs) = (SELECT count() FROM payflow_raw.log_records), 'OK', 'KO') AS one_log_per_record,
    if((SELECT countIf(match(Body, '\\b[0-9]{13,19}\\b')) FROM payflow_otel.otel_logs) = 0, 'OK', 'KO')       AS pci_masking,
    if((SELECT countIf(TraceId != '') / count() FROM payflow_otel.otel_logs) > 0.85, 'OK', 'KO')            AS trace_ids,
    if((SELECT max(Timestamp) FROM payflow_otel.otel_logs) > '2026-11-27 23:59:00', 'OK', 'KO')             AS continuous_flow
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 219 ms · 16,3 M lignes lues (755,6 Mo) · 225,8 Mo de mémoire
