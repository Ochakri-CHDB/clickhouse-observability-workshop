# Module 3 · Recherche et corrélation dans ClickStack

Les données sont dans les tables OpenTelemetry : la journée du Black Friday, et un flux en direct qui ajoute une minute de trafic chaque minute. Vous les regardez maintenant comme le fait un ingénieur d'astreinte, dans **ClickStack**, l'interface d'observabilité de ClickHouse (HyperDX), intégrée à ClickHouse Cloud. Ensuite, trois scénarios d'enquête passent d'un signal aux autres, et deux fichiers SQL montrent ce que ClickStack exécute pour vous.

Durée : 45 min.

| Fichier | Contenu |
|---|---|
| `01_sous_le_capot.sql` | la recherche en SQL, les index texte et EXPLAIN, du log à la trace puis aux métriques du pod, le live tail |
| `02_scenarios_de_correlation.sql` | trois enquêtes : depuis un log, depuis une alerte métrique, depuis une trace |

> ClickStack évolue vite : un libellé peut changer de place. Le principe, lui, ne change pas. Deux plages de temps comptent dans ce module : **l'incident**, une plage absolue de `2026-11-27 13:45` à `2026-11-27 15:00` (UTC), et **le flux en direct**, `Last 15 minutes`.

---

## Étape 1 · Ouvrir ClickStack et vérifier les sources (5 min)

1. Dans la console Cloud, ouvrez votre service, puis **ClickStack** dans le menu de gauche.
2. ClickStack cherche des tables OpenTelemetry. Les nôtres sont dans la base `payflow_otel`, pas dans `default` : allez dans **Team Settings**, puis **Sources**, et créez (ou modifiez) une source par signal.

| Paramètre | Logs | Traces | Métriques |
|---|---|---|---|
| Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
| Source Data Type | Log | Trace | Metrics |
| Server Connection | `Default` | `Default` | `Default` |
| Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
| Table | `otel_logs` | `otel_traces` | Gauge `otel_metrics_gauge`, Histogram `otel_metrics_histogram`, Sum `otel_metrics_sum` |

Comme les tables suivent exactement le schéma de l'exporteur, ClickStack remplit seul toutes les expressions de colonnes (Timestamp, ServiceName, SeverityText, Body, TraceId, SpanId, Duration...).

3. Reliez les sources entre elles, pour passer d'un signal à l'autre en un clic (**sources corrélées**) :
   - sur **PayFlow logs** : *Correlated Trace Source* `PayFlow traces`, *Correlated Metric Source* `PayFlow metrics` ;
   - sur **PayFlow traces** : *Correlated Log Source* `PayFlow logs`, *Correlated Metric Source* `PayFlow metrics`.
4. Facultatif, sur **PayFlow traces** : ajoutez un **Highlighted Trace Attribute** `SpanAttributes['merchant.id']`. Il s'affiche au-dessus de chaque waterfall de trace.

---

## Étape 2 · Search (10 min)

Ouvrez **Search**, source **PayFlow logs**, plage **l'incident**. La barre de recherche parle Lucene par défaut ; un bouton la bascule en SQL (n'importe quelle clause `WHERE`).

| Tapez | Ce que vous voyez |
|---|---|
| `SeverityText:ERROR` | l'histogramme des erreurs bondit à 13h58 et retombe à 14h44 |
| `ServiceName:payment SeverityText:ERROR` | un seul message : le timeout HikariPool |
| `"maximumPoolSize"` | la ligne de démarrage de chaque pod payment : 10 en v2.4.1, 50 avant et après |
| `ServiceName:k8s-events -EventName:Unhealthy` | le déploiement progressif (rollout), la pression mémoire sur ip-10-0-3-17, l'OOM kill |
| `"pan="` | les numéros de carte, tous masqués par la passerelle (gateway) du module 2 |
| Mode SQL : `ResourceAttributes['service.version'] = 'v2.4.1' AND SeverityNumber >= 17` | uniquement les erreurs de la version fautive |

- Cliquez sur un champ du panneau de gauche (`service.version`, `k8s.pod.name`, `service.team`) pour filtrer dessus. `service.team` et `cloud.availability_zone` ont été ajoutés par la passerelle (module 2).
- Faites glisser la souris sur l'histogramme pour zoomer sur une plage de temps.
- Enregistrez (**Save**) la recherche `ServiceName:payment SeverityText:ERROR` sous le nom `Payment errors`, avec le tag `payments`. Le module 5 y pose une alerte.

### Live tail
Passez la plage à `Last 15 minutes` et activez **Live tail** : le flux du module 2 défile, une minute de trafic par minute.

---

## Étape 3 · D'une ligne de log à sa trace, puis à son pod (10 min)

1. Plage **l'incident**, recherchez `ServiceName:checkout SeverityText:ERROR`, ouvrez une ligne.
2. Le panneau latéral affiche la ligne et ses attributs. Ouvrez l'onglet **Trace** : le waterfall de la requête, retrouvé grâce au `TraceId`.
   - 3 secondes passées dans `INSERT payflow.payments`, l'exception HikariPool sous forme de span event ;
   - le réseau carte, le ledger et la notification ne se sont jamais exécutés.
3. Ouvrez l'onglet **Infrastructure** : le CPU et la mémoire du pod qui a servi la requête, tirés de la source de métriques et rapprochés sur `k8s.pod.name`. Le pod ne travaille pas : il attend.
4. Sur une trace, la petite **service map** au-dessus du waterfall montre le chemin de cette requête précise.

