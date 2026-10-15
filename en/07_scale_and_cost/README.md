# Module 7 · Scale and cost

PayFlow runs in 8 regions. This module scales the logs to **875 million lines**, measures what ClickHouse does with them, then works on the bill: rollups, retention, sampling.

Duration: 35 min. Three SQL files, then one step in ClickStack.

| File | Content |
|---|---|
| `01_billion_lines.sql` | two weeks x 8 regions of logs, written in 8 statements of ~30 s; storage and compression per column |
| `02_search_and_indexes.sql` | text index, bloom filter, time-bounded trace lookup, projection, query cache, query condition cache, 3 replicas: every query with and without its helper |
| `03_rollups_retention_sampling.sql` | a rollup in ClickStack's convention, the cost of each signal per day, TTL policies, head and retention sampling, sizing |

> Give the service a few minutes after the 8 inserts of `01_billion_lines.sql`: while background merges run, the queries of file 02 are 2 to 3 times slower, and parallel replicas bring little.

---

## In ClickStack · Let ClickStack use the rollup (10 min)

`03_rollups_retention_sampling.sql` creates `payflow_otel.otel_traces_1m`: per minute, service, span name and status, with the aggregate columns named `count`, `avg__Duration`, `max__Duration`, `quantiles__Duration`. ClickStack can answer charts, dashboard tiles and alerts from it, without changing them.

1. **Team Settings**, **Sources**, open **PayFlow traces**, **Edit configuration**, section **Materialized views**, **Add materialized view**.
2. Database `payflow_otel`, table `otel_traces_1m`. ClickStack infers the timestamp (`Timestamp`), the dimensions (`ServiceName`, `SpanName`, `StatusCode`) and the metrics; check that `Duration` maps to `avg__Duration`, `max__Duration` and `quantiles__Duration`.
3. Granularity: **1 minute**. Minimum date: `2026-11-27 00:00:00` (the backfill of the file).
4. Save. Open the tile *p99 latency per service* of `PayFlow · SRE` on a full day: an indicator shows that the chart was served by the materialized view.

Rules worth knowing:
- the chart granularity must be a multiple of the view's (1 min view: charts at 1, 5, 15, 60 min);
- a view only contains what was inserted after its creation: backfill it, or set the minimum date;
- start with one rollup per source (count and duration by service), around ten at most.

## Read and write isolation (to know, not to do)

With a **warehouse**, ClickStack can run on a second, read-only service that shares the same storage: dashboards, alerts and notebooks never slow down ingestion, and each side scales on its own. ClickStack recommends it above about 100 TB a month.
