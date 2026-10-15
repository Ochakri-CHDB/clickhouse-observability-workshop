-- =====================================================================
--  MÓDULO 0 · Primeros pasos: un millón de líneas de log en una consulta
-- =====================================================================
--  Antes de construir nada, siente el motor. ClickHouse genera, parsea
--  y agrega datos a varios cientos de millones de filas por segundo en
--  una sola réplica. Todo este taller se basa en esta idea: los datos
--  se generan con SQL, dentro de la base de datos.
-- =====================================================================


-- PASO 1 · ¿Dónde estoy?
SELECT version() AS clickhouse_version, getMacro('replica') AS replica, uptime() AS uptime_seconds;
-- Medido: 1 ms · 1 fila leída


-- PASO 2 · numbers(): una tabla de enteros, tan larga como quieras
SELECT number FROM numbers(5);
-- Medido: 1 ms · 5 filas leídas


-- PASO 3 · Un millón de líneas de log, generadas en un solo SELECT
--  Cada línea recibe un nivel, un servicio y una duración, derivados del número de
--  línea con cityHash64 (determinista: todos obtienen las mismas líneas).
SELECT
    toDateTime('2026-11-27 00:00:00', 'UTC') + intDiv(number, 12)                                   AS ts,
    ['api-gateway', 'checkout', 'payment', 'fraud-scoring'][1 + cityHash64(number, 's') % 4]          AS service,
    multiIf(cityHash64(number, 'l') % 1000 < 5, 'ERROR', cityHash64(number, 'l') % 1000 < 40, 'WARN', 'INFO') AS level,
    concat('request ', toString(number), ' served in ', toString(5 + cityHash64(number, 'd') % 300), ' ms') AS message
FROM numbers(1000000)
LIMIT 5;
-- Medido: 3 ms · 5 filas leídas


-- PASO 4 · ... y agregadas al momento
SELECT
    service,
    level,
    count()                                                                      AS lines,
    round(avg(toUInt32(extract(message, 'in ([0-9]+) ms'))), 1)                  AS avg_ms
FROM
(
    SELECT
        ['api-gateway', 'checkout', 'payment', 'fraud-scoring'][1 + cityHash64(number, 's') % 4] AS service,
        multiIf(cityHash64(number, 'l') % 1000 < 5, 'ERROR', cityHash64(number, 'l') % 1000 < 40, 'WARN', 'INFO') AS level,
        concat('request ', toString(number), ' served in ', toString(5 + cityHash64(number, 'd') % 300), ' ms') AS message
    FROM numbers(1000000)
)
GROUP BY service, level
ORDER BY service, level;
-- Medido: 341 ms · 1 M filas leídas (7,6 MB)
-- Qué observar: un millón de líneas generadas, parseadas con una expresión regular
-- y agregadas, en unos cientos de milisegundos. Prueba con numbers(10000000).


-- PASO 5 · Checkpoint
SELECT if((SELECT count() FROM numbers(1000000)) = 1000000, 'OK', 'KO') AS first_steps;
-- Medido: 3 ms · 1 M filas leídas (7,6 MB)
