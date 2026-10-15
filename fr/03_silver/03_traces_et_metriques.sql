-- =====================================================================
--  MODULE 3 · Silver : traces et métriques
-- =====================================================================
--  Les traces et les métriques ne passent pas par bronze : le collector OpenTelemetry
--  les envoie déjà structurées (OTLP), l'exporter les écrit directement
--  dans otel_traces et otel_metrics_*. On fait pareil avec le simulateur.
--  Puis on construit en SQL ce qu'un collector calcule d'habitude :
--    · les histogrammes de latence à partir des spans (le connector "spanmetrics")
--    · CPU et mémoire des pods toutes les 15 s (le receiver "kubeletstats")
--    · les métriques applicatives : pool HikariCP, consumer lag Kafka, redémarrages
-- =====================================================================


-- ÉTAPE 1 · Les spans de la journée, en 4 lots
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 0, to_s = 28800);        -- 00h00 à 08h00
-- Mesuré : 5,5 s · 28 800 lignes lues (225 Ko) · 2,3 M lignes écrites · 5,3 Go de mémoire
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 28800, to_s = 50400);    -- 08h00 à 14h00
-- Mesuré : 5,39 s · 21 600 lignes lues (168,8 Ko) · 2,4 M lignes écrites · 5,6 Go de mémoire
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 50400, to_s = 68400);    -- 14h00 à 19h00
-- Mesuré : 8,04 s · 18 000 lignes lues (140,6 Ko) · 4,8 M lignes écrites · 9 Go de mémoire
INSERT INTO payflow_otel.otel_traces
    (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName, ResourceAttributes, ScopeName, ScopeVersion,
     SpanAttributes, Duration, StatusCode, StatusMessage, `Events.Timestamp`, `Events.Name`, `Events.Attributes`,
     `Links.TraceId`, `Links.SpanId`, `Links.TraceState`, `Links.Attributes`)
SELECT * EXCEPT (pod) FROM payflow_sim.spans(from_s = 68400, to_s = 86400);    -- 19h00 à 24h00
-- Mesuré : 9,25 s · 18 000 lignes lues (140,6 Ko) · 5 M lignes écrites · 8,2 Go de mémoire

SELECT count() AS spans, uniqExact(TraceId) AS traces, round(count() / uniqExact(TraceId), 1) AS spans_per_trace
FROM payflow_otel.otel_traces;
-- Mesuré : 288 ms · 14,6 M lignes lues (486,5 Mo) · 506,5 Mo de mémoire


-- ÉTAPE 2 · Histogrammes de latence par service et par span, chaque minute (spanmetrics)
--  Un histogramme OpenTelemetry stocke, pour chaque intervalle, le nombre par bucket
--  (BucketCounts) pour des bornes fixes (ExplicitBounds), plus count, sum, min, max.
--  L'exemplar garde le trace id de la requête la plus lente de la minute : depuis un
--  graphe de latence, on saute directement à la trace coupable (module 8).
INSERT INTO payflow_otel.otel_metrics_histogram
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix,
     Count, Sum, BucketCounts, ExplicitBounds, `Exemplars.FilteredAttributes`, `Exemplars.TimeUnix`, `Exemplars.Value`,
     `Exemplars.SpanId`, `Exemplars.TraceId`, Min, Max, AggregationTemporality)
WITH [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10] AS bounds
SELECT
    map('service.name', ServiceName, 'k8s.cluster.name', 'payflow-prod-eu')                            AS ResourceAttributes,
    ServiceName,
    'http.server.request.duration'                                                                     AS MetricName,
    'Duration of server spans, computed from the traces'                                               AS MetricDescription,
    's'                                                                                                AS MetricUnit,
    map('span.name', SpanName, 'span.kind', 'SPAN_KIND_SERVER', 'status.code', if(StatusCode = 'Error', 'STATUS_CODE_ERROR', 'STATUS_CODE_UNSET')) AS Attributes,
    toDateTime64(minute, 9, 'UTC')                                                                     AS StartTimeUnix,
    toDateTime64(minute + 60, 9, 'UTC')                                                                AS TimeUnix,
    count()                                                                                            AS Count,
    sum(Duration / 1e9)                                                                                AS Sum,
    sumForEach(arrayMap(b -> toUInt64(b = arrayFirstIndex(x -> Duration / 1e9 <= x, bounds)), range(1, 13))) AS BucketCounts,
    bounds                                                                                             AS ExplicitBounds,
    [map()]                                                                                            AS `Exemplars.FilteredAttributes`,
    [argMax(Timestamp, Duration)]                                                                      AS `Exemplars.TimeUnix`,
    [max(Duration) / 1e9]                                                                              AS `Exemplars.Value`,
    [argMax(SpanId, Duration)]                                                                         AS `Exemplars.SpanId`,
    [argMax(TraceId, Duration)]                                                                        AS `Exemplars.TraceId`,
    min(Duration / 1e9)                                                                                AS Min,
    max(Duration / 1e9)                                                                                AS Max,
    1                                                                                                  AS AggregationTemporality   -- delta : chaque ligne couvre sa propre minute