---

## Étape 4 · Trois chemins vers l'incident (15 min)

Une enquête part de ce qui vous arrive en premier. Les trois scénarios ci-dessous atteignent le même incident depuis trois signaux ; `02_scenarios_de_correlation.sql` déroule chacun en SQL, étape par étape, avec la réponse attendue à chaque étape. Plage **l'incident** pour les trois.

| | Part de | Passe par | Aboutit à |
|---|---|---|---|
| A | un **log** : le ticket d'un marchand | trace, métriques du pod, log de démarrage | `maximumPoolSize=10` sur un pod v2.4.1 |
| B | une **alerte métrique** : le pool sature | métrique par version, traces du pod, leurs logs, événements Kubernetes | le déploiement progressif (rollout) CHG-4117 |
| C | une **trace** : un nouveau message d'erreur | logs du pod, mémoire et débit de requêtes, événements Kubernetes | l'OOM kill sur ip-10-0-3-17, conséquence du premier bug |

### Scénario A · Depuis un log
14h12, un ticket : « marchand m_16523, un paiement a échoué juste après 14h09 ».
1. **Search**, source **PayFlow logs** : `LogAttributes.merchant_id:m_16523 SeverityText:ERROR`. Une ligne de checkout : "payment service returned 503". checkout ne fait que relayer l'erreur.
2. Ouvrez la ligne, onglet **Trace** : le span rouge en bas du waterfall est `INSERT payflow.payments` dans payment, 3 secondes à attendre une connexion. Cliquez dessus : ses attributs de ressource donnent le pod payment.
3. **Chart Explorer**, source **PayFlow metrics**, jauge `hikaricp.connections.pending` puis `hikaricp.connections.max`, filtre `k8s.pod.name` = ce pod : des dizaines de requêtes en attente, un pool de 10.
4. Retour dans **Search**, logs : `ResourceAttributes.k8s.pod.name:<le pod> "maximumPoolSize"`. Le pod a écrit `maximumPoolSize=10` au démarrage, version v2.4.1.

### Scénario B · Depuis une alerte métrique
1. **Chart Explorer**, source **PayFlow metrics**, jauge `hikaricp.connections.pending`, agrégation **Max**, group by `ResourceAttributes['k8s.pod.name']`, granularité 1 minute. Les 6 pods payment passent 20 ensemble à 14h03 : c'est ce qu'évalue une alerte sur graphique avec le seuil "au-dessus de 20" (le module 5 la crée).
2. Passez le group by à `ResourceAttributes['service.version']` et tracez `hikaricp.connections.max` : 50 pour v2.4.0, 10 pour v2.4.1. Activez **Show release markers**.
3. **Search**, source **PayFlow traces**, plage 14h03 à 14h04 : `ResourceAttributes.k8s.pod.name:<le pire pod> SpanKind:Server StatusCode:Error`. Ouvrez une trace : les logs de la requête apparaissent avec ses spans (payment expire, checkout signale une 503, la gateway la renvoie).
4. **Search**, logs : `ServiceName:k8s-events EventName:ScalingReplicaSet`. "rolling update CHG-4117" à 13h58 : de l'alerte au changement en quatre écrans.

### Scénario C · Depuis une trace
14h25. Le pool est compris et un retour arrière (rollback) se prépare, mais une trace montre une autre erreur.
1. **Search**, source **PayFlow traces**, plage 14h15 à 14h25 : `StatusCode:Error SpanKind:Server -StatusMessage:"HikariPool"`. Groupez par `StatusMessage` (**Analysis Mode**, ou un tableau dans **Chart Explorer**) : "connect: connection refused" sur `fraud.ScoreTransaction`, à partir de 14:21:07 seulement.
2. Ouvrez une de ces traces : checkout appelle fraud-scoring, qui refuse la connexion. Le span donne le pod et le nœud (`ip-10-0-3-17`). Onglet **Infrastructure** : la mémoire du pod monte à 2,2 Go, puis retombe.
3. **Search**, logs : `ServiceName:fraud-scoring -SeverityText:INFO -"score="`. La file grossit, le cache de features approche sa limite de 2 Gio, un worker timeout FATAL.
4. **Search**, logs : `ServiceName:k8s-events "ip-10-0-3-17"` : pression mémoire à 14h19, l'OOM kill à 14h21, le nœud revenu à 14h23. Tracez le débit de requêtes de fraud-scoring : il double à partir de 13h55, car checkout fait scorer à nouveau chaque nouvel essai d'un paiement en échec. Pas un second bug : le même. Le rollback de 14h42 règle les deux.

---

## Étape 5 · En dessous (10 min)

Lancez `01_sous_le_capot.sql` dans la console SQL :
- la même recherche en SQL, et `EXPLAIN indexes = 1` pour voir l'index texte sauter les granules qui ne contiennent pas le mot ;
- un filtre sur un attribut, résolu par l'index texte de `ResourceAttributeItems`, sans lire la map ;
- la corrélation log → trace → métriques, en trois requêtes ;
- le live tail, un simple `ORDER BY Timestamp DESC`.

Puis `02_scenarios_de_correlation.sql` : les trois scénarios, chacun en 4 ou 5 requêtes. Les clés sont toujours les mêmes : `TraceId` entre logs et traces, les attributs de ressource (`k8s.pod.name`, `k8s.node.name`, `service.version`) vers les métriques, et une plage de temps bornée (la table de recherche des traces donne les bornes d'une trace).

Checkpoint : `OK` partout, dans les deux fichiers.
