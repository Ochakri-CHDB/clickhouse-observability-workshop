# Measured results · ClickHouse observability workshop

Reference run of 16 October 2026 (so Black Friday was Friday 9 October), from scratch (`./run_all.sh`, about 14 min in total) on the test service: **ClickHouse Cloud 26.6, AWS eu-central-1, 3 replicas of 64 GB (16 vCPU each)**, the configuration recommended to attendees. Durations come from `system.query_log` (server time). The data is generated for the day you run the workshop: the incident, the volumes and the results are the same for every attendee (the randomness is keyed on the time relative to Black Friday); only the few days between Black Friday and today change with the day of the week, and durations vary by a few tens of percent from one run to another.
The same numbers appear as comments (`Measured`) under each statement of the SQL files.

> Orders of magnitude for the slides
> - **A month of a payment platform**, generated in SQL: 76.7 M spans, 27.8 M log lines, 37.8 M metric points, loaded in about 8 minutes, every statement under 35 s
> - **Black Friday** in it: 1.38 M requests, 21.5 M spans, 7.8 M log lines, 12 times an ordinary day
> - **The gateway in SQL**: 27.5 M agent records parsed, enriched and masked by materialized views; **0 raw line stored**, 766,724 card numbers masked, 11.6% of noise filtered
> - **Detection**: first page at 14:00, **2 minutes** after the faulty deploy; resolved at 14:47; 11 alerts in the month, all on Black Friday
> - **875 million log lines** written in 8 statements of ~30 s; a rare word found in **0.8 s** instead of 4.3 s, a trace in **22 ms** instead of 3 s
> - **Business impact**: 15,349 failed payments, **1.58 M EUR**, 7,999 merchants

---

## 01 · Data model
| Measure | Value |
|---|---|
| Calendar | Black Friday = the last Friday before today; history of 30 days ending with it; 3 functions (`pf_black_friday`, `pf_day`, `pf_at`) that keep the primary key and partition pruning |
| Service catalog | 12 nodes, 9 services, 16 changes in the month (5 weekly releases, the faulty release, the rollback), 74 pods (payment: 4 generations of 6), 20,000 merchants, 5 dictionaries |
| OpenTelemetry tables | the exact exporter DDL: 5 signal tables, 7 text indexes on otel_logs, plus the trace lookup table and its view |

## 02 · Collection
| Measure | Value |
|---|---|
| Requests | about 107,000 per ordinary day, 80,000 at weekends, 1.38 M on Black Friday (33/s during the flash sale) |
| Gateway: 10 inserts into the Null table | 14 to 22 s each; 27.5 M records received, 3.2 M health checks dropped (11.6%, 859 MB) |
| Stored by the landing table | 0 rows |
| Enrichment (k8sattributes from the catalog) | version, team, node and zone on every container log |
| PCI masking | 766,724 card numbers masked over the month, 0 in clear |
| Spans (OTLP), 6 batches | 11 to 33 s each, 67 M spans for the history (15.7 per trace, a Client and a Server span per call) |
| Metrics, kubeletstats and k8s_cluster names | 28.4 M gauge points over the month, every 30 s (pods, nodes, namespaces, HikariCP, Kafka lag), in 3 batches of 15 s; 2.1 M uptime counters |
| Catch-up, Black Friday to now (on a Friday: 6 days and the current morning) | 5 statements of 2 to 22 s |
| Live stream | the simulator every minute: 650 spans and 250 log lines a minute in the morning, about 2,200 spans at the evening peak; fills the gap by itself after an idle period |
| Chaos switch (measured on 16 Oct, 10:00 to 10:04) | replays the incident minutes, a quarter of their traffic: 6,800 to 7,200 spans and 2,500 log lines a minute (120 HikariPool timeouts, 20 per pod), 26% of the payments failing, burn rate 500 to 600; the SQL fast-burn rule fires on the first minute, the p99 rule on the third |

