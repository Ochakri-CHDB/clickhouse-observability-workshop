# Module 4 · Dashboards in ClickStack

A dashboard answers "is it working?" before anyone asks. `01_red_rollups.sql` builds the numbers behind it (RED per minute, the spanmetrics histogram); this README builds the dashboard itself in ClickStack, click by click.

Duration: 35 min. Run `01_red_rollups.sql` first (checkpoint `OK`).

> Range for the whole module: **the incident**, set with the time range, **Around a time**, Time `YYYY-MM-DD 14:20:00` (your Black Friday date, module 3 step 0), Duration ± `1h`. Some steps use `Last 1 hour` (the live stream) or `Last 30 days` (the whole month): it is said each time.

---

## Step 1 · Chart Explorer: one question, one chart (8 min)

**Chart Explorer** (left menu) is a `GROUP BY` with a form. The screen, from top to bottom:

| Zone | Use |
|---|---|
| **AI Assistant** (top, experimental) | describe a chart in a sentence, ClickStack fills the form |
| **Chart Name**, **Builder** / **SQL** | a name; the form or raw SQL |
| the chart types | Time Series, Table, Number, Bar, Pie, Search, Heatmap, Patterns, Markdown |
| **Data Source** | PayFlow logs, traces or metrics |
| the series line | the aggregation (Count of Events, Sum, 99th Percentile, Average, Maximum...), the column or metric, **Where**, **Group By** |
| **Add Series**, **Add Formula**, **Add alert** | more lines on the same chart, a formula between series (A / B), an alert on the chart |
| the time range, the granularity, **Run** | when, per how much time, run |
| **Generated SQL** (bottom) | the query ClickStack runs: open it once |

Build each chart below. For a metric source, a metric box appears next to the aggregation: type the first letters, then pick the name with its type, such as `hikaricp.connections.pending (Gauge)`. For a percentile on traces, a **SQL Column** box appears: type `Duration / 1e6` (nanoseconds to milliseconds).

| Data Source | Aggregation | Column or metric | Where | Group By | What you see |
|---|---|---|---|---|---|
| PayFlow traces | 99th Percentile | `Duration / 1e6` | `SpanKind:Server` | `ServiceName` | three services jump to 3 s at 13:58 |
| PayFlow traces | Count of Events | | `StatusCode:Error` | `ResourceAttributes['service.version']` | only v2.4.1 fails |
| PayFlow metrics | Maximum | `hikaricp.connections.pending (Gauge)` | | `ResourceAttributes['service.version']` | dozens of threads waiting in v2.4.1, none in v2.4.0 |
| PayFlow metrics | 99th Percentile | `traces.span.metrics.duration (Histogram)` | `span.name:"POST /v1/payments"` | | the spanmetrics histogram of `01_red_rollups.sql` |
| PayFlow traces | Count of Events | | `SpanKind:Server ServiceName:api-gateway` | | range `Last 30 days`: four weeks, the weekends lower, the Black Friday peak |

**Text-to-chart**: open **AI Assistant** at the top, type *error count per service over the last hour*, send. ClickStack fills the form for you; check the Where and Group By it chose before you trust it. If the assistant is missing, Generative AI is off for your team (Team Settings, **API & Agents**, **Configure Generative AI**).

---

## Step 2 · The SRE dashboard (15 min)

1. Left menu, **Dashboards**. On top, the **Preset Dashboards** (step 4); below, your dashboards.
2. **New Dashboard** (top right), then **Saved Dashboard** (kept for the team). The other choices: **Temporary Dashboard** (only in your browser) and **Generate with AI** (a dashboard drafted from your data, try it at the end).
3. The dashboard opens as *My Dashboard*. Click the pencil next to the name, type `PayFlow · SRE`, press Enter.
4. **Add**, then **New Tile**. The tile editor is Chart Explorer in a window: fill it in, **Run** to preview, **Save**. Create these tiles:

| Tile name | Chart type | Data Source | Settings |
|---|---|---|---|
| Requests per service | Time Series | PayFlow traces | Count of Events, Where `SpanKind:Server`, Group By `ServiceName` |
| p99 latency per service | Time Series | PayFlow traces | 99th Percentile of `Duration / 1e6`, Where `SpanKind:Server`, Group By `ServiceName` |
| Payment errors | Number | PayFlow traces | Count of Events, Where `StatusCode:Error SpanName:"POST /v1/payments"`; **Display Settings**, **Conditional colors**, **Add rule**: `>` `100`, the red dot under *Semantic*, **Apply** |
| Errors by version | Pie | PayFlow logs | Count of Events, Where `SeverityText:ERROR`, Group By `ResourceAttributes['service.version']` |
| Latency heatmap | Heatmap | PayFlow traces | `Duration`, Where `ServiceName:payment` |
| Top error messages | Table | PayFlow logs | Count of Events, Where `SeverityText:ERROR -ServiceName:api-gateway`, Group By `Body` (the gateway access lines are excluded: each one is unique, they would not group) |

