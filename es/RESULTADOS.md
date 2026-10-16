# Resultados medidos · Taller de observabilidad ClickHouse

Ejecución de referencia del 16 de octubre de 2026 (así que Black Friday fue el viernes 9 de octubre), desde cero (`./run_all.sh`, unos 14 min en total) en el servicio de prueba: **ClickHouse Cloud 26.6, AWS eu-central-1, 3 réplicas de 64 GB (16 vCPU cada una)**, la configuración recomendada a los asistentes. Las duraciones salen de `system.query_log` (tiempo de servidor). Los datos se generan para el día en que haces el taller: el incidente, los volúmenes y los resultados son los mismos para cada asistente (el azar depende del tiempo relativo a Black Friday); solo los pocos días entre Black Friday y hoy cambian con el día de la semana, y las duraciones varían unas decenas por ciento de una ejecución a otra.
Las mismas cifras aparecen como comentarios (`Medido`) bajo cada instrucción de los archivos SQL.

> Órdenes de magnitud para las diapositivas
> - **Un mes de una plataforma de pagos**, generado en SQL: 76,7 M de spans, 27,8 M de líneas de log, 37,8 M de puntos de métricas, cargado en unos 8 minutos, cada instrucción por debajo de 35 s
> - **Black Friday** dentro: 1,38 M de peticiones, 21,5 M de spans, 7,8 M de líneas de log, 12 veces un día ordinario
> - **La pasarela en SQL**: 27,5 M de registros de agente parseados, enriquecidos y enmascarados por vistas materializadas; **0 líneas en bruto almacenadas**, 766 724 números de tarjeta enmascarados, un 11,6 % de ruido filtrado
> - **Detección**: primer aviso a las 14:00, **2 minutos** después del despliegue defectuoso; resuelto a las 14:47; 11 alertas en el mes, todas en Black Friday
> - **875 millones de líneas de log** escritas en 8 instrucciones de ~30 s; una palabra rara encontrada en **0,8 s** en vez de 4,3 s, una traza en **22 ms** en vez de 3 s
> - **Impacto de negocio**: 15 349 pagos fallidos, **1,58 M EUR**, 7999 comercios

---

## 01 · Modelo de datos
| Medida | Valor |
|---|---|
| Calendario | Black Friday = el último viernes antes de hoy; historial de 30 días que termina con él; 3 funciones (`pf_black_friday`, `pf_day`, `pf_at`) que conservan la poda por clave primaria y por partición |
| Catálogo de servicios | 12 nodos, 9 servicios, 16 cambios en el mes (5 versiones semanales, la versión defectuosa, el rollback), 74 pods (payment: 4 generaciones de 6), 20 000 comercios, 5 diccionarios |
| Tablas OpenTelemetry | el DDL exacto del exportador: 5 tablas de señales, 7 índices de texto en otel_logs, más la tabla de búsqueda por traza y su vista |

## 02 · Recolección
| Medida | Valor |
|---|---|
| Peticiones | unas 107 000 por día ordinario, 80 000 el fin de semana, 1,38 M en Black Friday (33/s durante la venta flash) |
| Pasarela: 10 inserts en la tabla Null | de 14 a 22 s cada uno; 27,5 M de registros recibidos, 3,2 M de health checks descartados (11,6 %, 859 MB) |
| Almacenado por la tabla de aterrizaje | 0 filas |
| Enriquecimiento (k8sattributes desde el catálogo) | versión, equipo, nodo y zona en cada log de contenedor |
| Enmascarado PCI | 766 724 números de tarjeta enmascarados en el mes, 0 en claro |
| Spans (OTLP), 6 lotes | de 11 a 33 s cada uno, 67 M de spans para el historial (15,7 por traza, un span Client y uno Server por llamada) |
| Métricas, nombres de kubeletstats y k8s_cluster | 28,4 M de puntos gauge en el mes, cada 30 s (pods, nodos, namespaces, HikariCP, lag de Kafka), en 3 lotes de 15 s; 2,1 M de contadores de uptime |
| Puesta al día, de Black Friday a ahora (un viernes: 6 días y la mañana en curso) | 5 instrucciones de 2 a 22 s |
| Flujo en directo | el simulador cada minuto: 650 spans y 250 líneas de log por minuto por la mañana, unos 2200 spans en el pico de la tarde; rellena solo el hueco tras un periodo de reposo |
| Interruptor de caos (medido el 16 de octubre, de 10:00 a 10:04) | reproduce los minutos del incidente, a una cuarta parte de su tráfico: de 6800 a 7200 spans y 2500 líneas de log por minuto (120 timeouts de HikariPool, 20 por pod), el 26 % de los pagos fallando, burn rate de 500 a 600; la regla SQL de fast burn salta en el primer minuto, la del p99 en el tercero |

