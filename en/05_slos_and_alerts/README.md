# Module 5 · SLOs and alerts: break production, get paged

An alert is a query run on a schedule and compared to a threshold. `01_slo_burn_rate.sql` builds the SRE way of doing it (error budget, burn rate, multi-window) in SQL. This README builds the ClickStack alerts, then **you break production on purpose** and watch them fire, on the live stream of module 2.

Duration: 30 min. Run `01_slo_burn_rate.sql` first (checkpoint `OK`).

---

## Step 1 · Where to send the alerts (5 min)

An alert needs a destination (a **webhook**). In ClickHouse Cloud, ClickStack can send to Slack (webhook URL or Slack API), PagerDuty, or any HTTP endpoint.

For the workshop, use a generic webhook that only displays what it receives:
1. Open [webhook.site](https://webhook.site) in a new tab and copy your unique URL.
2. In ClickStack, during the creation of the first alert below, choose **Add New Webhook**, type **Generic**, paste the URL. The body can use `{{title}}`, `{{body}}` and `{{link}}`.

In production: a Slack channel per team, PagerDuty for the pages.

---

## Step 2 · Three alerts (10 min)

Alerts are evaluated on the current time: they watch the **live stream**. Set the range to `Last 15 minutes`.

| Alert | How | Condition |
|---|---|---|
| **Search alert** on the saved search `Payment errors` (module 3) | **Search**, open the saved search, **Alerts** (top right) | more than 50 lines in 1 minute, **grouped by** `ServiceName`: one alert per service |
| **Chart alert** on the p99 tile of `PayFlow · SRE` (module 4) | open the tile menu, **Add Alert** | p99 above 1000 ms for 1 minute |
| **SQL alert** on a SQL tile | a SQL tile of type Line, then **Add Alert**; the last numeric column is the value | the burn rate of the last 5 minutes above 14.4 (query below) |

The SQL tile for the third alert (it needs the `$__timeInterval` macro):

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

Before saving, ClickStack draws the threshold over the data: check that the live stream, in normal mode, stays under it.

---

## Step 3 · Break production (10 min)

The live stream replays a quiet hour. Flip the switch: it now replays the worst minutes of Black Friday, with the faulty v2.4.1 pods.

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
```

Within one to two minutes:
- **Search** (Live tail on): HikariPool timeouts scroll in;
- the three alerts go red in **Alerts** (left menu), each evaluation is a bar of the alert history;
- your webhook page receives the notifications, with a link back to ClickStack;
- the dashboard `PayFlow · SRE` on `Last 15 minutes`: the p99 climbs to 3 s, the release markers show v2.4.1 appearing.

In SQL, the refreshable views of `01_slo_burn_rate.sql` see the same thing:

```sql
SELECT ts, rule, state, summary FROM payflow_sre.alerts WHERE ts BETWEEN now() - INTERVAL 15 MINUTE AND now() ORDER BY ts
```

Then roll back:

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
```

The alerts resolve as soon as the windows clear: the 5-minute burn rate first, the others within a few minutes.

---

## Step 4 · What makes a good alert (5 min)

- **Alert on symptoms, investigate causes**: the page is the burn rate of what customers feel (failed payments), not the CPU of a pod.
- **Two windows**: the 1 h window ignores blips, the 5 min window clears the alert fast after the fix.
- **Group by** to get one alert per service, and route it to the team that owns it (`service.team`).
- In ClickStack, alerts can use the rollups registered on a source (module 7): an alert over a month of data stays cheap.
