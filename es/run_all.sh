#!/usr/bin/env bash
# =====================================================================
#  Ejecuta todo el taller en un servicio ClickHouse Cloud
#  (sirve también de puesta al día completa para un participante).
#
#  Requisito previo: el cliente ClickHouse
#      curl https://clickhouse.com/ | sh        # crea ./clickhouse
#
#  Uso:
#      export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
#      export CH_PASSWORD='...'                  # nunca en un fichero versionado
#      ./run_all.sh               # todo, desde cero (reset incluido)
#      ./run_all.sh 05_gold       # retomar desde un módulo (sin reset)
#      ./run_all.sh 03_silver/02  # o desde un fichero concreto
#      ./run_all.sh 01 04         # puesta al día: del módulo 01 al 04, incluido
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Define CH_HOST}"
: "${CH_PASSWORD:?Define CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
START_AT="${1:-}"
STOP_AT="${2:-}"          # opcional: parar tras este módulo (puesta al día "hasta")

FILES=(
  reset.sql
  00_introduccion/01_primeros_pasos.sql
  01_fundamentos/01_configuracion_e_inventario.sql
  02_bronze/01_simulador.sql
  02_bronze/02_ingesta_bruta.sql
  02_bronze/03_explorar_lo_bruto.sql
  03_silver/01_tablas_otel.sql
  03_silver/02_pipeline_de_logs.sql
  03_silver/03_trazas_y_metricas.sql
  04_diccionarios/01_diccionarios.sql
  05_gold/01_metricas_red.sql
  05_gold/02_slo_y_alertas.sql
  05_gold/03_mapa_de_servicios_y_patrones.sql
  06_rendimiento/01_cambio_de_escala.sql
  06_rendimiento/02_busqueda_e_indices.sql
  07_investigacion/01_investigacion_incidente.sql
  07_investigacion/02_operacion.sql
)
# El módulo 08 se hace en la consola, siguiendo 08_clickstack_dashboards_agente/README.md

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
    echo "   FALLO, mira logs/$(basename "$f" .sql).log"
    tail -20 "logs/$(basename "$f" .sql).log"
    exit 1
  fi
done
echo "Hecho. Resultados detallados en ./logs/"
