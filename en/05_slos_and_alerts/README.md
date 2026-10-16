# Module 5 · SLOs and alerts: break production, get paged

An alert is a query run on a schedule and compared to a threshold. `01_slo_burn_rate.sql` builds the SRE way of doing it (error budget, burn rate, two windows) in SQL. This README builds the same alerts in ClickStack, click by click, then **you break production on purpose** and watch them fire on the live stream of module 2.

Duration: 35 min. Run `01_slo_burn_rate.sql` first (checkpoint `OK`).

> ClickStack alerts are evaluated on the **current time**, every window (1 minute, 5 minutes...). They watch the live stream, not Black Friday. Set the range to `Last 1 hour` for the whole module.

---

## Step 1 · The three places an alert comes from (2 min)

| Where | Button | What the alert counts |
|---|---|---|
| a **saved search** | **Alerts**, top right of Search | the number of lines matching the search |
| a **dashboard tile** (Builder or SQL) | the bell on the tile, or **Add alert** in the tile editor | the value of the chart |
| **Chart Explorer** | **Add alert**, under the series | the value of the chart, without a dashboard |

Every alert then shows in **Alerts** (left menu), with its state and its history.

---

## Step 2 · Where the notifications go (5 min)

An alert needs a destination. Two options, pick one:

- **Email** (the simplest): in the alert form, **Send to**, change **Webhook** to **Email**, type your address and press **Enter**.
- **A webhook**: **Team Settings** (left menu), **Integrations** tab, **Add Webhook** (or **Add New Incoming Webhook** directly in the alert form). The **Service Type** choices: **Slack (Webhook URL)**, **Slack API**, **PagerDuty API**, **incident.io**, **Generic**.

