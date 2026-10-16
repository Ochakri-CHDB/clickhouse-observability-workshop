# Module 3 · Search and correlation in ClickStack

The month of PayFlow is in the OpenTelemetry tables, and a live stream adds the current minute every minute. Now you look at it the way an on-call engineer does, in **ClickStack**, the observability UI that comes with your ClickHouse Cloud service. No prior knowledge of ClickStack is needed: every click is described. Then two SQL files show what ClickStack runs for you.

Duration: 45 min.

| File | Content |
|---|---|
| `01_under_the_hood.sql` | the search as SQL, the text indexes and EXPLAIN, log to trace to pod metrics, live tail |
| `02_correlation_scenarios.sql` | three investigations: from a log, from a metric alert, from a trace |

---

## Step 0 · Your Black Friday date (1 min)

The data is relative to the day you run the workshop: Black Friday is **the last Friday before today**. In the SQL console, run:

```sql
SELECT pf_black_friday() AS black_friday, pf_day(-29) AS month_starts, now() AS now_utc;
```

Write the date down. Everywhere below, **the incident** means that date, from 13:20 to 15:20 UTC. The screenshots of this guide were taken with a Black Friday on 9 October: your dates differ, the curves are the same.

---

## Step 1 · Open ClickStack (2 min)

1. In the [ClickHouse Cloud console](https://console.clickhouse.cloud), open your service.
2. In the left menu, near the bottom, click **ClickStack**. It opens in a new browser tab (`hyperdx.clickhouse.cloud`), already connected to your service: no user, no password, no install.

The left menu of ClickStack is the map of this workshop:

| Menu | What it is | Module |
|---|---|---|
| **Search** | search and browse logs or traces, live tail | 3 |
| **Saved Searches** | searches you saved, to reuse or alert on | 3, 5 |
| **Chart Explorer** | build a chart from any source, without SQL | 3, 4 |
| **Alerts** | every alert of the team and its state | 5 |
| **Service Map** | the services and the calls between them, from the traces | 6 |
| **AI notebooks** | an investigation assistant that writes and runs the queries | 8 |
| **Dashboards** | your dashboards, and presets (Services, Kubernetes) | 4 |
| **Team Settings** | sources, members and roles, webhooks, MCP | 3, 5, 8 |

## Step 2 · Show times in UTC (1 min)

ClickStack shows times in the time zone of your browser. The workshop speaks UTC.

1. Bottom left, click your name, then **User Preferences**.
2. **Time format**: `24h`. **Use UTC time**: on. Close the window.

A small `UTC` badge appears next to the ClickStack logo.

![Use UTC time](../img/03_preferences_utc.png)

---

## Step 3 · Declare the sources (8 min)

A **source** tells ClickStack where a signal lives: which table, which columns. Our tables are in the database `payflow_otel`.

1. Left menu, **Team Settings**, tab **Data**. The **Sources** list may already contain sources of other demos: leave them.
2. Click **Add source** (bottom of the list) and fill in:

   | Field | Logs | Traces | Metrics |
   |---|---|---|---|
   | Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
   | Section | `PayFlow` | `PayFlow` | `PayFlow` |
   | Source Data Type | **Logs** | **Traces** | **OTel metrics** |
   | Server Connection | `Default` | `Default` | `Default` |
   | Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
   | Table | `otel_logs` | `otel_traces` | (filled in: gauge, histogram, sum) |

   - In **Database** and **Table**, type the first letters, then click the name in the list.
   - As soon as the table is chosen, a message says *Automatically inferred source configuration from table schema*: our tables follow the OpenTelemetry exporter schema exactly, so ClickStack fills in every column by itself (timestamp, service, severity, body, trace id...).
   - The **Section** groups the three sources under `PayFlow` in every source menu.
3. Click **Save New Source**. Do the same for the traces, then the metrics.

![Source settings](../img/03_source_logs.png)

4. Link the sources, so that one click jumps from a signal to another (**correlated sources**):
   - in **PayFlow traces**, field **Correlated Log Source**: `PayFlow logs`;
   - in **PayFlow metrics**, field **Correlated Log Source**: `PayFlow logs`.

   Open **PayFlow logs** (the arrow at the end of its row), then **Configure Optional Fields**: ClickStack has filled in **Correlated Trace Source** and **Correlated Metric Source** by itself.
5. Still in **PayFlow logs**, optional fields, **Highlighted Attributes**, **Add expression**: `ResourceAttributes['service.version']`, alias `version`. Click the check mark, then **Save Source**. The version of the pod will be shown on top of every log line you open. In **PayFlow traces**, **Highlighted Trace Attributes**: `SpanAttributes['merchant.id']`, alias `merchant`.

---

## Step 4 · Search (10 min)

Left menu, **Search**. The screen, from top to bottom:

| Zone | Use |
|---|---|
| source menu (top left) | which source you search: choose **PayFlow logs** |
| `SELECT` | the columns of the results table; leave it |
| `ORDER BY`, **Save**, **Alerts** | sort; save the search; put an alert on it |
| language menu (`SQL` or `Lucene`) | how you write the search: choose **Lucene** |
| the search bar | what you look for |
| the time range (calendar icon) | when |
| **Run** | runs the search (or press Enter in the search bar) |
| the histogram | how many results per minute, colored by severity |
| **Filters** (left) | the values of each field, click to filter |
| the results | one line per log line, click to open it |

**Set the time range of the incident.** Click the time range (calendar icon). On the left, ready-made ranges (`Last 15 minutes` to `Last 30 days`). On the right, two tabs:
- **Around a time**: a moment and a duration around it. This is the quickest: **Time** `YYYY-MM-DD 14:20:00` (your Black Friday date), **Duration ±** `1h`, then **Apply**. You get 13:20 to 15:20, the incident with an hour of normal traffic around it.
- **Time range**: a start and an end. Type the start, click the end field (close the small calendar if it opens), type the end, then **Apply**.

Both accept plain words too: *last friday at 14:20* works. The range stays when you move between Search, Chart Explorer and the dashboards.

Now type each search below in the search bar, press Enter, and look:

| Type | What you see |
|---|---|
| `SeverityText:ERROR` | the error histogram rises at 13:58, falls at 14:44 |
| `ServiceName:payment SeverityText:ERROR` | only one message: the HikariPool timeout |
| `"maximumPoolSize"` | the startup line of every payment pod: 10 in v2.4.1 |
| `ServiceName:k8s-events -EventName:Unhealthy` | the rollout, the memory pressure on ip-10-0-3-17, the OOM kill |
| `"pan="` | card numbers, all masked by the gateway of module 2 |

![Search](../img/03_search_errors.png)

- Lucene in short: `field:value`, `"exact phrase"`, `-` to exclude, `*` as a wildcard, `AND`, `OR`. A nested attribute is written with dots: `ResourceAttributes.k8s.pod.name:payment*`.
- Switch the language menu to **SQL** and type a `WHERE` clause instead: `ResourceAttributes['service.version'] = 'v2.4.1' AND SeverityNumber >= 17` shows the errors of the faulty version only.
- **Filters**: open `ServiceName` and tick `payment`; open `ResourceAttributes` to filter on `service.version`, `k8s.pod.name` or `service.team` (added by the gateway in module 2). Drag across the histogram to zoom on a few minutes.
- **Save a search**: source **PayFlow logs**, search `ServiceName:payment SeverityText:ERROR`, click **Save** (top right). The **Save Search** window shows the query it saves (SELECT, FROM, WHERE, ORDER BY); type the **Name** `Payment errors`, **Save**. The page title becomes *Payment errors*, the button **Save** becomes **Update** (to save a change), and the search appears in **Saved Searches**. Module 5 puts an alert on it.

### Live tail
Click the time range, choose **Live Tail** at the top of the list, clear the search bar: the newest lines arrive at the top, a minute of traffic every minute (the live stream of module 2). **Resume Live Tail** above the histogram restarts it after you scroll; pick a range again to leave it.

---

## Step 5 · From a log line to its trace, then to its pod (8 min)

1. Range: the incident. Search `ServiceName:checkout SeverityText:ERROR`, click a line. A side panel opens:
   - on top: the message, the service, the time, and the highlighted attribute `version`;
   - tabs: **Overview** (every attribute), **Column Values**, **Service Map**, **Surrounding Context** (the lines just before and after), **Infrastructure**.
2. Click **View Trace** (top right): the waterfall of the request.
   - the summary line counts the spans, the logs and the errors (`11 spans, 2 logs, 8 errors`); **Show** toggles spans, logs and span events: the log lines of the request are drawn inside the waterfall, with the spans that wrote them;
   - the highlighted attribute `merchant` is shown above the waterfall (step 3);
   - the long red bars end at `INSERT payflow.payments` in payment: 3 seconds waiting for a connection, then the log line `HikariPool-1 - Connection is not available`;
   - click a bar: on the right, **Overview** with the exception, the breadcrumbs and every attribute;
   - card network, ledger and notification never ran.

   ![Trace waterfall](../img/03_trace_waterfall.png)
3. Back to the log line, tab **Infrastructure**: CPU, memory and disk of the pod that wrote the line (30 minutes, 1 hour or 1 day around it), its **Pod Timeline** (the Kubernetes events of the pod), and the same three charts for its node. ClickStack finds them through the pod uid and the node name of the line: the metric names follow the kubeletstats receiver.
4. Tab **Service Map**: the path of this one request through the services. Tab **Surrounding Context**: the lines just before and after, on the same pod.

---

## Step 6 · Three ways into the incident (15 min)

An investigation starts from whatever reaches you first. The three scenarios below reach the same incident from three signals; `02_correlation_scenarios.sql` runs each one in SQL, step by step, with the answer expected at every step. Range: the incident, for all three.

| | Starts from | Walks through | Ends at |
|---|---|---|---|
| A | a **log**: a merchant ticket | trace, pod metrics, startup log | `maximumPoolSize=10` on a v2.4.1 pod |
| B | a **metric alert**: the pool saturates | metric by version, traces of the pod, their logs, Kubernetes events | the rollout CHG-4117 |
| C | a **trace**: a new error message | logs of the pod, memory and request rate, Kubernetes events | the OOM kill on ip-10-0-3-17, a consequence of the first bug |

### Scenario A · From a log
A ticket: "merchant m_16523, a payment failed just after 14:09".
1. **Search**, source **PayFlow logs**: `LogAttributes.merchant_id:m_16523 SeverityText:ERROR`. One checkout line: "payment service returned 503". checkout only relays the error.
2. Open the line, **View Trace**: the red bar at the bottom of the waterfall is `INSERT payflow.payments` in payment, 3 seconds waiting for a connection. Click it: in its attributes, `k8s.pod.name` is the payment pod.
3. **Chart Explorer** (left menu): **Data Source** `PayFlow metrics`; in the metric box type `hikaricp.connections.pending` and pick `hikaricp.connections.pending (Gauge)`; aggregation **Maximum**; Where `ResourceAttributes.k8s.pod.name:<the pod>`; **Run**: dozens of requests waiting. **Add Series** with `hikaricp.connections.max`: a pool of 10.
4. Back to **Search**, PayFlow logs: `ResourceAttributes.k8s.pod.name:<the pod> "maximumPoolSize"`. The pod logged `maximumPoolSize=10` at startup, version v2.4.1.

### Scenario B · From a metric alert
1. **Chart Explorer**, PayFlow metrics, `hikaricp.connections.pending`, **Maximum**, Group By `ResourceAttributes['k8s.pod.name']`, **Run**. The 6 payment pods cross 20 together at 14:03. This is what a chart alert with the threshold "above 20" evaluates: **Add alert**, under the series, opens the alert form (module 5 creates it).

   ![Pool pending per pod](../img/03_chart_pool_pending.png)
2. Change the metric to `hikaricp.connections.max` and the Group By to `ResourceAttributes['service.version']`: 50 for v2.4.0, 10 for v2.4.1.
3. **Search**, source **PayFlow traces**, range 14:03 to 14:04: `ResourceAttributes.k8s.pod.name:<the worst pod> SpanKind:Server StatusCode:Error`. Open a trace: its logs are shown with its spans (payment times out, checkout reports a 503, the gateway returns it).
4. **Search**, PayFlow logs: `ServiceName:k8s-events EventName:ScalingReplicaSet`. "rolling update CHG-4117" at 13:58: alert to change in four screens.

### Scenario C · From a trace
14:25. The pool is understood and a rollback is being prepared, but a trace shows another error.
1. **Search**, source **PayFlow traces**, range around 14:20 ± 5m: `StatusCode:Error SpanKind:Server`. In **Analysis Mode**, click **Event Patterns** and type `StatusMessage` in **Pattern Expression**: the error messages, grouped, with a trend each. One is new: "connect: connection refused" on `fraud.ScoreTransaction`, from 14:21:07 only.
2. Open one of these traces: checkout calls fraud-scoring, which refuses the connection. The span gives the pod and the node (`ip-10-0-3-17`). On a log line of fraud-scoring, tab **Infrastructure**: the pod memory climbs to 2.2 GB, then falls; the node is full.
3. **Search**, PayFlow logs: `ServiceName:fraud-scoring -SeverityText:INFO -"score="`. The queue grows, the feature cache nears its 2 GiB limit, a FATAL worker timeout.
4. **Search**, PayFlow logs: `ServiceName:k8s-events "ip-10-0-3-17"`: memory pressure at 14:19, the OOM kill at 14:21, the node back at 14:23. In **Chart Explorer**, PayFlow traces, count where `ServiceName:fraud-scoring SpanKind:Server`: the request rate doubled from 13:55, because checkout scores each retry of a failed payment again. Not a second bug: the same one. The rollback at 14:42 fixes both.

---

## Step 7 · Underneath (10 min)

Run `01_under_the_hood.sql` in the SQL console:
- the same search as SQL, and `EXPLAIN indexes = 1` to see the text index skip the granules without the word;
- an attribute filter answered by the text index of `ResourceAttributeItems`, without reading the map;
- the correlation log → trace → metrics, in three queries;
- the live tail as a plain `ORDER BY Timestamp DESC`.

Then `02_correlation_scenarios.sql`: the three scenarios, each in 4 or 5 queries. The keys are always the same: `TraceId` between logs and traces, the resource attributes (`k8s.pod.name`, `k8s.node.name`, `service.version`) toward the metrics, and a bounded time range (the trace lookup table gives the bounds of a trace).

Checkpoint: `OK` everywhere, in both files.
