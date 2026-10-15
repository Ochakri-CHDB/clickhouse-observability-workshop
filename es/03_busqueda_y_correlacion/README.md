# Módulo 3 · Búsqueda y correlación en ClickStack

Los datos ya están en las tablas OpenTelemetry: el día de Black Friday, y un flujo en directo que añade un minuto de tráfico cada minuto. Ahora los miras como lo hace un ingeniero de guardia, en **ClickStack**, la interfaz de observabilidad de ClickHouse (HyperDX), que funciona dentro de ClickHouse Cloud. Después, tres escenarios de investigación van de una señal a las demás, y dos ficheros SQL muestran lo que ClickStack ejecuta por ti.

Duración: 45 min.

| Fichero | Contenido |
|---|---|
| `01_bajo_el_capo.sql` | la búsqueda en SQL, los índices de texto y EXPLAIN, de log a traza y a métricas del pod, live tail |
| `02_escenarios_de_correlacion.sql` | tres investigaciones: desde un log, desde una alerta de métrica, desde una traza |

> ClickStack evoluciona deprisa: una etiqueta puede cambiar de sitio. El principio no cambia. En este módulo importan dos rangos de tiempo: **el incidente**, un rango absoluto de `2026-11-27 13:45` a `2026-11-27 15:00` (UTC), y **el flujo en directo**, `Last 15 minutes`.

---

## Paso 1 · Abrir ClickStack y comprobar las fuentes (5 min)

1. En la consola Cloud, abre tu servicio y luego **ClickStack** en el menú de la izquierda.
2. ClickStack busca tablas OpenTelemetry. Las nuestras están en la base de datos `payflow_otel`, no en `default`: ve a **Team Settings**, luego **Sources**, y crea (o edita) una fuente por señal.

| Ajuste | Logs | Trazas | Métricas |
|---|---|---|---|
| Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
| Source Data Type | Log | Trace | Metrics |
| Server Connection | `Default` | `Default` | `Default` |
| Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
| Table | `otel_logs` | `otel_traces` | Gauge `otel_metrics_gauge`, Histogram `otel_metrics_histogram`, Sum `otel_metrics_sum` |

Como las tablas siguen exactamente el esquema del exportador, ClickStack rellena solo todas las expresiones de columna (Timestamp, ServiceName, SeverityText, Body, TraceId, SpanId, Duration...).

3. Enlaza las fuentes, para que un clic salte de una señal a otra (**correlated sources**, fuentes correlacionadas):
   - en **PayFlow logs**: *Correlated Trace Source* `PayFlow traces`, *Correlated Metric Source* `PayFlow metrics`;
   - en **PayFlow traces**: *Correlated Log Source* `PayFlow logs`, *Correlated Metric Source* `PayFlow metrics`.
4. Opcional, en **PayFlow traces**: añade un **Highlighted Trace Attribute** `SpanAttributes['merchant.id']`. Aparece encima de cada cascada (waterfall) de traza.

---

## Paso 2 · Buscar (10 min)

Abre **Search**, fuente **PayFlow logs**, rango **el incidente**. La barra de búsqueda habla Lucene por defecto; un interruptor la pasa a SQL (cualquier cláusula `WHERE`).

| Escribe | Qué ves |
|---|---|
| `SeverityText:ERROR` | el histograma de errores se dispara a las 13:58 y cae a las 14:44 |
| `ServiceName:payment SeverityText:ERROR` | un solo mensaje: el timeout de HikariPool |
| `"maximumPoolSize"` | la línea de arranque de cada pod de payment: 10 en v2.4.1, 50 antes y después |
| `ServiceName:k8s-events -EventName:Unhealthy` | el rollout, la presión de memoria en ip-10-0-3-17, el OOM kill |
| `"pan="` | números de tarjeta, todos enmascarados por la pasarela (gateway) del módulo 2 |
| Modo SQL: `ResourceAttributes['service.version'] = 'v2.4.1' AND SeverityNumber >= 17` | solo los errores de la versión defectuosa |

- Haz clic en un campo del panel izquierdo (`service.version`, `k8s.pod.name`, `service.team`) para filtrar por él. `service.team` y `cloud.availability_zone` los añadió la pasarela (módulo 2).
- Arrastra sobre el histograma para hacer zoom en un rango de tiempo.
- Guarda con **Save** la búsqueda `ServiceName:payment SeverityText:ERROR` como `Payment errors`, con la etiqueta `payments`. El módulo 5 le pone una alerta.

### Live tail
Cambia el rango a `Last 15 minutes` y activa **Live tail**: el flujo del módulo 2 va desfilando, un minuto de tráfico por minuto.

---

## Paso 3 · De una línea de log a su traza, y luego a su pod (10 min)

1. Rango **el incidente**, busca `ServiceName:checkout SeverityText:ERROR` y abre una línea.
2. El panel lateral muestra la línea y sus atributos. Abre la pestaña **Trace**: la cascada de la petición, a través de `TraceId`.
   - 3 segundos dentro de `INSERT payflow.payments`, la excepción de HikariPool como evento del span;
   - la red de tarjetas, el ledger y la notificación nunca llegaron a ejecutarse.
3. Abre la pestaña **Infrastructure**: la CPU y la memoria del pod que sirvió la petición, desde la fuente de métricas, cruzadas por `k8s.pod.name`. El pod no está ocupado: espera.
4. En una traza, el pequeño **service map** encima de la cascada muestra el recorrido de esa petición concreta.

---

