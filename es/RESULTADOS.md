# Resultados medidos · Workshop de observabilidad ClickHouse

Ejecución de referencia del 15 de octubre de 2026, desde cero (`./run_all.sh`, 8 min en total) en el servicio de prueba:
**ClickHouse Cloud 26.6, AWS eu-central-1, 3 réplicas de 64 GB (16 vCPU cada una)**, la configuración recomendada a los participantes. Las duraciones salen de `system.query_log` (tiempo de servidor). Los datos son simulados y deterministas: volúmenes, filas leídas y resultados son iguales para todos los participantes; las duraciones varían unas decenas por ciento de una ejecución a otra.
Las mismas cifras aparecen como comentarios (`Medido`) bajo cada instrucción de los ficheros SQL.

> Órdenes de magnitud para las slides
> - **Un día de una plataforma de pagos**: 1,38 M de peticiones, 14,6 M de spans, 8,1 M de líneas de log, 612 000 puntos de métricas, generados en SQL
> - **910 millones de líneas de log** escritas en 4 minutos (8 lotes de ~30 s, 114 M de líneas cada uno), **9,1 GB en disco, 11 bytes por línea** tras los merges
> - **Búsqueda de texto completo** de una palabra rara en 910 M de líneas: **0,46 s** con el índice de texto, 3,5 s sin él (311 000 filas leídas en lugar de 910 M)
> - **Una traza entre 910 M de líneas**: **18 ms** con un rango de tiempo, 2,7 s solo con el bloom filter
> - **Del aviso (page) a la causa raíz**: 10 consultas, cada una por debajo de medio segundo
> - **Tiempo medio de detección**: 2 minutos (despliegue a las 13:58, primer aviso a las 14:00)

---

## 00 · Primeros pasos
| Medida | Valor |
|---|---|
| 1 millón de líneas de log generadas, parseadas con una regex y agregadas | 364 ms |

## 01 · Fundamentos e inventario
| Medida | Valor |
|---|---|
| Inventario | 12 nodos, 9 servicios, 49 pods (payment: 3 generaciones de 6), 11 periodos de despliegue, 20 000 comercios |
| Todas las tablas del inventario | creadas y rellenadas en menos de 0,1 s cada una |

## 02 · Bronze
| Medida | Valor |
|---|---|
| Peticiones generadas para el día | 1,38 M (15/s de noche, 33/s durante la venta flash) |
| Registros brutos cargados, de 00:00 a 20:00 | 6 M de líneas de log de contenedor y 354 eventos de Kubernetes, en 4 lotes de 4,7 a 8,5 s |
| El día completo en bronze | 8,1 M de registros, 3,8 GB de JSON, **341 MB en disco (x11,5)** |
| Números de tarjeta en claro en bronze | 179 450 líneas, todas de un pod de card-network-adapter que se quedó en DEBUG |
| Errores en el texto bruto, de 14:00 a 15:00 | 18 883, frente a ~50 por hora el resto del día |

## 03 · Silver
| Medida | Valor |
|---|---|
| Backfill del pipeline de logs (2 lotes) | 2,1 M de líneas en 4,9 s, 3,9 M de líneas en 7,9 s |
| Flujo continuo, de 20:00 a 24:00, a través de 2 vistas materializadas | 2,1 M de registros brutos → 2,1 M de logs OpenTelemetry, 18,7 s entre generación y parsing |
| Logs con trace id | 95,3 % |
| Números de tarjeta enmascarados | 244 982 líneas, 0 en claro en silver |
| Spans escritos | 14,6 M en 4 lotes de 5,4 a 9,3 s (10,6 spans por traza) |
| Histogramas de latencia a partir de los spans (spanmetrics) | 23 350 puntos en 668 ms |
| Gauges de pods cada 15 s / HikariCP / reinicios | 426 240 / 103 680 / 53 280 puntos |
| Almacenamiento | otel_traces 662 MB (x8,2), otel_logs 342 MB (x9), métricas por debajo de 6 MB |

## 04 · Diccionarios
| Medida | Valor |
|---|---|
| Diccionario de rangos: cambio activo en un momento dado | 2 ms |
| Spans de error de payment atribuidos a CHG-4117 | 37 084 (972 más bajo CHG-4118: pods v2.4.1 que seguían en marcha durante la marcha atrás) |
| Ingresos por tier de comercio, 941 000 pagos: dictGet / JOIN | 302 ms / 65 ms (aquí el JOIN es más rápido: solo 20 000 comercios) |
| Memoria de los 5 diccionarios | 12 MB en total (comercios), los demás por debajo de 60 KB |

