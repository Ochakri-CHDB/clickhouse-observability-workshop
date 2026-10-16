# Módulo 8 · IA y gobernanza

Dos preguntas cierran la jornada. ¿Puede una IA hacer la investigación por ti? ¿Y quién puede ver qué? Este README cubre la parte ClickStack y Cloud; `01_seguridad_y_operacion.sql` cubre el borrado, los permisos y la observabilidad del propio ClickHouse.

Duración: 40 min.

| Parte | Qué | Tiempo |
|---|---|---|
| 1 | AI Notebooks en ClickStack | 10 min |
| 2 | El servidor MCP de ClickStack: tu propio asistente de IA sobre los datos | 5 min |
| 3 | ClickHouse Agents: preguntas, dashboards a demanda, ciencia de datos | 15 min |
| 4 | Roles y accesos: RBAC en ClickStack, row policies en SQL | 5 min |
| 5 | Una API de estado para la página de estado de PayFlow | 5 min |

---

## 1. AI Notebooks (beta)

Un notebook es una investigación escrita como una lista de bloques: búsquedas, gráficos, tablas, notas. Un agente de IA puede escribir los bloques por ti a partir de una pregunta; tú conservas, editas o añades bloques, y compartes el notebook con el equipo.

1. Comprueba que la IA está activada: **Team Settings**, pestaña **API & Agents**, sección **Configure Generative AI**. Dice *Generative AI features are enabled for this service* y enumera **Chart AI Assistant** (el AI Assistant de Chart Explorer, módulo 4) y **AI Notebooks**. Si no, un administrador del equipo las activa ahí.
2. Tu fecha de Black Friday: `SELECT pf_black_friday()` en la consola SQL.
3. Menú de la izquierda, **AI notebooks**, **New Shared Notebook** (el equipo lo ve) o **New Private Notebook** (solo tú).
4. En el campo **Ask AI to explore your data**, escribe, con tu fecha: *¿Por qué falló POST /v1/payments entre las 13:58 y las 14:45 UTC del YYYY-MM-DD? ¿Qué versión, qué pods y cuál fue la causa raíz? Usa las fuentes PayFlow.*
5. Lee los bloques a medida que llegan: el agente busca en los logs, abre trazas, compara versiones. Cada bloque se puede abrir y editar como una búsqueda o un gráfico normal.
6. Compara su conclusión con la tuya (módulo 6). Después prueba sobre el flujo en directo, tras volver a romper producción (módulo 5): *¿Qué les pasa a los pagos en los últimos 10 minutos?*

La función está en beta: puede que la IA solo ponga título al notebook y no añada ningún bloque. En ese caso, construye tú la investigación con **Manual Block**: **Search**, **Chart**, **Table**, **Markdown**. Un notebook escrito a mano sigue siendo el mejor borrador de postmortem: cada bloque es una consulta viva, no una captura de pantalla.

---

## 2. El servidor MCP de ClickStack

ClickStack expone un servidor MCP: cualquier cliente MCP (Claude Code, Cursor, VS Code, Codex CLI...) puede buscar en logs y trazas, y leer dashboards y alertas, con tus permisos.

1. **Team Settings**, pestaña **API & Agents**, sección **Connect your AI agents**. **Remote MCP server** debe decir **ENABLED**.
2. Elige tu herramienta en las pestañas (**Claude Code**, **Cursor**, **VS Code**, **Codex CLI**, **OpenCode**, **Other**) y copia el comando que aparece. Para Claude Code lleva el id de tu servicio en una cabecera:
   ```bash
   claude mcp add clickstack --transport http https://mcp.clickhouse.cloud/clickstack --header "x-service-id: <your service id>"
   ```
   El **Service ID** está arriba en la misma pestaña, con un botón **Copy**. La primera llamada abre un inicio de sesión en el navegador (OAuth, sin API key). **Manage sessions** enumera y revoca las herramientas conectadas.
3. Pregunta a tu asistente, con tu fecha: *Con ClickStack, encuentra los event patterns de los errores de pago del YYYY-MM-DD entre las 14:00 y las 14:45 UTC y abre la traza más lenta.*

En la misma pestaña, **Export to Terraform** (experimental) descarga los dashboards, alertas, búsquedas guardadas y fuentes del equipo como un fichero de importación de Terraform: la configuración de este taller, versionada como código.

---

## 3. ClickHouse Agents

ClickHouse Agents trabajan en el lado SQL del servicio, con tres herramientas: ClickHouse (consultas), Artifacts (gráficos y dashboards), Run Code (Python).

### 3.1 · Documentar las tablas para el agente
Un agente lee primero los comentarios de tablas y columnas (regla `agent-discovery-schema`). Sin ellos, adivina qué significa `burn_1h`.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'RED metrics per minute: one row per service, operation (span name) and minute. Finish the aggregation with sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanoseconds). Filter on service first.',
    COMMENT COLUMN latency 'quantilesTDigest state of span durations in nanoseconds: use quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 for p99 in ms';

