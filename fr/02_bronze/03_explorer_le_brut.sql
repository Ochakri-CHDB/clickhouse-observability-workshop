-- =====================================================================
--  MODULE 2 · Explorer les enregistrements bruts avant de les modéliser
-- =====================================================================
--  Avant d'écrire la moindre règle de parsing, regardez les données. ClickHouse lit
--  le JSON sur place : fonctions JSONExtract* sur une String, ou le type JSON.
--  Cette étape montre aussi pourquoi il faut une couche silver : quatre langages,
--  quatre formats de log, et un problème de sécurité caché dans les logs.
-- =====================================================================


-- ÉTAPE 1 · JSONExtract sur une colonne String
--  Le moyen le plus rapide de lire quelques champs connus : ni schéma, ni conversion.
SELECT
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')   AS service,
    JSONExtractString(payload, 'kubernetes', 'pod_name')        AS pod,
    JSONExtractString(payload, 'log')                           AS line
FROM payflow_raw.log_records
WHERE source = 'fluent-bit'
LIMIT 5;
-- Mesuré : 279 ms · 532 480 lignes lues (249,1 Mo) · 419,3 Mo de mémoire


-- ÉTAPE 2 · Le type JSON : on navigue avec des points, ClickHouse infère les types
--  CAST(... AS JSON) transforme chaque chemin en sous-colonne. Pratique pour explorer,
--  et le même type peut servir à stocker des données semi-structurées.
--  Attention : un chemin JSON est de type Dynamic. Pour grouper ou trier dessus, castez-le
--  (::String), sinon ClickHouse refuse : le même chemin pourrait contenir un nombre ici
--  et une chaîne là.
SELECT
    j.kubernetes.labels.app::String      AS service,
    j.kubernetes.labels.version::String  AS version,
    count()                      AS records
FROM (SELECT payload::JSON AS j FROM payflow_raw.log_records WHERE source = 'fluent-bit' LIMIT 200000)
GROUP BY service, version
ORDER BY records DESC;
-- Mesuré : 485 ms · 532 480 lignes lues (249,1 Mo) · 541,2 Mo de mémoire


-- ÉTAPE 3 · Quatre services, quatre formats
--  Une ligne d'exemple par service : texte nginx, JSON Go, logback Java, logging Python.
SELECT
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')   AS service,
    any(JSONExtractString(payload, 'log'))                      AS example
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND payload NOT LIKE '%healthz%' AND payload NOT LIKE '%health status%' AND payload NOT LIKE '%health check%'
GROUP BY service
ORDER BY service;
-- Mesuré : 589 ms · 6 M de lignes lues (2,7 Go) · 651,2 Mo de mémoire
-- À observer : le niveau d'erreur s'écrit "error", " ERROR ", "ERROR:" ou sous forme
-- de statut HTTP selon le service. Compter les erreurs sur le texte brut est
-- fragile : la couche silver normalisera tout cela une fois, à l'ingestion.


-- ÉTAPE 4 · Les erreurs par heure, à la dure
SELECT
    toStartOfHour(received_at) AS hour,
    countIf(payload LIKE '%"level":"error"%' OR payload LIKE '% ERROR %' OR payload LIKE '%"log":"ERROR:%'
            OR match(payload, 'HTTP/1.1\\\\" 5[0-9][0-9] ')) AS errors
FROM payflow_raw.log_records
WHERE source = 'fluent-bit'
GROUP BY hour
ORDER BY hour;
-- Mesuré : 244 ms · 6 M de lignes lues (2,8 Go) · 612,6 Mo de mémoire
-- À observer : il se passe quelque chose à 14h00. On saura quoi, proprement, au module 7.


-- ÉTAPE 5 · Un problème de sécurité : des numéros de carte dans les logs
--  PCI DSS interdit de stocker un numéro de carte complet (PAN) dans les logs.
SELECT
    JSONExtractString(payload, 'kubernetes', 'pod_name') AS pod,
    count()                                              AS lines_with_pan,
    any(extract(JSONExtractString(payload, 'log'), 'pan=[0-9]+')) AS example
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND match(payload, 'pan=[0-9]{13,19}')
GROUP BY pod;
-- Mesuré : 148 ms · 6 M de lignes lues (2,7 Go) · 606,6 Mo de mémoire
-- À observer : un seul pod imprime des numéros de carte complets, il est resté en DEBUG.
-- Silver les masquera à l'entrée. Bronze garde la ligne brute : son accès doit être
-- restreint et sa rétention courte (module 7).


-- ÉTAPE 6 · Les événements Kubernetes
SELECT
    JSONExtractString(payload, 'type')                         AS type,
    JSONExtractString(payload, 'reason')                       AS reason,
    count()                                                    AS events
FROM payflow_raw.log_records
WHERE source = 'k8s-events'
GROUP BY type, reason
ORDER BY events DESC;
-- Mesuré : 4 ms · 4 334 lignes lues (1,6 Mo)
