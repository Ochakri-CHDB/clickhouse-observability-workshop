# Module 6 · The investigation: Black Friday, 14:00

The page arrived at 14:00: *POST /v1/payments: error budget burning 19x faster than allowed*. You have ClickStack and the SQL console. Find what broke, why, who is affected, and what it cost.

Duration: 45 min.
- Part 1 (25 min): the ClickStack journey below.
- Part 2 (20 min): `01_service_map_and_patterns.sql` and `02_incident_in_sql.sql`, the same answers in SQL, with the business impact.

> Range for the whole module: **the incident**, `2026-11-27 13:30` to `2026-11-27 15:00` (UTC).

---

## Step 1 · How bad, and where? The service map (5 min)

Open **Service Map** (left menu), source **PayFlow traces**, range **the incident**.
- Each node is a service (`service.name`), each edge a client span matched with a server span.
- Node size is traffic; red means errors. `api-gateway`, `checkout` and `payment` are red; `ledger`, `card-network-adapter` and `notification` are not, because the failing requests never reached them.
- Move the **sampling slider** down on a big dataset: the map loads faster and stays right.

## Step 2 · What do the errors say? Event Patterns (5 min)

**Search**, source **PayFlow logs**, `SeverityText:ERROR`. In **Analysis Mode**, choose **Event Patterns**.
- Millions of lines collapse into a handful of patterns; ClickStack replaces the variable parts (ids, numbers) for you.
- The top pattern is the HikariPool timeout in `payment`. The next ones (checkout "payment failed: payment service returned 503", the gateway 503s) only relay it.
- Narrow to one service first (`ServiceName:payment`): patterns work best on a narrow set.

## Step 3 · What do the slow spans have in common? Event Deltas (5 min)

**Search**, source **PayFlow traces**, `ServiceName:payment SpanKind:Client`. **Analysis Mode**, **Event Deltas**.
- The heatmap shows two populations: the normal band around 5 ms, and a flat band at 3,000 ms (a fixed timeout leaves exactly this signature).
- Drag a rectangle around the 3,000 ms band. The attribute charts compare it (Selection, orange) with everything else (Background, green), largest difference first.
- `ResourceAttributes['service.version']` stands out: the slow spans are all **v2.4.1**. Click the bar, **Filter**, and the heatmap redraws on the faulty version alone.

## Step 4 · What changed? Release markers and the startup logs (5 min)

- On the dashboard `PayFlow · SRE` (module 4), **Show release markers**: v2.4.1 appears at 13:58, exactly where the p99 jumps.
- **Search** `"maximumPoolSize"`: the v2.4.1 pods started with `maximumPoolSize=10`, the v2.4.0 pods with 50. The change note of CHG-4117 said "pool size 50 to 10".
- Open a failed trace, **Infrastructure** tab: CPU low, the pod waits for connections. Chart Explorer, metric `hikaricp.connections.pending` by `service.version`: v2.4.1 queues dozens of threads.

## Step 5 · The second fire (3 min)

**Search** `ServiceName:k8s-events SeverityText:WARN -EventName:Unhealthy`: memory pressure on ip-10-0-3-17 at 14:19, then the fraud-scoring worker OOM killed at 14:21:07. Chart Explorer, `k8s.pod.memory.working_set` where `k8s.node.name:ip-10-0-3-17`, group by `k8s.pod.name`: memory climbs with the client retries, then drops to 0. A consequence of the incident, not its cause.

## Step 6 · Ask an AI to do it (2 min)

If **Notebooks** are enabled (module 8), open a new notebook and ask: *"Why did POST /v1/payments fail between 13:58 and 14:45 on 2026-11-27?"* Watch the agent query the sources, tile by tile, and compare its conclusion with yours.

---

## Part 2 · The same investigation in SQL (20 min)

- `01_service_map_and_patterns.sql`: the service map and the event patterns, computed by refreshable views, before and during the incident.
- `02_incident_in_sql.sql`: ten questions, from the page to the root cause, the trace as a tree (recursive CTE), the change that was live for every error, the second fire, and **the business impact**: failed payments, euros, merchants.

The last query builds the timeline of the postmortem from every signal at once.
