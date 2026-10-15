# Resultados medidos · Taller de observabilidad ClickHouse

Ejecución de referencia del 15 de octubre de 2026, desde cero (`./run_all.sh`, unos 7 min en total) en el servicio de prueba: **ClickHouse Cloud 26.6, AWS eu-central-1, 3 réplicas de 64 GB (16 vCPU cada una)**, la configuración recomendada a los participantes. Las duraciones salen de `system.query_log` (tiempo del servidor). Los datos son simulados y deterministas: volúmenes, filas leídas y resultados son los mismos para todos los participantes; las duraciones varían unas decenas de por ciento de una ejecución a otra.
Las mismas cifras aparecen como comentarios (`Medido`) bajo cada instrucción de los archivos SQL.

> Órdenes de magnitud para las diapositivas
> - **Un día de una plataforma de pagos**, generado en SQL: 1,38 M de peticiones, 21,5 M de spans, 7,8 M de líneas de log, 612 000 puntos de métricas
> - **La pasarela en SQL**: 8,1 M de registros de agentes parseados, enriquecidos y enmascarados por vistas materializadas en 6 instrucciones de 12 a 16 s; **0 líneas en bruto almacenadas**, 0 números de tarjeta en claro, 4 % de ruido filtrado
> - **Detección**: primer aviso a las 14:00, **2 minutos** después del despliegue defectuoso; resuelto a las 14:47
> - **En directo**: un interruptor reproduce el incidente en el flujo en directo y la alerta de burn rate salta **en menos de 1 minuto**
> - **875 millones de líneas de log** escritas en 8 instrucciones de ~27 s; una palabra rara encontrada en **1 s** en lugar de 3,8 s, una traza en **31 ms** en lugar de 2,4 s
> - **Impacto de negocio**: 15 349 pagos fallidos, **1,58 M EUR**, 7999 comercios

---

## 01 · Modelo de datos
| Medida | Valor |
|---|---|
| Catálogo de servicios | 12 nodos, 9 servicios, 49 pods (payment: 3 generaciones de 6), 11 periodos de despliegue, 20 000 comercios, 5 diccionarios |
| Tablas OpenTelemetry | el DDL exacto del exportador: 5 tablas de señales, 7 índices de texto en otel_logs, más la tabla de búsqueda por traza y su vista |

## 02 · Recolección
| Medida | Valor |
|---|---|
| Peticiones del día | 1,38 M (15/s de noche, 33/s durante la venta flash) |
| Pasarela: 6 inserciones en la tabla Null | de 11,6 a 16,1 s cada una; 8,13 M de registros recibidos, 319 680 health checks descartados (3,9 %, 86 MB) |
| Almacenado por la tabla de aterrizaje | 0 filas |
| Enriquecimiento (k8sattributes desde el catálogo) | versión, equipo, nodo y zona en cada log de contenedor |
| Enmascarado PCI | 244 982 números de tarjeta enmascarados, 0 en claro |
| Spans (OTLP), 4 lotes | de 7,9 a 14,2 s cada uno, 21,5 M de spans (15,6 por traza, un span Client y uno Server por llamada) |
| Métricas | 426 240 puntos de pods (CPU, memoria), 103 680 puntos HikariCP, 53 280 puntos del contador de reinicios |
| Flujo en directo, tráfico tranquilo / caos | unos 9000 spans y 3000 líneas de log por minuto / 28 000 spans con 3000 errores por minuto |
| Almacenamiento del día | otel_traces 953 MB (x8,7), otel_logs 351 MB (x10,9), métricas por debajo de 6 MB |

## 03 · Búsqueda y correlación
| Medida | Valor |
|---|---|
| Búsqueda de texto completo en 10 minutos (índice de texto) | 24 ms, 172 032 filas leídas |
| Filtro por atributo a través del índice de texto en `ResourceAttributeItems` | 21 ms |
| Log → traza → métricas del pod | 3 consultas, menos de 0,6 s en total |
| Escenario A, desde el ticket de un comercio (log) | 4 consultas, de 15 a 206 ms: el id de comercio lleva a `maximumPoolSize=10` en un pod v2.4.1 |
| Escenario B, desde una alerta de métrica (pool pending por encima de 20) | salta a las 14:03 en los 6 pods; 5 consultas de 12 a 37 ms llevan al rollout CHG-4117 |
| Escenario C, desde una traza (mensaje de error nuevo) | 290 spans "connection refused" a partir de las 14:21:07; 5 consultas de 33 a 131 ms llevan al OOM kill, causado por los reintentos (tráfico de fraud-scoring x2,2) |

