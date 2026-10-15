# Module 8 · ClickStack, dashboards, API et ClickHouse Agents

Jusqu'ici, tout était en SQL. Ce module montre la même investigation telle qu'un SRE la vit, dans la console ClickHouse Cloud :

| Partie | Pour qui | Quoi | Durée |
|---|---|---|---|
| 1. ClickStack | l'ingénieur d'astreinte | chercher dans les logs, ouvrir des traces, tracer des métriques, construire un dashboard et une alerte, sur les tables des modules 3 à 5 | 35 min |
| 2. Dashboard dans la console SQL | le responsable d'équipe | 4 tuiles sur les tables gold | 10 min |
| 3. API de statut | la page de statut de PayFlow | un Query API endpoint sur la table des SLO | 10 min |
| 4. ClickHouse Agents | tout le monde | questions en français courant, dashboards à la demande, détection d'anomalies en Python | 25 min |

Aucun fichier à exécuter dans ce module : toutes les requêtes sont ci-dessous, prêtes à coller.

> Les données du workshop sont datées du **vendredi 27 novembre 2026, en UTC**. Chaque sélecteur de période de ce module doit être réglé sur une **plage absolue**, par exemple `2026-11-27 13:45` à `2026-11-27 15:00` (UTC). "Last 15 minutes" n'affiche rien.
>
> ClickStack et ClickHouse Agents évoluent vite : un libellé de bouton peut changer de place. Le principe, lui, ne change pas.

---

## 1. ClickStack : l'incident, en quelques clics

ClickStack est la stack d'observabilité de ClickHouse : son interface (HyperDX) tourne dans ClickHouse Cloud et interroge directement votre service. Rien à installer : les tables du module 3 suivent déjà le schéma OpenTelemetry qu'elle attend.

### Étape 1 · Ouvrir ClickStack
1. Dans la console Cloud, ouvrez votre service.
2. Lancez **ClickStack** depuis le service (menu de gauche).
3. Sur la page **Getting Started**, passez l'assistant d'ingestion : les données sont déjà là. Allez dans **Team Settings**, puis **Sources**.

### Étape 2 · Déclarer les trois sources
Créez une source par signal. Comme les tables suivent le schéma OpenTelemetry par défaut, ClickStack remplit tout seul les expressions de colonnes une fois la table choisie.

| Paramètre | Logs | Traces | Métriques |
|---|---|---|---|
| Name | `PayFlow logs` | `PayFlow traces` | `PayFlow metrics` |
| Source Data Type | Log | Trace | Metrics |
| Server Connection | `Default` | `Default` | `Default` |
| Database | `payflow_otel` | `payflow_otel` | `payflow_otel` |
| Table | `otel_logs` | `otel_traces` | Gauge `otel_metrics_gauge`, Histogram `otel_metrics_histogram`, Sum `otel_metrics_sum` |

Reliez-les ensuite, pour passer d'un signal à l'autre en un clic :
- sur **PayFlow logs** : *Correlated Trace Source* = `PayFlow traces`, *Correlated Metric Source* = `PayFlow metrics` ;
- sur **PayFlow traces** : *Correlated Log Source* = `PayFlow logs`, *Correlated Metric Source* = `PayFlow metrics`.

Vérifiez les expressions déduites sur la source de logs : Timestamp `Timestamp`, Service Name `ServiceName`, Log Level `SeverityText`, Body `Body`, Trace Id `TraceId`, Span Id `SpanId`.

### Étape 3 · Chercher dans les logs
Ouvrez **Search**, choisissez **PayFlow logs**, réglez la plage absolue `2026-11-27 13:45` à `15:00`.

| À taper dans la barre de recherche | Ce que vous voyez |
|---|---|
| `SeverityText:ERROR` | l'histogramme des erreurs bondit à 13:58 et s'arrête à 14:44 |
| `ServiceName:payment SeverityText:ERROR` | uniquement des timeouts HikariPool |
| `"maximumPoolSize"` | les lignes de démarrage de chaque pod payment : 10 en v2.4.1, 50 avant et après |
| `ServiceName:k8s-events` | le déploiement progressif (rollout), les readiness probes en échec, l'OOM kill sur ip-10-0-3-17 |
| `"pan="` | les numéros de carte, masqués par le pipeline du module 3 |

