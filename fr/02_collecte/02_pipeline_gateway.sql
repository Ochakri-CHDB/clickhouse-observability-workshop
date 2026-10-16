-- =====================================================================
--  MODULE 2 · Collecte (2/4) : la passerelle (gateway), en SQL
-- =====================================================================
--  En production, les agents envoient à un collecteur dans le rôle de passerelle (le
--  collecteur ClickStack), qui fait tourner des processeurs avant l'exporteur ClickHouse :
--      filter → transform → k8sattributes → redaction → batch → clickhouse exporter
--  Ici la passerelle tourne dans ClickHouse, comme le suggère la documentation ClickHouse
--  pour les traitements lourds : une table d'atterrissage avec le moteur Null (elle ne
--  stocke rien), et des vues matérialisées qui traitent chaque bloc inséré sur son chemin
--  vers les tables OpenTelemetry. Chaque vue joue un ou plusieurs processeurs :
--    · filter        écarte les health checks du kubelet (du bruit, une part du volume)
--    · transform     parse 4 formats de log : sévérité, trace id, message, attributs
--    · k8sattributes ajoute déploiement, version, nœud, zone et équipe à partir du nom du pod
--    · redaction     masque les numéros de carte ; table Null : aucune ligne brute stockée
--    · routing       logs de conteneurs et événements Kubernetes prennent des chemins différents
--    · count         un connecteur : compte tout par service et par minute, avant le filtre
-- =====================================================================


-- ÉTAPE 1 · La table d'atterrissage de la passerelle
--  ENGINE = Null : un INSERT passe par les vues matérialisées attachées à la table,
--  puis les données sont jetées. Rien n'est stocké deux fois, et les lignes brutes (avec
--  les numéros de carte) ne touchent jamais le disque.
CREATE OR REPLACE TABLE payflow_ingest.agent_records
(
    received_at  DateTime64(3, 'UTC'),
    source       LowCardinality(String),       -- filelog (logs de conteneurs) ou k8sobjects (événements)
    payload      String
)
ENGINE = Null;


-- ÉTAPE 2 · transform : les règles de parsing, sous forme de fonctions SQL
--  Dans le collecteur, c'est le processeur transform (instructions OTTL) ou les opérateurs
--  de filelog. ClickHouse recommande de faire ce travail dans la base : c'est plus rapide
--  et moins cher que dans le collecteur, et changer une règle ne demande pas de redéployer
--  les agents. Sévérité : Go écrit {"level":"error"}, Java " ERROR ", Python "ERROR:",
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

--  Trace id et span id : tous les formats les écrivent trace_id=..., "trace_id":"..."
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
    FROM payflow_sim.raw_records(from_t = pf_at('14:10:00'), to_t = pf_at('14:10:01'))
    WHERE source = 'filelog' AND payload NOT LIKE '%health%'
    LIMIT 1 BY splitByChar('/', JSONExtractString(payload, 'log.file.path'))[6], pf_log_severity(JSONExtractString(payload, 'log'))
)
FORMAT Vertical;
-- Mesuré : 643 ms · 225 lignes lues (12,8 Ko) · 60,6 Mo de mémoire
-- À observer : une ligne par service et par sévérité. Cinq formats en entrée, un seul modèle
-- en sortie.

--  k8sattributes : l'agent ne connaît que le chemin du fichier. La passerelle le parse, puis
--  demande le reste au catalogue (dictionnaires du module 1), comme le processeur interroge
--  l'API Kubernetes.
CREATE OR REPLACE FUNCTION pf_pod_from_path AS (path) -> splitByChar('_', splitByChar('/', path)[5])[2];

CREATE OR REPLACE FUNCTION pf_k8s_resource AS (path) ->
    map('service.name',               dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)),
        'service.version',            dictGet('payflow_inventory.dict_pod', 'version', pf_pod_from_path(path)),
        'service.team',               dictGet('payflow_inventory.dict_service', 'team', dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path))),
        'k8s.cluster.name',           'payflow-prod-eu',
        'k8s.namespace.name',         splitByChar('_', splitByChar('/', path)[5])[1],
        'k8s.deployment.name',        dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)),
        'k8s.pod.name',               pf_pod_from_path(path),
        'k8s.pod.uid',                splitByChar('_', splitByChar('/', path)[5])[3],
        'k8s.container.name',         splitByChar('/', path)[6],
        'k8s.node.name',              dictGet('payflow_inventory.dict_pod', 'node_name', pf_pod_from_path(path)),
        'cloud.availability_zone',    dictGet('payflow_inventory.dict_node', 'zone', dictGet('payflow_inventory.dict_pod', 'node_name', pf_pod_from_path(path))),
        'deployment.environment.name', 'production');

--  filter : les probes du kubelet, comme le processeur filter les écarterait
CREATE OR REPLACE FUNCTION pf_is_health_check AS (line) ->
    line LIKE '%GET /healthz%' OR line LIKE '%health status UP%' OR line LIKE '%"msg":"health check"%';


