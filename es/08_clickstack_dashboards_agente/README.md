# Módulo 8 · ClickStack, dashboards, API y ClickHouse Agents

Hasta aquí todo era SQL. Este módulo muestra la misma investigación tal y como la vive un SRE, en la consola de ClickHouse Cloud:

| Parte | Para quién | Qué | Tiempo |
|---|---|---|---|
| 1. ClickStack | el ingeniero de guardia | buscar en los logs, abrir trazas, representar métricas, montar un dashboard y una alerta, sobre las tablas de los módulos 3 a 5 | 35 min |
| 2. Dashboard en la consola SQL | el responsable del equipo | 4 tiles sobre las tablas gold | 10 min |
| 3. API de estado | la página de estado de PayFlow | un Query API endpoint sobre la tabla de SLO | 10 min |
| 4. ClickHouse Agents | todo el mundo | preguntas en lenguaje natural, dashboards a demanda, detección de anomalías en Python | 25 min |

En este módulo no hay ningún fichero que ejecutar: todas las consultas están abajo, listas para pegar.

> Los datos del workshop son del **viernes 27 de noviembre de 2026, UTC**. Todos los selectores de tiempo de este módulo deben estar en un **rango absoluto**, por ejemplo de `2026-11-27 13:45` a `2026-11-27 15:00` (UTC). "Last 15 minutes" no muestra nada.
>
> ClickStack y ClickHouse Agents evolucionan rápido: la etiqueta de un botón puede cambiar de sitio. El principio no cambia.

---

## 1. ClickStack: el incidente, en clics

ClickStack es el stack de observabilidad de ClickHouse: su interfaz (HyperDX) se ejecuta dentro de ClickHouse Cloud y consulta directamente tu servicio. No hay nada que instalar: las tablas del módulo 3 ya siguen el esquema OpenTelemetry que espera.

### Paso 1 · Abrir ClickStack
1. En la consola Cloud, abre tu servicio.
2. Lanza **ClickStack** desde el servicio (menú de la izquierda).
3. En la página **Getting Started**, sáltate el asistente de ingesta: los datos ya están ahí. Ve a **Team Settings** y luego a **Sources**.

### Paso 2 · Declarar las tres fuentes
Crea una fuente por señal. Como las tablas siguen el esquema OpenTelemetry por defecto, ClickStack rellena solo las expresiones de columna en cuanto eliges la tabla.

| Ajuste | Logs | Trazas | Métricas |
|---|---|---|---|
| Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
| Source Data Type | Log | Trace | Metrics |
| Server Connection | `Default` | `Default` | `Default` |
| Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
| Table | `otel_logs` | `otel_traces` | Gauge `otel_metrics_gauge`, Histogram `otel_metrics_histogram`, Sum `otel_metrics_sum` |

Después enlázalas, para saltar de una señal a otra con un solo clic:
- en **PayFlow logs**: *Correlated Trace Source* = `PayFlow traces`, *Correlated Metric Source* = `PayFlow metrics`;
- en **PayFlow traces**: *Correlated Log Source* = `PayFlow logs`, *Correlated Metric Source* = `PayFlow metrics`.

Comprueba las expresiones deducidas en la fuente de logs: Timestamp `Timestamp`, Service Name `ServiceName`, Log Level `SeverityText`, Body `Body`, Trace Id `TraceId`, Span Id `SpanId`.

### Paso 3 · Buscar en los logs
Abre **Search**, elige **PayFlow logs** y fija el rango absoluto de `2026-11-27 13:45` a `15:00`.

| Escribe en la barra de búsqueda | Qué ves |
|---|---|
| `SeverityText:ERROR` | el histograma de errores se dispara a las 13:58 y se corta a las 14:44 |
| `ServiceName:payment SeverityText:ERROR` | solo timeouts de HikariPool |
| `"maximumPoolSize"` | las líneas de arranque de cada pod de payment: 10 en v2.4.1, 50 antes y después |
| `ServiceName:k8s-events` | el despliegue progresivo (rollout), las readiness probes que fallan, el OOM kill en ip-10-0-3-17 |
| `"pan="` | números de tarjeta, enmascarados por el pipeline del módulo 3 |