## 03 · Search and correlation
| Measure | Value |
|---|---|
| Full-text search on 10 minutes (text index) | 172,033 rows read |
| Attribute filter through the text index on `ResourceAttributeItems` | 163,841 rows read |
| Scenario A, from a merchant ticket (log) | 4 queries: the merchant id leads to `maximumPoolSize=10` on a v2.4.1 pod |
| Scenario B, from a metric alert (pool pending over 20) | fires at 14:03 on the 6 pods; 5 queries lead to the rollout CHG-4117 |
| Scenario C, from a trace (new error message) | 290 "connection refused" spans from 14:21:07; 5 queries lead to the OOM kill, caused by the retries (fraud-scoring traffic x2.2) |

## 04 · Dashboards (RED rollups)
| Measure | Value |
|---|---|
| RED backfill, the whole month | 76.6 M spans → 720,523 rows in 11.8 s |
| Same curve from the rollup / from the spans | 8,193 / 81,921 rows read |
| spanmetrics histogram with exemplars, the month | 735,032 points in 7.6 s |
| p99 of POST /v1/payments | 300 ms before 13:58, 3.1 s during, back at 14:44 |

## 05 · SLOs and alerts
| Measure | Value |
|---|---|
| Burn rate, 1 h window, at the peak | 19 times the allowed rate on POST /v1/payments |
| Alerts of the month | 11 events, all on Black Friday: first page at 14:00, node memory pressure 14:19, OOM restart 14:22, resolved 14:47 |
| p99 rule | needs 150 calls a minute: on an ordinary day a p99 is only the slowest call |

## 06 · Investigation
| Measure | Value |
|---|---|
| Service map | 16 edges from the traces; payment → postgres p95 7.7 ms before, 3,033 ms during |
| Log patterns | 31 patterns for 6.4 M lines; the top new one is the HikariPool timeout (18,011 times, 0 before) |
| Root cause | `INSERT payflow.payments`, HikariPool timeout, only on v2.4.1 pods (CHG-4117) |
| Business impact, 13:58 to 14:50 | **15,349 failed payments, 1,576,893 EUR, 7,999 merchants** |

## 07 · Scale and cost (875 million log lines)
| Measure | Value |
|---|---|
| Write, 8 batches of 109 M lines | 28 to 31 s each, about 4 min in total, ~10 GB of memory per batch |
| Storage | 106 GB raw → 16.5 GB just after the inserts (x6.4, 20 bytes per line); background merges keep compressing |

| Query (service at rest) | Without | With | Rows read |
|---|---|---|---|
| Rare word, text index | 4.27 s | **774 ms** | 875 M → 286,720 |
| Frequent word (HikariPool), text index | 3.09 s | **367 ms** | 875 M → 9.7 M |
| One trace id, bloom filter alone / with a time range | 2.96 s | **22 ms** | 1.2 M → 368,641 |
| Errors per minute, projection | 1.08 s | **712 ms** | 875 M → 465,928 |
| Whole trace via the lookup table | | **454 ms** | 245,761 |
| Heavy regex aggregation, query cache | 6.99 s | **1 ms** | 875 M → 0 |
| Same filter again, query condition cache | 2.94 s | **14 ms** | 875 M → 745,472 |
| Full scan, 3 replicas | 7.03 s | **3.56 s** (x2) | 875 M |

| Lever | Value |
|---|---|
| Rollup in ClickStack's convention, the month | 76.6 M spans → 1.7 M rows in 8.7 s; Black Friday alone: 21.5 M spans → 53,926 rows (399 spans per row) |
| Retention sampling (errors and traces over 1 s) | 602,753 spans kept, 2.8% of Black Friday, every trace of the incident |
| Head sampling at 10% | the error rate is preserved, the rare traces are not |

## 08 · AI and governance
| Measure | Value |
|---|---|
| GDPR delete of a merchant over the month (lightweight DELETE) | 3,529 lines, 23 s |
| Row policies per team | 2 policies, applied to ClickStack, the SQL console and MCP alike |
| Self-observability of the run | 316 inserts (p50 1.2 s, max 33 s), 186 selects (p50 118 ms) |
