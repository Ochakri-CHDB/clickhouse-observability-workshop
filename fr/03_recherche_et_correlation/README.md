# Module 3 · Recherche et corrélation dans ClickStack

Le mois de PayFlow est dans les tables OpenTelemetry, et un flux en direct ajoute la minute courante chaque minute. Vous le regardez maintenant comme le fait un ingénieur d'astreinte, dans **ClickStack**, l'interface d'observabilité fournie avec votre service ClickHouse Cloud. Aucune connaissance préalable de ClickStack n'est nécessaire : chaque clic est décrit. Ensuite, deux fichiers SQL montrent ce que ClickStack exécute pour vous.

Durée : 45 min.

| Fichier | Contenu |
|---|---|
| `01_sous_le_capot.sql` | la recherche en SQL, les index texte et EXPLAIN, du log à la trace puis aux métriques du pod, le live tail |
| `02_scenarios_de_correlation.sql` | trois enquêtes : depuis un log, depuis une alerte métrique, depuis une trace |

---

## Étape 0 · Votre date de Black Friday (1 min)

Les données sont relatives au jour où vous lancez le workshop : le Black Friday est **le dernier vendredi avant aujourd'hui**. Dans la console SQL, lancez :

```sql
SELECT pf_black_friday() AS black_friday, pf_day(-29) AS month_starts, now() AS now_utc;
```

Notez la date. Partout dans la suite, **l'incident** désigne cette date, de 13h20 à 15h20 UTC. Les captures d'écran de ce guide ont été prises avec un Black Friday au 9 octobre : vos dates diffèrent, les courbes sont les mêmes.

---

## Étape 1 · Ouvrir ClickStack (2 min)