For a generic webhook that only displays what it receives, open [webhook.site](https://webhook.site) in a new tab and copy your unique URL (the page is public: fine for simulated data, never for real data). In ClickStack: **Service Type** `Generic`, **Webhook Name** `workshop`, **Webhook URL** the copied URL, **Test Webhook** (a test message arrives on webhook.site), then **Add Webhook**.

The **Webhook Body** of a generic webhook is a template. The most useful variables:

| Variable | Value |
|---|---|
| `{{title}}`, `{{body}}`, `{{link}}` | the alert title, the message, a link back to ClickStack |
| `{{status}}` | `firing`, `resolved`, `no_data`, `pending` or `error` |
| `{{value}}`, `{{threshold}}` | the value that crossed, the threshold |
| `{{groupKey}}` | the group that crossed (the pod, the service), when the alert is grouped |
| `{{alertId}}` | a stable id, to deduplicate on the receiving side |
| `{{note}}` | the note of the alert, usually a runbook link |

In production: a Slack channel per team, PagerDuty or incident.io for the pages.

---

## Step 3 · Three alerts (15 min)

### 3a · A search alert, one per pod

1. Left menu, **Saved Searches**, open **Payment errors** (saved in module 3, step 4; if it is missing: **Search**, source **PayFlow logs**, search `ServiceName:payment SeverityText:ERROR`, **Save**, name `Payment errors`, **Save**).
2. Click **Alerts** (top right). The form opens on **New Alert**.
3. Fill it in:
   - **Name**: `Payment errors per pod`.
   - **Alert type**: **Static threshold**.
   - **Alert when**: `At least (≥)`, `10`, lines appear within `1 minute`.
   - **grouped by**: `ResourceAttributes['k8s.pod.name']`. One alert per pod instead of one for the service: the notification says which pod.
   - **Send to**: your email or your webhook.
   - **Note**: a line for whoever is paged, such as `Pool exhaustion on payment, see the Payment errors saved search`.
4. Open **Advanced Settings** once: **Consecutive windows** (fire only after N bad windows in a row) and **Anchor start time** (align the windows on a given time). Leave the defaults.
5. Scroll down: the **Threshold chart** draws the last hour of the search with the threshold. In normal traffic it stays at 0 or 1: the alert would not have fired.
6. **Create Alert**.

![Search alert form](../img/05_search_alert.png)

### 3b · A latency alert from Chart Explorer

1. Left menu, **Chart Explorer**. **Data Source** `PayFlow traces`, **99th Percentile**, SQL Column `Duration / 1e6`, **Where** `SpanKind:Server ServiceName:payment`, **Run**.
2. Click **Add alert** (under the series). A panel opens on the right.
3. **Static threshold**, **Trigger when value** `is at least (≥)` `2000` over `5 minute`. **Name** `Payment p99 over 2 s`. **Send to** as before. **Create alert**.

Why `payment` and 2 s, and not every service above 1 s: on normal traffic, a card network timeout (5 s) now and then pushes the p99 of checkout and card-network-adapter above 1 s on a quiet 5 minutes (18 windows in the week, up to 3.5 s). The p99 of payment reaches 1.4 s at most; during the incident it is 3 s. A threshold is chosen on the data, not in the abstract.

The other **Alert type**, **Anomaly detection** (beta), needs no threshold: ClickStack learns the usual level of the series and fires when it leaves it. It is the same panel as the bell of a dashboard tile:

![Tile alert, anomaly detection](../img/05_alert_form.png)

### 3c · The burn rate, as a SQL tile alert

The burn rate of `01_slo_burn_rate.sql` is a ratio on a rollup: a SQL tile.
1. **Dashboards**, **PayFlow · SRE**, **Add**, **New Tile**, **SQL** (top right). **Connection** `Default`; clear **Source** with its **x** (the query reads a rollup, not a source).
2. Click inside the SQL editor, select all, paste:

```sql
SELECT
    $__timeInterval(minute) AS ts,
    sum(errors) / greatest(sum(requests), 1) / 0.0005 AS burn_rate
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

   Two orange warnings ask for `$__sourceTable` and `$__filters`: they are advice for tiles on a source, ignore them here.
3. **Chart Name** `Burn rate, POST /v1/payments`, **Run**. On the incident range (module 3, step 0) the curve climbs to about 600: the budget burns 600 times too fast.
4. **Add alert** (above the editor): **Trigger when value** `is at least (≥)` `100` over `5 minute`, **Send to**, **Add alert**, then **Save** the tile.

![SQL tile alert](../img/05_sql_tile_alert.png)

Why 100 and not 14.4, the classic fast-burn threshold: 14.4 is meant for a 1 h window confirmed by a 5 min one (that is what `01_slo_burn_rate.sql` does). Alone on 5 minutes, with about 240 payments per window, two failed payments are enough to cross 14.4: 5% of the windows of a normal week would page. On 5 minutes alone, 100 means "5% of payments failing": normal traffic peaks at 61, the incident at 600.

---

## Step 4 · Break production (10 min)

The live stream generates normal traffic. Flip the switch: it now replays the worst minutes of Black Friday, a quarter of their traffic, with the faulty v2.4.1 pods. From the SQL console:

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
```

Within one to three minutes:
- **Search**, source **PayFlow logs**, **Live Tail**: the HikariPool timeouts scroll in, from the `payment-5c8b7f9d21-*` pods (v2.4.1).
- **Dashboards**, **PayFlow · SRE**, range `Last 15 minutes`, **Live**: the requests jump, the p99 of payment climbs to 3 s, the burn rate tile to 500 or 600 (a quarter of the payments fail), **Payment errors** turns red past 100.
- **Alerts** (left menu): the three alerts go red. Click one: each evaluation is a bar of its history, with the value and the threshold.
- Your inbox or webhook.site receives the notifications, with a link back to ClickStack (`{{link}}`).
- Back on the dashboard, menu **⋮**, **Show alert annotations**: the moments the alerts fired are marked on the charts.

In SQL, the refreshable views of `01_slo_burn_rate.sql` see the same thing: the fast-burn rule fires on the first minute of chaos, the p99 rule on the third (it waits for 3 slow minutes in a row).

```sql
SELECT ts, rule, state, summary FROM payflow_sre.alerts WHERE ts >= now() - INTERVAL 15 MINUTE ORDER BY ts
```

Then roll back:

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
```

The alerts resolve as soon as their windows clear: the 1-minute search alert first, the 5-minute ones within five minutes. The notification says `resolved`.

> **Attention**: switch chaos off before the break. The live stream stops by itself 8 hours after it was started anyway (column `live_until` of `payflow_sim.chaos`).

---

## Step 5 · What makes a good alert (3 min)

- **Alert on symptoms, investigate causes**: the page is the burn rate of what customers feel (failed payments), not the CPU of a pod.
- **Choose the threshold on the data**: the threshold chart of the form shows what the alert would have done over the last hour. Look at a normal week before choosing (step 3b).
- **Two windows**: the 1 h window ignores blips, the 5 min window clears the alert fast after the fix. In ClickStack, **Consecutive windows** gives the same "for N windows in a row".
- **Group by** to get one alert per pod or per service, and route it to the team that owns it (`service.team`).
- **A note on every alert**: what it means and where to look, for whoever is woken up at 3 am.
- Alerts can use the rollups registered on a source (module 7): an alert over a month of data stays cheap.
