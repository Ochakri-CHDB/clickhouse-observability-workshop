# Measured results · ClickHouse observability workshop

Reference run of October 15, 2026, from scratch (`./run_all.sh`, 8 min in total) on the test service:
**ClickHouse Cloud 26.6, AWS eu-central-1, 3 replicas of 64 GB (16 vCPU each)**, the configuration recommended to attendees. Durations come from `system.query_log` (server time). The data is simulated and deterministic: volumes, rows read and results are the same for every attendee; durations vary by a few tens of percent from one run to another.
The same numbers appear as comments (`Measured`) under each statement of the SQL files.

> Orders of magnitude for the slides
> - **One day of a payment platform**: 1.38 M requests, 14.6 M spans, 8.1 M log lines, 612,000 metric points, generated in SQL
> - **910 million log lines** written in 4 minutes (8 batches of ~30 s, 114 M lines each), **9.1 GB on disk, 11 bytes per line** after merges
> - **Full-text search** of a rare word in 910 M lines: **0.46 s** with the text index, 3.5 s without (311,000 rows read instead of 910 M)
> - **One trace among 910 M lines**: **18 ms** with a time range, 2.7 s with the bloom filter alone
> - **From the page to the root cause**: 10 queries, each under half a second
> - **Mean time to detect**: 2 minutes (deploy at 13:58, first page at 14:00)

---

## 00 · First steps
| Measure | Value |
|---|---|
| 1 million log lines generated, parsed with a regex and aggregated | 364 ms |

## 01 · Fundamentals and inventory
| Measure | Value |
|---|---|
| Inventory | 12 nodes, 9 services, 49 pods (payment: 3 generations of 6), 11 deployment periods, 20,000 merchants |
| Every table of the inventory | created and filled in under 0.1 s each |

## 02 · Bronze
| Measure | Value |
|---|---|
| Requests generated for the day | 1.38 M (15/s at night, 33/s during the flash sale) |
| Raw records loaded, 00:00 to 20:00 | 6 M container log lines and 354 Kubernetes events, in 4 batches of 4.7 to 8.5 s |
| Whole day in bronze | 8.1 M records, 3.8 GB of JSON, **341 MB on disk (x11.5)** |
| Card numbers in clear in bronze | 179,450 lines, all from one card-network-adapter pod left in DEBUG |
| Errors in the raw text, 14:00 to 15:00 | 18,883, versus ~50 per hour the rest of the day |

## 03 · Silver
| Measure | Value |
|---|---|
| Log pipeline backfill (2 batches) | 2.1 M lines in 4.9 s, 3.9 M lines in 7.9 s |
| Continuous flow, 20:00 to 24:00 through 2 materialized views | 2.1 M raw records → 2.1 M OpenTelemetry logs, 18.7 s for generation and parsing |
| Logs with a trace id | 95.3% |
| Card numbers masked | 244,982 lines, 0 left in clear in silver |
| Spans written | 14.6 M in 4 batches of 5.4 to 9.3 s (10.6 spans per trace) |
| Latency histograms from the spans (spanmetrics) | 23,350 points in 668 ms |
| Pod gauges every 15 s / HikariCP / restarts | 426,240 / 103,680 / 53,280 points |
| Storage | otel_traces 662 MB (x8.2), otel_logs 342 MB (x9), metrics under 6 MB |

## 04 · Dictionaries
| Measure | Value |
|---|---|
| Range dictionary: change live at a given time | 2 ms |
| Payment error spans attributed to CHG-4117 | 37,084 (972 more under CHG-4118: v2.4.1 pods still running during the rollback) |
| Revenue per merchant tier, 941,000 payments: dictGet / JOIN | 302 ms / 65 ms (the JOIN is faster here: 20,000 merchants only) |
| Memory of the 5 dictionaries | 12 MB in total (merchants), the others under 60 KB |

## 05 · Gold
| Measure | Value |
|---|---|
| RED backfill | 8.3 M server spans → 20,165 rows in 1.25 s |
| p99 of POST /v1/payments | 300 ms before 13:58, 3.1 s during, back at 14:44 |
| Error rate of POST /v1/payments | 0.15% before, up to 31.8% at 14:15 |
| Burn rate, 1 h window, at the peak | over 400 times the allowed rate |
| Alerts | 11 events: first page at 14:00 (2 minutes after the deploy), node memory pressure 14:19, OOM restart 14:22, resolved 14:47 |
| Service map | 16 edges rebuilt from the traces; payment → postgres p95 7.7 ms before, 3,033 ms during |
| Log patterns | 8,308 patterns from 6.7 M lines; the top new pattern of the incident is the HikariPool timeout (18,011 times, 0 before) |

## 06 · Performance (910 million log lines)
| Measure | Value |
|---|---|
| Write, 8 batches of 114 M lines | 27.9 to 31.2 s per batch, about 4 min in total, ~10 GB of memory per batch |
| Storage after merges | 108 GB raw → **9.1 GB, x11.8, 11 bytes per line** |

| Query | Without | With | Rows read without → with |
|---|---|---|---|
| Rare word, text index | 3.45 s | **461 ms** | 910 M → 311,296 |
| Frequent word (HikariPool), text index | 2.97 s | **333 ms** | 910 M → 9.5 M |
| One trace id, bloom filter alone / with a time range | 2.73 s | **18 ms** | 1.8 M → 835,584 |
| Errors per minute, projection | 890 ms | **115 ms** | 910 M → 593,063 |
| Whole trace via the trace id lookup table | | **28 ms** | 188,416 |
| Heavy regex aggregation, query cache | 6.89 s | **1 ms** | 910 M → 0 |
| Same filter again, query condition cache | 1.71 s | **13 ms** | 593 M → 540,672 |
| Full scan, 3 replicas (parallel replicas) | 6.8 s | **3.77 s** (x1.8) | 910 M (split across 3) |

Measured on a service at rest. Run right after the 8 batches, while merges are still running, the same queries are 2 to 3 times slower and parallel replicas bring little: give the service a few minutes after module 6 step 2.

## 07 · Investigation and operations
| Measure | Value |
|---|---|
| The 10 questions of the investigation | 3 to 414 ms each |
| Root cause | `INSERT payflow.payments`, HikariPool timeout, only on v2.4.1 pods (26.5% errors) versus 0 on v2.4.0 pods at the same time |
| HikariCP during the incident | pool 10, 10 active, 45 to 49 threads waiting (v2.4.0: pool 50, ~4 active, 0 waiting) |
| Business impact, 13:58 to 14:50 | **15,349 failed payments, 1.58 M EUR, 7,999 merchants** |
| Timeline | deploy 13:58, first error 13:58:03, page 14:00, OOM 14:21:07, rollback 14:42, last error 14:43:39, resolved 14:47 |
| Replay of the day from bronze, then REPLACE PARTITION | 8.1 M lines rebuilt in 15.6 s, identical counts per severity, atomic swap |
| GDPR delete of a merchant (lightweight DELETE) | 1,017 lines, 3 to 38 s depending on the load |

## 08 · ClickStack, dashboards, API, agents
| Measure | Value |
|---|---|
| Dashboard tiles on gold | a few milliseconds, a few thousand rows read |
| Status API (parameterized view on slo_burn) | 11 rows for 10 minutes, a few ms |
| ClickStack | reads `payflow_otel` directly, sources inferred from the OpenTelemetry schema |
