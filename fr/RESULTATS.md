# Résultats mesurés · Workshop observabilité ClickHouse

Run de référence du 16 octobre 2026 (le Black Friday tombait donc le vendredi 9 octobre), depuis zéro (`./run_all.sh`, environ 14 min au total) sur le service de test : **ClickHouse Cloud 26.6, AWS eu-central-1, 3 répliques de 64 Go (16 vCPU chacune)**, la configuration recommandée aux participants. Les durées viennent de `system.query_log` (temps serveur). Les données sont générées pour le jour où vous lancez le workshop : l'incident, les volumes et les résultats sont les mêmes pour tous les participants (l'aléa est calé sur le temps relatif au Black Friday) ; seuls les quelques jours entre le Black Friday et aujourd'hui changent selon le jour de la semaine, et les durées varient de quelques dizaines de pour cent d'un run à l'autre.
Les mêmes chiffres figurent en commentaire (`Mesuré`) sous chaque instruction des fichiers SQL.

> Ordres de grandeur pour les slides
> - **Un mois d'une plateforme de paiement**, généré en SQL : 76,7 M de spans, 27,8 M de lignes de log, 37,8 M de points de métriques, chargés en 8 minutes environ, chaque instruction sous les 35 s
> - **Le Black Friday** dans ce mois : 1,38 M de requêtes, 21,5 M de spans, 7,8 M de lignes de log, 12 fois une journée ordinaire
> - **La passerelle en SQL** : 27,5 M d'enregistrements d'agents parsés, enrichis et masqués par des vues matérialisées ; **0 ligne brute stockée**, 766 724 numéros de carte masqués, 11,6 % de bruit filtré
> - **Détection** : première page à 14h00, **2 minutes** après le déploiement fautif ; résolu à 14h47 ; 11 alertes dans le mois, toutes le jour du Black Friday
> - **875 millions de lignes de log** écrites en 8 instructions d'environ 30 s ; un mot rare trouvé en **0,8 s** au lieu de 4,3 s, une trace en **22 ms** au lieu de 3 s
> - **Impact métier** : 15 349 paiements en échec, **1,58 M EUR**, 7 999 marchands

---

## 01 · Modèle de données
| Mesure | Valeur |
|---|---|
| Calendrier | Black Friday = le dernier vendredi avant aujourd'hui ; historique de 30 jours qui se termine par lui ; 3 fonctions (`pf_black_friday`, `pf_day`, `pf_at`) qui préservent l'élagage par clé primaire et par partition |
| Catalogue de services | 12 nœuds, 9 services, 16 changements dans le mois (5 livraisons hebdomadaires, la version fautive, le rollback), 74 pods (payment : 4 générations de 6), 20 000 marchands, 5 dictionnaires |
| Tables OpenTelemetry | le DDL exact de l'exporteur : 5 tables de signaux, 7 index texte sur otel_logs, plus la table de recherche par trace id et sa vue |

## 02 · Collecte
| Mesure | Valeur |
|---|---|
| Requêtes | environ 107 000 par journée ordinaire, 80 000 le week-end, 1,38 M le jour du Black Friday (33/s pendant la vente flash) |
| Passerelle : 10 inserts dans la table Null | de 14 à 22 s chacun ; 27,5 M d'enregistrements reçus, 3,2 M de health checks écartés (11,6 %, 859 Mo) |
| Stocké par la table d'atterrissage | 0 ligne |
| Enrichissement (k8sattributes depuis le catalogue) | version, équipe, nœud et zone sur chaque log de conteneur |
| Masquage PCI | 766 724 numéros de carte masqués sur le mois, 0 en clair |
| Spans (OTLP), 6 lots | de 11 à 33 s chacun, 67 M de spans pour l'historique (15,7 par trace, un span Client et un span Server par appel) |
| Métriques, noms kubeletstats et k8s_cluster | 28,4 M de points gauge sur le mois, toutes les 30 s (pods, nœuds, namespaces, HikariCP, lag Kafka), en 3 lots de 15 s ; 2,1 M de compteurs d'uptime |
| Rattrapage, du Black Friday à maintenant (un vendredi : 6 jours et la matinée en cours) | 5 instructions de 2 à 22 s |
| Flux en direct | le simulateur chaque minute : 650 spans et 250 lignes de log par minute le matin, environ 2 200 spans à la pointe du soir ; comble le trou tout seul après une mise en veille |
| Interrupteur de panne (mesuré le 16 oct., de 10h00 à 10h04) | rejoue les minutes de l'incident, au quart de leur trafic : de 6 800 à 7 200 spans et 2 500 lignes de log par minute (120 timeouts HikariPool, 20 par pod), 26 % des paiements en échec, burn rate de 500 à 600 ; la règle SQL de fast burn se déclenche dès la première minute, la règle p99 à la troisième |

