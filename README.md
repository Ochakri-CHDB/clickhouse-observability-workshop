# ClickHouse from zero to advanced · Observability workshop

A 5-hour hands-on workshop on **your own ClickHouse Cloud service**: Black Friday on PayFlow, a payment platform on Kubernetes, and the incident that hits it at 13:58. You collect logs, traces, metrics and Kubernetes events, model them in the OpenTelemetry schema, build SLOs and alerts, find the root cause in SQL, then replay the investigation in ClickStack and with ClickHouse Agents.

Everything is simulated in SQL and deterministic: no collector, no load generator, nothing to install. Everyone gets the same numbers.

| | Language | Start here |
|---|---|---|
| EN | English | [en/README.md](en/README.md) |
| FR | Français | coming soon |
| ES | Español | coming soon |

What you will see:
- the OpenTelemetry tables of the ClickHouse exporter, read by **ClickStack** as is
- a log pipeline in materialized views: 4 log formats, severity, trace ids, **card numbers masked** on ingestion
- RED metrics, **SLO burn rate** and alerts with refreshable views, a **service map** rebuilt from the traces
- **910 million log lines**: text index, bloom filter, projection, query caches, 3 replicas
- the investigation in 10 queries: from the page to the faulty release, and what the incident cost in euros
- ClickHouse Agents: questions in plain English, dashboards on demand, anomaly detection with Run Code

Quick start, from the folder of your language:

```bash
cd en
export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
export CH_PASSWORD='...'
./run_all.sh
```

A companion workshop on an energy use case (smart meter data) is available at [clickhouse-energie-workshop](https://github.com/Ochakri-CHDB/clickhouse-energie-workshop).