1. Dans la [console ClickHouse Cloud](https://console.clickhouse.cloud), ouvrez votre service.
2. Dans le menu de gauche, vers le bas, cliquez sur **ClickStack**. Il s'ouvre dans un nouvel onglet du navigateur (`hyperdx.clickhouse.cloud`), déjà connecté à votre service : ni utilisateur, ni mot de passe, ni installation.

Le menu de gauche de ClickStack est la carte de ce workshop :

| Menu | Ce que c'est | Module |
|---|---|---|
| **Search** | chercher et parcourir les logs ou les traces, live tail | 3 |
| **Saved Searches** | les recherches enregistrées, à réutiliser ou à alerter | 3, 5 |
| **Chart Explorer** | construire un graphique à partir de n'importe quelle source, sans SQL | 3, 4 |
| **Alerts** | toutes les alertes de l'équipe et leur état | 5 |
| **Service Map** | les services et les appels entre eux, tirés des traces | 6 |
| **AI notebooks** | un assistant d'enquête qui écrit et exécute les requêtes | 8 |
| **Dashboards** | vos dashboards, et des presets (Services, Kubernetes) | 4 |
| **Team Settings** | sources, membres et rôles, webhooks, MCP | 3, 5, 8 |

## Étape 2 · Afficher les heures en UTC (1 min)

ClickStack affiche les heures dans le fuseau horaire de votre navigateur. Le workshop parle en UTC.

1. En bas à gauche, cliquez sur votre nom, puis sur **User Preferences**.
2. **Time format** : `24h`. **Use UTC time** : activé. Fermez la fenêtre.

Un petit badge `UTC` apparaît à côté du logo ClickStack.

![Use UTC time](../../en/img/03_preferences_utc.png)

---

## Étape 3 · Déclarer les sources (8 min)

Une **source** indique à ClickStack où vit un signal : quelle table, quelles colonnes. Nos tables sont dans la base `payflow_otel`.

1. Menu de gauche, **Team Settings**, onglet **Data**. La liste **Sources** contient peut-être déjà des sources d'autres démos : laissez-les.
2. Cliquez sur **Add source** (en bas de la liste) et remplissez :

   | Champ | Logs | Traces | Métriques |
   |---|---|---|---|
   | Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
   | Section | `PayFlow` | `PayFlow` | `PayFlow` |
   | Source Data Type | **Logs** | **Traces** | **OTel metrics** |
   | Server Connection | `Default` | `Default` | `Default` |
   | Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
   | Table | `otel_logs` | `otel_traces` | (pré-rempli : gauge, histogram, sum) |

   - Dans **Database** et **Table**, tapez les premières lettres, puis cliquez sur le nom dans la liste.
   - Dès que la table est choisie, un message indique *Automatically inferred source configuration from table schema* : nos tables suivent exactement le schéma de l'exporteur OpenTelemetry, ClickStack remplit donc toutes les colonnes tout seul (horodatage, service, sévérité, corps, trace id...).
   - La **Section** regroupe les trois sources sous `PayFlow` dans tous les menus de sources.
3. Cliquez sur **Save New Source**. Faites de même pour les traces, puis pour les métriques.

![Paramètres de la source](../../en/img/03_source_logs.png)

4. Reliez les sources, pour qu'un clic fasse passer d'un signal à un autre (**sources corrélées**) :
   - dans **PayFlow traces**, champ **Correlated Log Source** : `PayFlow logs` ;
   - dans **PayFlow metrics**, champ **Correlated Log Source** : `PayFlow logs`.

   Ouvrez **PayFlow logs** (la flèche au bout de sa ligne), puis **Configure Optional Fields** : ClickStack a rempli tout seul **Correlated Trace Source** et **Correlated Metric Source**.
5. Toujours dans **PayFlow logs**, champs optionnels, **Highlighted Attributes**, **Add expression** : `ResourceAttributes['service.version']`, alias `version`. Cliquez sur la coche, puis sur **Save Source**. La version du pod s'affichera en haut de chaque ligne de log que vous ouvrez. Dans **PayFlow traces**, **Highlighted Trace Attributes** : `SpanAttributes['merchant.id']`, alias `merchant`.

---

## Étape 4 · Rechercher (10 min)

Menu de gauche, **Search**. L'écran, de haut en bas :

| Zone | Rôle |
|---|---|
| menu des sources (en haut à gauche) | la source dans laquelle vous cherchez : choisissez **PayFlow logs** |
| `SELECT` | les colonnes du tableau de résultats ; laissez-le tel quel |
| `ORDER BY`, **Save**, **Alerts** | trier ; enregistrer la recherche ; y poser une alerte |
| menu du langage (`SQL` ou `Lucene`) | la façon d'écrire la recherche : choisissez **Lucene** |
| la barre de recherche | ce que vous cherchez |
| la plage de temps (icône calendrier) | quand |
| **Run** | lance la recherche (ou appuyez sur Entrée dans la barre de recherche) |
| l'histogramme | combien de résultats par minute, coloré par sévérité |
| **Filters** (à gauche) | les valeurs de chaque champ, cliquez pour filtrer |
| les résultats | une ligne par ligne de log, cliquez pour l'ouvrir |

**Réglez la plage de temps de l'incident.** Cliquez sur la plage de temps (icône calendrier). À gauche, des plages toutes prêtes (de `Last 15 minutes` à `Last 30 days`). À droite, deux onglets :
- **Around a time** : un instant et une durée autour. C'est le plus rapide : **Time** `YYYY-MM-DD 14:20:00` (votre date de Black Friday), **Duration ±** `1h`, puis **Apply**. Vous obtenez 13h20 à 15h20, l'incident avec une heure de trafic normal autour.
- **Time range** : un début et une fin. Tapez le début, cliquez sur le champ de fin (fermez le petit calendrier s'il s'ouvre), tapez la fin, puis **Apply**.

Les deux acceptent aussi des mots simples, en anglais : *last friday at 14:20* fonctionne. La plage reste la même quand vous passez de Search à Chart Explorer et aux dashboards.

Tapez maintenant chaque recherche ci-dessous dans la barre de recherche, appuyez sur Entrée, et regardez :

| Tapez | Ce que vous voyez |
|---|---|
| `SeverityText:ERROR` | l'histogramme des erreurs monte à 13h58, retombe à 14h44 |
| `ServiceName:payment SeverityText:ERROR` | un seul message : le timeout HikariPool |
| `"maximumPoolSize"` | la ligne de démarrage de chaque pod payment : 10 en v2.4.1 |
| `ServiceName:k8s-events -EventName:Unhealthy` | le déploiement progressif (rollout), la pression mémoire sur ip-10-0-3-17, l'OOM kill |
| `"pan="` | les numéros de carte, tous masqués par la passerelle (gateway) du module 2 |

![Search](../../en/img/03_search_errors.png)

- Lucene en bref : `champ:valeur`, `"phrase exacte"`, `-` pour exclure, `*` comme joker, `AND`, `OR`. Un attribut imbriqué s'écrit avec des points : `ResourceAttributes.k8s.pod.name:payment*`.
- Passez le menu du langage sur **SQL** et tapez plutôt une clause `WHERE` : `ResourceAttributes['service.version'] = 'v2.4.1' AND SeverityNumber >= 17` ne montre que les erreurs de la version fautive.
- **Filters** : ouvrez `ServiceName` et cochez `payment` ; ouvrez `ResourceAttributes` pour filtrer sur `service.version`, `k8s.pod.name` ou `service.team` (ajouté par la passerelle au module 2). Faites glisser la souris sur l'histogramme pour zoomer sur quelques minutes.
- **Enregistrer une recherche** : source **PayFlow logs**, recherche `ServiceName:payment SeverityText:ERROR`, cliquez sur **Save** (en haut à droite). La fenêtre **Save Search** montre la requête enregistrée (SELECT, FROM, WHERE, ORDER BY) ; tapez le **Name** `Payment errors`, puis **Save**. Le titre de la page devient *Payment errors*, le bouton **Save** devient **Update** (pour enregistrer une modification), et la recherche apparaît dans **Saved Searches**. Le module 5 y pose une alerte.

### Live tail
Cliquez sur la plage de temps, choisissez **Live Tail** en haut de la liste, videz la barre de recherche : les lignes les plus récentes arrivent en haut, une minute de trafic chaque minute (le flux en direct du module 2). **Resume Live Tail**, au-dessus de l'histogramme, le relance après un défilement ; choisissez de nouveau une plage pour en sortir.

---

## Étape 5 · D'une ligne de log à sa trace, puis à son pod (8 min)

1. Plage : l'incident. Cherchez `ServiceName:checkout SeverityText:ERROR`, cliquez sur une ligne. Un panneau latéral s'ouvre :
   - en haut : le message, le service, l'heure, et l'attribut mis en avant `version` ;
   - des onglets : **Overview** (tous les attributs), **Column Values**, **Service Map**, **Surrounding Context** (les lignes juste avant et juste après), **Infrastructure**.
2. Cliquez sur **View Trace** (en haut à droite) : le waterfall de la requête.
   - la ligne de résumé compte les spans, les logs et les erreurs (`11 spans, 2 logs, 8 errors`) ; **Show** affiche ou masque les spans, les logs et les span events : les lignes de log de la requête sont dessinées dans le waterfall, avec les spans qui les ont écrites ;
   - l'attribut mis en avant `merchant` s'affiche au-dessus du waterfall (étape 3) ;
   - les longues barres rouges finissent sur `INSERT payflow.payments` dans payment : 3 secondes d'attente d'une connexion, puis la ligne de log `HikariPool-1 - Connection is not available` ;
   - cliquez sur une barre : à droite, **Overview** avec l'exception, les breadcrumbs et tous les attributs ;
   - le réseau carte, le ledger et la notification ne se sont jamais exécutés.

   ![Waterfall de la trace](../../en/img/03_trace_waterfall.png)
3. Revenez à la ligne de log, onglet **Infrastructure** : CPU, mémoire et disque du pod qui a écrit la ligne (30 minutes, 1 heure ou 1 jour autour), sa **Pod Timeline** (les événements Kubernetes du pod), et les trois mêmes graphiques pour son nœud. ClickStack les retrouve grâce à l'uid du pod et au nom du nœud de la ligne : les noms de métriques suivent le receiver kubeletstats.
4. Onglet **Service Map** : le chemin de cette requête précise à travers les services. Onglet **Surrounding Context** : les lignes juste avant et juste après, sur le même pod.

---

## Étape 6 · Trois portes d'entrée dans l'incident (15 min)

Une enquête part de ce qui vous arrive en premier. Les trois scénarios ci-dessous atteignent le même incident à partir de trois signaux ; `02_scenarios_de_correlation.sql` exécute chacun en SQL, étape par étape, avec la réponse attendue à chaque étape. Plage : l'incident, pour les trois.

| | Part de | Passe par | Aboutit à |
|---|---|---|---|
| A | un **log** : le ticket d'un marchand | trace, métriques du pod, log de démarrage | `maximumPoolSize=10` sur un pod v2.4.1 |
| B | une **alerte métrique** : le pool sature | métrique par version, traces du pod, leurs logs, événements Kubernetes | le déploiement progressif (rollout) CHG-4117 |
| C | une **trace** : un nouveau message d'erreur | logs du pod, mémoire et débit de requêtes, événements Kubernetes | l'OOM kill sur ip-10-0-3-17, conséquence du premier bug |

### Scénario A · Depuis un log
Un ticket : "marchand m_16523, un paiement a échoué juste après 14h09".
1. **Search**, source **PayFlow logs** : `LogAttributes.merchant_id:m_16523 SeverityText:ERROR`. Une ligne de checkout : "payment service returned 503". checkout ne fait que relayer l'erreur.
2. Ouvrez la ligne, **View Trace** : la barre rouge en bas du waterfall est `INSERT payflow.payments` dans payment, 3 secondes d'attente d'une connexion. Cliquez dessus : dans ses attributs, `k8s.pod.name` est le pod payment.
3. **Chart Explorer** (menu de gauche) : **Data Source** `PayFlow metrics` ; dans la case de la métrique, tapez `hikaricp.connections.pending` et choisissez `hikaricp.connections.pending (Gauge)` ; agrégation **Maximum** ; Where `ResourceAttributes.k8s.pod.name:<le pod>` ; **Run** : des dizaines de requêtes en attente. **Add Series** avec `hikaricp.connections.max` : un pool de 10.
4. Retour dans **Search**, PayFlow logs : `ResourceAttributes.k8s.pod.name:<le pod> "maximumPoolSize"`. Le pod a logué `maximumPoolSize=10` au démarrage, version v2.4.1.

### Scénario B · Depuis une alerte métrique
1. **Chart Explorer**, PayFlow metrics, `hikaricp.connections.pending`, **Maximum**, Group By `ResourceAttributes['k8s.pod.name']`, **Run**. Les 6 pods payment dépassent 20 ensemble à 14h03. C'est ce qu'évalue une alerte sur graphique avec le seuil "au-dessus de 20" : **Add alert**, sous la série, ouvre le formulaire d'alerte (le module 5 la crée).

   ![Pool pending par pod](../../en/img/03_chart_pool_pending.png)
2. Changez la métrique pour `hikaricp.connections.max` et le Group By pour `ResourceAttributes['service.version']` : 50 pour v2.4.0, 10 pour v2.4.1.
3. **Search**, source **PayFlow traces**, plage de 14h03 à 14h04 : `ResourceAttributes.k8s.pod.name:<le pire pod> SpanKind:Server StatusCode:Error`. Ouvrez une trace : ses logs s'affichent avec ses spans (payment tombe en timeout, checkout renvoie une 503, la gateway la retourne).
4. **Search**, PayFlow logs : `ServiceName:k8s-events EventName:ScalingReplicaSet`. "rolling update CHG-4117" à 13h58 : de l'alerte au changement en quatre écrans.

### Scénario C · Depuis une trace
14h25. Le pool est compris et un retour arrière (rollback) se prépare, mais une trace montre une autre erreur.
1. **Search**, source **PayFlow traces**, plage autour de 14:20 ± 5m : `StatusCode:Error SpanKind:Server`. Dans **Analysis Mode**, cliquez sur **Event Patterns** et tapez `StatusMessage` dans **Pattern Expression** : les messages d'erreur, regroupés, chacun avec sa tendance. L'un est nouveau : "connect: connection refused" sur `fraud.ScoreTransaction`, uniquement à partir de 14:21:07.
2. Ouvrez l'une de ces traces : checkout appelle fraud-scoring, qui refuse la connexion. Le span donne le pod et le nœud (`ip-10-0-3-17`). Sur une ligne de log de fraud-scoring, onglet **Infrastructure** : la mémoire du pod grimpe jusqu'à 2,2 Go, puis retombe ; le nœud est plein.
3. **Search**, PayFlow logs : `ServiceName:fraud-scoring -SeverityText:INFO -"score="`. La file grossit, le cache de features approche sa limite de 2 GiB, un timeout FATAL du worker.
4. **Search**, PayFlow logs : `ServiceName:k8s-events "ip-10-0-3-17"` : pression mémoire à 14h19, l'OOM kill à 14h21, le nœud de retour à 14h23. Dans **Chart Explorer**, PayFlow traces, un count avec le filtre `ServiceName:fraud-scoring SpanKind:Server` : le débit de requêtes double à partir de 13h55, parce que checkout fait de nouveau scorer chaque retry d'un paiement échoué. Pas un second bug : le même. Le rollback de 14h42 règle les deux.

---

## Étape 7 · En dessous (10 min)

Lancez `01_sous_le_capot.sql` dans la console SQL :
- la même recherche en SQL, et `EXPLAIN indexes = 1` pour voir l'index texte sauter les granules qui ne contiennent pas le mot ;
- un filtre sur un attribut, résolu par l'index texte de `ResourceAttributeItems`, sans lire la map ;
- la corrélation log → trace → métriques, en trois requêtes ;
- le live tail, un simple `ORDER BY Timestamp DESC`.

Puis `02_scenarios_de_correlation.sql` : les trois scénarios, chacun en 4 ou 5 requêtes. Les clés sont toujours les mêmes : `TraceId` entre logs et traces, les attributs de ressource (`k8s.pod.name`, `k8s.node.name`, `service.version`) vers les métriques, et une plage de temps bornée (la table de recherche des traces donne les bornes d'une trace).

Checkpoint : `OK` partout, dans les deux fichiers.
