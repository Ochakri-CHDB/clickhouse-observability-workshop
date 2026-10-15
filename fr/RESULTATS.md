# Résultats mesurés · Workshop observabilité ClickHouse

Run de référence du 15 octobre 2026, depuis zéro (`./run_all.sh`, environ 7 min au total) sur le service de test : **ClickHouse Cloud 26.6, AWS eu-central-1, 3 répliques de 64 Go (16 vCPU chacune)**, la configuration recommandée aux participants. Les durées viennent de `system.query_log` (temps serveur). Les données sont simulées et déterministes : volumes, lignes lues et résultats sont les mêmes pour chaque participant ; les durées varient de quelques dizaines de pourcents d'un run à l'autre.
Les mêmes chiffres figurent en commentaire (`Mesuré`) sous chaque instruction des fichiers SQL.

> Ordres de grandeur pour les slides
> - **Une journée d'une plateforme de paiement**, générée en SQL : 1,38 M de requêtes, 21,5 M de spans, 7,8 M de lignes de log, 612 000 points de métriques
> - **La passerelle en SQL** : 8,1 M d'enregistrements d'agents parsés, enrichis et masqués par des vues matérialisées en 6 instructions de 12 à 16 s ; **0 ligne brute stockée**, 0 numéro de carte en clair, 4 % de bruit filtré
> - **Détection** : première page (alerte qui réveille l'astreinte) à 14h00, **2 minutes** après le déploiement fautif ; résolue à 14h47
> - **En direct** : un interrupteur rejoue l'incident sur le flux en direct, l'alerte de burn rate se déclenche **en moins d'une minute**
> - **875 millions de lignes de log** écrites en 8 instructions de ~27 s ; un mot rare trouvé en **1 s** au lieu de 3,8 s, une trace en **31 ms** au lieu de 2,4 s
> - **Impact métier** : 15 349 paiements en échec, **1,58 M EUR**, 7 999 marchands

---

## 01 · Modèle de données
| Mesure | Valeur |
|---|---|
| Catalogue de services | 12 nœuds, 9 services, 49 pods (payment : 3 générations de 6), 11 périodes de déploiement, 20 000 marchands, 5 dictionnaires |
| Tables OpenTelemetry | le DDL exact de l'exporteur : 5 tables de signaux, 7 index texte sur otel_logs, plus la table de recherche par trace id et sa vue |

## 02 · Collecte
| Mesure | Valeur |
|---|---|
| Requêtes de la journée | 1,38 M (15/s la nuit, 33/s pendant la vente flash) |
| Passerelle : 6 insertions dans la table Null | 11,6 à 16,1 s chacune ; 8,13 M d'enregistrements reçus, 319 680 health checks écartés (3,9 %, 86 Mo) |
| Stocké par la table d'atterrissage | 0 ligne |
| Enrichissement (k8sattributes depuis le catalogue) | version, équipe, nœud et zone sur chaque log de conteneur |
| Masquage PCI | 244 982 numéros de carte masqués, 0 en clair |
| Spans (OTLP), 4 lots | 7,9 à 14,2 s chacun, 21,5 M de spans (15,6 par trace, un span Client et un span Server par appel) |
| Métriques | 426 240 points de pods (CPU, mémoire), 103 680 points HikariCP, 53 280 points de compteur de redémarrages |
| Flux en direct, trafic calme / panne | environ 9 000 spans et 3 000 lignes de log par minute / 28 000 spans dont 3 000 erreurs par minute |
| Stockage de la journée | otel_traces 953 Mo (x8,7), otel_logs 351 Mo (x10,9), métriques sous 6 Mo |

## 03 · Recherche et corrélation
| Mesure | Valeur |
|---|---|
| Recherche plein texte sur 10 minutes (index texte) | 24 ms, 172 032 lignes lues |
| Filtre d'attribut via l'index texte sur `ResourceAttributeItems` | 21 ms |
| Log → trace → métriques du pod | 3 requêtes, moins de 0,6 s au total |
| Scénario A, depuis le ticket d'un marchand (log) | 4 requêtes, de 15 à 206 ms : l'identifiant du marchand mène à `maximumPoolSize=10` sur un pod v2.4.1 |
| Scénario B, depuis une alerte métrique (plus de 20 connexions en attente dans le pool) | déclenchée à 14h03 sur les 6 pods ; 5 requêtes de 12 à 37 ms mènent au déploiement progressif (rollout) CHG-4117 |
| Scénario C, depuis une trace (nouveau message d'erreur) | 290 spans "connection refused" à partir de 14:21:07 ; 5 requêtes de 33 à 131 ms mènent à l'OOM kill, causé par les nouveaux essais (trafic de fraud-scoring x2,2) |

## 04 · Dashboards (agrégats RED)
| Mesure | Valeur |
|---|---|
| Backfill RED | 8,3 M de spans serveur → 20 160 lignes en 1,27 s |
| Même courbe depuis l'agrégat / depuis les spans | 8 192 / 90 112 lignes lues |
| Histogramme spanmetrics avec exemplars | 23 345 points en 751 ms |
| p99 de POST /v1/payments | 300 ms avant 13h58, 3,1 s pendant, retour à la normale à 14h44 |

## 05 · SLO et alertes
| Mesure | Valeur |
|---|---|
| Burn rate, fenêtre de 1 h, au pic | plus de 400 fois le rythme permis |
| Alertes de la journée | 11 événements : première page à 14h00, pression mémoire sur un nœud à 14h19, redémarrage OOM à 14h22, résolution à 14h47 |
| Interrupteur de panne sur le flux en direct | burn rate de 450x dès la première minute, page fast-burn en moins d'une minute, alerte p99 au bout de 3 minutes |

## 06 · Enquête
| Mesure | Valeur |
|---|---|
| Service map | 16 arêtes tirées des traces ; payment → postgres p95 de 7,7 ms avant, 3 033 ms pendant |
| Motifs de logs | 31 motifs pour 6,4 M de lignes ; le premier des nouveaux est le timeout HikariPool (18 011 fois, 0 avant) |
| Les 10 questions | 3 à 379 ms chacune |
| Cause racine | `INSERT payflow.payments`, timeout HikariPool, uniquement sur les pods v2.4.1 (CHG-4117) |
| Impact métier, de 13h58 à 14h50 | **15 349 paiements en échec, 1 576 893 EUR, 7 999 marchands** |

## 07 · Échelle et coût (875 millions de lignes de log)
| Mesure | Valeur |
|---|---|
| Écriture, 8 lots de 109 M de lignes | 26,4 à 29,5 s chacun, environ 3,5 min au total, ~10,5 Go de mémoire par lot |
| Stockage | 106 Go bruts → 13 Go juste après les insertions (x8,2, 16 octets par ligne) ; les fusions en arrière-plan continuent de compresser |

| Requête (service au repos) | Sans | Avec | Lignes lues |
|---|---|---|---|
| Mot rare, index texte | 3,81 s | **1,05 s** | 875 M → 606 208 |
| Mot fréquent (HikariPool), index texte | 2,41 s | **678 ms** | 875 M → 10,3 M |
| Un trace id, bloom filter seul / avec une plage horaire | 2,38 s | **31 ms** | 1,9 M → 1 M |
| Erreurs par minute, projection | 549 ms | **341 ms** | 875 M → 578 256 |
| Trace complète via la table de recherche | | **526 ms** | 245 760 |
| Agrégation lourde par regex, cache de requêtes | 5,13 s | **1 ms** | 875 M → 0 |
| Même filtre à nouveau, query condition cache | 2,37 s | **19 ms** | 875 M → 1,1 M |
| Scan complet, 3 répliques | 5,12 s | **2,11 s** (x2,4) | 875 M |

| Levier | Valeur |
|---|---|
| Agrégat (rollup) dans la convention de ClickStack | 21,5 M de spans → 53 926 lignes (399 spans par ligne), construit en 2,7 s |
| Échantillonnage à la rétention (erreurs et traces de plus de 1 s) | 602 753 spans gardés, 2,8 % de la journée, toutes les traces de l'incident |
| Échantillonnage en tête à 10 % | le taux d'erreur est préservé, les traces rares ne le sont pas |
| Règle de dimensionnement | 12 Go de télémétrie brute par jour = 0,01 vCPU d'ingestion |

## 08 · IA et gouvernance
| Mesure | Valeur |
|---|---|
| Suppression RGPD d'un marchand (lightweight DELETE) | 1 017 lignes, environ 1 s |
| Row policies par équipe | 2 policies, appliquées de la même façon à ClickStack, à la console SQL et au MCP |
| API de statut (vue paramétrée sur slo_burn) | 11 lignes pour 10 minutes, quelques ms |