-- ÉTAPE 3 · Les processeurs, sous forme de vues matérialisées sur la table d'atterrissage
--  Logs de conteneurs : filter, puis transform, k8sattributes et redaction en un seul SELECT.
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_gateway_logs TO payflow_otel.otel_logs AS
WITH JSONExtractString(payload, 'log') AS line,
     JSONExtractString(payload, 'log.file.path') AS path
SELECT
    parseDateTime64BestEffort(JSONExtractString(payload, 'time'), 9, 'UTC')   AS Timestamp,
    pf_log_trace_id(line)                                                     AS TraceId,
    pf_log_span_id(line)                                                      AS SpanId,
    toUInt8(TraceId != '')                                                    AS TraceFlags,
    pf_log_severity(line)                                                     AS SeverityText,
    pf_severity_number(SeverityText)                                          AS SeverityNumber,
    dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(path)) AS ServiceName,
    pf_mask_pan(pf_log_body(line))                                            AS Body,
    ''                                                                        AS ResourceSchemaUrl,
    pf_k8s_resource(path)                                                     AS ResourceAttributes,
    ''                                                                        AS ScopeSchemaUrl,
    pf_log_scope(line)                                                        AS ScopeName,
    ''                                                                        AS ScopeVersion,
    map()                                                                     AS ScopeAttributes,
    mapUpdate(mapApply((k, v) -> (k, pf_mask_pan(v)), pf_log_attributes(line)),
              map('log.file.path', path, 'log.iostream', JSONExtractString(payload, 'stream'))) AS LogAttributes,
    ''                                                                        AS EventName
FROM payflow_ingest.agent_records
WHERE source = 'filelog' AND NOT pf_is_health_check(JSONExtractString(payload, 'log'));

--  routing : les événements Kubernetes prennent un autre chemin, avec leur raison en EventName
CREATE OR REPLACE MATERIALIZED VIEW payflow_otel.mv_gateway_k8s_events TO payflow_otel.otel_logs AS
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
        'k8s.event.source', JSONExtractString(payload, 'source', 'component'),
        -- ce que lit la Pod Timeline de ClickStack : l'événement tel que le renvoie l'API events.k8s.io
        'k8s.resource.name', 'events',
        'object', toJSONString(CAST((
            tuple(JSONExtractString(payload, 'firstTimestamp')),
            JSONExtractString(payload, 'reason'), JSONExtractString(payload, 'message'), JSONExtractString(payload, 'type'),
            (JSONExtractString(payload, 'involvedObject', 'kind'), JSONExtractString(payload, 'involvedObject', 'name'),
             JSONExtractString(payload, 'involvedObject', 'namespace'),
             dictGetOrDefault('payflow_inventory.dict_pod', 'pod_uid', JSONExtractString(payload, 'involvedObject', 'name'), ''))),
            'Tuple(metadata Tuple(creationTimestamp String), reason String, note String, type String, regarding Tuple(kind String, name String, namespace String, uid String))')))
                                                                              AS LogAttributes,
    JSONExtractString(payload, 'reason')                                      AS EventName
FROM payflow_ingest.agent_records
WHERE source = 'k8sobjects';

--  count : un connecteur. Il compte chaque enregistrement par minute, service et sévérité,
--  gardé ou écarté par le filtre. C'est ainsi qu'on voit ce que le filtre économise.
CREATE OR REPLACE TABLE payflow_sre.log_volume_1m
(
    minute     DateTime('UTC'),
    service    LowCardinality(String),
    severity   LowCardinality(String),
    dropped    Bool,
    records    UInt64,
    bytes      UInt64
)
ENGINE = SummingMergeTree
ORDER BY (service, severity, dropped, minute);

CREATE OR REPLACE MATERIALIZED VIEW payflow_sre.mv_log_volume_1m TO payflow_sre.log_volume_1m AS
WITH JSONExtractString(payload, 'log') AS line
SELECT
    toStartOfMinute(toDateTime(received_at))                                          AS minute,
    if(source = 'k8sobjects', 'k8s-events', dictGet('payflow_inventory.dict_pod', 'deployment', pf_pod_from_path(JSONExtractString(payload, 'log.file.path')))) AS service,
    if(source = 'k8sobjects', if(JSONExtractString(payload, 'type') = 'Warning', 'WARN', 'INFO'), pf_log_severity(line)) AS severity,
    source = 'filelog' AND pf_is_health_check(line)                                   AS dropped,
    count()                                                                           AS records,
    sum(length(payload))                                                              AS bytes
FROM payflow_ingest.agent_records
GROUP BY minute, service, severity, dropped;