> **Attention**: in the tile editor, **Escape** asks to discard the tile. Close a dropdown by clicking next to it. Type in a box only after clicking inside it, or the text lands in the next box (check **ORDER BY**, it must stay empty here).

On the incident range the dashboard looks like this: the payment p99 at 3 s from 13:58 to 14:44, the error count in red, the HikariPool timeout at the top of the table.

![The SRE dashboard](../img/04_dashboard_sre.png)

Then:
- **Arrange**: drag a tile by its title, resize it from its bottom right corner. Each tile has its own toolbar: chart type, a magnifier (open the matching events in Search), a bell (alert on the tile), full screen, and **⋮** (edit, duplicate, delete).
- **Filters**: the filter icon left of **Run** opens **Filters and Variables**. **Add new filter**: Display name `Service`, Data source **PayFlow traces**, Filter expression `ServiceName` (pick it in the suggestions), leave **Broadcast filter condition** checked (the value applies to every tile, whatever its source), **Save filter**, **Close**. A **Service** dropdown appears above the tiles: pick `payment`, every tile follows. The other options: **Single select**, **Required** (tiles wait for a value), **Available as variable** (a `$variable` for the SQL tiles of step 3). Add a second one on `ResourceAttributes['service.team']` the same way.
- **Release markers**: dashboard menu **⋮** (top right), **Show release markers**. A dashed line labelled `v2.4.1` appears at 13:58 on the time charts: ClickStack reads `service.version` in the telemetry, nothing to configure. The first question of every incident, answered on the chart.

  ![Release marker](../img/04_dashboard_release_marker.png)
- **Row-click drilldown**: click the *HikariPool-1* row of *Top error messages*. Search opens on PayFlow logs, on the same range, with the tile Where and a filter `Body IN ('HikariPool-1 ...')`: the lines behind the number. This is the default. To change it, **⋮**, edit the tile, **Row Click Action: Default**: **Search** (another source, a Where written with `{{ColumnName}}` from the clicked row), **Dashboard** (another dashboard with filters, such as `ServiceName = '{{ServiceName}}'`), **External** (a URL, such as a runbook). Browser **Back** returns to the dashboard.
- **Live**: set the range to `Last 1 hour` and click **Live**: the dashboard refreshes by itself on the live stream.
- The menu **⋮** also has **Enter kiosk mode** (a wall screen), **Show alert annotations** (module 5), **Export Dashboard** and **Import New Dashboard** (JSON, to share a dashboard between services).

---

## Step 3 · A SQL tile on the rollups (8 min)

Some questions need SQL: a join, a ratio, a rollup. **Add**, **New Tile**, then **SQL** (top right of the editor, next to **Builder**): a message *Chart converted to SQL* appears and the editor is prefilled with the SQL of the Builder form. **Connection** `Default`; clear **Source** with its **x** (the query reads a rollup, not a source). Above the editor, **SQL Chart Instructions** gives the rules and the macros:

| Macro | Becomes |
|---|---|
| `$__timeFilter(col)` | `col` within the dashboard time range |
| `$__timeInterval(col)` | `col` rounded to the granularity of the chart |
| `$__fromTime`, `$__toTime` | the bounds of the range, in milliseconds |
| `$__sourceTable`, `$__filters` | the table of the chosen source, the dashboard filters (with a Source) |

The first DateTime column is the time axis, each numeric column a series, each String column a group. Click inside the editor, select all (Cmd+A or Ctrl+A), delete, and paste:

```sql
SELECT
    $__timeInterval(minute)                                             AS ts,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

Two orange warnings ask for `$__sourceTable` and `$__filters`: advice for tiles on a source, ignore them here. Name it `POST /v1/payments, rollup`, **Run**, **Save**. The tile reads a few hundred rows of the rollup instead of millions of spans: this is what `01_red_rollups.sql` is for. Set the range to `Last 30 days`: still instant.

A second SQL tile, chart type **Table**, the error budget of Black Friday (the table type needs no time macro):

```sql
SELECT
    sum(requests)                                                   AS requests,
    sum(errors)                                                     AS errors,
    round(100 * (1 - sum(errors) / sum(requests)), 3)               AS availability_pct,
    round(100 * sum(errors) / (sum(requests) * 0.0005), 1)          AS budget_spent_pct
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND toDate(minute) = pf_black_friday()
```

One bad release consumed many times the error budget of the day.

---

## Step 4 · Preset dashboards (4 min)

**Dashboards**, **Preset Dashboards**:
- **Services**: HTTP, database and error views of every service, from a trace source. Pick **PayFlow traces** at the top. On the incident range, the payment database calls stand out.
- **Kubernetes**: pick **PayFlow logs** and **PayFlow metrics** at the top. Tabs **Pods**, **Nodes**, **Namespaces**: CPU, memory, phase, restarts and uptime of every pod, the nodes and their readiness. Our metrics follow the names of the kubeletstats and k8s_cluster receivers, which is exactly what this dashboard reads. On the incident range, the fraud-scoring pod of ip-10-0-3-17 shows its restart.
- **Browse dashboard templates**: runtime metrics for Go, JVM, Node.js and .NET services, to import.
