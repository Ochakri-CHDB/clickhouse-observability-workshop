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
#      ./run_all.sh 05_slo_et_alertes  # reprendre à un module (sans reset)
#      ./run_all.sh 02_collecte/02  # ou à partir d'un fichier donné
#      ./run_all.sh 01 04         # rattrapage : du module 01 au module 04 inclus
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Définissez CH_HOST}"
: "${CH_PASSWORD:?Définissez CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
START_AT="${1:-}"
STOP_AT="${2:-}"          # optionnel : s'arrêter après ce module (rattrapage "jusqu'à")

FILES=(
  reset.sql
  00_premiers_pas/01_premiers_pas.sql
  01_modele_de_donnees/01_inventaire_plateforme.sql
  01_modele_de_donnees/02_schema_otel.sql
  02_collecte/01_simulateur.sql
  02_collecte/02_pipeline_gateway.sql
  02_collecte/03_traces_et_metriques.sql
  02_collecte/04_flux_en_direct.sql
  03_recherche_et_correlation/01_sous_le_capot.sql
  03_recherche_et_correlation/02_scenarios_de_correlation.sql
  04_dashboards/01_agregats_red.sql
  05_slo_et_alertes/01_burn_rate_slo.sql
  06_enquete/01_carte_et_motifs.sql
  06_enquete/02_incident_en_sql.sql
  07_echelle_et_cout/01_milliard_de_lignes.sql
  07_echelle_et_cout/02_recherche_et_index.sql
  07_echelle_et_cout/03_agregats_retention_echantillonnage.sql
  08_ia_et_gouvernance/01_securite_et_exploitation.sql
)
# Les parties ClickStack se font dans la console, en suivant le README de chaque module.
# Le flux en direct (module 2, fichier 04) continue de tourner : arrêtez-le avec arreter_flux_en_direct.sql.

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
