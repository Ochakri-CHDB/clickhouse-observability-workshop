-- =====================================================================
--  MODULE 2 · Explore the raw records before modelling them
-- =====================================================================
--  Before writing a single parsing rule, look at the data. ClickHouse reads
--  JSON in place: JSONExtract* functions on a String, or the JSON type.
--  This step also shows why we need a silver layer: four languages, four
--  log formats, and a security problem hidden in the logs.
-- =====================================================================


-- STEP 1 · JSONExtract on a String column
--  The fastest way to read a few known fields: no schema, no conversion.
SELECT
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')   AS service,
    JSONExtractString(payload, 'kubernetes', 'pod_name')        AS pod,
    JSONExtractString(payload, 'log')                           AS line
FROM payflow_raw.log_records
WHERE source = 'fluent-bit'
LIMIT 5;
-- Measured: 279 ms · 532,480 rows read (249.1 MB) · 419.3 MB memory


-- STEP 2 · The JSON type: navigate with dots, ClickHouse infers the types
--  CAST(... AS JSON) turns each path into a sub-column. Handy to explore,
--  and the same type can be used to store semi-structured data.
--  Watch out: a JSON path is of type Dynamic. To group or sort on it, cast it
--  (::String), otherwise ClickHouse refuses: the same path could hold a number here
--  and a string there.
SELECT
    j.kubernetes.labels.app::String      AS service,
    j.kubernetes.labels.version::String  AS version,
    count()                      AS records
FROM (SELECT payload::JSON AS j FROM payflow_raw.log_records WHERE source = 'fluent-bit' LIMIT 200000)
GROUP BY service, version
ORDER BY records DESC;
-- Measured: 485 ms · 532,480 rows read (249.1 MB) · 541.2 MB memory


-- STEP 3 · Four services, four formats
--  One example line per service: nginx text, Go JSON, Java logback, Python logging.
SELECT
    JSONExtractString(payload, 'kubernetes', 'labels', 'app')   AS service,
    any(JSONExtractString(payload, 'log'))                      AS example
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND payload NOT LIKE '%healthz%' AND payload NOT LIKE '%health status%' AND payload NOT LIKE '%health check%'
GROUP BY service
ORDER BY service;
-- Measured: 589 ms · 6 M rows read (2.7 GB) · 651.2 MB memory
-- What to look for: the error level is written "error", " ERROR ", "ERROR:" or
-- as an HTTP status depending on the service. Counting errors on raw text is
-- fragile: the silver layer will normalise this once, at ingestion.


-- STEP 4 · Errors per hour, the hard way
SELECT
    toStartOfHour(received_at) AS hour,
    countIf(payload LIKE '%"level":"error"%' OR payload LIKE '% ERROR %' OR payload LIKE '%"log":"ERROR:%'
            OR match(payload, 'HTTP/1.1\\\\" 5[0-9][0-9] ')) AS errors
FROM payflow_raw.log_records
WHERE source = 'fluent-bit'
GROUP BY hour
ORDER BY hour;
-- Measured: 244 ms · 6 M rows read (2.8 GB) · 612.6 MB memory
-- What to look for: something happens at 14:00. We will find out what, properly, in module 7.


-- STEP 5 · A security problem: card numbers in the logs
--  PCI DSS forbids storing a full card number (PAN) in logs.
SELECT
    JSONExtractString(payload, 'kubernetes', 'pod_name') AS pod,
    count()                                              AS lines_with_pan,
    any(extract(JSONExtractString(payload, 'log'), 'pan=[0-9]+')) AS example
FROM payflow_raw.log_records
WHERE source = 'fluent-bit' AND match(payload, 'pan=[0-9]{13,19}')
GROUP BY pod;
-- Measured: 148 ms · 6 M rows read (2.7 GB) · 606.6 MB memory
-- What to look for: a single pod prints full card numbers: it was left in DEBUG.
-- Silver will mask them on the way in. Bronze keeps the raw line: its access must
-- be restricted and its retention short (module 7).


-- STEP 6 · The Kubernetes events
SELECT
    JSONExtractString(payload, 'type')                         AS type,
    JSONExtractString(payload, 'reason')                       AS reason,
    count()                                                    AS events
FROM payflow_raw.log_records
WHERE source = 'k8s-events'
GROUP BY type, reason
ORDER BY events DESC;
-- Measured: 4 ms · 4,334 rows read (1.6 MB)
