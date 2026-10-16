# Module 6 · The investigation: Black Friday, 14:00

The page arrived at 14:00: *POST /v1/payments: error budget burning 19x faster than allowed*. You have ClickStack and the SQL console. Find what broke, why, who is affected, and what it cost.

Duration: 45 min.
- Part 1 (25 min): the ClickStack journey below, one screen per question.
- Part 2 (20 min): `01_service_map_and_patterns.sql` and `02_incident_in_sql.sql`, the same answers in SQL, with the business impact.

> Range for the whole module: **the incident**. In the time range: **Around a time**, Time `YYYY-MM-DD 14:20:00` (your Black Friday date, `SELECT pf_black_friday()`, module 3 step 0), Duration ± `1h`, **Apply**. All times are UTC (module 3, step 2).

---

## Step 1 · How bad, and where? The service map (5 min)

1. Left menu, **Service Map** (beta).
2. Top left, the source: **PayFlow traces**. Top right, the time range: **Around a time**, `14:30:00`, ± `15m` (the heart of the incident).
3. Read the map:
   - each circle is a service (`service.name`), each dashed line a call: a client span matched with the server span it called;
   - the legend (top right) has three tabs. **Error rate**: grey is no error, dark red is 5% or more. **Latency** and **Throughput** color by the other two signals. The size of a circle is always the traffic.
4. On **Error rate**: `api-gateway`, `checkout` and `payment` are dark red. `ledger` and `notification` are grey: the failing payments never reached them. `fraud-scoring` is red too: keep it for step 5.
5. Switch the legend to **Latency** (the p95): the same three services turn dark, about 3 s, the others stay light. **All Services** (top left) narrows the map to one service and its neighbours; the Lucene box filters the spans the map is built from (try `SpanAttributes['merchant.id']:m_00042`).
6. **Sampling** (top): the map is built from a sample of the traces, 10% by default. Move the slider down on a large dataset: the map loads faster and stays right.

![Service map](../img/06_service_map.png)

## Step 2 · What do the errors say? Event Patterns (5 min)

1. **Search**, source **PayFlow logs**, search `SeverityText:ERROR`, range **the incident**, **Run**.
2. Left column, **Analysis Mode**: click **Event Patterns** (instead of **Results Table**).
3. Tens of thousands of lines collapse into a handful of patterns. ClickStack replaces the variable parts (ips, ids, numbers) by `<*>`. For each pattern: a **Trend** (a small histogram over the range), a **Count**, the **Level**.
4. Read from top to bottom: the gateway access lines (`POST /v1/<*> ... 503`), then the **HikariPool-1 timeout** in payment, then checkout "payment failed: payment service returned <*>". The gateway and checkout only relay what payment says: the HikariPool line is the one to follow.
5. Narrow it: click `payment` under **ServiceName** in the filters. One pattern is left, the pool timeout.
6. **Pattern Expression** (above the table) changes what is grouped: `Body` by default; type `ServiceName` to count by service instead.

![Event patterns](../img/06_event_patterns.png)

## Step 3 · What do the slow spans have in common? Event Deltas (5 min)

1. **Search**, source **PayFlow traces**, search `ServiceName:payment`, range **the incident**, **Run**.
2. **Analysis Mode**, **Event Deltas** (traces only).
3. The heatmap: time across, duration up (log scale), color for the number of spans. Before 13:58 the spans sit in two bands, a few ms (database calls) and 100 to 300 ms (the payment calls). From 13:58 to 14:42 a block moves up to 1 to 3 s, with a flat top at 3,000 ms: a fixed timeout leaves exactly this signature. Until you select something, the charts below say *Select an area on the chart above to enable comparisons*. (The axis of this chart is in the local time of your browser, not UTC.)
4. **Drag a rectangle** around the slow block. Below, one chart per attribute compares the selection (**Selection**, orange) with everything else (**Background**, green), the attributes that differ most first. Hover a bar for its exact percentages.
5. Find `ResourceAttributes.service.version` among the first charts: the selection is 100% **v2.4.1**, the background mostly v2.4.0 (59%). Around it: `k8s.pod.name` shows only the six `payment-5c8b...` pods, `payment.status` `failed`, `StatusCode` `Error`.
6. Click the **v2.4.1** bar: a small window opens with three icons, **Filter for this value**, **Exclude this value** and copy. **Filter for this value**: the search and the heatmap redraw on the faulty version alone. **Exclude this value** shows the rest: the v2.4.0 pods, before 13:58 and after 14:42, without the slow block.

