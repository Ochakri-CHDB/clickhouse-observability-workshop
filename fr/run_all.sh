#!/usr/bin/env bash
# =====================================================================
#  Exécute tout le workshop sur un service ClickHouse Cloud
#  (sert aussi de rattrapage complet pour un participant).
#
#  Prérequis : le client ClickHouse
#      curl https://clickhouse.com/ | sh        # crée ./clickhouse
#
#  Utilisation :
#      export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
#      export CH_PASSWORD='...'                  # jamais dans un fichier versionné
#      ./run_all.sh               # tout, depuis zéro (reset compris)
#      ./run_all.sh 05_gold       # reprise à un module (sans reset)
#      ./run_all.sh 03_silver/02  # ou à un fichier donné
#      ./run_all.sh 01 04         # rattrapage : du module 01 au module 04 inclus
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Définir CH_HOST}"
: "${CH_PASSWORD:?Définir CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
START_AT="${1:-}"
STOP_AT="${2:-}"          # optionnel : s'arrêter après ce module (rattrapage "jusqu'à")

FILES=(
  reset.sql
  00_introduction/01_premiers_pas.sql
  01_fondamentaux/01_setup_et_inventaire.sql
  02_bronze/01_simulateur.sql
  02_bronze/02_ingestion_brute.sql
  02_bronze/03_explorer_le_brut.sql
  03_silver/01_tables_otel.sql
  03_silver/02_pipeline_de_logs.sql
  03_silver/03_traces_et_metriques.sql
  04_dictionnaires/01_dictionnaires.sql
  05_gold/01_metriques_red.sql
  05_gold/02_slo_et_alertes.sql
  05_gold/03_carte_des_services_et_motifs.sql
  06_performance/01_passage_a_l_echelle.sql
  06_performance/02_recherche_et_index.sql
  07_investigation/01_enquete_incident.sql
  07_investigation/02_exploitation.sql
)
# Le module 08 se fait dans la console, en suivant 08_clickstack_dashboards_agent/README.md

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
    echo "   OK en $(( $(date +%s) - t0 )) s"
  else
    echo "   ÉCHEC, voir logs/$(basename "$f" .sql).log"
    tail -20 "logs/$(basename "$f" .sql).log"
    exit 1
  fi
done
echo "Terminé. Résultats détaillés dans ./logs/"
