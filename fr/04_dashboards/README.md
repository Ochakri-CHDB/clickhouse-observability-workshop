# Module 4 · Dashboards dans ClickStack

Un dashboard répond à « est-ce que ça marche ? » avant que quiconque pose la question. `01_agregats_red.sql` construit les chiffres qui l'alimentent (RED par minute, l'histogramme spanmetrics) ; ce README construit le dashboard lui-même dans ClickStack.

Durée : 35 min. Lancez d'abord `01_agregats_red.sql` (checkpoint `OK`).

> Plage pour tout le module : **l'incident**, de `2026-11-27 13:00` à `2026-11-27 16:00` (UTC), sauf mention contraire.

---

## Étape 1 · Chart Explorer : une question, un graphe (5 min)

**Chart Explorer** (menu de gauche) est un `GROUP BY` avec une interface : une source, une métrique, un filtre, un regroupement.

| Source | Métrique | Where | Group by | Ce que vous voyez |
|---|---|---|---|---|
| PayFlow traces | 99e percentile de `Duration / 1e6` | `SpanKind:Server` | `ServiceName` | trois services montent à 3 s à 13h58 |
| PayFlow traces | Count | `StatusCode:Error` | `ResourceAttributes['service.version']` | seule la v2.4.1 échoue |
| PayFlow metrics | `hikaricp.connections.pending` (gauge), Max | | `service.version` | des dizaines de threads en attente en v2.4.1, aucun en v2.4.0 |
| PayFlow metrics | `traces.span.metrics.duration` (histogramme) | `span.name:"POST /v1/payments"` | | l'histogramme spanmetrics du fichier 01 du module 4 |

**Text-to-chart** : l'assistant IA de Chart Explorer transforme une phrase en graphe. Essayez *"error count per service over time"*. S'il n'est pas disponible, Generative AI n'est pas activé sur votre équipe (module 8).

---

## Étape 2 · Le dashboard SRE (15 min)

**Dashboards**, **New Dashboard**, nom `PayFlow · SRE`. Puis **Add New Tile** pour chaque tuile :

| Tuile | Type | Source | Réglages |
|---|---|---|---|
| Requêtes par service | Line/Bar | PayFlow traces | Count, where `SpanKind:Server`, group by `ServiceName` |
| Latence p99 par service | Line/Bar | PayFlow traces | 99e percentile de `Duration / 1e6`, where `SpanKind:Server`, group by `ServiceName` |
| Taux d'erreur | Number | PayFlow traces | Count, where `StatusCode:Error AND SpanName:"POST /v1/payments"` ; règle de couleur rouge au-dessus de 100 |
| Erreurs par version | Pie | PayFlow logs | Count, where `SeverityText:ERROR`, group by `ResourceAttributes['service.version']` |
| Heatmap des latences | Heatmap | PayFlow traces | `Duration / 1e6`, where `ServiceName:payment` |
| Messages d'erreur les plus fréquents | Table | PayFlow logs | Count, where `SeverityText:ERROR`, group by `Body` |

Ensuite :
- **Filtres** : **Edit Filters and Variables**, ajoutez un filtre sur `ServiceName` et un sur `ResourceAttributes['service.team']`. Toutes les tuiles les suivent.
- **Release markers** : dans le menu du dashboard, **Show release markers**. Une ligne pointillée apparaît à 13h58 (v2.4.1) et à 14h42 (v2.4.0) sur les graphes temporels : ClickStack lit `service.version` dans la télémétrie, rien à configurer. La première question de tout incident, avec sa réponse sur le graphe.
- **Drilldown au clic sur une ligne** : sur la table *Messages d'erreur les plus fréquents*, configurez un clic de ligne qui ouvre **Search** filtré sur cette ligne : d'un message à ses lignes de log en un clic.

---

## Étape 3 · Une tuile SQL sur les agrégats (10 min)

Certaines questions demandent du SQL : une jointure, un ratio, un agrégat (rollup). Ajoutez une tuile, choisissez l'onglet **SQL**, connexion `Default`, type **Line**, et collez :

```sql
SELECT
    minute AS ts,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

`$__timeFilter(minute)` est remplacé par la plage de temps du dashboard. La tuile lit quelques centaines de lignes de l'agrégat au lieu de millions de spans : c'est à cela que sert le fichier 01 du module 4.

Une seconde tuile SQL, type **Table**, le budget d'erreur de la journée :

```sql
SELECT
    sum(requests)                                                   AS requests,
    sum(errors)                                                     AS errors,
    round(100 * (1 - sum(errors) / sum(requests)), 3)               AS availability_pct,
    round(100 * sum(errors) / (sum(requests) * 0.0005), 1)          AS budget_spent_pct
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND toDate(minute) = '2026-11-27'
```

Une seule mauvaise version a consommé plusieurs fois le budget d'erreur de la journée.

---

## Étape 4 · Dashboards prêts à l'emploi (5 min)

ClickStack fournit des dashboards tout faits :
- **Services** : vues HTTP, base de données et erreurs de chaque service, à partir de la source de traces. Ouvrez-le sur la plage de l'incident : les appels à la base de payment ressortent.
- **Kubernetes** : pods, nœuds et namespaces à partir de la source de métriques. Nos métriques de pods suivent les noms kubeletstats (`k8s.pod.cpu.utilization`, `k8s.pod.memory.working_set`) ; les vues qui ont besoin de métriques que nous ne simulons pas restent vides.
- **Dashboard templates** (Browse dashboard templates) : métriques runtime des services Go, JVM, Node.js et .NET.