ALTER TABLE payflow_sre.slo_burn
    MODIFY COMMENT 'Error budget burn rate of each api-gateway route, per minute. burn_5m and burn_1h: how many times faster than allowed the budget is spent (1 = on budget). fast_burn = both above 14.4.';

ALTER TABLE payflow_sre.alerts
    MODIFY COMMENT 'Alert events (FIRING / RESOLVED) of the four rules: slo_fast_burn, p99_latency, container_restart, node_memory_pressure.';

ALTER TABLE payflow_otel.otel_traces
    MODIFY COMMENT 'OpenTelemetry spans of PayFlow. Timestamp in UTC (nanoseconds), Duration in nanoseconds, StatusCode Error or Unset. Always filter on Timestamp and ServiceName. Pod version in ResourceAttributes[''service.version''], business fields in SpanAttributes (payment.amount, payment.status, merchant.id).';

ALTER TABLE payflow_otel.otel_logs
    MODIFY COMMENT 'OpenTelemetry logs of PayFlow, card numbers masked. Always filter on Timestamp. Full-text search: hasToken(lower(Body), ''word''). Kubernetes events have ServiceName = ''k8s-events'' and the reason in EventName.';

SELECT name, comment FROM system.tables WHERE database IN ('payflow_sre', 'payflow_otel') AND comment != '' ORDER BY name
```

### 3.2 · Crear el agente
1. En el servicio, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model**: el modelo por defecto. **Tools**: `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (pégalas tal cual):
   ```
   Eres el asistente SRE de PayFlow, una plataforma de pagos sobre Kubernetes. Responde en español, de forma breve.
   - Los datos están en UTC. El incidente es en Black Friday: su fecha es SELECT pf_black_friday(), y
     pf_at('14:00:00') son las 14:00 de ese día. Usa rangos de tiempo absolutos construidos con estas funciones.
   - Usa preferentemente los agregados: payflow_sre.red_1m (RED por minuto), payflow_sre.slo_burn,
     payflow_sre.alerts, payflow_sre.service_map_5m, payflow_sre.log_patterns_10m.
     Ve a payflow_otel.otel_traces y otel_logs solo para los detalles, siempre con un filtro sobre Timestamp
     y un LIMIT. Lee primero los comentarios de las tablas.
   - Contexto de negocio: payflow_inventory.merchant (dictGet('payflow_inventory.dict_merchant', 'name', merchant_id)),
     despliegues: payflow_inventory.deployment_history.
   - Da las cifras clave con su unidad y después el SQL que has usado.
   - Si te piden un gráfico o un dashboard, constrúyelo con la herramienta Artifacts.
   - Para Python (estadística, detección de anomalías, previsión): ejecuta primero el SQL con la herramienta
     ClickHouse, mantén el resultado compacto (unos pocos miles de filas como máximo), pega los datos en el
     código y ejecútalo tú mismo con Run Code. Run Code no tiene acceso a ClickHouse. Muestra el resultado en un artifact.
   ```
4. Guarda, abre una conversación y elige el agente.

### 3.3 · Dos preguntas
| Pregunta | Respuesta esperada |
|---|---|
| "¿Qué les pasó a los pagos entre las 13:55 y las 14:50 de Black Friday?" | tasa de errores de `POST /v1/payments` de hasta ~30 %, p99 de 3 s, de 13:58 a 14:44; causa raíz: timeouts de HikariPool en `payment` v2.4.1 (CHG-4117, pool de 10); primer aviso a las 14:00 |
| "¿Cuánto dinero costó el incidente y qué comercios fueron los más afectados?" | ~15 300 pagos fallidos, ~1,58 M EUR, ~8000 comercios; los comercios principales por importe |

### 3.4 · Dashboards a demanda
- "Construye un dashboard del incidente: tasa de errores y p99 de POST /v1/payments por minuto, la tasa de consumo (burn rate) con su umbral de 14,4 y las alertas como marcadores."
- "Muestra el mapa de servicios durante el incidente como un grafo, con las aristas coloreadas según la latencia p95."
- "Compara los pods de payment de v2.4.0 y v2.4.1 durante el despliegue progresivo (rollout): conexiones HikariCP activas y en espera."

### 3.5 · Ciencia de datos con Run Code
- "Detecta los minutos anómalos del día en POST /v1/payments a partir de la tasa de errores y la latencia p99, con un Isolation Forest. Muéstralos en un gráfico."

  Respuesta esperada: los minutos anómalos van de las 13:58 a ~14:45. El modelo no sabe nada del incidente: lo encuentra solo.
