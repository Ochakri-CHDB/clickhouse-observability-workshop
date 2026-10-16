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

`03_rollups_retention_sampling.sql` creates `payflow_otel.otel_traces_1m`: per minute, service, span name and status, with the aggregate columns named `count`, `avg__Duration`, `max__Duration`, `quantiles__Duration` (ClickStack's naming convention). Declared on the source, it lets ClickStack answer charts, dashboard tiles and alerts from 1.7 million rows instead of 77 million spans, without changing them.

1. **Team Settings** (left menu), tab **Data**. In the list of sources, click the arrow at the end of the **PayFlow traces** line to open it. Leave the switch at the right of each line as it is.
2. Scroll down to **Materialized Views**, click **Add Materialized View**.
3. The database is already `payflow_otel`. In **Table**, type `otel_traces_1m` and click it in the list. The **⋮** next to it has **View schema**, to check the columns.
4. Fill in the form (ClickStack does not guess it):
   - **Timestamp Column**: `Timestamp`;
   - **Granularity**: `1 minute`;
   - **Minimum Date**: the first day of the history, `SELECT pf_day(-29)` in the SQL console (the backfill of the file starts there);
   - **Dimension Columns**: `ServiceName, SpanName, StatusCode`;
   - **Pre-aggregated Columns**, one **Add Column** per line: `avg`, `Duration`, `avg__Duration`; `max`, `Duration`, `max__Duration`; `quantile`, `Duration`, `quantiles__Duration`; `count`, `count` (count has no source column).
5. **Save Source**. A message *Source updated* confirms.

> **Attention**: in these lists, clicking the option that is already selected (with a check mark) clears it. If the save fails with `databaseName: Required`, pick another database, then `payflow_otel` again.

![Materialized view on the source](../img/07_source_mv.png)

Check it:
1. **Chart Explorer**, **PayFlow traces**, **Count of Events**, **Group By** `ServiceName`, range `Last 7 days`, **Run**. A green **ACCELERATED** badge appears top right, and **Generated SQL** (bottom) reads `FROM payflow_otel.otel_traces_1m` with `SUM(count)`.
2. Now type `SpanKind:Server` in **Where**, **Run**: the badge turns orange, **NOT ACCELERATED**. Click it: the view is **INCOMPATIBLE**, and the panel lists what it can serve (**Available Group and Filter Columns**: `ServiceName`, `SpanName`, `StatusCode`). `SpanKind` is not a dimension of the rollup, so ClickStack goes back to the spans, silently and correctly.
3. On a long range, the chart fills in several passes, the most recent days first: wait for it to settle before reading it.

![Accelerated chart and its SQL](../img/07_accelerated_sql.png)

Rules worth knowing:
- every column of **Where** and **Group By** must be a dimension of the view: choose the dimensions from the charts you want to accelerate (the tiles of module 4 filter on `SpanKind`: add it to the rollup to accelerate them too);
- the chart granularity must be a multiple of the view's (1 min view: charts at 1, 5, 15, 60 min);
- a view only contains what was inserted after its creation: backfill it, or set the minimum date;
- start with one rollup per source (count and duration by service), around ten at most.

## Read and write isolation (to know, not to do)

With a **warehouse**, ClickStack can run on a second, read-only service that shares the same storage: dashboards, alerts and notebooks never slow down ingestion, and each side scales on its own. ClickStack recommends it above about 100 TB a month.
