# Module 4 · Dashboards dans ClickStack

Un dashboard répond à « est-ce que ça marche ? » avant que quiconque pose la question. `01_agregats_red.sql` construit les chiffres qui l'alimentent (RED par minute, l'histogramme spanmetrics) ; ce README construit le dashboard lui-même dans ClickStack, clic par clic.

Durée : 35 min. Lancez d'abord `01_agregats_red.sql` (checkpoint `OK`).

> Plage pour tout le module : **l'incident**, réglée avec la plage de temps, **Around a time**, Time `YYYY-MM-DD 14:20:00` (votre date de Black Friday, module 3 étape 0), Duration ± `1h`. Certaines étapes utilisent `Last 1 hour` (le flux en direct) ou `Last 30 days` (tout le mois) : c'est précisé à chaque fois.

---

## Étape 1 · Chart Explorer : une question, un graphique (8 min)

**Chart Explorer** (menu de gauche) est un `GROUP BY` avec un formulaire. L'écran, de haut en bas :

| Zone | Rôle |
|---|---|
| **AI Assistant** (en haut, expérimental) | décrivez un graphique en une phrase, ClickStack remplit le formulaire |
| **Chart Name**, **Builder** / **SQL** | un nom ; le formulaire ou du SQL brut |
| les types de graphique | Time Series, Table, Number, Bar, Pie, Search, Heatmap, Patterns, Markdown |
| **Data Source** | PayFlow logs, traces ou metrics |
| la ligne de série | l'agrégation (Count of Events, Sum, 99th Percentile, Average, Maximum...), la colonne ou la métrique, **Where**, **Group By** |
| **Add Series**, **Add Formula**, **Add alert** | d'autres lignes sur le même graphique, une formule entre séries (A / B), une alerte sur le graphique |
| la plage de temps, la granularité, **Run** | quand, par tranche de combien de temps, exécuter |
| **Generated SQL** (en bas) | la requête que ClickStack exécute : ouvrez-la une fois |

Construisez chaque graphique ci-dessous. Pour une source de métriques, une case de métrique apparaît à côté de l'agrégation : tapez les premières lettres, puis choisissez le nom avec son type, par exemple `hikaricp.connections.pending (Gauge)`. Pour un percentile sur les traces, une case **SQL Column** apparaît : tapez `Duration / 1e6` (des nanosecondes aux millisecondes).

| Data Source | Agrégation | Colonne ou métrique | Where | Group By | Ce que vous voyez |
|---|---|---|---|---|---|
| PayFlow traces | 99th Percentile | `Duration / 1e6` | `SpanKind:Server` | `ServiceName` | trois services montent à 3 s à 13h58 |
| PayFlow traces | Count of Events | | `StatusCode:Error` | `ResourceAttributes['service.version']` | seule la v2.4.1 échoue |
| PayFlow metrics | Maximum | `hikaricp.connections.pending (Gauge)` | | `ResourceAttributes['service.version']` | des dizaines de threads en attente en v2.4.1, aucun en v2.4.0 |
| PayFlow metrics | 99th Percentile | `traces.span.metrics.duration (Histogram)` | `span.name:"POST /v1/payments"` | | l'histogramme spanmetrics de `01_agregats_red.sql` |
| PayFlow traces | Count of Events | | `SpanKind:Server ServiceName:api-gateway` | | plage `Last 30 days` : quatre semaines, les week-ends plus bas, le pic du Black Friday |

**Text-to-chart** : ouvrez **AI Assistant** en haut, tapez *error count per service over the last hour*, envoyez. ClickStack remplit le formulaire pour vous ; vérifiez le Where et le Group By qu'il a choisis avant de lui faire confiance. Si l'assistant est absent, Generative AI est désactivé pour votre équipe (Team Settings, **API & Agents**, **Configure Generative AI**).

---

## Étape 2 · Le dashboard SRE (15 min)

