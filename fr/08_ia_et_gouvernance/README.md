# Module 8 · IA et gouvernance

Deux questions pour finir la journée. Une IA peut-elle mener l'enquête à votre place ? Et qui a le droit de voir quoi ? Ce README couvre le côté ClickStack et Cloud ; `01_securite_et_exploitation.sql` couvre la suppression, les droits et l'observabilité de ClickHouse lui-même.

Durée : 40 min.

| Partie | Contenu | Durée |
|---|---|---|
| 1 | AI Notebooks dans ClickStack | 10 min |
| 2 | Le serveur MCP de ClickStack : votre propre assistant IA sur les données | 5 min |
| 3 | ClickHouse Agents : questions, dashboards à la demande, data science | 15 min |
| 4 | Rôles et accès : RBAC dans ClickStack, row policies en SQL | 5 min |
| 5 | Une API de statut pour la page de statut de PayFlow | 5 min |

---

## 1. AI Notebooks (bêta, Managed ClickStack uniquement)

Un notebook est une enquête rédigée par un agent IA, tuile par tuile : son raisonnement, chaque requête lancée, les graphiques, sa conclusion. Vous pouvez repartir de n'importe quelle étape, ajouter vos propres tuiles, le partager avec l'équipe.

1. Un admin de l'équipe active l'IA : **Team Settings**, **Security Policies**, activer **Generative AI**, accepter.
2. **Notebooks** (menu de gauche), **New Shared Notebook**.
3. Demandez : *"Pourquoi POST /v1/payments a-t-il échoué entre 13:58 et 14:45 le 27 novembre 2026 (UTC) ? Quelle version, quels pods, et quelle est la cause racine ?"*
4. Lisez les tuiles : l'agent cherche dans les logs, ouvre des traces, compare les versions. Sur une piste qu'il n'a pas suivie, **Restart from Here** avec un nouveau prompt pour faire bifurquer l'enquête.
5. Comparez sa conclusion avec la vôtre (module 6). Puis essayez sur le flux en direct, après avoir de nouveau cassé la production (module 5) : *"Qu'est-ce qui ne va pas avec les paiements depuis 10 minutes ?"*

---

## 2. Le serveur MCP de ClickStack

ClickStack expose un serveur MCP : n'importe quel client MCP (Claude Code, Cursor, VS Code...) peut chercher dans les logs et les traces, lire les dashboards et les alertes, avec vos droits.

1. Dans la console Cloud : **Connect**, **Connect with MCP**, activez-le sur le service.
2. Endpoint `https://mcp.clickhouse.cloud/clickstack`, connexion OAuth à la première utilisation (pas de clé d'API). Par exemple avec Claude Code :
   ```bash
   claude mcp add --transport http clickstack https://mcp.clickhouse.cloud/clickstack
   ```
3. Demandez à votre assistant : *"Avec ClickStack, trouve les event patterns des erreurs de paiement du 27 novembre 2026 entre 14:00 et 14:45 et ouvre la trace la plus lente."*

---

## 3. ClickHouse Agents

Les ClickHouse Agents travaillent côté SQL du service, avec trois outils : ClickHouse (requêtes), Artifacts (graphiques et dashboards), Run Code (Python).

### 3.1 · Documenter les tables pour l'agent
Un agent lit d'abord les commentaires des tables et des colonnes (règle `agent-discovery-schema`). Sans eux, il devine ce que veut dire `burn_1h`.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'Métriques RED par minute : une ligne par service, opération (nom du span) et minute. Terminer l''agrégation avec sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanosecondes). Filtrer d''abord sur service.',
    COMMENT COLUMN latency 'État quantilesTDigest des durées de span en nanosecondes : quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 donne le p99 en ms';

ALTER TABLE payflow_sre.slo_burn
    MODIFY COMMENT 'Taux de consommation (burn rate) du budget d''erreur de chaque route de api-gateway, par minute. burn_5m et burn_1h : combien de fois plus vite que permis le budget est consommé (1 = dans le budget). fast_burn = les deux au-dessus de 14.4.';

ALTER TABLE payflow_sre.alerts
    MODIFY COMMENT 'Événements d''alerte (FIRING / RESOLVED) des quatre règles : slo_fast_burn, p99_latency, container_restart, node_memory_pressure.';

ALTER TABLE payflow_otel.otel_traces
    MODIFY COMMENT 'Spans OpenTelemetry de PayFlow. Timestamp en UTC (nanosecondes), Duration en nanosecondes, StatusCode Error ou Unset. Toujours filtrer sur Timestamp et ServiceName. Version du pod dans ResourceAttributes[''service.version''], champs métier dans SpanAttributes (payment.amount, payment.status, merchant.id).';

ALTER TABLE payflow_otel.otel_logs
    MODIFY COMMENT 'Logs OpenTelemetry de PayFlow, numéros de carte masqués. Toujours filtrer sur Timestamp. Recherche plein texte : hasToken(lower(Body), ''mot''). Les événements Kubernetes ont ServiceName = ''k8s-events'' et la raison dans EventName.';

