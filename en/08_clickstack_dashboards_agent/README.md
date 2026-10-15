# Module 8 · ClickStack, dashboards, API and ClickHouse Agents

Everything so far was SQL. This module shows the same investigation the way an SRE lives it, in the ClickHouse Cloud console:

| Part | For whom | What | Time |
|---|---|---|---|
| 1. ClickStack | the on-call engineer | search logs, open traces, chart metrics, build a dashboard and an alert, on the tables of modules 3 to 5 | 35 min |
| 2. SQL console dashboard | the team lead | 4 tiles on the gold tables | 10 min |
| 3. Status API | the status page of PayFlow | a Query API endpoint on the SLO table | 10 min |
| 4. ClickHouse Agents | everyone | questions in plain English, dashboards on demand, anomaly detection in Python | 25 min |

No file to run in this module: every query is below, ready to paste.

> The workshop data is dated **Friday 27 November 2026, UTC**. Every time picker of this module must be set to an **absolute range**, for example `2026-11-27 13:45` to `2026-11-27 15:00` (UTC). "Last 15 minutes" shows nothing.
>
> ClickStack and ClickHouse Agents evolve quickly: a button label can move. The principle does not change.

---

## 1. ClickStack: the incident, in clicks

ClickStack is the observability stack of ClickHouse: its UI (HyperDX) runs inside ClickHouse Cloud and queries your service directly. Nothing to install: the tables of module 3 already follow the OpenTelemetry schema it expects.

### Step 1 · Open ClickStack
1. In the Cloud console, open your service.
2. Launch **ClickStack** from the service (left menu).
3. On the **Getting Started** page, skip the ingestion wizard: the data is already there. Go to **Team Settings**, then **Sources**.

### Step 2 · Declare the three sources
Create one source per signal. Because the tables follow the default OpenTelemetry schema, ClickStack fills in the column expressions by itself once the table is chosen.

| Setting | Logs | Traces | Metrics |
|---|---|---|---|
| Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
| Source Data Type | Log | Trace | Metrics |
| Server Connection | `Default` | `Default` | `Default` |
| Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
| Table | `otel_logs` | `otel_traces` | Gauge `otel_metrics_gauge`, Histogram `otel_metrics_histogram`, Sum `otel_metrics_sum` |

Then link them, so that one click jumps from a signal to another:
- on **PayFlow logs**: *Correlated Trace Source* = `PayFlow traces`, *Correlated Metric Source* = `PayFlow metrics`;
- on **PayFlow traces**: *Correlated Log Source* = `PayFlow logs`, *Correlated Metric Source* = `PayFlow metrics`.

Check the inferred expressions on the log source: Timestamp `Timestamp`, Service Name `ServiceName`, Log Level `SeverityText`, Body `Body`, Trace Id `TraceId`, Span Id `SpanId`.

### Step 3 · Search the logs
Open **Search**, choose **PayFlow logs**, set the absolute range `2026-11-27 13:45` to `15:00`.

| Type in the search bar | What you see |
|---|---|
| `SeverityText:ERROR` | the histogram of errors jumps at 13:58 and stops at 14:44 |
| `ServiceName:payment SeverityText:ERROR` | only HikariPool timeouts |
| `"maximumPoolSize"` | the startup lines of every payment pod: 10 in v2.4.1, 50 before and after |
| `ServiceName:k8s-events` | the rollout, the readiness probes failing, the OOM kill on ip-10-0-3-17 |
| `"pan="` | card numbers, masked by the pipeline of module 3 |

The full-text search runs on the text index of `otel_logs` (module 6): instant, even on a billion lines.

Click any field in the left panel (for example `k8s.pod.name` or `service.version`) to filter on it. Filter `service.version` = `v2.4.0` and `v2.4.1` in turn: only one of them has errors.

### Step 4 · From a log line to its trace
1. Search `ServiceName:checkout SeverityText:ERROR` and open one line.
2. The side panel shows the line, its attributes, and the **trace** it belongs to (through `TraceId`, thanks to the correlated sources).
3. Open the trace: the waterfall of module 7 (Q4), with 3 seconds spent in `INSERT payflow.payments` and the HikariPool exception as a span event.

### Step 5 · Chart the incident
Open **Chart Explorer** (or **Search**, then switch to chart mode):
- source **PayFlow traces**, aggregation **p99** of `Duration`, where `SpanKind:Server`, group by `ServiceName`: three services jump to 3 s;
- source **PayFlow metrics**, metric `hikaricp.connections.pending` (gauge), **max**, group by `service.version`: v2.4.1 has dozens of waiting threads, v2.4.0 none;
- metric `k8s.pod.memory.working_set`, where `k8s.node.name` = `ip-10-0-3-17`, group by `k8s.pod.name`: the fraud-scoring pod climbing to 2 GiB, then the drop.