-- ÉTAPE 4 · Les agents envoient le mois, à travers la passerelle
--  Chaque INSERT exécute le simulateur, puis les 3 vues : parsing, enrichissement et
--  masquage se font dans la même instruction, sous les 60 s de la console. Les journées
--  ordinaires passent par lots de 4 ou 5 jours ; le Black Friday, douze fois plus
--  chargé, par tiers de journée.
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-29), to_t = pf_day(-25));
-- Mesuré : 18,7 s · 8,1 M lignes lues (2,7 Go) · 4,8 M lignes écrites · 5,8 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-25), to_t = pf_day(-21));
-- Mesuré : 20 s · 9 M lignes lues (3 Go) · 5,4 M lignes écrites · 7,7 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-21), to_t = pf_day(-17));
-- Mesuré : 17,7 s · 8 M lignes lues (2,7 Go) · 4,8 M lignes écrites · 6,1 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-17), to_t = pf_day(-13));
-- Mesuré : 19,4 s · 9 M lignes lues (3 Go) · 5,4 M lignes écrites · 7,6 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-13), to_t = pf_day(-9));
-- Mesuré : 18 s · 8 M lignes lues (2,7 Go) · 4,8 M lignes écrites · 5,8 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-9), to_t = pf_day(-5));
-- Mesuré : 17,5 s · 8,5 M lignes lues (2,9 Go) · 5,1 M lignes écrites · 5,8 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_day(-5), to_t = pf_day(0));
-- Mesuré : 19,6 s · 10,8 M lignes lues (3,6 Go) · 6,5 M lignes écrites · 9 Go de mémoire
--  Black Friday
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_at('00:00'), to_t = pf_at('10:00'));
-- Mesuré : 14,1 s · 4,9 M lignes lues (1,8 Go) · 3,2 M lignes écrites · 4,8 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_at('10:00'), to_t = pf_at('17:00'));
-- Mesuré : 15,7 s · 7,3 M lignes lues (2,6 Go) · 4,8 M lignes écrites · 6,8 Go de mémoire
INSERT INTO payflow_ingest.agent_records SELECT * FROM payflow_sim.raw_records(from_t = pf_at('17:00'), to_t = pf_day(1));
-- Mesuré : 20,5 s · 11,7 M lignes lues (4,3 Go) · 7,7 M lignes écrites · 10,7 Go de mémoire

SELECT count() AS records_in_landing_table FROM payflow_ingest.agent_records;
-- Mesuré : 2 ms
-- À observer : 0. La table Null n'a rien gardé ; tout est dans otel_logs.


-- ÉTAPE 5 · Ce qu'a fait la passerelle
SELECT
    sum(records)                                                    AS received,
    sumIf(records, dropped)                                         AS dropped_by_filter,
    round(100 * sumIf(records, dropped) / sum(records), 1)          AS dropped_pct,
    formatReadableSize(sumIf(bytes, dropped))                       AS bytes_saved
FROM payflow_sre.log_volume_1m;
-- Mesuré : 54 ms · 822 544 lignes lues (13,3 Mo)

SELECT ServiceName, ResourceAttributes['service.version'] AS version, ResourceAttributes['service.team'] AS team,
       ResourceAttributes['cloud.availability_zone'] AS zone, count() AS log_records
FROM payflow_otel.otel_logs
WHERE ServiceName = 'payment' AND Timestamp BETWEEN pf_at('14:00') AND pf_at('14:05')
GROUP BY ALL
ORDER BY log_records DESC;
-- Mesuré : 29 ms · 502 877 lignes lues (3,8 Mo)
-- À observer : l'agent n'a envoyé qu'un chemin de fichier. Version, équipe et zone ont été
-- ajoutées par la passerelle. Pendant le rollout, les deux versions loguent côte à côte.

SELECT
    countIf(match(Body, '\\b[0-9]{13,19}\\b'))       AS full_pans_stored,
    countIf(Body LIKE '%pan=%******%')                AS masked_pans,
    any(if(Body LIKE '%pan=%', Body, NULL))           AS example
FROM payflow_otel.otel_logs
WHERE ServiceName = 'card-network-adapter';
-- Mesuré : 376 ms · 20,7 M lignes lues (1,3 Go) · 324,2 Mo de mémoire
-- À observer : aucun numéro de carte complet stocké, tous sont masqués.


-- ÉTAPE 6 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_ingest.agent_records) = 0, 'OK', 'KO')                                       AS nothing_stored_raw,
    if((SELECT count() FROM payflow_otel.otel_logs) = (SELECT sumIf(records, NOT dropped) FROM payflow_sre.log_volume_1m), 'OK', 'KO') AS every_kept_record_written,
    if((SELECT countIf(match(Body, '\\b[0-9]{13,19}\\b')) FROM payflow_otel.otel_logs) = 0, 'OK', 'KO')       AS pci_masking,
    if((SELECT countIf(ResourceAttributes['service.team'] = '' AND ServiceName != 'k8s-events') FROM payflow_otel.otel_logs) = 0, 'OK', 'KO') AS enrichment,
    if((SELECT countIf(TraceId != '') / count() FROM payflow_otel.otel_logs) > 0.9, 'OK', 'KO')                  AS trace_ids
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 1,32 s · 73,8 M lignes lues (2,5 Go) · 324,3 Mo de mémoire
