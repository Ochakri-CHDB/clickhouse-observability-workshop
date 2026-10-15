# ClickHouse from zero to advanced · Observability workshop

A 5-hour hands-on workshop on **your own ClickHouse Cloud service**: Black Friday on PayFlow, a payment platform on Kubernetes, and the incident that hits it at 13:58. You collect logs, traces, metrics and Kubernetes events, explore them in **ClickStack**, build dashboards and alerts, break production on purpose to get paged, run the investigation, and see underneath, in SQL, how each feature works.

Everything is simulated in SQL and deterministic: no collector, no load generator, nothing to install. The data follows the OpenTelemetry schema of the ClickHouse exporter, so ClickStack reads it as if a real collector had written it. A live stream replays traffic every minute; a switch replays the incident instead.

| | Language | Start here |
|---|---|---|
| EN | English | [en/README.md](en/README.md) |
| FR | Français | [fr/README.md](fr/README.md) |
| ES | Español | [es/README.md](es/README.md) |

The three versions run the same SQL (OpenTelemetry names are English by standard); comments, documentation and file names are translated.

What you will see:
- **Collection the OpenTelemetry way**: agents and a gateway, whose processors (filter, transform, k8sattributes, redaction, routing, count) run as materialized views on a Null table; card numbers are masked before anything is stored
- **Correlation**: three investigations of the same incident, starting from a log, a metric alert and a trace, in ClickStack and in SQL
- **ClickStack**: sources, Lucene and SQL search, live tail, log to trace to pod, service map, event patterns, event deltas, release markers, dashboards with SQL tiles and drilldowns, search, chart and SQL alerts with webhooks, AI notebooks, MCP, RBAC
- **The SQL underneath**: spanmetrics and servicegraph as views, SLO burn rate and multi-window alerting, the investigation in 10 queries and what the incident cost in euros
- **Scale and cost**: 875 million log lines, text index, bloom filter, projection, query caches, 3 replicas, a rollup registered on the source, retention and sampling

Quick start, from the folder of your language:

```bash
cd en    # or fr, es
export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
export CH_PASSWORD='...'
./run_all.sh
```

At the end of the day, run `stop_live_stream.sql` (FR `arreter_flux_en_direct.sql`, ES `detener_flujo_en_directo.sql`): the live stream refreshes every minute and keeps the service awake.

A companion workshop on an energy use case (smart meter data) is available at [clickhouse-energie-workshop](https://github.com/Ochakri-CHDB/clickhouse-energie-workshop).