FROM payflow_otel.otel_traces
WHERE SpanKind = 'Server'
GROUP BY ServiceName, SpanName, StatusCode, toStartOfMinute(toDateTime(Timestamp)) AS minute;
-- Mesuré : 668 ms · 14,6 M lignes lues (631,5 Mo) · 23 350 lignes écrites · 374,4 Mo de mémoire
-- Attention : arrayFirstIndex renvoie 0 quand la valeur dépasse la dernière borne : dans ce
-- cas aucun b de 1..12 ne correspond. Ici aucun span ne dépasse 10 s, chacun tombe dans un bucket.


-- ÉTAPE 3 · CPU et mémoire des pods, toutes les 15 secondes (kubeletstats)
--  La charge suit le trafic. Deux histoires se cachent dans ces chiffres :
--    · les pods payment en v2.4.1 consomment MOINS de CPU : leurs threads attendent une connexion
--    · le pod fraud-scoring sur ip-10-0-3-17 grossit dès 14h05 (retries) jusqu'à sa
--      limite de 2 GiB, est tué à 14:21:07, redémarre à 14:21:52
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', p.deployment, 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', p.deployment, 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name)                                          AS ResourceAttributes,
    p.deployment                                                                                          AS ServiceName,
    m.1                                                                                                   AS MetricName,
    m.2                                                                                                   AS MetricDescription,
    m.3                                                                                                   AS MetricUnit,
    map()                                                                                                 AS Attributes,
    addSeconds(day0, s)                                                                                   AS StartTimeUnix,
    addSeconds(day0, s)                                                                                   AS TimeUnix,
    m.4                                                                                                   AS Value
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 15) AS s
ARRAY JOIN [
    ('k8s.pod.cpu.utilization', 'CPU used, as a share of the pod limit', '1',
     least(0.98, (0.08 + 0.5 * pf_rate(s) / 40 * if(p.version = 'v2.4.1', 0.45, 1)
                  * if(p.deployment = 'fraud-scoring' AND s >= 50700 AND s < 53100, 2.2, 1)) * (0.9 + 0.2 * pf_r(cityHash64(p.pod_name), s)))),
    ('k8s.pod.memory.working_set', 'Memory working set of the pod', 'By',
     multiIf(p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 50700 AND s < 51667,
                 (900 + (s - 50700) / 967 * 1240) * 1048576,                        -- 900 MiB à 2,1 GiB en 16 minutes
             p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 51667 AND s < 51712, 0,   -- tué, en redémarrage
             p.deployment = 'fraud-scoring', (700 + 200 * least(1, greatest(0, (s - 51712) / 600.0) + if(p.slot = 2, 0, 1))) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), s)),
             p.deployment IN ('payment', 'card-network-adapter', 'ledger'), (1400 + 300 * pf_rate(s) / 40) * 1048576 * (0.97 + 0.06 * pf_r(cityHash64(p.pod_name), s)),
             (180 + 60 * pf_rate(s) / 40) * 1048576 * (0.95 + 0.1 * pf_r(cityHash64(p.pod_name), s))))] AS m
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Mesuré : 1,29 s · 49 lignes lues (3,4 Ko) · 426 240 lignes écrites · 644,5 Mo de mémoire


-- ÉTAPE 4 · Le pool de connexions HikariCP de chaque pod payment (la preuve du crime)
--  max est la taille configurée : 50 en v2.4.0, 10 en v2.4.1. Quand le pool est
--  plein, les requêtes font la queue (pending) et abandonnent au bout de 3 s.
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', 'payment', 'service.version', p.version, 'k8s.cluster.name', 'payflow-prod-eu',
        'k8s.namespace.name', p.namespace, 'k8s.deployment.name', 'payment', 'k8s.pod.name', p.pod_name,
        'k8s.pod.uid', p.pod_uid, 'k8s.node.name', p.node_name),
    'payment', m.1, m.2, '{connection}', map('pool', 'HikariPool-1'),
    addSeconds(day0, s), addSeconds(day0, s), m.3
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 15) AS s
ARRAY JOIN [
    ('hikaricp.connections.max',     'Configured pool size', toFloat64(if(p.version = 'v2.4.1', 10, 50))),
    ('hikaricp.connections.active',  'Connections in use',
        if(p.version = 'v2.4.1' AND s >= 50580, 10, round(1 + pf_rate(s) / 8 + 2 * pf_r(cityHash64(p.pod_name), s)))),
    ('hikaricp.connections.pending', 'Threads waiting for a connection',
        if(p.version = 'v2.4.1' AND s >= 50580, round(pf_rate(s) * 1.4 * (0.8 + 0.4 * pf_r(cityHash64(p.pod_name, 'p'), s))), 0))] AS m
