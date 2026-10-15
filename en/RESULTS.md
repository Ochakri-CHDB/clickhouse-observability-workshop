# Measured results · ClickHouse observability workshop

Reference run of October 15, 2026, from scratch (`./run_all.sh`, about 7 min in total) on the test service: **ClickHouse Cloud 26.6, AWS eu-central-1, 3 replicas of 64 GB (16 vCPU each)**, the configuration recommended to attendees. Durations come from `system.query_log` (server time). The data is simulated and deterministic: volumes, rows read and results are the same for every attendee; durations vary by a few tens of percent from one run to another.
The same numbers appear as comments (`Measured`) under each statement of the SQL files.

> Orders of magnitude for the slides
> - **One day of a payment platform**, generated in SQL: 1.38 M requests, 21.5 M spans, 7.8 M log lines, 612,000 metric points
> - **The gateway in SQL**: 8.1 M agent records parsed, enriched and masked by materialized views in 6 statements of 12 to 16 s; **0 raw line stored**, 0 card number in clear, 4% of noise filtered
> - **Detection**: first page at 14:00, **2 minutes** after the faulty deploy; resolved at 14:47
> - **Live**: a switch replays the incident on the live stream, the burn-rate alert fires **within 1 minute**
> - **875 million log lines** written in 8 statements of ~27 s; a rare word found in **1 s** instead of 3.8 s, a trace in **31 ms** instead of 2.4 s
> - **Business impact**: 15,349 failed payments, **1.58 M EUR**, 7,999 merchants

---

## 01 · Data model
| Measure | Value |
|---|---|
| Service catalog | 12 nodes, 9 services, 49 pods (payment: 3 generations of 6), 11 deployment periods, 20,000 merchants, 5 dictionaries |
| OpenTelemetry tables | the exact exporter DDL: 5 signal tables, 7 text indexes on otel_logs, plus the trace lookup table and its view |

## 02 · Collection
| Measure | Value |
|---|---|
| Requests of the day | 1.38 M (15/s at night, 33/s during the flash sale) |
| Gateway: 6 inserts into the Null table | 11.6 to 16.1 s each; 8.13 M records received, 319,680 health checks dropped (3.9%, 86 MB) |
| Stored by the landing table | 0 rows |
| Enrichment (k8sattributes from the catalog) | version, team, node and zone on every container log |
| PCI masking | 244,982 card numbers masked, 0 in clear |
| Spans (OTLP), 4 batches | 7.9 to 14.2 s each, 21.5 M spans (15.6 per trace, a Client and a Server span per call) |
| Metrics | 426,240 pod points (CPU, memory), 103,680 HikariCP points, 53,280 restart counter points |
| Live stream, quiet traffic / chaos | about 9,000 spans and 3,000 log lines per minute / 28,000 spans with 3,000 errors per minute |
| Storage of the day | otel_traces 953 MB (x8.7), otel_logs 351 MB (x10.9), metrics under 6 MB |

## 03 · Search and correlation
| Measure | Value |
|---|---|
| Full-text search on 10 minutes (text index) | 24 ms, 172,032 rows read |
| Attribute filter through the text index on `ResourceAttributeItems` | 21 ms |
| Log → trace → pod metrics | 3 queries, under 0.6 s in total |
| Scenario A, from a merchant ticket (log) | 4 queries, 15 to 206 ms: the merchant id leads to `maximumPoolSize=10` on a v2.4.1 pod |
| Scenario B, from a metric alert (pool pending over 20) | fires at 14:03 on the 6 pods; 5 queries of 12 to 37 ms lead to the rollout CHG-4117 |
| Scenario C, from a trace (new error message) | 290 "connection refused" spans from 14:21:07; 5 queries of 33 to 131 ms lead to the OOM kill, caused by the retries (fraud-scoring traffic x2.2) |

## 04 · Dashboards (RED rollups)
| Measure | Value |
|---|---|
| RED backfill | 8.3 M server spans → 20,160 rows in 1.27 s |
| Same curve from the rollup / from the spans | 8,192 / 90,112 rows read |
| spanmetrics histogram with exemplars | 23,345 points in 751 ms |
| p99 of POST /v1/payments | 300 ms before 13:58, 3.1 s during, back at 14:44 |

## 05 · SLOs and alerts
| Measure | Value |
|---|---|
| Burn rate, 1 h window, at the peak | over 400 times the allowed rate |
| Alerts of the day | 11 events: first page at 14:00, node memory pressure 14:19, OOM restart 14:22, resolved 14:47 |
| Chaos switch on the live stream | burn rate 450x in the first minute, fast-burn page within 1 minute, p99 alert after 3 minutes |

## 06 · Investigation
| Measure | Value |
|---|---|
| Service map | 16 edges from the traces; payment → postgres p95 7.7 ms before, 3,033 ms during |
| Log patterns | 31 patterns for 6.4 M lines; the top new one is the HikariPool timeout (18,011 times, 0 before) |
| The 10 questions | 3 to 379 ms each |
| Root cause | `INSERT payflow.payments`, HikariPool timeout, only on v2.4.1 pods (CHG-4117) |
| Business impact, 13:58 to 14:50 | **15,349 failed payments, 1,576,893 EUR, 7,999 merchants** |

## 07 · Scale and cost (875 million log lines)
| Measure | Value |
|---|---|
| Write, 8 batches of 109 M lines | 26.4 to 29.5 s each, about 3.5 min in total, ~10.5 GB of memory per batch |
| Storage | 106 GB raw → 13 GB just after the inserts (x8.2, 16 bytes per line); background merges keep compressing |

| Query (service at rest) | Without | With | Rows read |
|---|---|---|---|
| Rare word, text index | 3.81 s | **1.05 s** | 875 M → 606,208 |
| Frequent word (HikariPool), text index | 2.41 s | **678 ms** | 875 M → 10.3 M |
| One trace id, bloom filter alone / with a time range | 2.38 s | **31 ms** | 1.9 M → 1 M |
| Errors per minute, projection | 549 ms | **341 ms** | 875 M → 578,256 |
| Whole trace via the lookup table | | **526 ms** | 245,760 |
| Heavy regex aggregation, query cache | 5.13 s | **1 ms** | 875 M → 0 |
| Same filter again, query condition cache | 2.37 s | **19 ms** | 875 M → 1.1 M |
| Full scan, 3 replicas | 5.12 s | **2.11 s** (x2.4) | 875 M |

| Lever | Value |
|---|---|
| Rollup in ClickStack's convention | 21.5 M spans → 53,926 rows (399 spans per row), built in 2.7 s |
| Retention sampling (errors and traces over 1 s) | 602,753 spans kept, 2.8% of the day, every trace of the incident |
| Head sampling at 10% | the error rate is preserved, the rare traces are not |
| Sizing rule of thumb | 12 GB of raw telemetry per day = 0.01 vCPU of ingest |

## 08 · AI and governance
| Measure | Value |
|---|---|
| GDPR delete of a merchant (lightweight DELETE) | 1,017 lines, about 1 s |
| Row policies per team | 2 policies, applied to ClickStack, the SQL console and MCP alike |
| Status API (parameterized view on slo_burn) | 11 rows for 10 minutes, a few ms |