The latency histogram `http.server.request.duration` carries an **exemplar** per minute (module 3): the trace id of the slowest request. Where the chart shows exemplars, one click opens that trace.

### Step 6 · A dashboard and an alert
1. **Dashboards**, **New Dashboard**, name `PayFlow · SRE`. Add four tiles from the charts of step 5: p99 per service, error count per service (logs, `SeverityText:ERROR`), HikariCP pending per version, memory of ip-10-0-3-17.
2. Back in **Search**, save the search `ServiceName:payment SeverityText:ERROR` as `Payment errors`, then create an **alert** on it: more than 100 lines in 1 minute.

> The alert is evaluated on the current time. The workshop data is in November 2026, so it will not fire: the rule is what matters. The same rule, in SQL, is `payflow_sre.rmv_alerts` (module 5).

---

## 2. A dashboard in the SQL console, on gold

For the team lead, four tiles straight on the gold tables of module 5. Each query reads a few thousand rows.

1. In the SQL console, paste each query in a new tab, run it, **Save** it with the given name.
2. **Dashboards**, **New Dashboard** `PayFlow · SLO`, then one visualization per saved query.

**Tile 1 · `tile_red_payments`** (Line, X = `minute`, Y = `error_pct` and `p99_ms`)
```sql
SELECT
    minute,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN '2026-11-27 13:30:00' AND '2026-11-27 15:30:00'
GROUP BY minute
ORDER BY minute
```

**Tile 2 · `tile_burn_rate`** (Line, X = `minute`, Y = `burn_5m`, `burn_1h`, `threshold`)
```sql
SELECT minute, round(burn_5m, 1) AS burn_5m, round(burn_1h, 1) AS burn_1h, 14.4 AS threshold
FROM payflow_sre.slo_burn
WHERE route = 'POST /v1/payments' AND minute BETWEEN '2026-11-27 13:30:00' AND '2026-11-27 15:30:00'
ORDER BY minute
```

**Tile 3 · `tile_alerts`** (Table)
```sql
SELECT ts, rule, severity, service, state, summary
FROM payflow_sre.alerts
ORDER BY ts
```

**Tile 4 · `tile_service_map`** (Table: the edges whose latency changed the most)
```sql
SELECT caller, callee,
       maxIf(p95_ms, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00') AS p95_before_ms,
       maxIf(p95_ms, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS p95_during_ms,
       sumIf(errors, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS errors_during
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 8
```

---

## 3. A status API for the PayFlow status page

The status page must show, for one route, the burn rate of the last minutes, without any SQL on the client side.

### Step 1 · The parameterized view
```sql
CREATE OR REPLACE VIEW payflow_sre.api_route_status AS
SELECT minute, route, requests, errors, round(burn_5m, 1) AS burn_5m, fast_burn
FROM payflow_sre.slo_burn
WHERE route = {route:String} AND minute BETWEEN {start:DateTime} AND {finish:DateTime}
ORDER BY minute
```

### Step 2 · Test it
```sql
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = '2026-11-27 14:00:00', finish = '2026-11-27 14:10:00')
```

### Step 3 · Publish it as an endpoint
1. New tab, paste:
   ```sql
   SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})
   ```
2. **Save** as `api_route_status`, then **Share**, **API Endpoint**: choose an API key with the **Query Endpoints** access, and the **Read only** database role.
3. Call it (replace the two values):
   ```bash
   curl --user '<Key ID>:<Key secret>' \
     'https://queries.clickhouse.cloud/run/<endpoint id>?format=JSONEachRow&param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00'
   ```

