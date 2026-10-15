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
#      ./run_all.sh 05_slos       # resume from a module (no reset)
#      ./run_all.sh 02_collection/02  # or from a given file
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
  00_first_steps/01_first_steps.sql
  01_data_model/01_platform_inventory.sql
  01_data_model/02_otel_schema.sql
  02_collection/01_simulator.sql
  02_collection/02_gateway_pipeline.sql
  02_collection/03_traces_and_metrics.sql
  02_collection/04_live_stream.sql
  03_search_and_correlation/01_under_the_hood.sql
  03_search_and_correlation/02_correlation_scenarios.sql
  04_dashboards/01_red_rollups.sql
  05_slos_and_alerts/01_slo_burn_rate.sql
  06_investigation/01_service_map_and_patterns.sql
  06_investigation/02_incident_in_sql.sql
  07_scale_and_cost/01_billion_lines.sql
  07_scale_and_cost/02_search_and_indexes.sql
  07_scale_and_cost/03_rollups_retention_sampling.sql
  08_ai_and_governance/01_security_and_operations.sql
)
# The ClickStack parts are done in the console, following the README of each module.
# The live stream (module 2 file 04) keeps running: stop it with stop_live_stream.sql.

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
