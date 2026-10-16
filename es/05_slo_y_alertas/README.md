# Módulo 5 · SLO y alertas: romper producción, recibir el aviso

Una alerta es una consulta que se ejecuta periódicamente y se compara con un umbral. `01_burn_rate_slo.sql` monta en SQL la forma SRE de hacerlo (presupuesto de errores, tasa de consumo o burn rate, dos ventanas). Este README monta las mismas alertas en ClickStack, clic a clic, y luego **rompes producción a propósito** y las ves saltar sobre el flujo en directo del módulo 2.

Duración: 35 min. Ejecuta antes `01_burn_rate_slo.sql` (checkpoint `OK`).

> Las alertas de ClickStack se evalúan sobre la **hora actual**, en cada ventana (1 minuto, 5 minutos...). Vigilan el flujo en directo, no Black Friday. Pon el rango en `Last 1 hour` para todo el módulo.

---

## Paso 1 · Los tres sitios de donde sale una alerta (2 min)

| Dónde | Botón | Lo que cuenta la alerta |
|---|---|---|
| una **búsqueda guardada** | **Alerts**, arriba a la derecha de Search | el número de líneas que cumplen la búsqueda |
| un **tile de dashboard** (Builder o SQL) | la campana del tile, o **Add alert** en el editor de tiles | el valor del gráfico |
| **Chart Explorer** | **Add alert**, debajo de la serie | el valor del gráfico, sin dashboard |

Después, cada alerta aparece en **Alerts** (menú de la izquierda), con su estado y su historial.

---

## Paso 2 · Adónde van las notificaciones (5 min)

Una alerta necesita un destino. Dos opciones, elige una:

- **Email** (lo más sencillo): en el formulario de alerta, **Send to**, cambia **Webhook** por **Email**, escribe tu dirección y pulsa **Enter**.
- **Un webhook**: **Team Settings** (menú de la izquierda), pestaña **Integrations**, **Add Webhook** (o **Add New Incoming Webhook** directamente en el formulario de alerta). Las opciones de **Service Type**: **Slack (Webhook URL)**, **Slack API**, **PagerDuty API**, **incident.io**, **Generic**.

