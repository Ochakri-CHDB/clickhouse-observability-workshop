-- =====================================================================
--  MODULE 0 · Premiers pas : un million de lignes de log en une requête
-- =====================================================================
--  Avant de construire quoi que ce soit, prenez la mesure du moteur. ClickHouse
--  génère, parse et agrège des données à plusieurs centaines de millions de
--  lignes par seconde sur une seule réplique. Tout le workshop repose sur cette
--  idée : les données sont générées en SQL, dans la base elle-même.
-- =====================================================================


-- ÉTAPE 1 · Où suis-je ?
SELECT version() AS clickhouse_version, getMacro('replica') AS replica, uptime() AS uptime_seconds;
-- Mesuré : 1 ms · 1 ligne lue


-- ÉTAPE 2 · numbers() : une table d'entiers, aussi longue que vous voulez
SELECT number FROM numbers(5);
-- Mesuré : 1 ms · 5 lignes lues


-- ÉTAPE 3 · Un million de lignes de log, générées en un seul SELECT
--  Chaque ligne reçoit un niveau, un service et une durée, dérivés du numéro de
--  ligne avec cityHash64 (déterministe : tout le monde obtient les mêmes lignes).
SELECT
    toDateTime(today() - 1, 'UTC') + intDiv(number, 12)                                             AS ts,
    ['api-gateway', 'checkout', 'payment', 'fraud-scoring'][1 + cityHash64(number, 's') % 4]          AS service,
    multiIf(cityHash64(number, 'l') % 1000 < 5, 'ERROR', cityHash64(number, 'l') % 1000 < 40, 'WARN', 'INFO') AS level,
    concat('request ', toString(number), ' served in ', toString(5 + cityHash64(number, 'd') % 300), ' ms') AS message
FROM numbers(1000000)
LIMIT 5;
-- Mesuré : 3 ms · 5 lignes lues


-- ÉTAPE 4 · ... et agrégées dans la foulée
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
-- Mesuré : 349 ms · 1 M lignes lues (7,6 Mo)
-- À observer : un million de lignes générées, parsées avec une expression régulière
-- et agrégées, en quelques centaines de millisecondes. Essayez numbers(10000000).


-- ÉTAPE 5 · Checkpoint
SELECT if((SELECT count() FROM numbers(1000000)) = 1000000, 'OK', 'KO') AS first_steps;
-- Mesuré : 3 ms · 1 M lignes lues (7,6 Mo)