1. Menu de gauche, **Dashboards**. En haut, les **Preset Dashboards** (étape 4) ; en dessous, vos dashboards.
2. **New Dashboard** (en haut à droite), puis **Saved Dashboard** (conservé pour l'équipe). Les autres choix : **Temporary Dashboard** (uniquement dans votre navigateur) et **Generate with AI** (un dashboard ébauché à partir de vos données, essayez-le à la fin).
3. Le dashboard s'ouvre sous le nom *My Dashboard*. Cliquez sur le crayon à côté du nom, tapez `PayFlow · SRE`, appuyez sur Entrée.
4. **Add**, puis **New Tile**. L'éditeur de tuile, c'est Chart Explorer dans une fenêtre : remplissez-le, **Run** pour prévisualiser, **Save**. Créez ces tuiles :

| Nom de la tuile | Type de graphique | Data Source | Réglages |
|---|---|---|---|
| Requests per service | Time Series | PayFlow traces | Count of Events, Where `SpanKind:Server`, Group By `ServiceName` |
| p99 latency per service | Time Series | PayFlow traces | 99th Percentile de `Duration / 1e6`, Where `SpanKind:Server`, Group By `ServiceName` |
| Payment errors | Number | PayFlow traces | Count of Events, Where `StatusCode:Error SpanName:"POST /v1/payments"` ; **Display Settings**, **Conditional colors**, **Add rule** : `>` `100`, le point rouge sous *Semantic*, **Apply** |
| Errors by version | Pie | PayFlow logs | Count of Events, Where `SeverityText:ERROR`, Group By `ResourceAttributes['service.version']` |
| Latency heatmap | Heatmap | PayFlow traces | `Duration`, Where `ServiceName:payment` |
| Top error messages | Table | PayFlow logs | Count of Events, Where `SeverityText:ERROR -ServiceName:api-gateway`, Group By `Body` (les lignes d'accès de la gateway sont exclues : chacune est unique, elles ne se regrouperaient pas) |

> **Attention** : dans l'éditeur de tuile, **Échap** propose d'abandonner la tuile. Fermez une liste déroulante en cliquant à côté. Ne tapez dans une case qu'après avoir cliqué dedans, sinon le texte atterrit dans la case suivante (vérifiez **ORDER BY**, elle doit rester vide ici).

Sur la plage de l'incident, le dashboard ressemble à ceci : le p99 de payment à 3 s de 13h58 à 14h44, le nombre d'erreurs en rouge, le timeout HikariPool en tête du tableau.

![Le dashboard SRE](../../en/img/04_dashboard_sre.png)

Ensuite :
- **Disposer** : faites glisser une tuile par son titre, redimensionnez-la par son coin inférieur droit. Chaque tuile a sa propre barre d'outils : type de graphique, une loupe (ouvrir les événements correspondants dans Search), une cloche (alerte sur la tuile), plein écran, et **⋮** (modifier, dupliquer, supprimer).
- **Filtres** : l'icône de filtre à gauche de **Run** ouvre **Filters and Variables**. **Add new filter** : Display name `Service`, Data source **PayFlow traces**, Filter expression `ServiceName` (choisissez-le dans les suggestions), laissez **Broadcast filter condition** coché (la valeur s'applique à toutes les tuiles, quelle que soit leur source), **Save filter**, **Close**. Une liste déroulante **Service** apparaît au-dessus des tuiles : choisissez `payment`, toutes les tuiles suivent. Les autres options : **Single select**, **Required** (les tuiles attendent une valeur), **Available as variable** (une `$variable` pour les tuiles SQL de l'étape 3). Ajoutez-en un second sur `ResourceAttributes['service.team']` de la même façon.
- **Release markers** : menu **⋮** du dashboard (en haut à droite), **Show release markers**. Une ligne pointillée marquée `v2.4.1` apparaît à 13h58 sur les graphiques temporels : ClickStack lit `service.version` dans la télémétrie, rien à configurer. La première question de tout incident, avec sa réponse sur le graphique.

  ![Release marker](../../en/img/04_dashboard_release_marker.png)
- **Drilldown au clic sur une ligne** : cliquez sur la ligne *HikariPool-1* de *Top error messages*. Search s'ouvre sur PayFlow logs, sur la même plage, avec le Where de la tuile et un filtre `Body IN ('HikariPool-1 ...')` : les lignes derrière le chiffre. C'est le comportement par défaut. Pour le changer, **⋮**, modifiez la tuile, **Row Click Action: Default** : **Search** (une autre source, un Where écrit avec `{{ColumnName}}` à partir de la ligne cliquée), **Dashboard** (un autre dashboard avec des filtres, par exemple `ServiceName = '{{ServiceName}}'`), **External** (une URL, par exemple un runbook). Le bouton **Précédent** du navigateur ramène au dashboard.
- **Live** : réglez la plage sur `Last 1 hour` et cliquez sur **Live** : le dashboard se rafraîchit tout seul sur le flux en direct.
- Le menu **⋮** propose aussi **Enter kiosk mode** (un écran mural), **Show alert annotations** (module 5), **Export Dashboard** et **Import New Dashboard** (en JSON, pour partager un dashboard entre services).

---

## Étape 3 · Une tuile SQL sur les agrégats (8 min)

Certaines questions demandent du SQL : une jointure, un ratio, un agrégat (rollup). **Add**, **New Tile**, puis **SQL** (en haut à droite de l'éditeur, à côté de **Builder**) : un message *Chart converted to SQL* apparaît et l'éditeur est prérempli avec le SQL du formulaire Builder. **Connection** `Default` ; videz **Source** avec son **x** (la requête lit un agrégat, pas une source). Au-dessus de l'éditeur, **SQL Chart Instructions** donne les règles et les macros :

| Macro | Devient |
|---|---|
| `$__timeFilter(col)` | `col` dans la plage de temps du dashboard |
| `$__timeInterval(col)` | `col` arrondi à la granularité du graphique |
| `$__fromTime`, `$__toTime` | les bornes de la plage, en millisecondes |
| `$__sourceTable`, `$__filters` | la table de la source choisie, les filtres du dashboard (avec une Source) |

La première colonne DateTime est l'axe du temps, chaque colonne numérique une série, chaque colonne String un groupe. Cliquez dans l'éditeur, sélectionnez tout (Cmd+A ou Ctrl+A), supprimez, et collez :

```sql
SELECT
    $__timeInterval(minute)                                             AS ts,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

Deux avertissements orange réclament `$__sourceTable` et `$__filters` : des conseils pour les tuiles posées sur une source, ignorez-les ici. Nommez-la `POST /v1/payments, rollup`, **Run**, **Save**. La tuile lit quelques centaines de lignes de l'agrégat au lieu de millions de spans : c'est à cela que sert `01_agregats_red.sql`. Réglez la plage sur `Last 30 days` : toujours instantané.

Une seconde tuile SQL, type de graphique **Table**, le budget d'erreur du Black Friday (le type table n'a pas besoin de macro de temps) :

```sql
SELECT
    sum(requests)                                                   AS requests,
    sum(errors)                                                     AS errors,
    round(100 * (1 - sum(errors) / sum(requests)), 3)               AS availability_pct,
    round(100 * sum(errors) / (sum(requests) * 0.0005), 1)          AS budget_spent_pct
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND toDate(minute) = pf_black_friday()
```

Une seule mauvaise version a consommé plusieurs fois le budget d'erreur de la journée.

---

## Étape 4 · Les dashboards prédéfinis (4 min)

**Dashboards**, **Preset Dashboards** :
- **Services** : vues HTTP, base de données et erreurs de chaque service, à partir d'une source de traces. Choisissez **PayFlow traces** en haut. Sur la plage de l'incident, les appels de payment à la base sautent aux yeux.
- **Kubernetes** : choisissez **PayFlow logs** et **PayFlow metrics** en haut. Onglets **Pods**, **Nodes**, **Namespaces** : CPU, mémoire, phase, redémarrages et uptime de chaque pod, les nœuds et leur état ready. Nos métriques suivent les noms des receivers kubeletstats et k8s_cluster, exactement ce que lit ce dashboard. Sur la plage de l'incident, le pod fraud-scoring d'ip-10-0-3-17 montre son redémarrage.
- **Browse dashboard templates** : des métriques d'exécution pour les services Go, JVM, Node.js et .NET, à importer.