Before you have a key, the HTTPS interface of the service accepts the same parameters (a test only: never put the `default` password in a front end):
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})"
```
Expected: 11 rows, `fast_burn` true from 14:00.

---

## 4. ClickHouse Agents: ask the platform

### Step 1 · Document the tables for the agent
An agent reads the comments of tables and columns first (rule `agent-discovery-schema`). Without them it guesses what `burn_1h` means.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'RED metrics per minute: one row per service, operation (span name) and minute. Finish the aggregation with sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanoseconds). Filter on service first.',
    COMMENT COLUMN latency 'quantilesTDigest state of span durations in nanoseconds: use quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 for p99 in ms';

ALTER TABLE payflow_sre.slo_burn
    MODIFY COMMENT 'Error budget burn rate of each api-gateway route, per minute. burn_5m and burn_1h: how many times faster than allowed the budget is spent (1 = on budget). fast_burn = both above 14.4.';

ALTER TABLE payflow_sre.alerts
    MODIFY COMMENT 'Alert events (FIRING / RESOLVED) of the four rules: slo_fast_burn, p99_latency, container_restart, node_memory_pressure.';

ALTER TABLE payflow_otel.otel_traces
    MODIFY COMMENT 'OpenTelemetry spans of PayFlow. Timestamp in UTC (nanoseconds), Duration in nanoseconds, StatusCode Error or Unset. Always filter on Timestamp and ServiceName. Pod version in ResourceAttributes[''service.version''], business fields in SpanAttributes (payment.amount, payment.status, merchant.id).';

ALTER TABLE payflow_otel.otel_logs
    MODIFY COMMENT 'OpenTelemetry logs of PayFlow, card numbers masked. Always filter on Timestamp. Full-text search: hasToken(lower(Body), ''word''). Kubernetes events have ServiceName = ''k8s-events'' and the reason in EventName.';

SELECT name, comment FROM system.tables WHERE database IN ('payflow_sre', 'payflow_otel') AND comment != '' ORDER BY name
```

### Step 2 · Create the agent
1. In the service, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model**: the default model. **Tools**: `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (paste as is):
   ```
   You are the SRE assistant of PayFlow, a payment platform on Kubernetes. Answer in English, briefly.
   - Data is in UTC, on Friday 2026-11-27. Use absolute time ranges on that day.
   - Prefer the gold tables: payflow_sre.red_1m (RED per minute), payflow_sre.slo_burn,
     payflow_sre.alerts, payflow_sre.service_map_5m, payflow_sre.log_patterns_10m.
     Go to payflow_otel.otel_traces and otel_logs only for details, always with a Timestamp filter
     and a LIMIT. Read the table comments first.
   - Business context: payflow_ref.merchant (dictGet('payflow_ref.dict_merchant', 'name', merchant_id)),
     deployments: payflow_ref.deployment_history.
   - Give the key numbers with their unit, then the SQL you used.
   - When asked for a chart or a dashboard, build it with the Artifacts tool.
   - For Python (statistics, anomaly detection, forecasting): first run the SQL with the ClickHouse
     tool, keep the result compact (at most a few thousand rows), paste the data into the code and
     execute it yourself with Run Code. Run Code has no access to ClickHouse. Show the result in an artifact.
   ```
4. Save, open a conversation, choose the agent.

### Step 3 · Two questions
| Ask | Expected answer |
|---|---|
| "What happened to payments between 13:55 and 14:50 on November 27?" | error rate of `POST /v1/payments` up to ~30%, p99 3 s, from 13:58 to 14:44; root cause HikariPool timeouts in `payment` v2.4.1 (CHG-4117, pool size 10); first page at 14:00 |
| "How much money did the incident cost, and which merchants were hit the most?" | ~15,300 failed payments, ~1.58 M EUR, ~8,000 merchants; top merchants by amount |

### Step 4 · Dashboards on demand
- "Build a dashboard of the incident: error rate and p99 of POST /v1/payments per minute, the burn rate with its 14.4 threshold, and the alerts as markers."
- "Show the service map during the incident as a graph, with the edges colored by p95 latency."
- "Compare the payment pods of v2.4.0 and v2.4.1 during the rollout: HikariCP active and pending connections."

### Step 5 · Data science with Run Code
- "Detect the anomalous minutes of the day on POST /v1/payments using error rate and p99 latency, with an Isolation Forest. Show them on a chart."

  Expected: the anomalous minutes are 13:58 to ~14:45. The model knows nothing about the incident: it finds it alone.
- "Forecast the requests per minute of POST /v1/payments for 20:00 to 21:00 from the rest of the day, and compare with what really happened."

  Expected: the evening peak is well predicted; the flash sale of 14:00 is an outlier the model should not learn from.

### In production
Give the agent a read-only role with limits per query (rule `agent-query-safety`), for example:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS payflow_agent_profile SETTINGS readonly = 2, max_execution_time = 30, max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS payflow_agent_role SETTINGS PROFILE 'payflow_agent_profile';
GRANT SELECT ON payflow_sre.* TO payflow_agent_role;
GRANT SELECT ON payflow_otel.* TO payflow_agent_role;
GRANT SELECT, dictGet ON payflow_ref.* TO payflow_agent_role;
```
