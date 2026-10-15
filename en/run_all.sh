#!/usr/bin/env bash
# =====================================================================
#  Runs the whole workshop on a ClickHouse Cloud service
#  (also a full catch-up for an attendee).
#
#  Prerequisite: the ClickHouse client
#      curl https://clickhouse.com/ | sh        # creates ./clickhouse
#
#  Usage:
#      export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
#      export CH_PASSWORD='...'                  # never in a versioned file
#      ./run_all.sh               # everything, from scratch (reset included)
#      ./run_all.sh 05_gold       # resume from a module (no reset)
#      ./run_all.sh 03_silver/02  # or from a given file
#      ./run_all.sh 01 04         # catch-up: from module 01 to module 04 included
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Set CH_HOST}"
: "${CH_PASSWORD:?Set CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
START_AT="${1:-}"
STOP_AT="${2:-}"          # optional: stop after this module (catch-up "up to")

FILES=(
  reset.sql
  00_introduction/01_first_steps.sql
  01_fundamentals/01_setup_and_inventory.sql
  02_bronze/01_simulator.sql
  02_bronze/02_raw_ingestion.sql
  02_bronze/03_exploring_raw.sql
  03_silver/01_otel_tables.sql
  03_silver/02_log_pipeline.sql
  03_silver/03_traces_and_metrics.sql
  04_dictionaries/01_dictionaries.sql
  05_gold/01_red_metrics.sql
  05_gold/02_slo_and_alerts.sql
  05_gold/03_service_map_and_patterns.sql
  06_performance/01_scaling_up.sql
  06_performance/02_search_and_indexes.sql
  07_investigation/01_incident_investigation.sql
  07_investigation/02_operations.sql
)
# Module 08 is done in the console, following 08_clickstack_dashboards_agent/README.md

mkdir -p logs
started=0; [ -z "$START_AT" ] && started=1
for f in "${FILES[@]}"; do
  if [ $started -eq 0 ]; then
    [[ "$f" == "$START_AT"* ]] && started=1 || continue
  fi
  [ "$f" == "reset.sql" ] && [ -n "$START_AT" ] && continue
  if [ -n "$STOP_AT" ] && [[ "$f" > "$STOP_AT" ]] && [[ "$f" != "$STOP_AT"* ]]; then break; fi
  echo "-> $f"
  t0=$(date +%s)
  if $CLIENT --multiquery --time --format PrettyCompactMonoBlock < "$f" > "logs/$(basename "$f" .sql).log" 2>&1; then
    echo "   OK in $(( $(date +%s) - t0 )) s"
  else
    echo "   FAILED, see logs/$(basename "$f" .sql).log"
    tail -20 "logs/$(basename "$f" .sql).log"
    exit 1
  fi
done
echo "Done. Detailed results in ./logs/"