La búsqueda de texto completo se apoya en el índice de texto de `otel_logs` (módulo 6): instantánea, incluso sobre mil millones de líneas.

Haz clic en cualquier campo del panel de la izquierda (por ejemplo `k8s.pod.name` o `service.version`) para filtrar por él. Filtra `service.version` = `v2.4.0` y luego `v2.4.1`: solo una de las dos tiene errores.

### Paso 4 · De una línea de log a su traza
1. Busca `ServiceName:checkout SeverityText:ERROR` y abre una línea.
2. El panel lateral muestra la línea, sus atributos y la **traza** a la que pertenece (a través de `TraceId`, gracias a las fuentes correlacionadas).
3. Abre la traza: es el waterfall del módulo 7 (Q4), con 3 segundos pasados en `INSERT payflow.payments` y la excepción de HikariPool como evento del span.

### Paso 5 · Representar el incidente
Abre **Chart Explorer** (o **Search** y cambia a modo gráfico):
- fuente **PayFlow traces**, agregación **p99** de `Duration`, con `SpanKind:Server`, agrupado por `ServiceName`: tres servicios suben a 3 s;
- fuente **PayFlow metrics**, métrica `hikaricp.connections.pending` (gauge), **max**, agrupado por `service.version`: v2.4.1 tiene decenas de hilos en espera, v2.4.0 ninguno;
- métrica `k8s.pod.memory.working_set`, con `k8s.node.name` = `ip-10-0-3-17`, agrupado por `k8s.pod.name`: el pod de fraud-scoring que sube hasta 2 GiB, y luego la caída.

El histograma de latencia `http.server.request.duration` lleva un **exemplar** por minuto (módulo 3): el trace id de la petición más lenta. Donde el gráfico muestra exemplars, un clic abre esa traza.

### Paso 6 · Un dashboard y una alerta
1. **Dashboards**, **New Dashboard**, nombre `PayFlow · SRE`. Añade cuatro tiles a partir de los gráficos del paso 5: p99 por servicio, número de errores por servicio (logs, `SeverityText:ERROR`), HikariCP pending por versión, memoria de ip-10-0-3-17.
2. De vuelta en **Search**, guarda la búsqueda `ServiceName:payment SeverityText:ERROR` como `Payment errors` y crea una **alerta** sobre ella: más de 100 líneas en 1 minuto.

> La alerta se evalúa sobre la hora actual. Los datos del workshop son de noviembre de 2026, así que no saltará: lo que importa es la regla. La misma regla, en SQL, es `payflow_sre.rmv_alerts` (módulo 5).

---

## 2. Un dashboard en la consola SQL, sobre gold

Para el responsable del equipo, cuatro tiles directamente sobre las tablas gold del módulo 5. Cada consulta lee unos pocos miles de filas.

1. En la consola SQL, pega cada consulta en una pestaña nueva, ejecútala y guárdala con **Save** con el nombre indicado.
2. **Dashboards**, **New Dashboard** `PayFlow · SLO`, y luego una visualización por consulta guardada.

**Tile 1 · `tile_red_payments`** (Line, X = `minute`, Y = `error_pct` y `p99_ms`)
```sql
SELECT
    minute,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN '2026-11-27 13:30:00' AND '2026-11-27 15:30:00'
GROUP BY minute
ORDER BY minute
```

**Tile 2 · `tile_burn_rate`** (Line, X = `minute`, Y = `burn_5m`, `burn_1h`, `threshold`)
```sql
SELECT minute, round(burn_5m, 1) AS burn_5m, round(burn_1h, 1) AS burn_1h, 14.4 AS threshold
FROM payflow_sre.slo_burn
WHERE route = 'POST /v1/payments' AND minute BETWEEN '2026-11-27 13:30:00' AND '2026-11-27 15:30:00'
ORDER BY minute
```