La recherche plein texte s'appuie sur l'index texte de `otel_logs` (module 6) : instantanée, même sur un milliard de lignes.

Cliquez sur n'importe quel champ du panneau de gauche (par exemple `k8s.pod.name` ou `service.version`) pour filtrer dessus. Filtrez `service.version` = `v2.4.0` puis `v2.4.1` : une seule des deux a des erreurs.

### Étape 4 · D'une ligne de log à sa trace
1. Cherchez `ServiceName:checkout SeverityText:ERROR` et ouvrez une ligne.
2. Le panneau latéral affiche la ligne, ses attributs et la **trace** à laquelle elle appartient (via `TraceId`, grâce aux sources corrélées).
3. Ouvrez la trace : c'est la cascade du module 7 (Q4), avec 3 secondes passées dans `INSERT payflow.payments` et l'exception HikariPool en span event.

### Étape 5 · Tracer l'incident
Ouvrez **Chart Explorer** (ou **Search**, puis passez en mode graphique) :
- source **PayFlow traces**, agrégation **p99** de `Duration`, avec `SpanKind:Server`, groupé par `ServiceName` : trois services montent à 3 s ;
- source **PayFlow metrics**, métrique `hikaricp.connections.pending` (gauge), **max**, groupé par `service.version` : la v2.4.1 a des dizaines de threads en attente, la v2.4.0 aucun ;
- métrique `k8s.pod.memory.working_set`, avec `k8s.node.name` = `ip-10-0-3-17`, groupé par `k8s.pod.name` : le pod fraud-scoring qui grimpe à 2 Gio, puis la chute.

L'histogramme de latence `http.server.request.duration` porte un **exemplar** par minute (module 3) : le trace id de la requête la plus lente. Là où le graphique affiche les exemplars, un clic ouvre cette trace.

### Étape 6 · Un dashboard et une alerte
1. **Dashboards**, **New Dashboard**, nom `PayFlow · SRE`. Ajoutez quatre tuiles à partir des graphiques de l'étape 5 : p99 par service, nombre d'erreurs par service (logs, `SeverityText:ERROR`), connexions HikariCP en attente par version, mémoire de ip-10-0-3-17.
2. De retour dans **Search**, enregistrez la recherche `ServiceName:payment SeverityText:ERROR` sous le nom `Payment errors`, puis créez une **alerte** dessus : plus de 100 lignes en 1 minute.

> L'alerte est évaluée sur l'heure courante. Les données du workshop sont en novembre 2026, elle ne se déclenchera donc pas : c'est la règle qui compte. La même règle, en SQL, c'est `payflow_sre.rmv_alerts` (module 5).

---

## 2. Un dashboard dans la console SQL, sur gold

Pour le responsable d'équipe, quatre tuiles directement sur les tables gold du module 5. Chaque requête lit quelques milliers de lignes.

1. Dans la console SQL, collez chaque requête dans un nouvel onglet, exécutez-la, puis **Save** sous le nom indiqué.
2. **Dashboards**, **New Dashboard** `PayFlow · SLO`, puis une visualisation par requête enregistrée.

**Tuile 1 · `tile_red_payments`** (Line, X = `minute`, Y = `error_pct` et `p99_ms`)
```sql
SELECT
    minute,
    round(100 * sum(errors) / sum(requests), 2)                         AS error_pct,
    round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6)     AS p99_ms
FROM payflow_sre.red_1m
WHERE service = 'api-gateway' AND operation = 'POST /v1/payments'
  AND minute BETWEEN '2026-11-27 13:30:00' AND '2026-11-27 15:30:00'
GROUP BY minute
ORDER BY minute
```

**Tuile 2 · `tile_burn_rate`** (Line, X = `minute`, Y = `burn_5m`, `burn_1h`, `threshold`)
```sql
SELECT minute, round(burn_5m, 1) AS burn_5m, round(burn_1h, 1) AS burn_1h, 14.4 AS threshold
FROM payflow_sre.slo_burn
WHERE route = 'POST /v1/payments' AND minute BETWEEN '2026-11-27 13:30:00' AND '2026-11-27 15:30:00'
ORDER BY minute
```