WHERE p.deployment = 'payment'
  AND addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Mesuré : 389 ms · 49 lignes lues (3,4 Ko) · 103 680 lignes écrites · 172,2 Mo de mémoire


-- ÉTAPE 5 · Consumer lag Kafka et redémarrages de conteneurs
INSERT INTO payflow_otel.otel_metrics_gauge
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', 'notification', 'k8s.cluster.name', 'payflow-prod-eu'), 'notification',
    'kafka.consumer.lag', 'Messages not yet processed by the consumer group', '{message}',
    map('messaging.destination.name', 'payment.events', 'messaging.consumer.group.name', 'notification'),
    addSeconds(day0, s), addSeconds(day0, s),
    round(pf_rate(s) * 4 * (0.5 + pf_r(s, 'lag')))
FROM numbers(5760) ARRAY JOIN [toUInt32(number * 15)] AS s;
-- Mesuré : 82 ms · 5 760 lignes lues (45 Ko) · 5 760 lignes écrites

INSERT INTO payflow_otel.otel_metrics_sum
    (ResourceAttributes, ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, StartTimeUnix, TimeUnix, Value,
     AggregationTemporality, IsMonotonic)
WITH toDateTime64('2026-11-27 00:00:00', 9, 'UTC') AS day0
SELECT
    map('service.name', p.deployment, 'k8s.cluster.name', 'payflow-prod-eu', 'k8s.namespace.name', p.namespace,
        'k8s.pod.name', p.pod_name, 'k8s.node.name', p.node_name),
    p.deployment, 'k8s.container.restarts', 'Restarts of the container since the pod started', '{restart}', map(),
    toDateTime64(p.started_at, 9, 'UTC'), addSeconds(day0, s),
    if(p.deployment = 'fraud-scoring' AND p.slot = 2 AND s >= 51712, 1, 0),
    2, true   -- cumulatif et monotone : un compteur qui ne fait que monter
FROM payflow_ref.pod AS p
ARRAY JOIN range(0, 86400, 60) AS s
WHERE addSeconds(day0, s) >= p.started_at AND addSeconds(day0, s) <= p.stopped_at;
-- Mesuré : 168 ms · 49 lignes lues (2,4 Ko) · 53 280 lignes écrites · 65,2 Mo de mémoire

SELECT MetricName, count() AS points, round(min(Value), 2) AS min_value, round(max(Value), 2) AS max_value
FROM payflow_otel.otel_metrics_gauge
GROUP BY MetricName
ORDER BY MetricName;
-- Mesuré : 16 ms · 535 680 lignes lues (18,3 Mo) · 65,5 Mo de mémoire


-- ÉTAPE 6 · Les trois signaux, côte à côte, sur une minute de l'incident
SELECT 'logs' AS signal, count() AS records FROM payflow_otel.otel_logs
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'spans', count() FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 14:10:00' AND Timestamp < '2026-11-27 14:11:00'
UNION ALL
SELECT 'metric points', count() FROM payflow_otel.otel_metrics_gauge
WHERE TimeUnix >= '2026-11-27 14:10:00' AND TimeUnix < '2026-11-27 14:11:00';
-- Mesuré : 197 ms · 6,7 M lignes lues (50,9 Mo) · 78,8 Mo de mémoire


-- ÉTAPE 7 · Checkpoint
SELECT
    if((SELECT count() FROM payflow_otel.otel_traces) > 14000000, 'OK', 'KO')                                   AS spans,
    if((SELECT count() FROM payflow_otel.otel_metrics_histogram) > 10000, 'OK', 'KO')                         AS histograms,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_gauge WHERE MetricName = 'hikaricp.connections.pending') > 20, 'OK', 'KO') AS pool_story,
    if((SELECT max(Value) FROM payflow_otel.otel_metrics_sum WHERE MetricName = 'k8s.container.restarts') = 1, 'OK', 'KO')         AS restart_story,
    -- chaque ligne de log qui porte un trace id pointe vers un span qui existe
    if((SELECT count() FROM (SELECT TraceId FROM payflow_otel.otel_logs WHERE TraceId != '' AND Timestamp BETWEEN '2026-11-27 14:10:00' AND '2026-11-27 14:10:10' LIMIT 1000)
        WHERE TraceId NOT IN (SELECT TraceId FROM payflow_otel.otel_traces WHERE Timestamp BETWEEN '2026-11-27 14:09:50' AND '2026-11-27 14:10:20')) = 0, 'OK', 'KO') AS logs_to_traces
SETTINGS select_sequential_consistency = 1;
-- Mesuré : 309 ms · 4,2 M lignes lues (39,3 Mo) · 178,2 Mo de mémoire
