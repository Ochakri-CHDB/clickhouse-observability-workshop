# Module 4 · Dashboards in ClickStack

A dashboard answers "is it working?" before anyone asks. `01_red_rollups.sql` builds the numbers behind it (RED per minute, the spanmetrics histogram); this README builds the dashboard itself in ClickStack.

Duration: 35 min. Run `01_red_rollups.sql` first (checkpoint `OK`).

> Range for the whole module: **the incident**, `2026-11-27 13:00` to `2026-11-27 16:00` (UTC), unless said otherwise.

---

## Step 1 · Chart Explorer: one question, one chart (5 min)

**Chart Explorer** (left menu) is a `GROUP BY` with a UI: a source, a metric, a filter, a group by.

| Source | Metric | Where | Group by | What you see |
|---|---|---|---|---|
| PayFlow traces | 99th percentile of `Duration / 1e6` | `SpanKind:Server` | `ServiceName` | three services jump to 3 s at 13:58 |
| PayFlow traces | Count | `StatusCode:Error` | `ResourceAttributes['service.version']` | only v2.4.1 fails |
| PayFlow metrics | `hikaricp.connections.pending` (gauge), Max | | `service.version` | dozens of threads waiting in v2.4.1, none in v2.4.0 |
| PayFlow metrics | `traces.span.metrics.duration` (histogram) | `span.name:"POST /v1/payments"` | | the spanmetrics histogram of module 4 file 01 |

**Text-to-chart**: the AI assistant of Chart Explorer turns a sentence into a chart. Try *"error count per service over time"*. If it is not available, Generative AI is not enabled on your team (module 8).

---

## Step 2 · The SRE dashboard (15 min)

**Dashboards**, **New Dashboard**, name `PayFlow · SRE`. Then **Add New Tile** for each tile:

| Tile | Type | Source | Settings |
|---|---|---|---|
| Requests per service | Line/Bar | PayFlow traces | Count, where `SpanKind:Server`, group by `ServiceName` |
| p99 latency per service | Line/Bar | PayFlow traces | 99th percentile of `Duration / 1e6`, where `SpanKind:Server`, group by `ServiceName` |
| Error rate | Number | PayFlow traces | Count, where `StatusCode:Error AND SpanName:"POST /v1/payments"`; color rule red above 100 |
| Errors by version | Pie | PayFlow logs | Count, where `SeverityText:ERROR`, group by `ResourceAttributes['service.version']` |
| Latency heatmap | Heatmap | PayFlow traces | `Duration / 1e6`, where `ServiceName:payment` |
| Top error messages | Table | PayFlow logs | Count, where `SeverityText:ERROR`, group by `Body` |

Then:
- **Filters**: **Edit Filters and Variables**, add a filter on `ServiceName` and one on `ResourceAttributes['service.team']`. Every tile follows them.
- **Release markers**: in the dashboard menu, **Show release markers**. A dashed line appears at 13:58 (v2.4.1) and at 14:42 (v2.4.0) on the time charts: ClickStack reads `service.version` from the telemetry, nothing to configure. The first question of every incident, answered on the chart.
- **Row-click drilldown**: on the *Top error messages* table, configure a row click that opens **Search** filtered on the row: from a message to its lines in one click.

---

## Step 3 · A SQL tile on the rollups (10 min)

Some questions need SQL: a join, a ratio, a rollup. Add a tile, choose the **SQL** tab, connection `Default`, type **Line**, and paste:

```sql
SELECT
    minute AS ts,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

`$__timeFilter(minute)` is replaced by the dashboard time range. The tile reads a few hundred rows of the rollup instead of millions of spans: this is what module 4 file 01 is for.

A second SQL tile, type **Table**, the error budget of the day:

```sql
SELECT
    sum(requests)                                                   AS requests,
    sum(errors)                                                     AS errors,
    round(100 * (1 - sum(errors) / sum(requests)), 3)               AS availability_pct,
    round(100 * sum(errors) / (sum(requests) * 0.0005), 1)          AS budget_spent_pct
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND toDate(minute) = '2026-11-27'
```

One bad release consumed many times the error budget of the day.

---

## Step 4 · Preset dashboards (5 min)

ClickStack ships ready-made dashboards:
- **Services**: HTTP, database and error views of every service, from the trace source. Open it on the incident range: the payment database calls stand out.
- **Kubernetes**: pods, nodes and namespaces from the metric source. Our pod metrics follow the kubeletstats names (`k8s.pod.cpu.utilization`, `k8s.pod.memory.working_set`); the views that need metrics we do not simulate stay empty.
- **Dashboard templates** (Browse dashboard templates): runtime metrics for Go, JVM, Node.js and .NET services.
