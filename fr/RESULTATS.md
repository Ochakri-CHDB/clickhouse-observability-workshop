# Résultats mesurés · Workshop observabilité ClickHouse

Run de référence du 15 octobre 2026, depuis zéro (`./run_all.sh`, 8 min au total) sur le service de test :
**ClickHouse Cloud 26.6, AWS eu-central-1, 3 répliques de 64 Go (16 vCPU chacune)**, la configuration recommandée aux participants. Les durées viennent de `system.query_log` (temps serveur). Les données sont simulées et déterministes : volumes, lignes lues et résultats sont les mêmes pour chaque participant ; les durées varient de quelques dizaines de pourcents d'un run à l'autre.
Les mêmes chiffres figurent en commentaire (`Mesuré`) sous chaque instruction des fichiers SQL.

> Ordres de grandeur pour les slides
> - **Une journée d'une plateforme de paiement** : 1,38 M de requêtes, 14,6 M de spans, 8,1 M de lignes de log, 612 000 points de métriques, générés en SQL
> - **910 millions de lignes de log** écrites en 4 minutes (8 lots d'environ 30 s, 114 M de lignes chacun), **9,1 Go sur disque, 11 octets par ligne** après les merges
> - **Recherche plein texte** d'un mot rare dans 910 M de lignes : **0,46 s** avec l'index texte, 3,5 s sans (311 000 lignes lues au lieu de 910 M)
> - **Une trace parmi 910 M de lignes** : **18 ms** avec une plage horaire, 2,7 s avec le bloom filter seul
> - **De l'alerte à la cause racine** : 10 requêtes, chacune sous la demi-seconde
> - **Temps moyen de détection** : 2 minutes (déploiement à 13h58, première page à 14h00)

---

## 00 · Premiers pas
| Mesure | Valeur |
|---|---|
| 1 million de lignes de log générées, parsées avec une regex et agrégées | 364 ms |

## 01 · Fondamentaux et inventaire
| Mesure | Valeur |
|---|---|
| Inventaire | 12 nœuds, 9 services, 49 pods (payment : 3 générations de 6), 11 périodes de déploiement, 20 000 marchands |
| Chaque table de l'inventaire | créée et remplie en moins de 0,1 s chacune |

## 02 · Bronze
| Mesure | Valeur |
|---|---|
| Requêtes générées pour la journée | 1,38 M (15/s la nuit, 33/s pendant la vente flash) |
| Enregistrements bruts chargés, de 00h00 à 20h00 | 6 M de lignes de log de conteneurs et 354 événements Kubernetes, en 4 lots de 4,7 à 8,5 s |
| Journée entière en bronze | 8,1 M d'enregistrements, 3,8 Go de JSON, **341 Mo sur disque (x11,5)** |
| Numéros de carte en clair dans bronze | 179 450 lignes, toutes issues d'un pod card-network-adapter resté en DEBUG |
| Erreurs dans le texte brut, de 14h00 à 15h00 | 18 883, contre ~50 par heure le reste de la journée |

## 03 · Silver
| Mesure | Valeur |
|---|---|
| Backfill du pipeline de logs (2 lots) | 2,1 M de lignes en 4,9 s, 3,9 M de lignes en 7,9 s |
| Flux continu, de 20h00 à 24h00, via 2 vues matérialisées | 2,1 M d'enregistrements bruts → 2,1 M de logs OpenTelemetry, 18,7 s pour la génération et le parsing |
| Logs avec un trace id | 95,3 % |
| Numéros de carte masqués | 244 982 lignes, 0 en clair dans silver |
| Spans écrits | 14,6 M en 4 lots de 5,4 à 9,3 s (10,6 spans par trace) |
| Histogrammes de latence tirés des spans (spanmetrics) | 23 350 points en 668 ms |
| Gauges des pods toutes les 15 s / HikariCP / redémarrages | 426 240 / 103 680 / 53 280 points |
| Stockage | otel_traces 662 Mo (x8,2), otel_logs 342 Mo (x9), métriques sous 6 Mo |

## 04 · Dictionnaires
| Mesure | Valeur |
|---|---|
| Dictionnaire de plages : changement en production à un instant donné | 2 ms |
| Spans d'erreur de payment attribués à CHG-4117 | 37 084 (972 de plus sous CHG-4118 : pods v2.4.1 encore actifs pendant le retour arrière) |
| Chiffre d'affaires par niveau de marchand, 941 000 paiements : dictGet / JOIN | 302 ms / 65 ms (le JOIN est plus rapide ici : 20 000 marchands seulement) |
| Mémoire des 5 dictionnaires | 12 Mo au total (marchands), les autres sous 60 Ko |

## 05 · Gold
| Mesure | Valeur |
|---|---|
| Backfill RED | 8,3 M de spans serveur → 20 165 lignes en 1,25 s |
| p99 de POST /v1/payments | 300 ms avant 13h58, 3,1 s pendant, revenu à la normale à 14h44 |
| Taux d'erreur de POST /v1/payments | 0,15 % avant, jusqu'à 31,8 % à 14h15 |
| Taux de consommation (burn rate), fenêtre de 1 h, au pic | plus de 400 fois le rythme permis |
| Alertes | 11 événements : première page à 14h00 (2 minutes après le déploiement), pression mémoire sur le nœud 14h19, redémarrage OOM 14h22, résolu 14h47 |
| Service map | 16 arcs reconstruits depuis les traces ; payment → postgres p95 7,7 ms avant, 3 033 ms pendant |
| Patterns de logs | 8 308 patterns sur 6,7 M de lignes ; le premier nouveau pattern de l'incident est le timeout HikariPool (18 011 fois, 0 avant) |

## 06 · Performance (910 millions de lignes de log)
| Mesure | Valeur |
|---|---|
| Écriture, 8 lots de 114 M de lignes | 27,9 à 31,2 s par lot, environ 4 min au total, ~10 Go de mémoire par lot |
| Stockage après les merges | 108 Go bruts → **9,1 Go, x11,8, 11 octets par ligne** |

| Requête | Sans | Avec | Lignes lues sans → avec |
|---|---|---|---|
| Mot rare, index texte | 3,45 s | **461 ms** | 910 M → 311 296 |
| Mot fréquent (HikariPool), index texte | 2,97 s | **333 ms** | 910 M → 9,5 M |
| Un trace id, bloom filter seul / avec une plage horaire | 2,73 s | **18 ms** | 1,8 M → 835 584 |
| Erreurs par minute, projection | 890 ms | **115 ms** | 910 M → 593 063 |
| Trace entière via la table de correspondance des trace ids | | **28 ms** | 188 416 |
| Agrégation regex lourde, cache de requêtes | 6,89 s | **1 ms** | 910 M → 0 |
| Même filtre relancé, query condition cache | 1,71 s | **13 ms** | 593 M → 540 672 |
| Scan complet, 3 répliques (parallel replicas) | 6,8 s | **3,77 s** (x1,8) | 910 M (répartis sur 3) |

Mesuré sur un service au repos. Lancées juste après les 8 lots, pendant que les merges tournent encore, les mêmes requêtes sont 2 à 3 fois plus lentes et les parallel replicas apportent peu : laissez quelques minutes au service après l'étape 2 du module 6.

## 07 · Enquête et exploitation
| Mesure | Valeur |
|---|---|
| Les 10 questions de l'enquête | 3 à 414 ms chacune |
| Cause racine | `INSERT payflow.payments`, timeout HikariPool, uniquement sur les pods v2.4.1 (26,5 % d'erreurs) contre 0 sur les pods v2.4.0 au même moment |
| HikariCP pendant l'incident | pool de 10, 10 actives, 45 à 49 threads en attente (v2.4.0 : pool de 50, ~4 actives, 0 en attente) |
| Impact métier, de 13h58 à 14h50 | **15 349 paiements en échec, 1,58 M EUR, 7 999 marchands** |
| Chronologie | déploiement 13h58, première erreur 13:58:03, page 14h00, OOM 14:21:07, retour arrière 14h42, dernière erreur 14:43:39, résolu 14h47 |
| Rejeu de la journée depuis bronze, puis REPLACE PARTITION | 8,1 M de lignes reconstruites en 15,6 s, comptes identiques par sévérité, échange atomique |
| Suppression RGPD d'un marchand (DELETE léger) | 1 017 lignes, 3 à 38 s selon la charge |

## 08 · ClickStack, dashboards, API, agents
| Mesure | Valeur |
|---|---|
| Tuiles de dashboard sur gold | quelques millisecondes, quelques milliers de lignes lues |
| API de statut (vue paramétrée sur slo_burn) | 11 lignes pour 10 minutes, quelques ms |
| ClickStack | lit directement `payflow_otel`, sources déduites du schéma OpenTelemetry |