**Tuile 3 · `tile_alerts`** (Table)
```sql
SELECT ts, rule, severity, service, state, summary
FROM payflow_sre.alerts
ORDER BY ts
```

**Tuile 4 · `tile_service_map`** (Table : les liens dont la latence a le plus changé)
```sql
SELECT caller, callee,
       maxIf(p95_ms, bucket >= '2026-11-27 12:45:00' AND bucket < '2026-11-27 13:45:00') AS p95_before_ms,
       maxIf(p95_ms, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS p95_during_ms,
       sumIf(errors, bucket >= '2026-11-27 14:00:00' AND bucket < '2026-11-27 14:40:00') AS errors_during
FROM payflow_sre.service_map_5m
GROUP BY caller, callee
ORDER BY p95_during_ms / greatest(p95_before_ms, 1) DESC
LIMIT 8
```

---

## 3. Une API de statut pour la page de statut de PayFlow

La page de statut doit afficher, pour une route, le taux de consommation (burn rate) des dernières minutes, sans aucun SQL côté client.

### Étape 1 · La vue paramétrée
```sql
CREATE OR REPLACE VIEW payflow_sre.api_route_status AS
SELECT minute, route, requests, errors, round(burn_5m, 1) AS burn_5m, fast_burn
FROM payflow_sre.slo_burn
WHERE route = {route:String} AND minute BETWEEN {start:DateTime} AND {finish:DateTime}
ORDER BY minute
```

### Étape 2 · La tester
```sql
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = '2026-11-27 14:00:00', finish = '2026-11-27 14:10:00')
```

### Étape 3 · La publier comme endpoint
1. Nouvel onglet, collez :
   ```sql
   SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})
   ```
2. **Save** sous le nom `api_route_status`, puis **Share**, **API Endpoint** : choisissez une clé d'API avec l'accès **Query Endpoints**, et le rôle de base de données **Read only**.
3. Appelez-le (remplacez les deux valeurs) :
   ```bash
   curl --user '<Key ID>:<Key secret>' \
     'https://queries.clickhouse.cloud/run/<endpoint id>?format=JSONEachRow&param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00'
   ```

En attendant d'avoir une clé, l'interface HTTPS du service accepte les mêmes paramètres (pour un test seulement : ne mettez jamais le mot de passe `default` dans un front end) :
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})"
```
Réponse attendue : 11 lignes, `fast_burn` à true dès 14:00.

---

## 4. ClickHouse Agents : interroger la plateforme

### Étape 1 · Documenter les tables pour l'agent
Un agent lit d'abord les commentaires des tables et des colonnes (règle `agent-discovery-schema`). Sans eux, il devine ce que veut dire `burn_1h`.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'Métriques RED par minute : une ligne par service, opération (nom de span) et minute. Terminer l''agrégation avec sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanosecondes). Filtrer d''abord sur service.',
    COMMENT COLUMN latency 'État quantilesTDigest des durées de span en nanosecondes : utiliser quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 pour le p99 en ms';

ALTER TABLE payflow_sre.slo_burn
    MODIFY COMMENT 'Taux de consommation du budget d''erreur (burn rate) de chaque route de l''api-gateway, par minute. burn_5m et burn_1h : combien de fois plus vite que permis le budget est consommé (1 = dans le budget). fast_burn = les deux au-dessus de 14,4.';

ALTER TABLE payflow_sre.alerts
    MODIFY COMMENT 'Événements d''alerte (FIRING / RESOLVED) des quatre règles : slo_fast_burn, p99_latency, container_restart, node_memory_pressure.';

ALTER TABLE payflow_otel.otel_traces
    MODIFY COMMENT 'Spans OpenTelemetry de PayFlow. Timestamp en UTC (nanosecondes), Duration en nanosecondes, StatusCode Error ou Unset. Toujours filtrer sur Timestamp et ServiceName. Version du pod dans ResourceAttributes[''service.version''], champs métier dans SpanAttributes (payment.amount, payment.status, merchant.id).';

ALTER TABLE payflow_otel.otel_logs
    MODIFY COMMENT 'Logs OpenTelemetry de PayFlow, numéros de carte masqués. Toujours filtrer sur Timestamp. Recherche plein texte : hasToken(lower(Body), ''word''). Les événements Kubernetes ont ServiceName = ''k8s-events'' et la raison dans EventName.';

SELECT name, comment FROM system.tables WHERE database IN ('payflow_sre', 'payflow_otel') AND comment != '' ORDER BY name
```