## 03 · Búsqueda y correlación
| Medida | Valor |
|---|---|
| Búsqueda de texto completo en 10 minutos (índice de texto) | 172 033 filas leídas |
| Filtro de atributo mediante el índice de texto de `ResourceAttributeItems` | 163 841 filas leídas |
| Escenario A, desde el ticket de un comercio (log) | 4 consultas: el id del comercio lleva a `maximumPoolSize=10` en un pod v2.4.1 |
| Escenario B, desde una alerta de métrica (pool pending por encima de 20) | salta a las 14:03 en los 6 pods; 5 consultas llevan al rollout CHG-4117 |
| Escenario C, desde una traza (mensaje de error nuevo) | 290 spans "connection refused" desde las 14:21:07; 5 consultas llevan al OOM kill, causado por los reintentos (tráfico de fraud-scoring x2,2) |

## 04 · Dashboards (agregados RED)
| Medida | Valor |
|---|---|
| Backfill RED, todo el mes | 76,6 M de spans → 720 523 filas en 11,8 s |
| La misma curva desde el agregado / desde los spans | 8193 / 81 921 filas leídas |
| Histograma spanmetrics con exemplars, el mes | 735 032 puntos en 7,6 s |
| p99 de POST /v1/payments | 300 ms antes de las 13:58, 3,1 s durante, normal de nuevo a las 14:44 |

## 05 · SLO y alertas
| Medida | Valor |
|---|---|
| Burn rate, ventana de 1 h, en el pico | 19 veces el ritmo permitido en POST /v1/payments |
| Alertas del mes | 11 eventos, todos en Black Friday: primer aviso a las 14:00, presión de memoria del nodo 14:19, reinicio por OOM 14:22, resuelto 14:47 |
| Regla del p99 | exige 150 llamadas por minuto: en un día ordinario un p99 es solo la llamada más lenta |

## 06 · Investigación
| Medida | Valor |
|---|---|
| Mapa de servicios | 16 aristas a partir de las trazas; payment → postgres p95 de 7,7 ms antes, 3033 ms durante |
| Patrones de logs | 31 patrones para 6,4 M de líneas; el nuevo más frecuente es el timeout de HikariPool (18 011 veces, 0 antes) |
| Causa raíz | `INSERT payflow.payments`, timeout de HikariPool, solo en los pods v2.4.1 (CHG-4117) |
| Impacto de negocio, de 13:58 a 14:50 | **15 349 pagos fallidos, 1 576 893 EUR, 7999 comercios** |

## 07 · Escala y coste (875 millones de líneas de log)
| Medida | Valor |
|---|---|
| Escritura, 8 lotes de 109 M de líneas | de 28 a 31 s cada uno, unos 4 min en total, ~10 GB de memoria por lote |
| Almacenamiento | 106 GB en bruto → 16,5 GB justo después de los inserts (x6,4, 20 bytes por línea); los merges en segundo plano siguen comprimiendo |

| Consulta (servicio en reposo) | Sin | Con | Filas leídas |
|---|---|---|---|
| Palabra rara, índice de texto | 4,27 s | **774 ms** | 875 M → 286 720 |
| Palabra frecuente (HikariPool), índice de texto | 3,09 s | **367 ms** | 875 M → 9,7 M |
| Un trace id, solo bloom filter / con un rango de tiempo | 2,96 s | **22 ms** | 1,2 M → 368 641 |
| Errores por minuto, proyección | 1,08 s | **712 ms** | 875 M → 465 928 |
| Traza completa mediante la tabla de búsqueda | | **454 ms** | 245 761 |
| Agregación pesada con regex, query cache | 6,99 s | **1 ms** | 875 M → 0 |
| El mismo filtro otra vez, query condition cache | 2,94 s | **14 ms** | 875 M → 745 472 |
| Escaneo completo, 3 réplicas | 7,03 s | **3,56 s** (x2) | 875 M |

| Palanca | Valor |
|---|---|
| Agregado con la convención de ClickStack, el mes | 76,6 M de spans → 1,7 M de filas en 8,7 s; solo Black Friday: 21,5 M de spans → 53 926 filas (399 spans por fila) |
| Muestreo de retención (errores y trazas de más de 1 s) | 602 753 spans conservados, el 2,8 % de Black Friday, todas las trazas del incidente |
| Muestreo en cabeza (head sampling) al 10 % | la tasa de errores se conserva, las trazas raras no |

## 08 · IA y gobernanza
| Medida | Valor |
|---|---|
| Borrado RGPD de un comercio en el mes (DELETE ligero) | 3529 líneas, 23 s |
| Row policies por equipo | 2 políticas, aplicadas por igual a ClickStack, la consola SQL y MCP |
| Auto-observabilidad de la ejecución | 316 inserts (p50 1,2 s, máx. 33 s), 186 selects (p50 118 ms) |