![Event deltas](../img/06_event_deltas.png)

## Step 4 · What changed? Release markers and the startup logs (5 min)

1. **Dashboards**, **PayFlow · SRE** (module 4), range **the incident**, menu **⋮** (top right), **Show release markers**: a dashed line `v2.4.1` at 13:58, exactly where the p99 jumps.
2. **Search**, source **PayFlow logs**, search `"maximumPoolSize"`, range **the incident**. Six lines from 13:58 (the six v2.4.1 pods starting, one every 30 s) say `maximumPoolSize=10`; open one, its **version** chip says `v2.4.1`. Six lines from 14:42, the rollback to v2.4.0, say 50. Range `Last 30 days`: the v2.4.0 pods of the release ten days earlier said 50 too.
3. The change: in the SQL console, `SELECT * FROM payflow_inventory.deployment_history WHERE deployment = 'payment' ORDER BY valid_from`. CHG-4117, j.martin, 13:58: "pool size 50 to 10".
4. The resource side: open a failed trace (module 3, step 5), tab **Infrastructure**. CPU low, memory flat: the pod is not busy, it waits for connections.
5. The proof in metrics: **Chart Explorer**, **PayFlow metrics**, **Maximum** of `hikaricp.connections.pending (Gauge)`, **Group By** `ResourceAttributes['service.version']`, **Run**: v2.4.1 queues dozens of threads, v2.4.0 none.

## Step 5 · The second fire (3 min)

1. **Search**, source **PayFlow logs**, search `ServiceName:k8s-events SeverityText:WARN -EventName:Unhealthy`, range **the incident**. Four events, read the **EventName** column: `NodeHasInsufficientMemory` on node `ip-10-0-3-17` at 14:19:31, `OOMKilling` of the fraud-scoring worker at 14:21:07, `BackOff` (the container restarts, `OOMKilled, exit code 137`), and `NodeHasSufficientMemory` at 14:23:40.
2. **Chart Explorer**, **PayFlow metrics**, **Maximum** of `k8s.pod.memory.usage (Gauge)`, **Where** `ResourceAttributes['k8s.node.name']:ip-10-0-3-17`, **Group By** `ResourceAttributes['k8s.pod.name']`, **Run**: the fraud-scoring pod climbs with the client retries (its traffic x2.2), then drops at the restart.
3. Open one of the "connection refused" spans of 14:21 (module 3, scenario C), **Infrastructure** tab: the pod charts (CPU, memory, disk) around the error, and the **Pod Timeline**, the Kubernetes events of that pod.

A consequence of the incident (the retries), not its cause. Both go in the postmortem.

## Step 6 · Ask an AI to do it (2 min)

Left menu, **AI notebooks** (beta), **New Private Notebook**. In **Ask AI to explore your data**, type, with your Black Friday date:

*Why did POST /v1/payments fail between 13:58 and 14:45 UTC on YYYY-MM-DD? Use the PayFlow sources.*

Watch it add blocks (searches, charts) one after another, then compare its conclusion with yours. The feature is in beta: if no block appears, add them by hand with **Manual Block** (Search, Chart, Table, Markdown) and keep the notebook as the written trace of your investigation. Module 8 shows the same questions asked through MCP.

---

## Part 2 · The same investigation in SQL (20 min)

- `01_service_map_and_patterns.sql`: the service map and the event patterns, computed by refreshable views, before and during the incident.
- `02_incident_in_sql.sql`: ten questions, from the page to the root cause, the trace as a tree (recursive CTE), the change that was live for every error, the second fire, and **the business impact**: failed payments, euros, merchants.

The last query builds the timeline of the postmortem from every signal at once.