**Tile 3 · `tile_alerts`** (Table)
```sql
SELECT ts, rule, severity, service, state, summary
FROM payflow_sre.alerts
ORDER BY ts
```

**Tile 4 · `tile_service_map`** (Table: las aristas cuya latencia más ha cambiado)
```sql
SELECT caller, callee,
       maxIf(p95_ms, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00') AS p95_before_ms,
       maxIf(p95_ms, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS p95_during_ms,
       sumIf(errors, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS errors_during
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 8
```

---

## 3. Una API de estado para la página de estado de PayFlow

La página de estado debe mostrar, para una ruta, la tasa de consumo (burn rate) de los últimos minutos, sin nada de SQL en el lado del cliente.

### Paso 1 · La vista parametrizada
```sql
CREATE OR REPLACE VIEW payflow_sre.api_route_status AS
SELECT minute, route, requests, errors, round(burn_5m, 1) AS burn_5m, fast_burn
FROM payflow_sre.slo_burn
WHERE route = {route:String} AND minute BETWEEN {start:DateTime} AND {finish:DateTime}
ORDER BY minute
```

### Paso 2 · Probarla
```sql
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = '2026-11-27 14:00:00', finish = '2026-11-27 14:10:00')
```

### Paso 3 · Publicarla como endpoint
1. Pestaña nueva, pega:
   ```sql
   SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})
   ```
2. Guárdala con **Save** como `api_route_status`, luego **Share**, **API Endpoint**: elige una API key con el acceso **Query Endpoints** y el rol de base de datos **Read only**.
3. Llámala (sustituye los dos valores):
   ```bash
   curl --user '<Key ID>:<Key secret>' \
     'https://queries.clickhouse.cloud/run/<endpoint id>?format=JSONEachRow&param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00'
   ```

Mientras no tengas una key, la interfaz HTTPS del servicio acepta los mismos parámetros (solo para probar: nunca pongas la contraseña de `default` en un front end):
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})"
```
Respuesta esperada: 11 filas, `fast_burn` a true desde las 14:00.

---

## 4. ClickHouse Agents: pregúntale a la plataforma

### Paso 1 · Documentar las tablas para el agente
Un agente lee primero los comentarios de tablas y columnas (regla `agent-discovery-schema`). Sin ellos, tiene que adivinar qué significa `burn_1h`.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'Métricas RED por minuto: una fila por servicio, operación (nombre del span) y minuto. Termina la agregación con sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanosegundos). Filtra primero por service.',
    COMMENT COLUMN latency 'Estado quantilesTDigest de las duraciones de span en nanosegundos: usa quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 para el p99 en ms';

ALTER TABLE payflow_sre.slo_burn
    MODIFY COMMENT 'Tasa de consumo (burn rate) del presupuesto de errores de cada ruta de api-gateway, por minuto. burn_5m y burn_1h: cuántas veces más rápido de lo permitido se gasta el presupuesto (1 = dentro del presupuesto). fast_burn = ambos por encima de 14,4.';

ALTER TABLE payflow_sre.alerts
    MODIFY COMMENT 'Eventos de alerta (FIRING / RESOLVED) de las cuatro reglas: slo_fast_burn, p99_latency, container_restart, node_memory_pressure.';

ALTER TABLE payflow_otel.otel_traces
    MODIFY COMMENT 'Spans OpenTelemetry de PayFlow. Timestamp en UTC (nanosegundos), Duration en nanosegundos, StatusCode Error o Unset. Filtra siempre por Timestamp y ServiceName. Versión del pod en ResourceAttributes[''service.version''], campos de negocio en SpanAttributes (payment.amount, payment.status, merchant.id).';

ALTER TABLE payflow_otel.otel_logs
    MODIFY COMMENT 'Logs OpenTelemetry de PayFlow, números de tarjeta enmascarados. Filtra siempre por Timestamp. Búsqueda de texto completo: hasToken(lower(Body), ''palabra''). Los eventos de Kubernetes tienen ServiceName = ''k8s-events'' y el motivo en EventName.';

SELECT name, comment FROM system.tables WHERE database IN ('payflow_sre', 'payflow_otel') AND comment != '' ORDER BY name
```

