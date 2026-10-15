# Módulo 6 · La investigación: Black Friday, 14:00

El aviso (page) llegó a las 14:00: *POST /v1/payments: error budget burning 19x faster than allowed*. Tienes ClickStack y la consola SQL. Encuentra qué se ha roto, por qué, a quién afecta y cuánto ha costado.

Duración: 45 min.
- Parte 1 (25 min): el recorrido por ClickStack que sigue.
- Parte 2 (20 min): `01_mapa_y_patrones.sql` y `02_incidente_en_sql.sql`, las mismas respuestas en SQL, con el impacto de negocio.

> Rango para todo el módulo: **el incidente**, `2026-11-27 13:30` a `2026-11-27 15:00` (UTC).

---

## Paso 1 · ¿Cómo de grave, y dónde? El mapa de servicios (5 min)

Abre **Service Map** (menú de la izquierda), fuente **PayFlow traces**, rango **el incidente**.
- Cada nodo es un servicio (`service.name`), cada arista un span de cliente emparejado con un span de servidor.
- El tamaño del nodo es el tráfico; el rojo indica errores. `api-gateway`, `checkout` y `payment` están en rojo; `ledger`, `card-network-adapter` y `notification` no, porque las peticiones fallidas nunca llegaron hasta ellos.
- Baja el **control de muestreo** (sampling slider) en un dataset grande: el mapa carga más rápido y sigue siendo correcto.

## Paso 2 · ¿Qué dicen los errores? Event Patterns (5 min)

**Search**, fuente **PayFlow logs**, `SeverityText:ERROR`. En **Analysis Mode**, elige **Event Patterns**.
- Millones de líneas se reducen a un puñado de patrones; ClickStack sustituye por ti las partes variables (ids, números).
- El patrón principal es el timeout de HikariPool en `payment`. Los siguientes (el "payment failed: payment service returned 503" de checkout, los 503 del gateway) solo lo propagan.
- Acota primero a un servicio (`ServiceName:payment`): los patrones funcionan mejor sobre un conjunto reducido.

## Paso 3 · ¿Qué tienen en común los spans lentos? Event Deltas (5 min)

**Search**, fuente **PayFlow traces**, `ServiceName:payment SpanKind:Client`. **Analysis Mode**, **Event Deltas**.
- El mapa de calor muestra dos poblaciones: la banda normal en torno a 5 ms y una banda plana en 3 000 ms (un timeout fijo deja exactamente esta firma).
- Dibuja un rectángulo alrededor de la banda de 3 000 ms. Los gráficos de atributos la comparan (Selection, naranja) con todo lo demás (Background, verde), de mayor a menor diferencia.
- `ResourceAttributes['service.version']` destaca: los spans lentos son todos **v2.4.1**. Haz clic en la barra, **Filter**, y el mapa de calor se redibuja solo con la versión defectuosa.

## Paso 4 · ¿Qué ha cambiado? Release markers y los logs de arranque (5 min)

- En el dashboard `PayFlow · SRE` (módulo 4), **Show release markers**: v2.4.1 aparece a las 13:58, justo donde salta el p99.
- **Search** `"maximumPoolSize"`: los pods v2.4.1 arrancaron con `maximumPoolSize=10`, los pods v2.4.0 con 50. La nota del cambio CHG-4117 decía "pool size 50 to 10".
- Abre una traza fallida, pestaña **Infrastructure**: CPU baja, el pod espera conexiones. Chart Explorer, métrica `hikaricp.connections.pending` por `service.version`: v2.4.1 encola decenas de hilos.

## Paso 5 · El segundo fuego (3 min)

**Search** `ServiceName:k8s-events SeverityText:WARN -EventName:Unhealthy`: presión de memoria en ip-10-0-3-17 a las 14:19, después el worker de fraud-scoring muerto por OOM a las 14:21:07. Chart Explorer, `k8s.pod.memory.working_set` con `k8s.node.name:ip-10-0-3-17`, agrupado por `k8s.pod.name`: la memoria sube con los reintentos de los clientes y luego cae a 0. Una consecuencia del incidente, no su causa.

## Paso 6 · Pídeselo a una IA (2 min)

Si los **Notebooks** están activados (módulo 8), abre un notebook nuevo y pregunta: *"¿Por qué falló POST /v1/payments entre las 13:58 y las 14:45 del 27 de noviembre de 2026?"* Mira cómo el agente consulta las fuentes, tile a tile, y compara su conclusión con la tuya.

---

## Parte 2 · La misma investigación en SQL (20 min)

- `01_mapa_y_patrones.sql`: el mapa de servicios y los patrones de eventos, calculados por vistas materializadas refrescables, antes y durante el incidente.
- `02_incidente_en_sql.sql`: diez preguntas, del aviso a la causa raíz, la traza en forma de árbol (CTE recursiva), el cambio activo en cada error, el segundo fuego y **el impacto de negocio**: pagos fallidos, euros, comercios.

La última consulta construye la cronología del postmortem con todas las señales a la vez.
