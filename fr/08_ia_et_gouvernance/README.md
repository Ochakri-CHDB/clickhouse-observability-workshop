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

## 1. AI Notebooks (bêta)

Un notebook est une enquête écrite sous forme de liste de blocs : recherches, graphiques, tableaux, notes. Un agent IA peut écrire les blocs pour vous à partir d'une question ; vous gardez, modifiez ou ajoutez des blocs, et partagez le notebook avec l'équipe.

1. Vérifiez que l'IA est activée : **Team Settings**, onglet **API & Agents**, section **Configure Generative AI**. Elle indique *Generative AI features are enabled for this service* et liste **Chart AI Assistant** (l'AI Assistant de Chart Explorer, module 4) et **AI Notebooks**. Sinon, un administrateur de l'équipe les active à cet endroit.
2. Votre date de Black Friday : `SELECT pf_black_friday()` dans la console SQL.
3. Menu de gauche, **AI notebooks**, **New Shared Notebook** (l'équipe le voit) ou **New Private Notebook** (vous seul).
4. Dans la case **Ask AI to explore your data**, tapez, avec votre date : *Pourquoi POST /v1/payments a-t-il échoué entre 13h58 et 14h45 UTC le YYYY-MM-DD ? Quelle version, quels pods, et quelle est la cause racine ? Utilise les sources PayFlow.*
5. Lisez les blocs à mesure qu'ils arrivent : l'agent cherche dans les logs, ouvre des traces, compare les versions. Chaque bloc s'ouvre et se modifie comme une recherche ou un graphique ordinaire.
6. Comparez sa conclusion avec la vôtre (module 6). Puis essayez sur le flux en direct, après avoir de nouveau cassé la production (module 5) : *Qu'est-ce qui ne va pas avec les paiements depuis 10 minutes ?*

La fonctionnalité est en bêta : il peut arriver que l'IA se contente de donner un titre au notebook, sans ajouter de bloc. Construisez alors l'enquête vous-même avec **Manual Block** : **Search**, **Chart**, **Table**, **Markdown**. Un notebook écrit à la main reste le meilleur brouillon de postmortem : chaque bloc est une requête vivante, pas une capture d'écran.

---

## 2. Le serveur MCP de ClickStack

ClickStack expose un serveur MCP : n'importe quel client MCP (Claude Code, Cursor, VS Code, Codex CLI...) peut chercher dans les logs et les traces, lire les dashboards et les alertes, avec vos droits.

1. **Team Settings**, onglet **API & Agents**, section **Connect your AI agents**. **Remote MCP server** doit indiquer **ENABLED**.
2. Choisissez votre outil dans les onglets (**Claude Code**, **Cursor**, **VS Code**, **Codex CLI**, **OpenCode**, **Other**) et copiez la commande affichée. Pour Claude Code, elle contient l'identifiant de votre service dans un en-tête :
   ```bash
   claude mcp add clickstack --transport http https://mcp.clickhouse.cloud/clickstack --header "x-service-id: <your service id>"
   ```
   Le **Service ID** est en haut du même onglet, avec un bouton **Copy**. Le premier appel ouvre une connexion dans le navigateur (OAuth, pas de clé d'API). **Manage sessions** liste et révoque les outils connectés.
3. Demandez à votre assistant, avec votre date : *Avec ClickStack, trouve les event patterns des erreurs de paiement du YYYY-MM-DD entre 14h00 et 14h45 UTC et ouvre la trace la plus lente.*

Dans le même onglet, **Export to Terraform** (expérimental) télécharge les dashboards, les alertes, les recherches enregistrées et les sources de l'équipe sous forme de fichier d'import Terraform : la configuration de ce workshop, versionnée comme du code.

---

## 3. ClickHouse Agents

Les ClickHouse Agents travaillent côté SQL du service, avec trois outils : ClickHouse (requêtes), Artifacts (graphiques et dashboards), Run Code (Python).

### 3.1 · Documenter les tables pour l'agent
Un agent lit d'abord les commentaires des tables et des colonnes (règle `agent-discovery-schema`). Sans eux, il devine ce que veut dire `burn_1h`.
```sql
ALTER TABLE payflow_sre.red_1m
    MODIFY COMMENT 'RED metrics per minute: one row per service, operation (span name) and minute. Finish the aggregation with sum(requests), sum(errors), quantilesTDigestMerge(0.5, 0.95, 0.99)(latency) (nanoseconds). Filter on service first.',
    COMMENT COLUMN latency 'quantilesTDigest state of span durations in nanoseconds: use quantilesTDigestMerge(0.5, 0.95, 0.99)(latency)[3] / 1e6 for p99 in ms';

ALTER TABLE payflow_sre.slo_burn
    MODIFY COMMENT 'Error budget burn rate of each api-gateway route, per minute. burn_5m and burn_1h: how many times faster than allowed the budget is spent (1 = on budget). fast_burn = both above 14.4.';

ALTER TABLE payflow_sre.alerts
    MODIFY COMMENT 'Alert events (FIRING / RESOLVED) of the four rules: slo_fast_burn, p99_latency, container_restart, node_memory_pressure.';

ALTER TABLE payflow_otel.otel_traces
    MODIFY COMMENT 'OpenTelemetry spans of PayFlow. Timestamp in UTC (nanoseconds), Duration in nanoseconds, StatusCode Error or Unset. Always filter on Timestamp and ServiceName. Pod version in ResourceAttributes[''service.version''], business fields in SpanAttributes (payment.amount, payment.status, merchant.id).';

ALTER TABLE payflow_otel.otel_logs
    MODIFY COMMENT 'OpenTelemetry logs of PayFlow, card numbers masked. Always filter on Timestamp. Full-text search: hasToken(lower(Body), ''word''). Kubernetes events have ServiceName = ''k8s-events'' and the reason in EventName.';

SELECT name, comment FROM system.tables WHERE database IN ('payflow_sre', 'payflow_otel') AND comment != '' ORDER BY name
```

### 3.2 · Créer l'agent
1. Dans le service, **ClickHouse agents**, **Create New Agent**.
2. **Name** `PayFlow SRE assistant`. **Model** : le modèle par défaut. **Tools** : `ClickHouse`, `Artifacts`, `Run Code`.
3. **Instructions** (à coller telles quelles) :
   ```
   Tu es l'assistant SRE de PayFlow, une plateforme de paiement sur Kubernetes. Réponds en français, brièvement.
   - Les données sont en UTC. L'incident a lieu le jour du Black Friday : sa date est SELECT pf_black_friday(), et
     pf_at('14:00:00') vaut 14:00 ce jour-là. Utilise des plages horaires absolues construites avec ces fonctions.
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
| "Que s'est-il passé sur les paiements entre 13h55 et 14h50 le jour du Black Friday ?" | taux d'erreur de `POST /v1/payments` jusqu'à ~30 %, p99 de 3 s, de 13h58 à 14h44 ; cause racine : timeouts HikariPool dans `payment` v2.4.1 (CHG-4117, pool de 10) ; première page (alerte qui réveille l'astreinte) à 14h00 |
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

### Dans ClickStack
1. **Team Settings**, onglet **Members & Roles**. En haut, les membres de l'équipe (**Manage in Console** pour inviter des personnes, depuis l'organisation Cloud). En dessous, les rôles : **Admin**, **Member**, **ReadOnly**, et **Default New User Role** tout en bas (le rôle de toute personne qui rejoint l'équipe).
2. **Add Role** : **Role Name** `Payments SRE`, une **Description**, puis une ligne par ressource avec **No Access**, **Read** ou **Manage** : Dashboards, Saved Searches, Sources, Webhooks, Alerts, Notebooks ; **Users** (No Access, Read) et **Team** (Read, Manage).
3. La flèche au bout de Dashboards, Saved Searches, Sources et Notebooks ouvre **Fine-Grained Controls** : **Add Access Rule**, une **Condition** sur le **Name**, l'**ID** ou un **Tag** (`is` ou `contains`), et le niveau d'accès des objets correspondants. Par exemple, Dashboards, Tag is `payments`, **Manage** : l'équipe modifie ses propres dashboards et ne fait que lire les autres.
4. Fermez avec le **x** si vous n'avez fait que regarder ; **Create Role** l'enregistre.

### Dans ClickHouse
`01_securite_et_exploitation.sql` crée un rôle par équipe et une row policy par table. ClickStack interroge le service avec les droits de l'utilisateur : l'équipe payments ne voit jamais que le namespace `payments`, dans la console SQL, dans ClickStack et via le serveur MCP. Les rôles ClickStack décident de ce que vous pouvez faire dans l'interface ; les rôles ClickHouse décident des lignes que vous pouvez lire.

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
SELECT * FROM payflow_sre.api_route_status(route = 'POST /v1/payments', start = pf_at('14:00:00'), finish = pf_at('14:10:00'))
```

### 5.3 · La publier comme endpoint
1. Nouvel onglet, collez :
   ```sql
   SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})
   ```
2. **Save** sous le nom `api_route_status`, puis **Share**, **API Endpoint** : choisissez une clé d'API avec l'accès **Query Endpoints**, et le rôle de base de données **Read only**.
3. Appelez-le (remplacez les deux valeurs, et `YYYY-MM-DD` par votre date de Black Friday) :
   ```bash
   curl --user '<Key ID>:<Key secret>' \
     'https://queries.clickhouse.cloud/run/<endpoint id>?format=JSONEachRow&param_route=POST%20%2Fv1%2Fpayments&param_start=YYYY-MM-DD%2014%3A00%3A00&param_finish=YYYY-MM-DD%2014%3A10%3A00'
   ```

Avant d'avoir une clé, l'interface HTTPS du service accepte les mêmes paramètres (pour un test uniquement : ne mettez jamais le mot de passe de `default` dans un front-end) :
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_route=POST%20%2Fv1%2Fpayments&param_start=YYYY-MM-DD%2014%3A00%3A00&param_finish=YYYY-MM-DD%2014%3A10%3A00&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM payflow_sre.api_route_status(route = {route:String}, start = {start:DateTime}, finish = {finish:DateTime})"
```
Réponse attendue : 11 lignes, `fast_burn` à true à partir de 14:00.

---

## Fin de la journée

Arrêtez le flux en direct du module 2 (sept vues rafraîchissables), sinon le service ne se met jamais en veille : lancez `arreter_flux_en_direct.sql`, ou :

```sql
SYSTEM STOP VIEW payflow_sim.rmv_live_logs;
SYSTEM STOP VIEW payflow_sim.rmv_live_traces;
SYSTEM STOP VIEW payflow_sim.rmv_live_metrics;
SYSTEM STOP VIEW payflow_sim.rmv_live_sums;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_traces;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_logs;
SYSTEM STOP VIEW payflow_sim.rmv_chaos_metrics;
```

`reset.sql` supprime tout ce que le workshop a créé dans le service. Les objets ClickStack (sources, dashboard, recherche enregistrée, alertes, notebooks) restent : supprimez-les depuis l'interface si vous voulez une équipe propre.
