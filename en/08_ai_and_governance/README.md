# Module 8 · AI and governance

Two questions close the day. Can an AI do the investigation for you? And who is allowed to see what? This README covers the ClickStack and Cloud side; `01_security_and_operations.sql` covers deletion, rights and the observability of ClickHouse itself.

Duration: 40 min.

| Part | What | Time |
|---|---|---|
| 1 | AI Notebooks in ClickStack | 10 min |
| 2 | The ClickStack MCP server: your own AI assistant on the data | 5 min |
| 3 | ClickHouse Agents: questions, dashboards on demand, data science | 15 min |
| 4 | Roles and access: RBAC in ClickStack, row policies in SQL | 5 min |
| 5 | A status API for the PayFlow status page | 5 min |

---

## 1. AI Notebooks (beta, Managed ClickStack only)

A notebook is an investigation written by an AI agent, tile by tile: its reasoning, every query it ran, the charts, its conclusion. You can branch from any step, add your own tiles, share it with the team.

1. A team admin enables AI: **Team Settings**, **Security Policies**, toggle **Generative AI**, accept.
2. **Notebooks** (left menu), **New Shared Notebook**.
3. Ask: *"Why did POST /v1/payments fail between 13:58 and 14:45 on 2026-11-27 (UTC)? Which version, which pods, and what was the root cause?"*
4. Read the tiles: the agent searches the logs, opens traces, compares versions. On a thought it did not follow, **Restart from Here** with a new prompt to branch the investigation.
5. Compare its conclusion with yours (module 6). Then try on the live stream, after breaking production again (module 5): *"What is wrong with payments in the last 10 minutes?"*

---

## 2. The ClickStack MCP server

ClickStack exposes an MCP server: any MCP client (Claude Code, Cursor, VS Code...) can search logs and traces, read dashboards and alerts, with your rights.

1. In the Cloud console: **Connect**, **Connect with MCP**, enable it on the service.
2. Endpoint `https://mcp.clickhouse.cloud/clickstack`, OAuth sign-in on first use (no API key). For example with Claude Code:
   ```bash
   claude mcp add --transport http clickstack https://mcp.clickhouse.cloud/clickstack
   ```
3. Ask your assistant: *"Using ClickStack, find the event patterns of the payment errors on 2026-11-27 between 14:00 and 14:45 and open the slowest trace."*

---

## 3. ClickHouse Agents

ClickHouse Agents work on the SQL side of the service, with three tools: ClickHouse (queries), Artifacts (charts and dashboards), Run Code (Python).

### 3.1 · Document the tables for the agent
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

### 3.2 · Create the agent
1. In the service, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model**: the default model. **Tools**: `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (paste as is):
   ```
   You are the SRE assistant of PayFlow, a payment platform on Kubernetes. Answer in English, briefly.
   - Data is in UTC, on Friday 2026-11-27. Use absolute time ranges on that day.
   - Prefer the rollups: payflow_sre.red_1m (RED per minute), payflow_sre.slo_burn,
     payflow_sre.alerts, payflow_sre.service_map_5m, payflow_sre.log_patterns_10m.
     Go to payflow_otel.otel_traces and otel_logs only for details, always with a Timestamp filter
     and a LIMIT. Read the table comments first.
   - Business context: payflow_inventory.merchant (dictGet('payflow_inventory.dict_merchant', 'name', merchant_id)),
     deployments: payflow_inventory.deployment_history.
   - Give the key numbers with their unit, then the SQL you used.
   - When asked for a chart or a dashboard, build it with the Artifacts tool.
   - For Python (statistics, anomaly detection, forecasting): first run the SQL with the ClickHouse
     tool, keep the result compact (at most a few thousand rows), paste the data into the code and
     execute it yourself with Run Code. Run Code has no access to ClickHouse. Show the result in an artifact.
   ```
4. Save, open a conversation, choose the agent.

### 3.3 · Two questions
| Ask | Expected answer |
|---|---|
| "What happened to payments between 13:55 and 14:50 on November 27?" | error rate of `POST /v1/payments` up to ~30%, p99 3 s, from 13:58 to 14:44; root cause HikariPool timeouts in `payment` v2.4.1 (CHG-4117, pool size 10); first page at 14:00 |
| "How much money did the incident cost, and which merchants were hit the most?" | ~15,300 failed payments, ~1.58 M EUR, ~8,000 merchants; top merchants by amount |

### 3.4 · Dashboards on demand
- "Build a dashboard of the incident: error rate and p99 of POST /v1/payments per minute, the burn rate with its 14.4 threshold, and the alerts as markers."
- "Show the service map during the incident as a graph, with the edges colored by p95 latency."
- "Compare the payment pods of v2.4.0 and v2.4.1 during the rollout: HikariCP active and pending connections."

### 3.5 · Data science with Run Code
- "Detect the anomalous minutes of the day on POST /v1/payments using error rate and p99 latency, with an Isolation Forest. Show them on a chart."

  Expected: the anomalous minutes are 13:58 to ~14:45. The model knows nothing about the incident: it finds it alone.
- "Forecast the requests per minute of POST /v1/payments for 20:00 to 21:00 from the rest of the day, and compare with what really happened."

  Expected: the evening peak is well predicted; the flash sale of 14:00 is an outlier the model should not learn from.

### 3.6 · In production
Give the agent a read-only role with limits per query (rule `agent-query-safety`), for example:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS payflow_agent_profile SETTINGS readonly = 2, max_execution_time = 30, max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS payflow_agent_role SETTINGS PROFILE 'payflow_agent_profile';
GRANT SELECT ON payflow_sre.* TO payflow_agent_role;
GRANT SELECT ON payflow_otel.* TO payflow_agent_role;
GRANT SELECT, dictGet ON payflow_inventory.* TO payflow_agent_role;
```

---

## 4. Roles and access

- **In ClickStack (RBAC, Managed)**: **Team Settings**, roles Admin, Member, ReadOnly, or custom roles with No Access / Read / Manage per resource (dashboards, saved searches, alerts, notebooks). Give the payments team Manage on its own dashboards and alerts, Read elsewhere.
- **In ClickHouse**: `01_security_and_operations.sql` creates a role per team and a row policy per table. ClickStack queries the service with the rights of the user: the payments team only ever sees the `payments` namespace, in the SQL console, in ClickStack and through the MCP server.

---

## 5. A status API for the PayFlow status page

The status page must show, for one route, the burn rate of the last minutes, without any SQL on the client side.

### 5.1 · The parameterized view
```sql
CREATE OR REPLACE VIEW payflow_sre.api_route_status AS
SELECT minute, route, requests, errors, round(burn_5m, 1) AS burn_5m, fast_burn
FROM payflow_sre.slo_burn
WHERE route = {route:String} AND minute BETWEEN {start:DateTime} AND {finish:DateTime}
ORDER BY minute
```

### 5.2 · Test it
```sql
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = '2026-11-27 14:00:00', finish = '2026-11-27 14:10:00')
```

### 5.3 · Publish it as an endpoint
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

## End of the day

Stop the live stream of module 2, otherwise the service never idles:

```sql
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
```

(or run `stop_live_stream.sql`). `reset.sql` removes everything the workshop created.
