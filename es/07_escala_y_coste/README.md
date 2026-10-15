# Módulo 7 · Escala y coste

PayFlow funciona en 8 regiones. Este módulo lleva los logs a **875 millones de líneas**, mide lo que ClickHouse hace con ellas y después ataca la factura: agregados (rollups), retención, muestreo.

Duración: 35 min. Tres ficheros SQL y después un paso en ClickStack.

| Fichero | Contenido |
|---|---|
| `01_mil_millones_de_lineas.sql` | dos semanas x 8 regiones de logs, escritas en 8 instrucciones de ~30 s; almacenamiento y compresión por columna |
| `02_busqueda_e_indices.sql` | índice de texto, bloom filter, búsqueda de traza acotada en el tiempo, proyección, query cache, query condition cache, 3 réplicas: cada consulta con y sin su ayuda |
| `03_agregados_retencion_muestreo.sql` | un agregado (rollup) con la convención de ClickStack, el coste de cada señal por día, políticas de TTL, muestreo en cabeza y de retención, dimensionamiento |

> Dale al servicio unos minutos tras los 8 inserts de `01_mil_millones_de_lineas.sql`: mientras corren los merges en segundo plano, las consultas del fichero 02 son de 2 a 3 veces más lentas y las réplicas paralelas aportan poco.

---

## En ClickStack · Deja que ClickStack use el agregado (10 min)

`03_agregados_retencion_muestreo.sql` crea `payflow_otel.otel_traces_1m`: por minuto, servicio, nombre de span y estado, con las columnas de agregado llamadas `count`, `avg__Duration`, `max__Duration`, `quantiles__Duration`. ClickStack puede responder desde ella a gráficos, tiles de dashboard y alertas, sin modificarlos.

1. **Team Settings**, **Sources**, abre **PayFlow traces**, **Edit configuration**, sección **Materialized views**, **Add materialized view**.
2. Base de datos `payflow_otel`, tabla `otel_traces_1m`. ClickStack deduce el timestamp (`Timestamp`), las dimensiones (`ServiceName`, `SpanName`, `StatusCode`) y las métricas; comprueba que `Duration` se asocia a `avg__Duration`, `max__Duration` y `quantiles__Duration`.
3. Granularidad: **1 minute**. Fecha mínima: `2026-11-27 00:00:00` (el backfill del fichero).
4. Guarda (Save). Abre el tile *p99 latency per service* de `PayFlow · SRE` sobre un día completo: un indicador muestra que el gráfico lo ha servido la vista materializada.

Reglas que conviene conocer:
- la granularidad del gráfico debe ser múltiplo de la de la vista (vista de 1 min: gráficos a 1, 5, 15, 60 min);
- una vista solo contiene lo que se insertó después de crearla: haz el backfill o fija la fecha mínima;
- empieza con un agregado por fuente (recuento y duración por servicio), una decena como mucho.

## Aislamiento de lectura y escritura (para saberlo, no para hacerlo)

Con un **warehouse**, ClickStack puede funcionar sobre un segundo servicio, de solo lectura, que comparte el mismo almacenamiento: dashboards, alertas y notebooks nunca ralentizan la ingesta, y cada lado escala por su cuenta. ClickStack lo recomienda a partir de unos 100 TB al mes.