## 03 · Recherche et corrélation
| Mesure | Valeur |
|---|---|
| Recherche plein texte sur 10 minutes (index texte) | 172 033 lignes lues |
| Filtre d'attribut via l'index texte sur `ResourceAttributeItems` | 163 841 lignes lues |
| Scénario A, depuis un ticket marchand (log) | 4 requêtes : l'identifiant du marchand mène à `maximumPoolSize=10` sur un pod v2.4.1 |
| Scénario B, depuis une alerte métrique (pool pending au-dessus de 20) | se déclenche à 14h03 sur les 6 pods ; 5 requêtes mènent au rollout CHG-4117 |
| Scénario C, depuis une trace (nouveau message d'erreur) | 290 spans "connection refused" à partir de 14:21:07 ; 5 requêtes mènent à l'OOM kill, causé par les retries (trafic de fraud-scoring x2,2) |

## 04 · Dashboards (agrégats RED)
| Mesure | Valeur |
|---|---|
| Backfill RED, tout le mois | 76,6 M de spans → 720 523 lignes en 11,8 s |
| Même courbe depuis l'agrégat / depuis les spans | 8 193 / 81 921 lignes lues |
| Histogramme spanmetrics avec exemplars, le mois | 735 032 points en 7,6 s |
| p99 de POST /v1/payments | 300 ms avant 13h58, 3,1 s pendant, retour à la normale à 14h44 |

## 05 · SLO et alertes
| Mesure | Valeur |
|---|---|
| Burn rate, fenêtre de 1 h, au pic | 19 fois le taux autorisé sur POST /v1/payments |
| Alertes du mois | 11 événements, tous le jour du Black Friday : première page à 14h00, pression mémoire du nœud à 14h19, redémarrage OOM à 14h22, résolu à 14h47 |
| Règle p99 | exige 150 appels par minute : une journée ordinaire, un p99 n'est que l'appel le plus lent |

## 06 · Enquête
| Mesure | Valeur |
|---|---|
| Service map | 16 arêtes tirées des traces ; payment → postgres p95 de 7,7 ms avant, 3 033 ms pendant |
| Motifs de logs | 31 motifs pour 6,4 M de lignes ; le premier des nouveaux est le timeout HikariPool (18 011 fois, 0 avant) |
| Cause racine | `INSERT payflow.payments`, timeout HikariPool, uniquement sur les pods v2.4.1 (CHG-4117) |
| Impact métier, de 13h58 à 14h50 | **15 349 paiements en échec, 1 576 893 EUR, 7 999 marchands** |

## 07 · Échelle et coût (875 millions de lignes de log)
| Mesure | Valeur |
|---|---|
| Écriture, 8 lots de 109 M de lignes | de 28 à 31 s chacun, environ 4 min au total, ~10 Go de mémoire par lot |
| Stockage | 106 Go bruts → 16,5 Go juste après les insertions (x6,4, 20 octets par ligne) ; les fusions en arrière-plan continuent de compresser |

| Requête (service au repos) | Sans | Avec | Lignes lues |
|---|---|---|---|
| Mot rare, index texte | 4,27 s | **774 ms** | 875 M → 286 720 |
| Mot fréquent (HikariPool), index texte | 3,09 s | **367 ms** | 875 M → 9,7 M |
| Un trace id, bloom filter seul / avec une plage de temps | 2,96 s | **22 ms** | 1,2 M → 368 641 |
| Erreurs par minute, projection | 1,08 s | **712 ms** | 875 M → 465 928 |
| Trace entière via la table de recherche | | **454 ms** | 245 761 |
| Agrégation lourde par regex, cache de requêtes | 6,99 s | **1 ms** | 875 M → 0 |
| Même filtre à nouveau, query condition cache | 2,94 s | **14 ms** | 875 M → 745 472 |
| Scan complet, 3 répliques | 7,03 s | **3,56 s** (x2) | 875 M |

| Levier | Valeur |
|---|---|
| Agrégat selon la convention de ClickStack, le mois | 76,6 M de spans → 1,7 M de lignes en 8,7 s ; le Black Friday seul : 21,5 M de spans → 53 926 lignes (399 spans par ligne) |
| Échantillonnage pour la rétention (erreurs et traces au-delà de 1 s) | 602 753 spans gardés, 2,8 % du Black Friday, toutes les traces de l'incident |
| Échantillonnage en tête à 10 % | le taux d'erreur est préservé, les traces rares ne le sont pas |

## 08 · IA et gouvernance
| Mesure | Valeur |
|---|---|
| Suppression RGPD d'un marchand sur le mois (DELETE léger) | 3 529 lignes, 23 s |
| Row policies par équipe | 2 policies, appliquées de la même façon à ClickStack, à la console SQL et au MCP |
| Auto-observabilité du run | 316 inserts (p50 1,2 s, max 33 s), 186 selects (p50 118 ms) |
