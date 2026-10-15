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

## 1. AI Notebooks (beta, solo Managed ClickStack)

Un notebook es una investigación escrita por un agente de IA, tile a tile: su razonamiento, cada consulta que ejecutó, los gráficos y su conclusión. Puedes bifurcar desde cualquier paso, añadir tus propios tiles y compartirlo con el equipo.

1. Un administrador del equipo activa la IA: **Team Settings**, **Security Policies**, activa **Generative AI** y acepta.
2. **Notebooks** (menú de la izquierda), **New Shared Notebook**.
3. Pregunta: *"¿Por qué falló POST /v1/payments entre las 13:58 y las 14:45 del 27 de noviembre de 2026 (UTC)? ¿Qué versión, qué pods y cuál fue la causa raíz?"*
4. Lee los tiles: el agente busca en los logs, abre trazas, compara versiones. Si sigue una pista que no te convence, usa **Restart from Here** con un nuevo prompt para bifurcar la investigación.
5. Compara su conclusión con la tuya (módulo 6). Después prueba sobre el flujo en directo, tras volver a romper producción (módulo 5): *"¿Qué les pasa a los pagos en los últimos 10 minutos?"*

---

## 2. El servidor MCP de ClickStack

ClickStack expone un servidor MCP: cualquier cliente MCP (Claude Code, Cursor, VS Code...) puede buscar en logs y trazas, y leer dashboards y alertas, con tus permisos.

1. En la consola Cloud: **Connect**, **Connect with MCP**, actívalo en el servicio.
2. Endpoint `https://mcp.clickhouse.cloud/clickstack`, inicio de sesión OAuth en el primer uso (sin API key). Por ejemplo con Claude Code:
   ```bash
   claude mcp add --transport http clickstack https://mcp.clickhouse.cloud/clickstack
   ```
3. Pregunta a tu asistente: *"Con ClickStack, encuentra los event patterns de los errores de pago del 27 de noviembre de 2026 entre las 14:00 y las 14:45 y abre la traza más lenta."*

---

## 3. ClickHouse Agents

ClickHouse Agents trabajan en el lado SQL del servicio, con tres herramientas: ClickHouse (consultas), Artifacts (gráficos y dashboards), Run Code (Python).

### 3.1 · Documentar las tablas para el agente
Un agente lee primero los comentarios de tablas y columnas (regla `agent-discovery-schema`). Sin ellos, adivina qué significa `burn_1h`.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'Métricas RED por minuto: una fila por servicio, operación (span name) y minuto. Termina la agregación con sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanosegundos). Filtra primero por service.',
    COMMENT COLUMN latency 'Estado quantilesTDigest de las duraciones de los spans en nanosegundos: usa quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 para el p99 en ms';

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

### 3.2 · Crear el agente
1. En el servicio, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model**: el modelo por defecto. **Tools**: `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (pégalas tal cual):
   ```
   Eres el asistente SRE de PayFlow, una plataforma de pagos sobre Kubernetes. Responde en español, de forma breve.
   - Los datos están en UTC, del viernes 27 de noviembre de 2026. Usa rangos de tiempo absolutos de ese día.
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
4. Guarda (**Save**), abre una conversación y elige el agente.

### 3.3 · Dos preguntas
| Pregunta | Respuesta esperada |
|---|---|
| "¿Qué les pasó a los pagos entre las 13:55 y las 14:50 del 27 de noviembre?" | tasa de errores de `POST /v1/payments` de hasta ~30 %, p99 de 3 s, de 13:58 a 14:44; causa raíz: timeouts de HikariPool en `payment` v2.4.1 (CHG-4117, pool de 10); primer aviso a las 14:00 |
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

- **En ClickStack (RBAC, Managed)**: **Team Settings**, roles Admin, Member, ReadOnly, o roles personalizados con No Access / Read / Manage por recurso (dashboards, saved searches, alerts, notebooks). Da al equipo de pagos Manage sobre sus propios dashboards y alertas, y Read en el resto.
- **En ClickHouse**: `01_seguridad_y_operacion.sql` crea un rol por equipo y una row policy por tabla. ClickStack consulta el servicio con los permisos del usuario: el equipo de pagos solo ve el namespace `payments`, en la consola SQL, en ClickStack y a través del servidor MCP.

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
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = '2026-11-27 14:00:00', finish = '2026-11-27 14:10:00')
```

### 5.3 · Publicarla como endpoint
1. Nueva pestaña, pega:
   ```sql
   SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})
   ```
2. **Save** como `api_route_status`, luego **Share**, **API Endpoint**: elige una API key con el acceso **Query Endpoints** y el rol de base de datos **Read only**.
3. Llámalo (sustituye los dos valores):
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

## Fin de la jornada

Detén el flujo en directo del módulo 2; si no, el servicio nunca entra en reposo:

```sql
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
```

(o ejecuta `detener_flujo_en_directo.sql`). `reset.sql` borra todo lo que ha creado el taller.
