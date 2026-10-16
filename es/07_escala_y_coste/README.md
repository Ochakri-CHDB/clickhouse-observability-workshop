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

`03_agregados_retencion_muestreo.sql` crea `payflow_otel.otel_traces_1m`: por minuto, servicio, nombre de span y estado, con las columnas de agregado llamadas `count`, `avg__Duration`, `max__Duration`, `quantiles__Duration` (la convención de nombres de ClickStack). Declarada en la fuente, permite a ClickStack responder a gráficos, tiles de dashboard y alertas desde 1,7 millones de filas en vez de 77 millones de spans, sin modificarlos.

1. **Team Settings** (menú de la izquierda), pestaña **Data**. En la lista de fuentes, haz clic en la flecha al final de la línea **PayFlow traces** para abrirla. Deja como está el interruptor a la derecha de cada línea.
2. Baja hasta **Materialized Views** y haz clic en **Add Materialized View**.
3. La base de datos ya es `payflow_otel`. En **Table**, escribe `otel_traces_1m` y haz clic en ella en la lista. El **⋮** que hay al lado tiene **View schema**, para comprobar las columnas.
4. Rellena el formulario (ClickStack no lo deduce):
   - **Timestamp Column**: `Timestamp`;
   - **Granularity**: `1 minute`;
   - **Minimum Date**: el primer día del historial, `SELECT pf_day(-29)` en la consola SQL (el backfill del fichero empieza ahí);
   - **Dimension Columns**: `ServiceName, SpanName, StatusCode`;
   - **Pre-aggregated Columns**, un **Add Column** por línea: `avg`, `Duration`, `avg__Duration`; `max`, `Duration`, `max__Duration`; `quantile`, `Duration`, `quantiles__Duration`; `count`, `count` (count no tiene columna de origen).
5. **Save Source**. Un mensaje *Source updated* lo confirma.

> **Atención**: en estas listas, hacer clic en la opción ya seleccionada (con una marca de validación) la borra. Si el guardado falla con `databaseName: Required`, elige otra base de datos y luego otra vez `payflow_otel`.

![Vista materializada en la fuente](../../en/img/07_source_mv.png)

Compruébalo:
1. **Chart Explorer**, **PayFlow traces**, **Count of Events**, **Group By** `ServiceName`, rango `Last 7 days`, **Run**. Aparece una etiqueta verde **ACCELERATED** arriba a la derecha, y **Generated SQL** (abajo) lee `FROM payflow_otel.otel_traces_1m` con `SUM(count)`.
2. Ahora escribe `SpanKind:Server` en **Where**, **Run**: la etiqueta se vuelve naranja, **NOT ACCELERATED**. Haz clic en ella: la vista es **INCOMPATIBLE**, y el panel enumera lo que puede servir (**Available Group and Filter Columns**: `ServiceName`, `SpanName`, `StatusCode`). `SpanKind` no es una dimensión del agregado, así que ClickStack vuelve a los spans, sin avisar y correctamente.
3. En un rango largo, el gráfico se rellena en varias pasadas, primero los días más recientes: espera a que se estabilice antes de leerlo.

![Gráfico acelerado y su SQL](../../en/img/07_accelerated_sql.png)

Reglas que conviene conocer:
- cada columna de **Where** y de **Group By** debe ser una dimensión de la vista: elige las dimensiones según los gráficos que quieras acelerar (los tiles del módulo 4 filtran por `SpanKind`: añádela al agregado para acelerarlos también);
- la granularidad del gráfico debe ser múltiplo de la de la vista (vista de 1 min: gráficos a 1, 5, 15, 60 min);
- una vista solo contiene lo que se insertó después de crearla: haz el backfill o fija la fecha mínima;
- empieza con un agregado por fuente (recuento y duración por servicio), una decena como mucho.

## Aislamiento de lectura y escritura (para saberlo, no para hacerlo)

Con un **warehouse**, ClickStack puede funcionar sobre un segundo servicio, de solo lectura, que comparte el mismo almacenamiento: dashboards, alertas y notebooks nunca ralentizan la ingesta, y cada lado escala por su cuenta. ClickStack lo recomienda a partir de unos 100 TB al mes.