Para un webhook genérico que solo muestra lo que recibe, abre [webhook.site](https://webhook.site) en una pestaña nueva y copia tu URL única (la página es pública: vale para datos simulados, nunca para datos reales). En ClickStack: **Service Type** `Generic`, **Webhook Name** `workshop`, **Webhook URL** la URL copiada, **Test Webhook** (llega un mensaje de prueba a webhook.site) y luego **Add Webhook**.

El **Webhook Body** de un webhook genérico es una plantilla. Las variables más útiles:

| Variable | Valor |
|---|---|
| `{{title}}`, `{{body}}`, `{{link}}` | el título de la alerta, el mensaje, un enlace de vuelta a ClickStack |
| `{{status}}` | `firing`, `resolved`, `no_data`, `pending` o `error` |
| `{{value}}`, `{{threshold}}` | el valor que ha cruzado, el umbral |
| `{{groupKey}}` | el grupo que ha cruzado (el pod, el servicio), cuando la alerta está agrupada |
| `{{alertId}}` | un id estable, para deduplicar en el lado receptor |
| `{{note}}` | la nota de la alerta, normalmente un enlace a un runbook |

En producción: un canal de Slack por equipo, PagerDuty o incident.io para los avisos (pages).

---

## Paso 3 · Tres alertas (15 min)

### 3a · Una alerta de búsqueda, una por pod

1. Menú de la izquierda, **Saved Searches**, abre **Payment errors** (guardada en el módulo 3, paso 4; si no está: **Search**, fuente **PayFlow logs**, búsqueda `ServiceName:payment SeverityText:ERROR`, **Save**, nombre `Payment errors`, **Save**).
2. Haz clic en **Alerts** (arriba a la derecha). El formulario se abre en **New Alert**.
3. Rellénalo:
   - **Name**: `Payment errors per pod`.
   - **Alert type**: **Static threshold**.
   - **Alert when**: `At least (≥)`, `10`, líneas en `1 minute`.
   - **grouped by**: `ResourceAttributes['k8s.pod.name']`. Una alerta por pod en vez de una por servicio: la notificación dice qué pod.
   - **Send to**: tu email o tu webhook.
   - **Note**: una línea para quien reciba el aviso, por ejemplo `Pool exhaustion on payment, see the Payment errors saved search`.
4. Abre una vez **Advanced Settings**: **Consecutive windows** (saltar solo tras N ventanas malas seguidas) y **Anchor start time** (alinear las ventanas con una hora dada). Deja los valores por defecto.
5. Baja: el **Threshold chart** dibuja la última hora de la búsqueda con el umbral. Con tráfico normal se queda en 0 o 1: la alerta no habría saltado.
6. **Create Alert**.

![Formulario de alerta de búsqueda](../../en/img/05_search_alert.png)

### 3b · Una alerta de latencia desde Chart Explorer

1. Menú de la izquierda, **Chart Explorer**. **Data Source** `PayFlow traces`, **99th Percentile**, SQL Column `Duration / 1e6`, **Where** `SpanKind:Server ServiceName:payment`, **Run**.
2. Haz clic en **Add alert** (debajo de la serie). Se abre un panel a la derecha.
3. **Static threshold**, **Trigger when value** `is at least (≥)` `2000` en `5 minute`. **Name** `Payment p99 over 2 s`. **Send to** como antes. **Create alert**.

Por qué `payment` y 2 s, y no todos los servicios por encima de 1 s: con tráfico normal, un timeout de la red de tarjetas (5 s) de vez en cuando empuja el p99 de checkout y de card-network-adapter por encima de 1 s en 5 minutos tranquilos (18 ventanas en la semana, hasta 3,5 s). El p99 de payment llega como mucho a 1,4 s; durante el incidente es de 3 s. Un umbral se elige sobre los datos, no en abstracto.

El otro **Alert type**, **Anomaly detection** (beta), no necesita umbral: ClickStack aprende el nivel habitual de la serie y salta cuando se sale de él. Es el mismo panel que el de la campana de un tile de dashboard:

![Alerta de tile, detección de anomalías](../../en/img/05_alert_form.png)

### 3c · El burn rate, como alerta de un tile SQL

El burn rate de `01_burn_rate_slo.sql` es un ratio sobre un agregado: un tile SQL.
1. **Dashboards**, **PayFlow · SRE**, **Add**, **New Tile**, **SQL** (arriba a la derecha). **Connection** `Default`; vacía **Source** con su **x** (la consulta lee un agregado, no una fuente).
2. Haz clic dentro del editor SQL, selecciona todo y pega:

```sql
SELECT
    $__timeInterval(minute) AS ts,
    sum(errors) / greatest(sum(requests), 1) / 0.0005 AS burn_rate
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

   Dos avisos naranjas piden `$__sourceTable` y `$__filters`: son consejos para los tiles sobre una fuente, aquí ignóralos.
3. **Chart Name** `Burn rate, POST /v1/payments`, **Run**. En el rango del incidente (módulo 3, paso 0) la curva sube hasta unos 600: el presupuesto se consume 600 veces demasiado rápido.
4. **Add alert** (encima del editor): **Trigger when value** `is at least (≥)` `100` en `5 minute`, **Send to**, **Add alert**, y luego **Save** el tile.

![Alerta de tile SQL](../../en/img/05_sql_tile_alert.png)

Por qué 100 y no 14,4, el umbral clásico de fast burn: 14,4 está pensado para una ventana de 1 h confirmada por otra de 5 min (es lo que hace `01_burn_rate_slo.sql`). Solo sobre 5 minutos, con unos 240 pagos por ventana, bastan dos pagos fallidos para cruzar 14,4: el 5 % de las ventanas de una semana normal lanzaría un aviso. Solo sobre 5 minutos, 100 significa "el 5 % de los pagos falla": el tráfico normal llega como mucho a 61, el incidente a 600.

---

## Paso 4 · Romper producción (10 min)

El flujo en directo genera tráfico normal. Acciona el interruptor: ahora reproduce los peores minutos de Black Friday, a una cuarta parte de su tráfico, con los pods defectuosos de v2.4.1. Desde la consola SQL:

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
```

En uno a tres minutos:
- **Search**, fuente **PayFlow logs**, **Live Tail**: empiezan a desfilar los timeouts de HikariPool, desde los pods `payment-5c8b7f9d21-*` (v2.4.1).
- **Dashboards**, **PayFlow · SRE**, rango `Last 15 minutes`, **Live**: las peticiones saltan, el p99 de payment sube a 3 s, el tile del burn rate a 500 o 600 (falla una cuarta parte de los pagos), **Payment errors** se pone en rojo por encima de 100.
- **Alerts** (menú de la izquierda): las tres alertas se ponen en rojo. Haz clic en una: cada evaluación es una barra de su historial, con el valor y el umbral.
- Tu buzón o webhook.site recibe las notificaciones, con un enlace de vuelta a ClickStack (`{{link}}`).
- De vuelta en el dashboard, menú **⋮**, **Show alert annotations**: los momentos en que saltaron las alertas quedan marcados en los gráficos.

En SQL, las vistas refrescables de `01_burn_rate_slo.sql` ven lo mismo: la regla de fast burn salta en el primer minuto de caos, la del p99 en el tercero (espera 3 minutos lentos seguidos).

```sql
SELECT ts, rule, state, summary FROM payflow_sre.alerts WHERE ts >= now() - INTERVAL 15 MINUTE ORDER BY ts
```

Después, marcha atrás (rollback):

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
```

Las alertas se resuelven en cuanto sus ventanas se limpian: primero la alerta de búsqueda de 1 minuto, las de 5 minutos en cinco minutos como mucho. La notificación dice `resolved`.

> **Atención**: desactiva el caos antes de la pausa. De todos modos, el flujo en directo se detiene solo 8 horas después de arrancar (columna `live_until` de `payflow_sim.chaos`).

---

## Paso 5 · Qué hace buena a una alerta (3 min)

- **Alertar por síntomas, investigar causas**: el aviso es la tasa de consumo de lo que sienten los clientes (pagos fallidos), no la CPU de un pod.
- **Elegir el umbral sobre los datos**: el gráfico de umbral del formulario muestra lo que habría hecho la alerta durante la última hora. Mira una semana normal antes de elegir (paso 3b).
- **Dos ventanas**: la de 1 h ignora los picos aislados, la de 5 min apaga la alerta rápido después del arreglo. En ClickStack, **Consecutive windows** da el mismo "durante N ventanas seguidas".
- **Group by** para tener una alerta por pod o por servicio, y enrutarla al equipo propietario (`service.team`).
- **Una nota en cada alerta**: qué significa y dónde mirar, para quien se despierta a las 3 de la mañana.
- Las alertas pueden usar los agregados (rollups) registrados en una fuente (módulo 7): una alerta sobre un mes de datos sigue siendo barata.