## Paso 4 · Tres entradas al incidente (15 min)

Una investigación empieza por lo primero que te llega. Los tres escenarios de abajo llegan al mismo incidente desde tres señales; `02_escenarios_de_correlacion.sql` ejecuta cada uno en SQL, paso a paso, con la respuesta esperada en cada paso. Rango **el incidente** para los tres.

| | Empieza por | Pasa por | Termina en |
|---|---|---|---|
| A | un **log**: el ticket de un comercio | traza, métricas del pod, log de arranque | `maximumPoolSize=10` en un pod v2.4.1 |
| B | una **alerta de métrica**: el pool se satura | métrica por versión, trazas del pod, sus logs, eventos de Kubernetes | el rollout CHG-4117 |
| C | una **traza**: un mensaje de error nuevo | logs del pod, memoria y ritmo de peticiones, eventos de Kubernetes | el OOM kill en ip-10-0-3-17, consecuencia del primer bug |

### Escenario A · Desde un log
14:12, un ticket: "comercio m_16523, un pago falló justo después de las 14:09".
1. **Search**, fuente **PayFlow logs**: `LogAttributes.merchant_id:m_16523 SeverityText:ERROR`. Una línea de checkout: "payment service returned 503". checkout solo transmite el error.
2. Abre la línea, pestaña **Trace**: el span rojo al fondo de la cascada es `INSERT payflow.payments` en payment, 3 segundos esperando una conexión. Haz clic en él: sus atributos de recurso dan el pod de payment.
3. **Chart Explorer**, fuente **PayFlow metrics**, gauge `hikaricp.connections.pending` y luego `hikaricp.connections.max`, filtro `k8s.pod.name` = ese pod: decenas de peticiones esperando, un pool de 10.
4. Vuelta a **Search**, logs: `ResourceAttributes.k8s.pod.name:<el pod> "maximumPoolSize"`. El pod escribió `maximumPoolSize=10` al arrancar, versión v2.4.1.

### Escenario B · Desde una alerta de métrica
1. **Chart Explorer**, fuente **PayFlow metrics**, gauge `hikaricp.connections.pending`, agregación **Max**, agrupar por `ResourceAttributes['k8s.pod.name']`, granularidad 1 minuto. Los 6 pods de payment superan 20 a la vez a las 14:03: es lo que evalúa una alerta de gráfico con el umbral "above 20" (el módulo 5 la crea).
2. Cambia la agrupación a `ResourceAttributes['service.version']` y representa `hikaricp.connections.max`: 50 en v2.4.0, 10 en v2.4.1. Activa **Show release markers**.
3. **Search**, fuente **PayFlow traces**, rango de 14:03 a 14:04: `ResourceAttributes.k8s.pod.name:<el peor pod> SpanKind:Server StatusCode:Error`. Abre una traza: los logs de la petición aparecen con sus spans (payment agota el tiempo, checkout informa de un 503, api-gateway lo devuelve).
4. **Search**, logs: `ServiceName:k8s-events EventName:ScalingReplicaSet`. "rolling update CHG-4117" a las 13:58: de la alerta al cambio en cuatro pantallas.

### Escenario C · Desde una traza
14:25. El problema del pool está entendido y se prepara una marcha atrás (rollback), pero una traza muestra otro error.
1. **Search**, fuente **PayFlow traces**, rango de 14:15 a 14:25: `StatusCode:Error SpanKind:Server -StatusMessage:"HikariPool"`. Agrupa por `StatusMessage` (**Analysis Mode**, o una tabla en **Chart Explorer**): "connect: connection refused" en `fraud.ScoreTransaction`, solo a partir de las 14:21:07.
2. Abre una de esas trazas: checkout llama a fraud-scoring, que rechaza la conexión. El span da el pod y el nodo (`ip-10-0-3-17`). Pestaña **Infrastructure**: la memoria del pod sube hasta 2,2 GB y luego cae.
3. **Search**, logs: `ServiceName:fraud-scoring -SeverityText:INFO -"score="`. La cola crece, la caché de features se acerca a su límite de 2 GiB, un worker timeout FATAL.
4. **Search**, logs: `ServiceName:k8s-events "ip-10-0-3-17"`: presión de memoria a las 14:19, el OOM kill a las 14:21, el nodo de vuelta a las 14:23. Representa el ritmo de peticiones de fraud-scoring: se duplicó desde las 13:55, porque checkout puntúa de nuevo cada reintento de un pago fallido. No es un segundo bug: es el mismo. El rollback de las 14:42 arregla ambos.

---

## Paso 5 · Por debajo (10 min)

Ejecuta `01_bajo_el_capo.sql` en la consola SQL:
- la misma búsqueda en SQL, y `EXPLAIN indexes = 1` para ver cómo el índice de texto descarta los gránulos que no contienen la palabra;
- un filtro sobre un atributo resuelto por el índice de texto de `ResourceAttributeItems`, sin leer el map;
- la correlación log → traza → métricas, en tres consultas;
- el live tail como un simple `ORDER BY Timestamp DESC`.

Luego `02_escenarios_de_correlacion.sql`: los tres escenarios, cada uno en 4 o 5 consultas. Las claves son siempre las mismas: `TraceId` entre logs y trazas, los atributos de recurso (`k8s.pod.name`, `k8s.node.name`, `service.version`) hacia las métricas, y un rango de tiempo acotado (la tabla de búsqueda de trazas da los límites de una traza).

Checkpoint: `OK` en todas partes, en los dos ficheros.
