#!/usr/bin/env bash
# =====================================================================
#  Ejecuta todo el taller en un servicio ClickHouse Cloud
#  (sirve también como recuperación completa para un asistente).
#
#  Requisito: el cliente de ClickHouse
#      curl https://clickhouse.com/ | sh        # crea ./clickhouse
#
#  Uso:
#      export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
#      export CH_PASSWORD='...'                  # nunca en un fichero versionado
#      ./run_all.sh               # todo, desde cero (con reset)
#      ./run_all.sh 05_slo_y_alertas # reanudar desde un módulo (sin reset)
#      ./run_all.sh 02_recoleccion/02  # o desde un fichero concreto
#      ./run_all.sh 01 04         # recuperación: del módulo 01 al 04 incluido
# =====================================================================
set -euo pipefail

: "${CH_HOST:?Define CH_HOST}"
: "${CH_PASSWORD:?Define CH_PASSWORD}"
CH_USER="${CH_USER:-default}"
if [ -z "${CLICKHOUSE_BIN:-}" ]; then [ -x ./clickhouse ] && CLICKHOUSE_BIN=./clickhouse || CLICKHOUSE_BIN=clickhouse; fi
CLIENT="$CLICKHOUSE_BIN client --host $CH_HOST --secure --user $CH_USER --password $CH_PASSWORD"
START_AT="${1:-}"
STOP_AT="${2:-}"          # opcional: parar tras este módulo (recuperación "hasta")

FILES=(
  reset.sql
  00_primeros_pasos/01_primeros_pasos.sql
  01_modelo_de_datos/01_inventario_plataforma.sql
  01_modelo_de_datos/02_esquema_otel.sql
  02_recoleccion/01_simulador.sql
  02_recoleccion/02_pipeline_gateway.sql
  02_recoleccion/03_trazas_y_metricas.sql
  02_recoleccion/04_flujo_en_directo.sql
  03_busqueda_y_correlacion/01_bajo_el_capo.sql
  03_busqueda_y_correlacion/02_escenarios_de_correlacion.sql
  04_dashboards/01_agregados_red.sql
  05_slo_y_alertas/01_burn_rate_slo.sql
  06_investigacion/01_mapa_y_patrones.sql
  06_investigacion/02_incidente_en_sql.sql
  07_escala_y_coste/01_mil_millones_de_lineas.sql
  07_escala_y_coste/02_busqueda_e_indices.sql
  07_escala_y_coste/03_agregados_retencion_muestreo.sql
  08_ia_y_gobernanza/01_seguridad_y_operacion.sql
)
# Las partes de ClickStack se hacen en la consola, siguiendo el README de cada módulo.
# El flujo en directo (módulo 2, fichero 04) sigue activo: detenlo con detener_flujo_en_directo.sql.

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
    echo "   FALLO, ver logs/$(basename "$f" .sql).log"
    tail -20 "logs/$(basename "$f" .sql).log"
    exit 1
  fi
done
echo "Terminado. Resultados detallados en ./logs/"