### Étape 2 · Créer l'agent
1. Dans le service, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model** : le modèle par défaut. **Tools** : `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (à coller tel quel) :
   ```
   Tu es l'assistant SRE de PayFlow, une plateforme de paiement sur Kubernetes. Réponds en français, brièvement.
   - Les données sont en UTC, le vendredi 2026-11-27. Utilise des plages horaires absolues sur ce jour.
   - Privilégie les tables gold : payflow_sre.red_1m (RED par minute), payflow_sre.slo_burn,
     payflow_sre.alerts, payflow_sre.service_map_5m, payflow_sre.log_patterns_10m.
     Ne va dans payflow_otel.otel_traces et otel_logs que pour les détails, toujours avec un filtre
     sur Timestamp et un LIMIT. Lis d'abord les commentaires des tables.
   - Contexte métier : payflow_ref.merchant (dictGet('payflow_ref.dict_merchant', 'name', merchant_id)),
     déploiements : payflow_ref.deployment_history.
   - Donne les chiffres clés avec leur unité, puis le SQL utilisé.
   - Quand on te demande un graphique ou un dashboard, construis-le avec l'outil Artifacts.
   - Pour le Python (statistiques, détection d'anomalies, prévision) : exécute d'abord le SQL avec l'outil
     ClickHouse, garde un résultat compact (quelques milliers de lignes au plus), colle les données dans le
     code et exécute-le toi-même avec Run Code. Run Code n'a pas accès à ClickHouse. Montre le résultat
     dans un artifact.
   ```
4. Enregistrez, ouvrez une conversation, choisissez l'agent.

### Étape 3 · Deux questions
| Question | Réponse attendue |
|---|---|
| "Que s'est-il passé sur les paiements entre 13:55 et 14:50 le 27 novembre ?" | taux d'erreur de `POST /v1/payments` jusqu'à ~30 %, p99 à 3 s, de 13:58 à 14:44 ; cause racine : timeouts HikariPool dans `payment` v2.4.1 (CHG-4117, pool de 10) ; première page (alerte qui réveille l'astreinte) à 14:00 |
| "Combien l'incident a-t-il coûté, et quels marchands ont été les plus touchés ?" | ~15 300 paiements en échec, ~1,58 M EUR, ~8 000 marchands ; les principaux marchands par montant |

### Étape 4 · Des dashboards à la demande
- "Construis un dashboard de l'incident : taux d'erreur et p99 de POST /v1/payments par minute, le burn rate avec son seuil de 14,4, et les alertes sous forme de marqueurs."
- "Montre la service map pendant l'incident sous forme de graphe, avec les liens colorés selon la latence p95."
- "Compare les pods payment de la v2.4.0 et de la v2.4.1 pendant le rollout : connexions HikariCP actives et en attente."

### Étape 5 · De la data science avec Run Code
- "Détecte les minutes anormales de la journée sur POST /v1/payments à partir du taux d'erreur et de la latence p99, avec un Isolation Forest. Affiche-les sur un graphique."

  Réponse attendue : les minutes anormales vont de 13:58 à ~14:45. Le modèle ne sait rien de l'incident : il le trouve tout seul.
- "Prévois les requêtes par minute de POST /v1/payments entre 20:00 et 21:00 à partir du reste de la journée, et compare avec ce qui s'est réellement passé."

  Réponse attendue : le pic du soir est bien prédit ; la vente flash de 14:00 est une valeur aberrante dont le modèle ne doit pas apprendre.

### En production
Donnez à l'agent un rôle en lecture seule avec des limites par requête (règle `agent-query-safety`), par exemple :
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS payflow_agent_profile SETTINGS readonly = 2, max_execution_time = 30, max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS payflow_agent_role SETTINGS PROFILE 'payflow_agent_profile';
GRANT SELECT ON payflow_sre.* TO payflow_agent_role;
GRANT SELECT ON payflow_otel.* TO payflow_agent_role;
GRANT SELECT, dictGet ON payflow_ref.* TO payflow_agent_role;
```
