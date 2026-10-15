-- =====================================================================
--  MÓDULO 4 · Diccionarios: enriquecer miles de millones de señales en memoria
-- =====================================================================
--  Una línea de log conoce su pod. Un span conoce el id de su comercio. Ninguno
--  sabe el equipo responsable, el tamaño del nodo, el nivel del comercio ni qué
--  cambio estaba desplegado en ese momento. Los diccionarios aportan ese contexto:
--  una tabla de referencia cargada en memoria, leída con dictGet() a la velocidad
--  de una búsqueda en hash, sin JOIN (regla query-join-use-dictionaries).
--  SOURCE dice dónde leer, LAYOUT cómo organizarlo en memoria,
--  LIFETIME cada cuánto recargarlo.
-- =====================================================================


-- PASO 1 · Servicios, nodos y comercios: clave simple → atributos
CREATE OR REPLACE DICTIONARY payflow_ref.dict_service
(
    service     String,
    namespace   String,
    team        String,
    language    String,
    tier        String,
    slo_target  Float32
)
PRIMARY KEY service
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'service' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

CREATE OR REPLACE DICTIONARY payflow_ref.dict_node
(
    node_name      String,
    zone           String,
    instance_type  String,
    memory_gib     UInt16
)
PRIMARY KEY node_name
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'node' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

CREATE OR REPLACE DICTIONARY payflow_ref.dict_merchant
(
    merchant_id  String,
    name         String,
    country      String,
    category     String,
    tier         String
)
PRIMARY KEY merchant_id
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'merchant' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);


-- PASO 2 · "¿Qué cambio estaba en producción en ese momento?": un diccionario de rangos
--  Clave = deployment, rango = [valid_from, valid_to]. dictGet con una marca de tiempo
--  devuelve la versión, el change id y su autor en ese instante.
--  Este diccionario responde a la primera pregunta de toda revisión de incidente.
CREATE OR REPLACE DICTIONARY payflow_ref.dict_deployment
(
    deployment  String,
    valid_from  DateTime,
    valid_to    DateTime,
    version     String,
    change_id   String,
    author      String,
    note        String
)
PRIMARY KEY deployment
SOURCE(CLICKHOUSE(DB 'payflow_ref' TABLE 'deployment_history' USER 'payflow_dict' PASSWORD 'PayFlow_Dict_2026!'))
LAYOUT(COMPLEX_KEY_RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 300 MAX 600);

SELECT
    t,
    dictGet('payflow_ref.dict_deployment', ('version', 'change_id', 'author'), 'payment', t) AS running
FROM (SELECT arrayJoin([toDateTime('2026-11-27 13:00:00', 'UTC'), toDateTime('2026-11-27 14:15:00', 'UTC'),
                        toDateTime('2026-11-27 15:00:00', 'UTC')]) AS t);
-- Medido: 2 ms · 1 fila leída
-- Qué observar: v2.4.0, luego v2.4.1 (CHG-4117 de j.martin), y otra vez v2.4.0.


-- PASO 3 · Errores por equipo y por minuto, en torno al incidente
--  El span solo conoce su servicio: el equipo sale del diccionario.
SELECT
    toStartOfFiveMinutes(toDateTime(Timestamp))                         AS t,
    dictGet('payflow_ref.dict_service', 'team', ServiceName)            AS team,
    countIf(StatusCode = 'Error')                                       AS error_spans
FROM payflow_otel.otel_traces
WHERE Timestamp >= '2026-11-27 13:45:00' AND Timestamp < '2026-11-27 15:00:00' AND SpanKind = 'Server'
GROUP BY t, team
HAVING error_spans > 0
ORDER BY t, error_spans DESC;
-- Medido: 41 ms · 1,4 M filas leídas (9,8 MB) · 66 MB de memoria
-- Qué observar: la mayoría de los errores son del equipo "payments", "checkout" y
-- "platform" solo los propagan. Avisar primero al equipo correcto ahorra minutos.


