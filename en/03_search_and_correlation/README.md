# Module 3 · Search and correlation in ClickStack

The data is in the OpenTelemetry tables: the Black Friday day, and a live stream that adds a minute of traffic every minute. Now you look at it the way an on-call engineer does, in **ClickStack**, the observability UI of ClickHouse (HyperDX), which runs inside ClickHouse Cloud. Then three investigation scenarios walk from one signal to the others, and two SQL files show what ClickStack runs for you.

Duration: 45 min.

| File | Content |
|---|---|
| `01_under_the_hood.sql` | the search as SQL, the text indexes and EXPLAIN, log to trace to pod metrics, live tail |
| `02_correlation_scenarios.sql` | three investigations: from a log, from a metric alert, from a trace |

> ClickStack evolves quickly: a label can move. The principle does not change. Two time ranges matter in this module: **the incident**, an absolute range `2026-11-27 13:45` to `2026-11-27 15:00` (UTC), and **the live stream**, `Last 15 minutes`.

---

## Step 1 · Open ClickStack and check the sources (5 min)

1. In the Cloud console, open your service, then **ClickStack** in the left menu.
2. ClickStack looks for OpenTelemetry tables. Ours are in the database `payflow_otel`, not in `default`: go to **Team Settings**, then **Sources**, and create (or edit) one source per signal.

| Setting | Logs | Traces | Metrics |
|---|---|---|---|
| Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
| Source Data Type | Log | Trace | Metrics |
| Server Connection | `Default` | `Default` | `Default` |
| Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
| Table | `otel_logs` | `otel_traces` | Gauge `otel_metrics_gauge`, Histogram `otel_metrics_histogram`, Sum `otel_metrics_sum` |

Because the tables follow the exporter schema exactly, ClickStack fills in every column expression by itself (Timestamp, ServiceName, SeverityText, Body, TraceId, SpanId, Duration...).

3. Link the sources, so that one click jumps from a signal to another (**correlated sources**):
   - on **PayFlow logs**: *Correlated Trace Source* `PayFlow traces`, *Correlated Metric Source* `PayFlow metrics`;
   - on **PayFlow traces**: *Correlated Log Source* `PayFlow logs`, *Correlated Metric Source* `PayFlow metrics`.
4. Optional, on **PayFlow traces**: add a **Highlighted Trace Attribute** `SpanAttributes['merchant.id']`. It is shown above every trace waterfall.

---

## Step 2 · Search (10 min)

Open **Search**, source **PayFlow logs**, range **the incident**. The search bar speaks Lucene by default; a toggle switches it to SQL (any `WHERE` clause).

| Type | What you see |
|---|---|
| `SeverityText:ERROR` | the error histogram jumps at 13:58, falls at 14:44 |
| `ServiceName:payment SeverityText:ERROR` | only one message: the HikariPool timeout |
| `"maximumPoolSize"` | the startup line of every payment pod: 10 in v2.4.1, 50 before and after |
| `ServiceName:k8s-events -EventName:Unhealthy` | the rollout, the memory pressure on ip-10-0-3-17, the OOM kill |
| `"pan="` | card numbers, all masked by the gateway of module 2 |
| SQL mode: `ResourceAttributes['service.version'] = 'v2.4.1' AND SeverityNumber >= 17` | the errors of the faulty version only |

- Click a field in the left panel (`service.version`, `k8s.pod.name`, `service.team`) to filter on it. `service.team` and `cloud.availability_zone` were added by the gateway (module 2).
- Drag across the histogram to zoom on a time range.
- **Save** the search `ServiceName:payment SeverityText:ERROR` as `Payment errors`, with the tag `payments`. Module 5 puts an alert on it.

### Live tail
Switch the range to `Last 15 minutes` and turn on **Live tail**: the stream of module 2 scrolls by, one minute of traffic per minute.

---

## Step 3 · From a log line to its trace, then to its pod (10 min)

1. Range **the incident**, search `ServiceName:checkout SeverityText:ERROR`, open one line.
2. The side panel shows the line and its attributes. Open the **Trace** tab: the waterfall of the request, through `TraceId`.
   - 3 seconds spent in `INSERT payflow.payments`, the HikariPool exception as a span event;
   - card network, ledger and notification never ran.
3. Open the **Infrastructure** tab: the CPU and memory of the pod that served the request, from the metric source, matched on `k8s.pod.name`. The pod is not busy: it waits.
4. On a trace, the small **service map** above the waterfall shows the path of this one request.

---

## Step 4 · Three ways into the incident (15 min)

