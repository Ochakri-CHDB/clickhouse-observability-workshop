# Módulo 4 · Dashboards en ClickStack

Un dashboard responde a "¿funciona?" antes de que nadie lo pregunte. `01_agregados_red.sql` construye las cifras que hay detrás (RED por minuto, el histograma spanmetrics); este README construye el dashboard en sí en ClickStack.

Duración: 35 min. Ejecuta antes `01_agregados_red.sql` (checkpoint `OK`).

> Rango para todo el módulo: **el incidente**, de `2026-11-27 13:00` a `2026-11-27 16:00` (UTC), salvo que se diga lo contrario.

---

## Paso 1 · Chart Explorer: una pregunta, un gráfico (5 min)

**Chart Explorer** (menú de la izquierda) es un `GROUP BY` con interfaz: una fuente, una métrica, un filtro, un group by.

| Fuente | Métrica | Where | Group by | Qué ves |
|---|---|---|---|---|
| PayFlow traces | percentil 99 de `Duration / 1e6` | `SpanKind:Server` | `ServiceName` | tres servicios saltan a 3 s a las 13:58 |
| PayFlow traces | Count | `StatusCode:Error` | `ResourceAttributes['service.version']` | solo falla v2.4.1 |
| PayFlow metrics | `hikaricp.connections.pending` (gauge), Max | | `service.version` | decenas de hilos esperando en v2.4.1, ninguno en v2.4.0 |
| PayFlow metrics | `traces.span.metrics.duration` (histogram) | `span.name:"POST /v1/payments"` | | el histograma spanmetrics del fichero 01 del módulo 4 |

**Text-to-chart**: el asistente de IA de Chart Explorer convierte una frase en un gráfico. Prueba *"error count per service over time"*. Si no está disponible, Generative AI no está activado en tu equipo (módulo 8).

---

## Paso 2 · El dashboard SRE (15 min)

**Dashboards**, **New Dashboard**, nombre `PayFlow · SRE`. Después **Add New Tile** para cada panel:

| Panel | Tipo | Fuente | Ajustes |
|---|---|---|---|
| Requests per service | Line/Bar | PayFlow traces | Count, where `SpanKind:Server`, group by `ServiceName` |
| p99 latency per service | Line/Bar | PayFlow traces | percentil 99 de `Duration / 1e6`, where `SpanKind:Server`, group by `ServiceName` |
| Error rate | Number | PayFlow traces | Count, where `StatusCode:Error AND SpanName:"POST /v1/payments"`; regla de color en rojo por encima de 100 |
| Errors by version | Pie | PayFlow logs | Count, where `SeverityText:ERROR`, group by `ResourceAttributes['service.version']` |
| Latency heatmap | Heatmap | PayFlow traces | `Duration / 1e6`, where `ServiceName:payment` |
| Top error messages | Table | PayFlow logs | Count, where `SeverityText:ERROR`, group by `Body` |

Los nombres de los paneles se quedan en inglés: otros módulos se refieren a ellos.

Después:
- **Filters**: **Edit Filters and Variables**, añade un filtro sobre `ServiceName` y otro sobre `ResourceAttributes['service.team']`. Todos los paneles los siguen.
- **Release markers**: en el menú del dashboard, **Show release markers**. Aparece una línea discontinua a las 13:58 (v2.4.1) y a las 14:42 (v2.4.0) en los gráficos temporales: ClickStack lee `service.version` de la telemetría, no hay nada que configurar. La primera pregunta de cualquier incidente, respondida en el gráfico.
- **Row-click drilldown**: en la tabla *Top error messages*, configura un clic de fila que abra **Search** filtrado por esa fila: de un mensaje a sus líneas en un clic.

---

## Paso 3 · Un panel SQL sobre los agregados (10 min)

Algunas preguntas necesitan SQL: un join, un ratio, un agregado (rollup). Añade un panel, elige la pestaña **SQL**, conexión `Default`, tipo **Line**, y pega:

```sql
SELECT
    minute AS ts,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

`$__timeFilter(minute)` se sustituye por el rango de tiempo del dashboard. El panel lee unos cientos de filas del agregado en vez de millones de spans: para eso sirve el fichero 01 del módulo 4.

Un segundo panel SQL, tipo **Table**, el presupuesto de errores del día:

```sql
SELECT
    sum(requests)                                                   AS requests,
    sum(errors)                                                     AS errors,
    round(100 * (1 - sum(errors) / sum(requests)), 3)               AS availability_pct,
    round(100 * sum(errors) / (sum(requests) * 0.0005), 1)          AS budget_spent_pct
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND toDate(minute) = '2026-11-27'
```

Una sola mala versión se ha comido varias veces el presupuesto de errores del día.

---

## Paso 4 · Dashboards predefinidos (5 min)

ClickStack trae dashboards listos para usar:
- **Services**: vistas HTTP, base de datos y errores de cada servicio, desde la fuente de trazas. Ábrelo en el rango del incidente: las llamadas a base de datos de payment destacan.
- **Kubernetes**: pods, nodos y namespaces desde la fuente de métricas. Nuestras métricas de pod siguen los nombres de kubeletstats (`k8s.pod.cpu.utilization`, `k8s.pod.memory.working_set`); las vistas que necesitan métricas que no simulamos se quedan vacías.
- **Dashboard templates** (Browse dashboard templates): métricas de runtime para servicios Go, JVM, Node.js y .NET.