-- PASO 4 · Cada span en error, marcado con el cambio que estaba en producción
SELECT
    ServiceName,
    dictGet('payflow_ref.dict_deployment', 'version', ServiceName, toDateTime(Timestamp))    AS version,
    dictGet('payflow_ref.dict_deployment', 'change_id', ServiceName, toDateTime(Timestamp))  AS change_id,
    count()                                                                                   AS error_spans
FROM payflow_otel.otel_traces
WHERE StatusCode = 'Error' AND ServiceName = 'payment'
GROUP BY ServiceName, version, change_id
ORDER BY error_spans DESC;
-- Medido: 199 ms · 3,6 M filas leídas (15,7 MB) · 88,9 MB de memoria
-- Qué observar: casi todos los errores de payment ocurrieron con CHG-4117.
-- Atención: durante un despliegue progresivo (rollout) conviven dos versiones. El diccionario
-- da el cambio del deployment; la versión real del pod está en ResourceAttributes['service.version'].


-- PASO 5 · dictGet frente a JOIN: facturación por nivel de comercio, sobre todos los pagos del día
--  Las dos consultas devuelven las mismas cifras. Compara tiempo y memoria en system.query_log.
SELECT
    dictGet('payflow_ref.dict_merchant', 'tier', SpanAttributes['merchant.id'])  AS tier,
    count()                                                                      AS payments,
    round(sum(toFloat64(SpanAttributes['payment.amount'])))                      AS amount_eur
FROM payflow_otel.otel_traces
WHERE ServiceName = 'payment' AND SpanName = 'payment.AuthorizePayment' AND SpanAttributes['payment.status'] = 'authorized'
GROUP BY tier
ORDER BY amount_eur DESC;
-- Medido: 302 ms · 1,1 M filas leídas (32,6 MB) · 173,2 MB de memoria

SELECT
    m.tier                                                                       AS tier,
    count()                                                                      AS payments,
    round(sum(toFloat64(t.SpanAttributes['payment.amount'])))                    AS amount_eur
FROM payflow_otel.otel_traces AS t
INNER JOIN payflow_ref.merchant AS m ON m.merchant_id = t.SpanAttributes['merchant.id']
WHERE t.ServiceName = 'payment' AND t.SpanName = 'payment.AuthorizePayment' AND t.SpanAttributes['payment.status'] = 'authorized'
GROUP BY tier
ORDER BY amount_eur DESC;
-- Medido: 65 ms · 1,1 M filas leídas (32,8 MB) · 174,3 MB de memoria


-- PASO 6 · Logs por zona de disponibilidad y tamaño de nodo
SELECT
    dictGet('payflow_ref.dict_node', 'zone', ResourceAttributes['k8s.node.name'])           AS zone,
    dictGet('payflow_ref.dict_node', 'instance_type', ResourceAttributes['k8s.node.name'])  AS instance_type,
    count()                                                                                  AS log_records,
    countIf(SeverityNumber >= 17)                                                            AS errors
FROM payflow_otel.otel_logs
WHERE ServiceName != 'k8s-events'
GROUP BY zone, instance_type
ORDER BY zone, instance_type;
-- Medido: 319 ms · 8,1 M filas leídas (131,8 MB) · 266,4 MB de memoria


-- PASO 7 · Lo que cuestan los diccionarios en memoria
SELECT name, status, element_count, formatReadableSize(bytes_allocated) AS memory, loading_duration
FROM system.dictionaries
WHERE database IN ('payflow_ref', 'payflow_sim')
ORDER BY bytes_allocated DESC;
-- Medido: 4 ms · 36 filas leídas (17,3 KB)


-- PASO 8 · Checkpoint
SELECT
    if(dictGet('payflow_ref.dict_deployment', 'change_id', 'payment', toDateTime('2026-11-27 14:15:00', 'UTC')) = 'CHG-4117', 'OK', 'KO') AS range_dict,
    if(dictGet('payflow_ref.dict_service', 'team', 'payment') = 'payments', 'OK', 'KO')                                               AS dict_service,
    if((SELECT element_count FROM system.dictionaries WHERE database = 'payflow_ref' AND name = 'dict_merchant') = 20000, 'OK', 'KO')  AS dict_merchant
SETTINGS select_sequential_consistency = 1;
-- Medido: 6 ms · 37 filas leídas (17,3 KB)