## 04 · Dashboards (agregados RED)
| Medida | Valor |
|---|---|
| Backfill RED | 8,3 M de spans de servidor → 20 160 filas en 1,27 s |
| La misma curva desde el agregado / desde los spans | 8192 / 90 112 filas leídas |
| Histograma spanmetrics con exemplars | 23 345 puntos en 751 ms |
| p99 de POST /v1/payments | 300 ms antes de las 13:58, 3,1 s durante, normal de nuevo a las 14:44 |

## 05 · SLO y alertas
| Medida | Valor |
|---|---|
| Burn rate, ventana de 1 h, en el pico | más de 400 veces la tasa permitida |
| Alertas del día | 11 eventos: primer aviso a las 14:00, presión de memoria en el nodo 14:19, reinicio por OOM 14:22, resuelto 14:47 |
| Interruptor de caos en el flujo en directo | burn rate de 450x en el primer minuto, aviso fast-burn en menos de 1 minuto, alerta de p99 a los 3 minutos |

## 06 · Investigación
| Medida | Valor |
|---|---|
| Mapa de servicios | 16 aristas a partir de las trazas; payment → postgres p95 de 7,7 ms antes, 3033 ms durante |
| Patrones de logs | 31 patrones para 6,4 M de líneas; el nuevo más frecuente es el timeout de HikariPool (18 011 veces, 0 antes) |
| Las 10 preguntas | de 3 a 379 ms cada una |
| Causa raíz | `INSERT payflow.payments`, timeout de HikariPool, solo en los pods v2.4.1 (CHG-4117) |
| Impacto de negocio, de 13:58 a 14:50 | **15 349 pagos fallidos, 1 576 893 EUR, 7999 comercios** |

## 07 · Escala y coste (875 millones de líneas de log)
| Medida | Valor |
|---|---|
| Escritura, 8 lotes de 109 M de líneas | de 26,4 a 29,5 s cada uno, unos 3,5 min en total, ~10,5 GB de memoria por lote |
| Almacenamiento | 106 GB en bruto → 13 GB justo después de las inserciones (x8,2, 16 bytes por línea); los merges en segundo plano siguen comprimiendo |

| Consulta (servicio en reposo) | Sin | Con | Filas leídas |
|---|---|---|---|
| Palabra rara, índice de texto | 3,81 s | **1,05 s** | 875 M → 606 208 |
| Palabra frecuente (HikariPool), índice de texto | 2,41 s | **678 ms** | 875 M → 10,3 M |
| Un trace id, bloom filter solo / con un rango de tiempo | 2,38 s | **31 ms** | 1,9 M → 1 M |
| Errores por minuto, proyección | 549 ms | **341 ms** | 875 M → 578 256 |
| Traza completa vía la tabla de búsqueda | | **526 ms** | 245 760 |
| Agregación pesada con regex, caché de consultas | 5,13 s | **1 ms** | 875 M → 0 |
| Mismo filtro otra vez, query condition cache | 2,37 s | **19 ms** | 875 M → 1,1 M |
| Escaneo completo, 3 réplicas | 5,12 s | **2,11 s** (x2,4) | 875 M |

| Palanca | Valor |
|---|---|
| Agregado (rollup) con la convención de ClickStack | 21,5 M de spans → 53 926 filas (399 spans por fila), construido en 2,7 s |
| Muestreo para la retención (errores y trazas de más de 1 s) | 602 753 spans conservados, 2,8 % del día, todas las trazas del incidente |
| Muestreo en cabeza (head sampling) al 10 % | la tasa de errores se conserva, las trazas raras no |
| Regla práctica de dimensionamiento | 12 GB de telemetría en bruto al día = 0,01 vCPU de ingesta |

## 08 · IA y gobernanza
| Medida | Valor |
|---|---|
| Borrado RGPD de un comercio (DELETE ligero) | 1017 líneas, en torno a 1 s |
| Row policies por equipo | 2 políticas, aplicadas por igual a ClickStack, la consola SQL y MCP |
| API de estado (vista parametrizada sobre slo_burn) | 11 filas para 10 minutos, unos pocos ms |
