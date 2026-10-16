# Module 6 · L'enquête : Black Friday, 14h00

La page (l'alerte qui réveille l'astreinte) est tombée à 14h00 : *POST /v1/payments: error budget burning 19x faster than allowed*. Vous avez ClickStack et la console SQL. Trouvez ce qui a cassé, pourquoi, qui est touché et combien ça a coûté.

Durée : 45 min.
- Partie 1 (25 min) : le parcours ClickStack ci-dessous, un écran par question.
- Partie 2 (20 min) : `01_carte_et_motifs.sql` et `02_incident_en_sql.sql`, les mêmes réponses en SQL, avec l'impact métier.

> Plage pour tout le module : **l'incident**. Dans la plage de temps : **Around a time**, Time `YYYY-MM-DD 14:20:00` (votre date de Black Friday, `SELECT pf_black_friday()`, module 3 étape 0), Duration ± `1h`, **Apply**. Toutes les heures sont en UTC (module 3, étape 2).

---

## Étape 1 · C'est grave à quel point, et où ? La carte des services (5 min)

1. Menu de gauche, **Service Map** (bêta).
2. En haut à gauche, la source : **PayFlow traces**. En haut à droite, la plage de temps : **Around a time**, `14:30:00`, ± `15m` (le cœur de l'incident).
3. Lisez la carte :
   - chaque cercle est un service (`service.name`), chaque ligne pointillée un appel : un span client apparié au span serveur qu'il a appelé ;
   - la légende (en haut à droite) a trois onglets. **Error rate** : gris, aucune erreur ; rouge foncé, 5 % ou plus. **Latency** et **Throughput** colorent selon les deux autres signaux. La taille d'un cercle, c'est toujours le trafic.
4. Sur **Error rate** : `api-gateway`, `checkout` et `payment` sont rouge foncé. `ledger` et `notification` sont gris : les paiements en échec ne les ont jamais atteints. `fraud-scoring` est rouge aussi : gardez-le pour l'étape 5.
5. Passez la légende sur **Latency** (le p95) : les trois mêmes services foncent, environ 3 s, les autres restent clairs. **All Services** (en haut à gauche) restreint la carte à un service et à ses voisins ; la case Lucene filtre les spans à partir desquels la carte est construite (essayez `SpanAttributes['merchant.id']:m_00042`).
6. **Sampling** (en haut) : la carte est construite à partir d'un échantillon des traces, 10 % par défaut. Baissez le curseur sur un gros jeu de données : la carte se charge plus vite et reste juste.

![Service map](../../en/img/06_service_map.png)

## Étape 2 · Que disent les erreurs ? Event Patterns (5 min)

1. **Search**, source **PayFlow logs**, recherche `SeverityText:ERROR`, plage **l'incident**, **Run**.
2. Colonne de gauche, **Analysis Mode** : cliquez sur **Event Patterns** (au lieu de **Results Table**).
3. Des dizaines de milliers de lignes se réduisent à une poignée de motifs. ClickStack remplace les parties variables (adresses IP, identifiants, nombres) par `<*>`. Pour chaque motif : une **Trend** (un petit histogramme sur la plage), un **Count**, le **Level**.
4. Lisez de haut en bas : les lignes d'accès de la gateway (`POST /v1/<*> ... 503`), puis le **timeout HikariPool-1** dans payment, puis checkout "payment failed: payment service returned <*>". La gateway et checkout ne font que relayer ce que dit payment : la ligne HikariPool est celle à suivre.
5. Restreignez : cliquez sur `payment` sous **ServiceName** dans les filtres. Il reste un seul motif, le timeout du pool.
6. **Pattern Expression** (au-dessus du tableau) change ce qui est regroupé : `Body` par défaut ; tapez `ServiceName` pour compter plutôt par service.

![Event patterns](../../en/img/06_event_patterns.png)

## Étape 3 · Qu'ont en commun les spans lents ? Event Deltas (5 min)

1. **Search**, source **PayFlow traces**, recherche `ServiceName:payment`, plage **l'incident**, **Run**.
2. **Analysis Mode**, **Event Deltas** (traces uniquement).
3. La heatmap : le temps en abscisse, la durée en ordonnée (échelle log), la couleur pour le nombre de spans. Avant 13h58, les spans se tiennent dans deux bandes, quelques ms (les appels à la base) et 100 à 300 ms (les appels de paiement). De 13h58 à 14h42, un bloc monte entre 1 et 3 s, avec un sommet plat à 3 000 ms : un timeout fixe laisse exactement cette signature. Tant que vous n'avez rien sélectionné, les graphiques du dessous affichent *Select an area on the chart above to enable comparisons*. (L'axe de ce graphique est dans l'heure locale de votre navigateur, pas en UTC.)
4. **Tracez un rectangle** autour du bloc lent. En dessous, un graphique par attribut compare la sélection (**Selection**, en orange) à tout le reste (**Background**, en vert), les attributs les plus différents en premier. Survolez une barre pour voir ses pourcentages exacts.
5. Trouvez `ResourceAttributes.service.version` parmi les premiers graphiques : la sélection est à 100 % en **v2.4.1**, le fond surtout en v2.4.0 (59 %). Autour : `k8s.pod.name` ne montre que les six pods `payment-5c8b...`, `payment.status` `failed`, `StatusCode` `Error`.
6. Cliquez sur la barre **v2.4.1** : une petite fenêtre s'ouvre avec trois icônes, **Filter for this value**, **Exclude this value** et copier. **Filter for this value** : la recherche et la heatmap se redessinent sur la seule version fautive. **Exclude this value** montre le reste : les pods v2.4.0, avant 13h58 et après 14h42, sans le bloc lent.

![Event deltas](../../en/img/06_event_deltas.png)

## Étape 4 · Qu'est-ce qui a changé ? Les Release markers et les logs de démarrage (5 min)

1. **Dashboards**, **PayFlow · SRE** (module 4), plage **l'incident**, menu **⋮** (en haut à droite), **Show release markers** : une ligne pointillée `v2.4.1` à 13h58, exactement là où le p99 décolle.
2. **Search**, source **PayFlow logs**, recherche `"maximumPoolSize"`, plage **l'incident**. Six lignes à partir de 13h58 (les six pods v2.4.1 qui démarrent, un toutes les 30 s) disent `maximumPoolSize=10` ; ouvrez-en une, sa pastille **version** indique `v2.4.1`. Six lignes à partir de 14h42, le rollback vers v2.4.0, disent 50. Plage `Last 30 days` : les pods v2.4.0 de la livraison dix jours plus tôt disaient 50 eux aussi.
3. Le changement : dans la console SQL, `SELECT * FROM payflow_inventory.deployment_history WHERE deployment = 'payment' ORDER BY valid_from`. CHG-4117, j.martin, 13h58 : "pool size 50 to 10".
4. Côté ressources : ouvrez une trace en échec (module 3, étape 5), onglet **Infrastructure**. CPU bas, mémoire stable : le pod n'est pas occupé, il attend des connexions.
5. La preuve dans les métriques : **Chart Explorer**, **PayFlow metrics**, **Maximum** de `hikaricp.connections.pending (Gauge)`, **Group By** `ResourceAttributes['service.version']`, **Run** : v2.4.1 met des dizaines de threads en file d'attente, v2.4.0 aucun.

## Étape 5 · Le second feu (3 min)

1. **Search**, source **PayFlow logs**, recherche `ServiceName:k8s-events SeverityText:WARN -EventName:Unhealthy`, plage **l'incident**. Quatre événements, lisez la colonne **EventName** : `NodeHasInsufficientMemory` sur le nœud `ip-10-0-3-17` à 14:19:31, `OOMKilling` du worker fraud-scoring à 14:21:07, `BackOff` (le conteneur redémarre, `OOMKilled, exit code 137`), et `NodeHasSufficientMemory` à 14:23:40.
2. **Chart Explorer**, **PayFlow metrics**, **Maximum** de `k8s.pod.memory.usage (Gauge)`, **Where** `ResourceAttributes['k8s.node.name']:ip-10-0-3-17`, **Group By** `ResourceAttributes['k8s.pod.name']`, **Run** : le pod fraud-scoring grimpe avec les retries des clients (son trafic x2,2), puis chute au redémarrage.
3. Ouvrez l'un des spans "connection refused" de 14h21 (module 3, scénario C), onglet **Infrastructure** : les graphiques du pod (CPU, mémoire, disque) autour de l'erreur, et la **Pod Timeline**, les événements Kubernetes de ce pod.

Une conséquence de l'incident (les retries), pas sa cause. Les deux vont dans le postmortem.

## Étape 6 · Demander à une IA de le faire (2 min)

Menu de gauche, **AI notebooks** (bêta), **New Private Notebook**. Dans **Ask AI to explore your data**, tapez, avec votre date de Black Friday :

*Pourquoi POST /v1/payments a-t-il échoué entre 13h58 et 14h45 UTC le YYYY-MM-DD ? Utilise les sources PayFlow.*

Regardez-le ajouter des blocs (recherches, graphiques) l'un après l'autre, puis comparez sa conclusion à la vôtre. La fonctionnalité est en bêta : si aucun bloc n'apparaît, ajoutez-les à la main avec **Manual Block** (Search, Chart, Table, Markdown) et gardez le notebook comme trace écrite de votre enquête. Le module 8 montre les mêmes questions posées via MCP.

---

## Partie 2 · La même enquête en SQL (20 min)

- `01_carte_et_motifs.sql` : la carte des services et les motifs de logs, calculés par des vues rafraîchissables, avant et pendant l'incident.
- `02_incident_en_sql.sql` : dix questions, de la page à la cause racine, la trace sous forme d'arbre (CTE récursive), le changement en place pour chaque erreur, le second feu, et **l'impact métier** : paiements échoués, euros, marchands.

La dernière requête construit la chronologie du postmortem à partir de tous les signaux à la fois.