### Paso 2 · Crear el agente
1. En el servicio, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model**: el modelo por defecto. **Tools**: `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (pégalas tal cual):
   ```
   Eres el asistente SRE de PayFlow, una plataforma de pagos en Kubernetes. Responde en español, de forma breve.
   - Los datos están en UTC, del viernes 2026-11-27. Usa rangos de tiempo absolutos dentro de ese día.
   - Prioriza las tablas gold: payflow_sre.red_1m (RED por minuto), payflow_sre.slo_burn,
     payflow_sre.alerts, payflow_sre.service_map_5m, payflow_sre.log_patterns_10m.
     Ve a payflow_otel.otel_traces y otel_logs solo para el detalle, siempre con un filtro sobre
     Timestamp y un LIMIT. Lee primero los comentarios de las tablas.
   - Contexto de negocio: payflow_ref.merchant (dictGet('payflow_ref.dict_merchant', 'name', merchant_id)),
     despliegues: payflow_ref.deployment_history.
   - Da las cifras clave con su unidad y después el SQL que has usado.
   - Cuando te pidan un gráfico o un dashboard, constrúyelo con la herramienta Artifacts.
   - Para Python (estadística, detección de anomalías, previsión): ejecuta primero el SQL con la
     herramienta ClickHouse, mantén el resultado compacto (como mucho unos pocos miles de filas), pega
     los datos en el código y ejecútalo tú mismo con Run Code. Run Code no tiene acceso a ClickHouse.
     Muestra el resultado en un artifact.
   ```
4. Guarda, abre una conversación y elige el agente.

### Paso 3 · Dos preguntas
| Pregunta | Respuesta esperada |
|---|---|
| "¿Qué les pasó a los pagos entre las 13:55 y las 14:50 del 27 de noviembre?" | tasa de error de `POST /v1/payments` hasta ~30 %, p99 de 3 s, de 13:58 a 14:44; causa raíz: timeouts de HikariPool en `payment` v2.4.1 (CHG-4117, pool size 10); primer aviso (page) a las 14:00 |
| "¿Cuánto dinero costó el incidente y qué comercios fueron los más afectados?" | ~15 300 pagos fallidos, ~1,58 M EUR, ~8 000 comercios; los comercios principales por importe |

### Paso 4 · Dashboards a demanda
- "Construye un dashboard del incidente: tasa de error y p99 de POST /v1/payments por minuto, el burn rate con su umbral de 14,4, y las alertas como marcadores."
- "Muestra el mapa de servicios durante el incidente como un grafo, con las aristas coloreadas según la latencia p95."
- "Compara los pods de payment de v2.4.0 y v2.4.1 durante el despliegue progresivo: conexiones HikariCP activas y en espera."

### Paso 5 · Data science con Run Code
- "Detecta los minutos anómalos del día en POST /v1/payments a partir de la tasa de error y la latencia p99, con un Isolation Forest. Muéstralos en un gráfico."

  Respuesta esperada: los minutos anómalos van de 13:58 a ~14:45. El modelo no sabe nada del incidente: lo encuentra solo.
- "Prevé las peticiones por minuto de POST /v1/payments entre las 20:00 y las 21:00 a partir del resto del día, y compáralo con lo que pasó realmente."

  Respuesta esperada: el pico de la tarde-noche se predice bien; la venta flash de las 14:00 es un valor atípico del que el modelo no debería aprender.

### En producción
Dale al agente un rol de solo lectura con límites por consulta (regla `agent-query-safety`), por ejemplo:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS payflow_agent_profile SETTINGS readonly = 2, max_execution_time = 30, max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS payflow_agent_role SETTINGS PROFILE 'payflow_agent_profile';
GRANT SELECT ON payflow_sre.* TO payflow_agent_role;
GRANT SELECT ON payflow_otel.* TO payflow_agent_role;
GRANT SELECT, dictGet ON payflow_ref.* TO payflow_agent_role;
```
