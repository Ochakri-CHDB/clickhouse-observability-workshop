# Module 7 · Échelle et coût

PayFlow tourne dans 8 régions. Ce module fait passer les logs à **875 millions de lignes**, mesure ce que ClickHouse en fait, puis s'attaque à la facture : agrégats (rollups), rétention, échantillonnage.

Durée : 35 min. Trois fichiers SQL, puis une étape dans ClickStack.

| Fichier | Contenu |
|---|---|
| `01_milliard_de_lignes.sql` | deux semaines x 8 régions de logs, écrites en 8 instructions de ~30 s ; stockage et compression par colonne |
| `02_recherche_et_index.sql` | index texte, bloom filter, accès par trace borné dans le temps, projection, cache de requêtes, query condition cache, 3 répliques : chaque requête avec et sans son accélérateur |
| `03_agregats_retention_echantillonnage.sql` | un agrégat (rollup) dans la convention de ClickStack, le coût de chaque signal par jour, les politiques de TTL, le head sampling et l'échantillonnage à la rétention, le dimensionnement |

> Laissez quelques minutes au service après les 8 insertions de `01_milliard_de_lignes.sql` : tant que les merges tournent en arrière-plan, les requêtes du fichier 02 sont 2 à 3 fois plus lentes, et les parallel replicas apportent peu.

---

## Dans ClickStack · Laisser ClickStack utiliser l'agrégat (10 min)

`03_agregats_retention_echantillonnage.sql` crée `payflow_otel.otel_traces_1m` : par minute, service, nom de span et statut, avec les colonnes d'agrégat nommées `count`, `avg__Duration`, `max__Duration`, `quantiles__Duration`. ClickStack peut s'en servir pour répondre aux graphiques, aux tuiles de dashboard et aux alertes, sans les modifier.

1. **Team Settings**, **Sources**, ouvrez **PayFlow traces**, **Edit configuration**, section **Materialized views**, **Add materialized view**.
2. Base `payflow_otel`, table `otel_traces_1m`. ClickStack déduit l'horodatage (`Timestamp`), les dimensions (`ServiceName`, `SpanName`, `StatusCode`) et les métriques ; vérifiez que `Duration` correspond bien à `avg__Duration`, `max__Duration` et `quantiles__Duration`.
3. Granularité : **1 minute**. Date minimale : `2026-11-27 00:00:00` (l'historique chargé par le fichier).
4. Save. Ouvrez la tuile *Latence p99 par service* de `PayFlow · SRE` sur une journée complète : un indicateur montre que le graphique a été servi par la vue matérialisée.

Règles bonnes à connaître :
- la granularité du graphique doit être un multiple de celle de la vue (vue à 1 min : graphiques à 1, 5, 15, 60 min) ;
- une vue ne contient que ce qui a été inséré après sa création : chargez l'historique, ou fixez la date minimale ;
- commencez par un agrégat par source (comptage et durée par service), une dizaine au maximum.

## Isolation lecture et écriture (à connaître, pas à faire)

Avec un **warehouse**, ClickStack peut tourner sur un second service, en lecture seule, qui partage le même stockage : les dashboards, les alertes et les notebooks ne ralentissent jamais l'ingestion, et chacun passe à l'échelle indépendamment. ClickStack le recommande au-delà d'environ 100 To par mois.