## 05 · Gold
| Medida | Valor |
|---|---|
| Backfill RED | 8,3 M de spans de servidor → 20 165 filas en 1,25 s |
| p99 de POST /v1/payments | 300 ms antes de las 13:58, 3,1 s durante, normal de nuevo a las 14:44 |
| Tasa de error de POST /v1/payments | 0,15 % antes, hasta el 31,8 % a las 14:15 |
| Tasa de consumo (burn rate), ventana de 1 h, en el pico | más de 400 veces la tasa permitida |
| Alertas | 11 eventos: primer aviso a las 14:00 (2 minutos después del despliegue), presión de memoria en el nodo 14:19, reinicio por OOM 14:22, resuelto 14:47 |
| Mapa de servicios | 16 aristas reconstruidas a partir de las trazas; payment → postgres p95 7,7 ms antes, 3 033 ms durante |
| Patrones de logs | 8 308 patrones a partir de 6,7 M de líneas; el principal patrón nuevo del incidente es el timeout de HikariPool (18 011 veces, 0 antes) |

## 06 · Rendimiento (910 millones de líneas de log)
| Medida | Valor |
|---|---|
| Escritura, 8 lotes de 114 M de líneas | de 27,9 a 31,2 s por lote, unos 4 min en total, ~10 GB de memoria por lote |
| Almacenamiento tras los merges | 108 GB en bruto → **9,1 GB, x11,8, 11 bytes por línea** |

| Consulta | Sin | Con | Filas leídas sin → con |
|---|---|---|---|
| Palabra rara, índice de texto | 3,45 s | **461 ms** | 910 M → 311 296 |
| Palabra frecuente (HikariPool), índice de texto | 2,97 s | **333 ms** | 910 M → 9,5 M |
| Un trace id, solo bloom filter / con rango de tiempo | 2,73 s | **18 ms** | 1,8 M → 835 584 |
| Errores por minuto, proyección | 890 ms | **115 ms** | 910 M → 593 063 |
| Traza completa vía la tabla de búsqueda por trace id | | **28 ms** | 188 416 |
| Agregación pesada con regex, caché de consultas | 6,89 s | **1 ms** | 910 M → 0 |
| Mismo filtro otra vez, query condition cache | 1,71 s | **13 ms** | 593 M → 540 672 |
| Scan completo, 3 réplicas (parallel replicas) | 6,8 s | **3,77 s** (x1,8) | 910 M (repartidas entre 3) |

Medido con el servicio en reposo. Si se lanzan justo después de los 8 lotes, con los merges todavía en marcha, las mismas consultas son 2 a 3 veces más lentas y las parallel replicas aportan poco: deja al servicio unos minutos tras el paso 2 del módulo 6.

## 07 · Investigación y operación
| Medida | Valor |
|---|---|
| Las 10 preguntas de la investigación | de 3 a 414 ms cada una |
| Causa raíz | `INSERT payflow.payments`, timeout de HikariPool, solo en los pods v2.4.1 (26,5 % de errores) frente a 0 en los pods v2.4.0 a la misma hora |
| HikariCP durante el incidente | pool de 10, 10 activas, de 45 a 49 hilos esperando (v2.4.0: pool de 50, ~4 activas, 0 en espera) |
| Impacto de negocio, de 13:58 a 14:50 | **15 349 pagos fallidos, 1,58 M EUR, 7 999 comercios** |
| Cronología | despliegue 13:58, primer error 13:58:03, aviso 14:00, OOM 14:21:07, marcha atrás 14:42, último error 14:43:39, resuelto 14:47 |
| Reproceso del día desde bronze, después REPLACE PARTITION | 8,1 M de líneas reconstruidas en 15,6 s, recuentos idénticos por severidad, intercambio atómico |
| Borrado RGPD de un comercio (DELETE ligero) | 1 017 líneas, de 3 a 38 s según la carga |

## 08 · ClickStack, dashboards, API, agentes
| Medida | Valor |
|---|---|
| Tiles del dashboard sobre gold | unos milisegundos, unos miles de filas leídas |
| API de estado (vista parametrizada sobre slo_burn) | 11 filas para 10 minutos, unos ms |
| ClickStack | lee `payflow_otel` directamente, fuentes deducidas del esquema OpenTelemetry |
