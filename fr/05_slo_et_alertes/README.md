# Module 5 · SLO et alertes : casser la production, se faire réveiller

Une alerte, c'est une requête lancée à intervalle régulier et comparée à un seuil. `01_burn_rate_slo.sql` construit en SQL la méthode SRE (budget d'erreur, taux de consommation ou burn rate, multi-fenêtre). Ce README construit les alertes ClickStack, puis **vous cassez la production exprès** et les regardez se déclencher, sur le flux en direct du module 2.

Durée : 30 min. Lancez d'abord `01_burn_rate_slo.sql` (checkpoint `OK`).

---

## Étape 1 · Où envoyer les alertes (5 min)

Une alerte a besoin d'une destination (un **webhook**). Dans ClickHouse Cloud, ClickStack peut envoyer vers Slack (URL de webhook ou API Slack), PagerDuty, ou n'importe quel endpoint HTTP.

Pour le workshop, utilisez un webhook générique qui se contente d'afficher ce qu'il reçoit :
1. Ouvrez [webhook.site](https://webhook.site) dans un nouvel onglet et copiez votre URL unique.
2. Dans ClickStack, pendant la création de la première alerte ci-dessous, choisissez **Add New Webhook**, type **Generic**, collez l'URL. Le corps peut utiliser `{{title}}`, `{{body}}` et `{{link}}`.

En production : un canal Slack par équipe, PagerDuty pour les pages (les alertes qui réveillent l'astreinte).

---

## Étape 2 · Trois alertes (10 min)

Les alertes sont évaluées sur l'heure courante : elles surveillent le **flux en direct**. Réglez la plage sur `Last 15 minutes`.

| Alerte | Comment | Condition |
|---|---|---|
| **Search alert** sur la recherche enregistrée `Payment errors` (module 3) | **Search**, ouvrez la recherche enregistrée, **Alerts** (en haut à droite) | plus de 50 lignes en 1 minute, **grouped by** `ServiceName` : une alerte par service |
| **Chart alert** sur la tuile p99 de `PayFlow · SRE` (module 4) | ouvrez le menu de la tuile, **Add Alert** | p99 au-dessus de 1000 ms pendant 1 minute |
| **SQL alert** sur une tuile SQL | une tuile SQL de type Line, puis **Add Alert** ; la dernière colonne numérique est la valeur | le burn rate des 5 dernières minutes au-dessus de 14,4 (requête ci-dessous) |

La tuile SQL de la troisième alerte (elle a besoin de la macro `$__timeInterval`) :

```sql
SELECT
    $__timeInterval(minute) AS ts,
    sum(errors) / greatest(sum(requests), 1) / 0.0005 AS burn_rate
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND $__timeFilter(minute)
GROUP BY ts
ORDER BY ts
```

Avant d'enregistrer, ClickStack trace le seuil par-dessus les données : vérifiez que le flux en direct, en mode normal, reste en dessous.

---

## Étape 3 · Casser la production (10 min)

Le flux en direct rejoue une heure calme. Basculez l'interrupteur de panne : il rejoue alors les pires minutes du Black Friday, avec les pods v2.4.1 fautifs.

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (1, 'deploy payment v2.4.1');
```

En une à deux minutes :
- **Search** (Live tail activé) : les timeouts HikariPool défilent ;
- les trois alertes passent au rouge dans **Alerts** (menu de gauche), chaque évaluation est une barre de l'historique de l'alerte ;
- votre page webhook reçoit les notifications, avec un lien de retour vers ClickStack ;
- le dashboard `PayFlow · SRE` sur `Last 15 minutes` : le p99 grimpe à 3 s, les release markers montrent l'arrivée de la v2.4.1.

En SQL, les vues rafraîchissables de `01_burn_rate_slo.sql` voient la même chose :

```sql
SELECT ts, rule, state, summary FROM payflow_sre.alerts WHERE ts BETWEEN now() - INTERVAL 15 MINUTE AND now() ORDER BY ts
```

Puis faites le retour arrière (rollback) :

```sql
INSERT INTO payflow_sim.chaos (enabled, note) VALUES (0, 'rollback');
```

Les alertes se résolvent dès que les fenêtres se vident : le burn rate sur 5 minutes d'abord, les autres en quelques minutes.

---

## Étape 4 · Ce qui fait une bonne alerte (5 min)

- **Alerter sur les symptômes, enquêter sur les causes** : la page, c'est le burn rate de ce que ressentent les clients (les paiements en échec), pas le CPU d'un pod.
- **Deux fenêtres** : la fenêtre de 1 h ignore les pics isolés, celle de 5 min lève l'alerte vite après la correction.
- **Group by** pour obtenir une alerte par service, et l'envoyer à l'équipe qui en est propriétaire (`service.team`).
- Dans ClickStack, les alertes peuvent s'appuyer sur les agrégats (rollups) déclarés sur une source (module 7) : une alerte sur un mois de données reste peu coûteuse.
