-- =====================================================================
--  MÓDULO 2 · Explorar los registros brutos antes de modelarlos
-- =====================================================================
--  Antes de escribir una sola regla de parseo, mira los datos. ClickHouse lee
--  el JSON tal cual: funciones JSONExtract* sobre un String, o el tipo JSON.
--  Este paso muestra también por qué necesitamos una capa silver: cuatro lenguajes,
--  cuatro formatos de log y un problema de seguridad escondido en los logs.
-- =====================================================================


-- PASO 1 · JSONExtract sobre una columna String
--  La forma más rápida de leer unos pocos campos conocidos: sin esquema, sin conversión.
SELECT
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')   AS service,
    JSONExtractString(payload, 'kubernetes', 'pod_name')        AS pod,
    JSONExtractString(payload, 'log')                           AS line
FROM payflow_raw.log_records
WHERE source = 'fluent-bit'
LIMIT 5;
-- Medido: 279 ms · 532 480 filas leídas (249,1 MB) · 419,3 MB de memoria


-- PASO 2 · El tipo JSON: navega con puntos, ClickHouse infiere los tipos
--  CAST(... AS JSON) convierte cada ruta en una subcolumna. Práctico para explorar,
--  y el mismo tipo sirve para guardar datos semiestructurados.
--  Atención: una ruta JSON es de tipo Dynamic. Para agrupar u ordenar por ella, haz
--  un cast (::String); si no, ClickHouse se niega: la misma ruta podría contener un
--  número aquí y una cadena allá.
SELECT
    j.kubernetes.labels.app::String      AS service,
    j.kubernetes.labels.version::String  AS version,
    count()                      AS records
FROM (SELECT payload::JSON AS j FROM payflow_raw.log_records WHERE source = 'fluent-bit' LIMIT 200000)
GROUP BY service, version
ORDER BY records DESC;
-- Medido: 485 ms · 532 480 filas leídas (249,1 MB) · 541,2 MB de memoria


-- PASO 3 · Cuatro servicios, cuatro formatos
--  Una línea de ejemplo por servicio: texto nginx, JSON de Go, logback de Java, logging de Python.
SELECT
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')   AS service,
    any(JSONExtractString(payload, 'log'))                      AS example
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND payload NOT LIKE '%healthz%' AND payload NOT LIKE '%health status%' AND payload NOT LIKE '%health check%'
GROUP BY service
ORDER BY service;
-- Medido: 589 ms · 6 M filas leídas (2,7 GB) · 651,2 MB de memoria
-- Qué observar: el nivel de error se escribe "error", " ERROR ", "ERROR:" o como
-- código de estado HTTP según el servicio. Contar errores sobre el texto bruto es
-- frágil: la capa silver lo normalizará una sola vez, en la ingesta.


-- PASO 4 · Errores por hora, por las malas
SELECT
    toStartOfHour(received_at) AS hour,
    countIf(payload LIKE '%"level":"error"%' OR payload LIKE '% ERROR %' OR payload LIKE '%"log":"ERROR:%'
            OR match(payload, 'HTTP/1.1\\\\" 5[0-9][0-9] ')) AS errors
FROM payflow_raw.log_records
WHERE source = 'fluent-bit'
GROUP BY hour
ORDER BY hour;
-- Medido: 244 ms · 6 M filas leídas (2,8 GB) · 612,6 MB de memoria
-- Qué observar: algo pasa a las 14:00. Veremos qué, como es debido, en el módulo 7.


-- PASO 5 · Un problema de seguridad: números de tarjeta en los logs
--  PCI DSS prohíbe guardar un número de tarjeta completo (PAN) en los logs.
SELECT
    JSONExtractString(payload, 'kubernetes', 'pod_name') AS pod,
    count()                                              AS lines_with_pan,
    any(extract(JSONExtractString(payload, 'log'), 'pan=[0-9]+')) AS example
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND match(payload, 'pan=[0-9]{13,19}')
GROUP BY pod;
-- Medido: 148 ms · 6 M filas leídas (2,7 GB) · 606,6 MB de memoria
-- Qué observar: un único pod imprime números de tarjeta completos: se quedó en DEBUG.
-- Silver los enmascarará a la entrada. Bronze guarda la línea bruta: su acceso debe
-- estar restringido y su retención ser corta (módulo 7).


-- PASO 6 · Los eventos de Kubernetes
SELECT
    JSONExtractString(payload, 'type')                         AS type,
    JSONExtractString(payload, 'reason')                       AS reason,
    count()                                                    AS events
FROM payflow_raw.log_records
WHERE source = 'k8s-events'
GROUP BY type, reason
ORDER BY events DESC;
-- Medido: 4 ms · 4 334 filas leídas (1,6 MB)
