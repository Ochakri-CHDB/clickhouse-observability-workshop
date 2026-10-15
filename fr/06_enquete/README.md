# Module 6 · L'enquête : Black Friday, 14h00

La page (l'alerte qui réveille l'astreinte) est tombée à 14h00 : *POST /v1/payments: error budget burning 19x faster than allowed*. Vous avez ClickStack et la console SQL. Trouvez ce qui a cassé, pourquoi, qui est touché et combien ça a coûté.

Durée : 45 min.
- Partie 1 (25 min) : le parcours ClickStack ci-dessous.
- Partie 2 (20 min) : `01_carte_et_motifs.sql` et `02_incident_en_sql.sql`, les mêmes réponses en SQL, avec l'impact métier.

> Plage pour tout le module : **l'incident**, `2026-11-27 13:30` à `2026-11-27 15:00` (UTC).

---

## Étape 1 · C'est grave à quel point, et où ? La carte des services (5 min)

Ouvrez **Service Map** (menu de gauche), source **PayFlow traces**, plage **l'incident**.
- Chaque nœud est un service (`service.name`), chaque arête un span client apparié à un span serveur.
- La taille du nœud, c'est le trafic ; le rouge, ce sont les erreurs. `api-gateway`, `checkout` et `payment` sont rouges ; `ledger`, `card-network-adapter` et `notification` ne le sont pas, parce que les requêtes en échec ne les ont jamais atteints.
- Sur un gros volume, baissez le **sampling slider** (curseur d'échantillonnage) : la carte se charge plus vite et reste juste.

## Étape 2 · Que disent les erreurs ? Event Patterns (5 min)

**Search**, source **PayFlow logs**, `SeverityText:ERROR`. Dans **Analysis Mode**, choisissez **Event Patterns**.
- Des millions de lignes se réduisent à une poignée de motifs ; ClickStack remplace pour vous les parties variables (identifiants, nombres).
- Le motif en tête est le timeout HikariPool dans `payment`. Les suivants (checkout "payment failed: payment service returned 503", les 503 de la gateway) ne font que le relayer.
- Restreignez d'abord à un seul service (`ServiceName:payment`) : les motifs marchent mieux sur un ensemble étroit.

## Étape 3 · Qu'ont en commun les spans lents ? Event Deltas (5 min)

**Search**, source **PayFlow traces**, `ServiceName:payment SpanKind:Client`. **Analysis Mode**, **Event Deltas**.
- La heatmap montre deux populations : la bande normale autour de 5 ms, et une bande plate à 3 000 ms (un timeout fixe laisse exactement cette signature).
- Tracez un rectangle autour de la bande des 3 000 ms. Les graphiques d'attributs la comparent (Selection, en orange) à tout le reste (Background, en vert), la plus grande différence en premier.
- `ResourceAttributes['service.version']` ressort : les spans lents sont tous en **v2.4.1**. Cliquez sur la barre, **Filter**, et la heatmap se redessine sur la seule version fautive.

## Étape 4 · Qu'est-ce qui a changé ? Les Release markers et les logs de démarrage (5 min)

- Sur le dashboard `PayFlow · SRE` (module 4), **Show release markers** : v2.4.1 apparaît à 13h58, exactement là où le p99 décolle.
- **Search** `"maximumPoolSize"` : les pods v2.4.1 ont démarré avec `maximumPoolSize=10`, les pods v2.4.0 avec 50. La note du changement CHG-4117 disait "pool size 50 to 10".
- Ouvrez une trace en échec, onglet **Infrastructure** : CPU bas, le pod attend des connexions. Chart Explorer, métrique `hikaricp.connections.pending` par `service.version` : v2.4.1 met des dizaines de threads en file d'attente.

## Étape 5 · Le second feu (3 min)

**Search** `ServiceName:k8s-events SeverityText:WARN -EventName:Unhealthy` : pression mémoire sur ip-10-0-3-17 à 14h19, puis le worker fraud-scoring tué par OOM à 14:21:07. Chart Explorer, `k8s.pod.memory.working_set` avec `k8s.node.name:ip-10-0-3-17`, groupé par `k8s.pod.name` : la mémoire monte avec les nouvelles tentatives des clients, puis tombe à 0. Une conséquence de l'incident, pas sa cause.

## Étape 6 · Demander à une IA de le faire (2 min)

Si les **Notebooks** sont activés (module 8), ouvrez un nouveau notebook et demandez : *"Pourquoi POST /v1/payments a-t-il échoué entre 13h58 et 14h45 le 27 novembre 2026 ?"* Regardez l'agent interroger les sources, tuile par tuile, et comparez sa conclusion à la vôtre.

---

## Partie 2 · La même enquête en SQL (20 min)

- `01_carte_et_motifs.sql` : la carte des services et les motifs de logs, calculés par des vues rafraîchissables, avant et pendant l'incident.
- `02_incident_en_sql.sql` : dix questions, de la page à la cause racine, la trace sous forme d'arbre (CTE récursive), le changement en place pour chaque erreur, le second feu, et **l'impact métier** : paiements échoués, euros, marchands.

La dernière requête construit la chronologie du postmortem à partir de tous les signaux à la fois.