- "Predice las peticiones por minuto de POST /v1/payments entre las 20:00 y las 21:00 a partir del resto del día, y compáralo con lo que pasó de verdad."

  Respuesta esperada: el pico de la tarde se predice bien; la venta flash de las 14:00 es un valor atípico del que el modelo no debería aprender.

### 3.6 · En producción
Dale al agente un rol de solo lectura con límites por consulta (regla `agent-query-safety`), por ejemplo:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS payflow_agent_profile SETTINGS readonly = 2, max_execution_time = 30, max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS payflow_agent_role SETTINGS PROFILE 'payflow_agent_profile';
GRANT SELECT ON payflow_sre.* TO payflow_agent_role;
GRANT SELECT ON payflow_otel.* TO payflow_agent_role;
GRANT SELECT, dictGet ON payflow_inventory.* TO payflow_agent_role;
```

---

## 4. Roles y accesos

### En ClickStack
1. **Team Settings**, pestaña **Members & Roles**. Arriba, los miembros del equipo (**Manage in Console** para invitar a gente, desde la organización Cloud). Debajo, los roles: **Admin**, **Member**, **ReadOnly**, y **Default New User Role** al final (el rol de quien se une).
2. **Add Role**: **Role Name** `Payments SRE`, una **Description**, y luego una línea por recurso con **No Access**, **Read** o **Manage**: Dashboards, Saved Searches, Sources, Webhooks, Alerts, Notebooks; **Users** (No Access, Read) y **Team** (Read, Manage).
3. La flecha al final de Dashboards, Saved Searches, Sources y Notebooks abre **Fine-Grained Controls**: **Add Access Rule**, una **Condition** sobre el **Name**, el **ID** o un **Tag** (`is` o `contains`), y el nivel de acceso de los objetos que coinciden. Por ejemplo, Dashboards, Tag is `payments`, **Manage**: el equipo edita sus propios dashboards y solo lee los demás.
4. Cierra con la **x** si solo estabas mirando; **Create Role** lo guarda.

### En ClickHouse
`01_seguridad_y_operacion.sql` crea un rol por equipo y una row policy por tabla. ClickStack consulta el servicio con los permisos del usuario: el equipo de pagos solo ve el namespace `payments`, en la consola SQL, en ClickStack y a través del servidor MCP. Los roles de ClickStack deciden lo que puedes hacer en la interfaz; los roles de ClickHouse deciden qué filas puedes leer.

---

## 5. Una API de estado para la página de estado de PayFlow

La página de estado debe mostrar, para una ruta, la tasa de consumo (burn rate) de los últimos minutos, sin nada de SQL en el lado del cliente.

### 5.1 · La vista parametrizada
```sql
CREATE OR REPLACE VIEW payflow_sre.api_route_status AS
SELECT minute, route, requests, errors, round(burn_5m, 1) AS burn_5m, fast_burn
FROM payflow_sre.slo_burn
WHERE route = {route:String} AND minute BETWEEN {start:DateTime} AND {finish:DateTime}
ORDER BY minute
```

### 5.2 · Probarla
```sql
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = pf_at('14:00:00'), finish = pf_at('14:10:00'))
```

### 5.3 · Publicarla como endpoint
1. Nueva pestaña, pega:
   ```sql
   SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})
   ```
2. **Save** como `api_route_status`, luego **Share**, **API Endpoint**: elige una API key con el acceso **Query Endpoints** y el rol de base de datos **Read only**.
3. Llámalo (sustituye los dos valores, y `YYYY-MM-DD` por tu fecha de Black Friday):
   ```bash
   curl --user '<Key ID>:<Key secret>' \
     'https://queries.clickhouse.cloud/run/<endpoint id>?format=JSONEachRow&param_route=POST%20%2Fv1%2Fpayments&param_start=YYYY-MM-DD%2014%3A00%3A00&param_finish=YYYY-MM-DD%2014%3A10%3A00'
   ```

Mientras no tengas una key, la interfaz HTTPS del servicio acepta los mismos parámetros (solo para probar: nunca pongas la contraseña de `default` en un front end):
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_route=POST%20%2Fv1%2Fpayments&param_start=YYYY-MM-DD%2014%3A00%3A00&param_finish=YYYY-MM-DD%2014%3A10%3A00&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})"
```
Respuesta esperada: 11 filas, `fast_burn` a true desde las 14:00.

---

## Fin de la jornada

Detén el flujo en directo del módulo 2 (siete vistas refrescables); si no, el servicio nunca entra en reposo: ejecuta `detener_flujo_en_directo.sql`, o:

```sql
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
SYSTEM STOP VIEW payflow_sim.rmv_live_sums;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_traces;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_logs;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_metrics;
```

`reset.sql` borra todo lo que ha creado el taller en el servicio. Los objetos de ClickStack (fuentes, dashboard, búsqueda guardada, alertas, notebooks) se quedan: bórralos desde la interfaz si quieres un equipo limpio.