An investigation starts from whatever reaches you first. The three scenarios below reach the same incident from three signals; `02_correlation_scenarios.sql` runs each one in SQL, step by step, with the answer expected at every step. Range **the incident** for all three.

| | Starts from | Walks through | Ends at |
|---|---|---|---|
| A | a **log**: a merchant ticket | trace, pod metrics, startup log | `maximumPoolSize=10` on a v2.4.1 pod |
| B | a **metric alert**: the pool saturates | metric by version, traces of the pod, their logs, Kubernetes events | the rollout CHG-4117 |
| C | a **trace**: a new error message | logs of the pod, memory and request rate, Kubernetes events | the OOM kill on ip-10-0-3-17, a consequence of the first bug |

### Scenario A · From a log
14:12, a ticket: "merchant m_16523, a payment failed just after 14:09".
1. **Search**, source **PayFlow logs**: `LogAttributes.merchant_id:m_16523 SeverityText:ERROR`. One checkout line: "payment service returned 503". checkout only relays the error.
2. Open the line, tab **Trace**: the red span at the bottom of the waterfall is `INSERT payflow.payments` in payment, 3 seconds waiting for a connection. Click it: its resource attributes give the payment pod.
3. **Chart Explorer**, source **PayFlow metrics**, gauge `hikaricp.connections.pending` and then `hikaricp.connections.max`, filter `k8s.pod.name` = that pod: dozens of requests waiting, a pool of 10.
4. Back to **Search**, logs: `ResourceAttributes.k8s.pod.name:<the pod> "maximumPoolSize"`. The pod logged `maximumPoolSize=10` at startup, version v2.4.1.

### Scenario B · From a metric alert
1. **Chart Explorer**, source **PayFlow metrics**, gauge `hikaricp.connections.pending`, aggregation **Max**, group by `ResourceAttributes['k8s.pod.name']`, granularity 1 minute. The 6 payment pods cross 20 together at 14:03: this is what a chart alert with the threshold "above 20" evaluates (module 5 creates it).
2. Change the group by to `ResourceAttributes['service.version']` and chart `hikaricp.connections.max`: 50 for v2.4.0, 10 for v2.4.1. Turn on **Show release markers**.
3. **Search**, source **PayFlow traces**, range 14:03 to 14:04: `ResourceAttributes.k8s.pod.name:<the worst pod> SpanKind:Server StatusCode:Error`. Open a trace: the logs of the request appear with its spans (payment times out, checkout reports a 503, the gateway returns it).
4. **Search**, logs: `ServiceName:k8s-events EventName:ScalingReplicaSet`. "rolling update CHG-4117" at 13:58: alert to change in four screens.

### Scenario C · From a trace
14:25. The pool is understood and a rollback is being prepared, but a trace shows another error.
1. **Search**, source **PayFlow traces**, range 14:15 to 14:25: `StatusCode:Error SpanKind:Server -StatusMessage:"HikariPool"`. Group by `StatusMessage` (**Analysis Mode**, or a table in **Chart Explorer**): "connect: connection refused" on `fraud.ScoreTransaction`, from 14:21:07 only.
2. Open one of these traces: checkout calls fraud-scoring, which refuses the connection. The span gives the pod and the node (`ip-10-0-3-17`). Tab **Infrastructure**: the pod memory climbs to 2.2 GB, then falls.
3. **Search**, logs: `ServiceName:fraud-scoring -SeverityText:INFO -"score="`. The queue grows, the feature cache nears its 2 GiB limit, a FATAL worker timeout.
4. **Search**, logs: `ServiceName:k8s-events "ip-10-0-3-17"`: memory pressure at 14:19, the OOM kill at 14:21, the node back at 14:23. Chart the request rate of fraud-scoring: it doubled from 13:55, because checkout scores each retry of a failed payment again. Not a second bug: the same one. The rollback at 14:42 fixes both.

---

## Step 5 · Underneath (10 min)

Run `01_under_the_hood.sql` in the SQL console:
- the same search as SQL, and `EXPLAIN indexes = 1` to see the text index skip the granules without the word;
- an attribute filter answered by the text index of `ResourceAttributeItems`, without reading the map;
- the correlation log → trace → metrics, in three queries;
- the live tail as a plain `ORDER BY Timestamp DESC`.

Then `02_correlation_scenarios.sql`: the three scenarios, each in 4 or 5 queries. The keys are always the same: `TraceId` between logs and traces, the resource attributes (`k8s.pod.name`, `k8s.node.name`, `service.version`) toward the metrics, and a bounded time range (the trace lookup table gives the bounds of a trace).

Checkpoint: `OK` everywhere, in both files.
