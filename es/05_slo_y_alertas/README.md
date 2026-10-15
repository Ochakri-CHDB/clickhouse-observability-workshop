# Módulo 5 · SLO y alertas: romper producción, recibir el aviso

Una alerta es una consulta que se ejecuta periódicamente y se compara con un umbral. `01_burn_rate_slo.sql` monta en SQL la forma SRE de hacerlo (presupuesto de errores, tasa de consumo o burn rate, multiventana). Este README monta las alertas de ClickStack y luego **rompes producción a propósito** y las ves saltar, sobre el flujo en directo del módulo 2.

Duración: 30 min. Ejecuta antes `01_burn_rate_slo.sql` (checkpoint `OK`).

---

## Paso 1 · Adónde enviar las alertas (5 min)

Una alerta necesita un destino (un **webhook**). En ClickHouse Cloud, ClickStack puede enviar a Slack (URL de webhook o API de Slack), a PagerDuty o a cualquier endpoint HTTP.

Para el workshop, usa un webhook genérico que solo muestra lo que recibe:
1. Abre [webhook.site](https://webhook.site) en una pestaña nueva y copia tu URL única.
2. En ClickStack, al crear la primera alerta de abajo, elige **Add New Webhook**, tipo **Generic**, y pega la URL. El cuerpo puede usar `{{title}}`, `{{body}}` y `{{link}}`.

En producción: un canal de Slack por equipo, PagerDuty para los avisos (pages).

---

## Paso 2 · Tres alertas (10 min)

Las alertas se evalúan sobre la hora actual: vigilan el **flujo en directo**. Pon el rango en `Last 15 minutes`.

| Alerta | Cómo | Condición |
|---|---|---|
| **Alerta de búsqueda** sobre la búsqueda guardada `Payment errors` (módulo 3) | **Search**, abre la búsqueda guardada, **Alerts** (arriba a la derecha) | más de 50 líneas en 1 minuto, **agrupadas por** `ServiceName`: una alerta por servicio |
| **Alerta de gráfico** sobre el panel p99 de `PayFlow · SRE` (módulo 4) | abre el menú del panel, **Add Alert** | p99 por encima de 1000 ms durante 1 minuto |
| **Alerta SQL** sobre un panel SQL | un panel SQL de tipo Line y luego **Add Alert**; la última columna numérica es el valor | la tasa de consumo de los últimos 5 minutos por encima de 14,4 (consulta abajo) |

El panel SQL para la tercera alerta (necesita la macro `$__timeInterval`):

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

Antes de guardar, ClickStack dibuja el umbral sobre los datos: comprueba que el flujo en directo, en modo normal, se queda por debajo.

---

## Paso 3 · Romper producción (10 min)

El flujo en directo reproduce una hora tranquila. Acciona el interruptor de caos: ahora reproduce los peores minutos de Black Friday, con los pods defectuosos de v2.4.1.

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
```

En uno o dos minutos:
- **Search** (con Live tail activado): empiezan a desfilar los timeouts de HikariPool;
- las tres alertas se ponen en rojo en **Alerts** (menú de la izquierda), cada evaluación es una barra del historial de la alerta;
- tu página de webhook recibe las notificaciones, con un enlace de vuelta a ClickStack;
- el dashboard `PayFlow · SRE` en `Last 15 minutes`: el p99 sube a 3 s, los release markers muestran la aparición de v2.4.1.

En SQL, las vistas refrescables de `01_burn_rate_slo.sql` ven lo mismo:

```sql
SELECT ts, rule, state, summary FROM payflow_sre.alerts WHERE ts BETWEEN now() - INTERVAL 15 MINUTE AND now() ORDER BY ts
```

Después, marcha atrás (rollback):

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
```

Las alertas se resuelven en cuanto las ventanas se limpian: primero la tasa de consumo de 5 minutos, las demás en pocos minutos.

---

## Paso 4 · Qué hace buena a una alerta (5 min)

- **Alertar por síntomas, investigar causas**: el aviso es la tasa de consumo de lo que sienten los clientes (pagos fallidos), no la CPU de un pod.
- **Dos ventanas**: la de 1 h ignora los picos aislados, la de 5 min apaga la alerta rápido después del arreglo.
- **Group by** para tener una alerta por servicio, y enrutarla al equipo propietario (`service.team`).
- En ClickStack, las alertas pueden usar los agregados (rollups) registrados en una fuente (módulo 7): una alerta sobre un mes de datos sigue siendo barata.