SELECT name, comment FROM system.tables WHERE database IN ('payflow_sre', 'payflow_otel') AND comment != '' ORDER BY name
```

### 3.2 · Créer l'agent
1. Dans le service, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model** : le modèle par défaut. **Tools** : `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (à coller telles quelles) :
   ```
   Tu es l'assistant SRE de PayFlow, une plateforme de paiement sur Kubernetes. Réponds en français, brièvement.
   - Les données sont en UTC, le vendredi 2026-11-27. Utilise des plages horaires absolues sur ce jour.
   - Privilégie les agrégats (rollups) : payflow_sre.red_1m (RED par minute), payflow_sre.slo_burn,
     payflow_sre.alerts, payflow_sre.service_map_5m, payflow_sre.log_patterns_10m.
     Ne va dans payflow_otel.otel_traces et otel_logs que pour le détail, toujours avec un filtre
     sur Timestamp et un LIMIT. Lis d'abord les commentaires des tables.
   - Contexte métier : payflow_inventory.merchant (dictGet('payflow_inventory.dict_merchant', 'name', merchant_id)),
     déploiements : payflow_inventory.deployment_history.
   - Donne les chiffres clés avec leur unité, puis le SQL utilisé.
   - Quand on te demande un graphique ou un dashboard, construis-le avec l'outil Artifacts.
   - Pour le Python (statistiques, détection d'anomalies, prévision) : lance d'abord le SQL avec l'outil
     ClickHouse, garde un résultat compact (quelques milliers de lignes au plus), colle les données
     dans le code et exécute-le toi-même avec Run Code. Run Code n'a pas accès à ClickHouse.
     Montre le résultat dans un artifact.
   ```
4. **Save**, ouvrez une conversation, choisissez l'agent.

### 3.3 · Deux questions
| Question | Réponse attendue |
|---|---|
| "Que s'est-il passé sur les paiements entre 13:55 et 14:50 le 27 novembre ?" | taux d'erreur de `POST /v1/payments` jusqu'à ~30 %, p99 de 3 s, de 13:58 à 14:44 ; cause racine : timeouts HikariPool dans `payment` v2.4.1 (CHG-4117, pool de 10) ; première page (alerte qui réveille l'astreinte) à 14:00 |
| "Combien l'incident a-t-il coûté, et quels marchands ont été les plus touchés ?" | ~15 300 paiements en échec, ~1,58 M EUR, ~8 000 marchands ; top des marchands par montant |

### 3.4 · Dashboards à la demande
- "Construis un dashboard de l'incident : taux d'erreur et p99 de POST /v1/payments par minute, le burn rate avec son seuil de 14,4, et les alertes en marqueurs."
- "Montre la service map pendant l'incident sous forme de graphe, avec les arêtes colorées selon la latence p95."
- "Compare les pods payment de v2.4.0 et v2.4.1 pendant le déploiement progressif (rollout) : connexions HikariCP actives et en attente."

### 3.5 · Data science avec Run Code
- "Détecte les minutes anormales de la journée sur POST /v1/payments à partir du taux d'erreur et de la latence p99, avec un Isolation Forest. Montre-les sur un graphique."

  Réponse attendue : les minutes anormales vont de 13:58 à ~14:45. Le modèle ne sait rien de l'incident : il le trouve seul.
- "Prévois les requêtes par minute de POST /v1/payments entre 20:00 et 21:00 à partir du reste de la journée, et compare avec ce qui s'est vraiment passé."

  Réponse attendue : le pic du soir est bien prévu ; la vente flash de 14:00 est une valeur aberrante dont le modèle ne doit pas s'inspirer.

### 3.6 · En production
Donnez à l'agent un rôle en lecture seule avec des limites par requête (règle `agent-query-safety`), par exemple :
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS payflow_agent_profile SETTINGS readonly = 2, max_execution_time = 30, max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS payflow_agent_role SETTINGS PROFILE 'payflow_agent_profile';
GRANT SELECT ON payflow_sre.* TO payflow_agent_role;
GRANT SELECT ON payflow_otel.* TO payflow_agent_role;
GRANT SELECT, dictGet ON payflow_inventory.* TO payflow_agent_role;
```

---

## 4. Rôles et accès

- **Dans ClickStack (RBAC, Managed)** : **Team Settings**, rôles Admin, Member, ReadOnly, ou rôles personnalisés avec No Access / Read / Manage par ressource (dashboards, recherches enregistrées, alertes, notebooks). Donnez à l'équipe payments Manage sur ses propres dashboards et alertes, Read ailleurs.
- **Dans ClickHouse** : `01_securite_et_exploitation.sql` crée un rôle par équipe et une row policy par table. ClickStack interroge le service avec les droits de l'utilisateur : l'équipe payments ne voit jamais que le namespace `payments`, dans la console SQL, dans ClickStack et via le serveur MCP.

---

## 5. Une API de statut pour la page de statut de PayFlow

La page de statut doit afficher, pour une route, le burn rate des dernières minutes, sans aucun SQL côté client.

### 5.1 · La vue paramétrée
```sql
CREATE OR REPLACE VIEW payflow_sre.api_route_status AS
SELECT minute, route, requests, errors, round(burn_5m, 1) AS burn_5m, fast_burn
FROM payflow_sre.slo_burn
WHERE route = {route:String} AND minute BETWEEN {start:DateTime} AND {finish:DateTime}
ORDER BY minute
```

### 5.2 · La tester
```sql
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = '2026-11-27 14:00:00', finish = '2026-11-27 14:10:00')
```

### 5.3 · La publier comme endpoint
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

Avant d'avoir une clé, l'interface HTTPS du service accepte les mêmes paramètres (pour un test uniquement : ne mettez jamais le mot de passe de `default` dans un front-end) :
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_route=POST%20%2Fv1%2Fpayments&param_start=2026-11-27%2014%3A00%3A00&param_finish=2026-11-27%2014%3A10%3A00&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})"
```
Réponse attendue : 11 lignes, `fast_burn` à true à partir de 14:00.

---

## Fin de la journée

Arrêtez le flux en direct du module 2, sinon le service ne se met jamais en veille :

```sql
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
```

(ou lancez `arreter_flux_en_direct.sql`). `reset.sql` supprime tout ce que le workshop a créé.
