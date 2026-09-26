# Dépannage

## Base (SQL Editor)

| Symptôme | Cause | Remède |
|---|---|---|
| `unterminated dollar-quoted string` | le fichier a été copié tronqué (aperçu GitHub) | GitHub > le fichier > **Copy raw file**, recoller, relancer |
| `Fichier obsolète : relancez plutôt outils/supabase.sql…` | un ancien fichier isolé a été lancé sur une base à jour | normal : il est inclus dans la chaîne. Suivre `outils/migrations.txt` |
| `violates check constraint "notifications_canal_check"` en relançant `supabase.sql` | version de `supabase.sql` antérieure à la Phase 12 sur une base qui a des notifications `app` | reprendre `supabase.sql` depuis `main` (corrigé), relancer la chaîne |
| Une erreur au milieu de la chaîne | un fichier suivant dépend de ce qui a échoué | **s'arrêter**, corriger, relancer le fichier en échec puis les suivants (tous rejouables) |
| `rpc/sante` répond 404 | `supabase-production.sql` pas encore passé | le passer (deployment.md § 1) |
| `sante()` → `notifications: en_retard` | pg_cron arrêté, tâche absente, ou `traiter_notifications()` en erreur | `select jobname, schedule, active from cron.job;` ; `select status, return_message from cron.job_run_details order by start_time desc limit 5;` ; tâche absente → relancer `supabase-notifications.sql` |
| `sante()` → `notifications: inactives` | `supabase-notifications.sql` pas passé | le passer (et lire deployment.md, « Premier passage ») |
| `pg_cron indisponible` en fin de `supabase-notifications.sql` | extension non activée | Database > Extensions > `pg_cron` (et `pg_net`), relancer le fichier |
| Envois « annulé » avec « canal non configuré » | aucune clé de fournisseur dans le Vault pour ce canal | `definir_reglage` (docs/notifications.md) — attendu tant que le canal n'est pas mis en service |
| Envois « échec » avec un code 401/403 | clé du fournisseur fausse ou révoquée | nouvelle clé, `definir_reglage` |
| `controle-securite.sql` : ALERTE « Extensions » | pg_cron / pg_net non activés | les activer |
| `controle-securite.sql` : ALERTE « Comptes de démonstration » | un compte `@goship.demo`, `@goship.test`, `@exemple.com`… existe en production | le supprimer (Authentication > Users) après avoir vérifié qu'il n'a aucune donnée réelle |

## Outils de production

| Symptôme | Cause | Remède |
|---|---|---|
| `audit-production.yml` rouge : « ABSENTE supabase-… » | la migration n'est pas passée en production | deployment.md § 1 (préproduction, sauvegarde, puis `appliquer-chaine.sh`) |
| `audit-production.yml` : « OUVERTE AUX VISITEURS » | une fonction a reçu `execute` pour `anon` | S1 : `revoke execute on function … from anon;` dans une migration, puis `controles-production.yml` |
| `appliquer-chaine.sh` : « REFUS » (code 3) | l'adresse est celle de la production | voulu : ajouter `CONFIRMER_PRODUCTION=gpfdyslysqjmojgzggib` seulement après préproduction et sauvegarde restaurée |
| `appliquer-chaine.sh` : « ÉCHEC <fichier> — arrêt » | ce fichier a échoué ; rien après lui n'a été lancé ; le fichier lui-même est annulé (transaction unique) | lire l'erreur, corriger, relancer **à partir de ce fichier** |
| Restauration d'épreuve rouge : `violates foreign key constraint` | des lignes orphelines dans la production (sauvegarde non restaurable telle quelle) | `controles-production.yml` (intégrité) ; corriger par une migration relue, en préproduction d'abord |
| Restauration d'épreuve : `role "…" does not exist` | un droit cite un rôle Supabase que l'épreuve ne crée pas | ajouter ce rôle à l'étape « Une base comme un projet Supabase neuf » de `sauvegarde.yml` |
| `preproduction.yml` : « Préproduction non configurée » | environnement `staging` incomplet | environment.md, « Créer la préproduction » |
| `preproduction.yml` : « STAGING pointe vers la PRODUCTION » | `STAGING_DB_URL` ou `STAGING_SUPABASE_URL` contient la référence de production | corriger le secret / la variable |
| `essai-metier.sql` : « ÉCHEC : … » | une règle métier ne tient pas dans la préproduction | ne pas migrer la production ; le message nomme la règle |
| Bureau : `spctl` refuse ou `stapler validate` échoue | notarisation absente ou refusée par Apple | vérifier `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` et le certificat *Developer ID Application* |
| Bureau : Authenticode ≠ `Valid` | certificat Windows expiré ou mot de passe faux | `WIN_CSC_LINK`, `WIN_CSC_KEY_PASSWORD` |
| Mobile : « Préproduction mal configurée » au démarrage | `eas.json`, profil staging : valeurs `REMPLACER…` | les remplacer par l'adresse et la clé publiable de goship-staging |

## Site

| Symptôme | Cause | Remède |
|---|---|---|
| « Service indisponible / hors service » sur toutes les pages de compte | `config.js` publié sans adresse ni clé | vérifier `assets/js/config.js` sur `main` |
| `deploy.yml` : « Fichiers de travail dans le site publié » | un `.md`, `.sql`, `.py`, `.env`, une clé… à la racine ou dans `assets/` | le déplacer dans `outils/` ou `docs/`, ou l'ajouter aux exclusions de `deploy.yml` s'il ne doit pas être servi |
| `deploy.yml` : « Une clé secrète est dans le site publié » | une clé `sb_secret_`, `service_role` ou privée dans un fichier | **ne pas publier**, retirer la clé, la révoquer (secrets.md) |
| Contrôle après publication : « … servi publiquement » | un fichier de travail est en ligne | exclusion manquante dans `deploy.yml` |
| Les liens « mot de passe oublié » mènent à `localhost` | *Site URL* de Supabase Auth encore sur `localhost` | README, « Les cinq réglages », point 2 |
| Un client ne reçoit pas l'e-mail de confirmation | expéditeur non authentifié (indésirables) | authentifier le domaine chez Brevo ; SMTP personnalisé dans Supabase |
| Le site montre l'ancienne version | cache de GitHub Pages / du navigateur | attendre ~10 min, recharger sans cache |

## Surveillance

| Symptôme | Cause | Remède |
|---|---|---|
| Plus aucune exécution de `surveillance.yml` / `sauvegarde.yml` | GitHub suspend les workflows planifiés après 60 jours sans activité | onglet Actions > le workflow > *Enable workflow* |
| `sauvegarde.yml` : « Sauvegarde non configurée » | secrets de l'environnement `production` absents | backup.md, « Mettre en service » |
| `sauvegarde.yml` : échec de connexion | mot de passe changé, ou chaîne *direct* (IPv6) au lieu du *Session pooler* | reprendre la chaîne dans Supabase > Connect > Session pooler |
| `sauvegarde.yml` : `server version mismatch` | Supabase est passé à une version de PostgreSQL plus récente que le client 17 | changer `postgresql-client-17` (et le chemin) dans `sauvegarde.yml` |

## Bureau et mobile

| Symptôme | Cause | Remède |
|---|---|---|
| Bureau : plus d'impression directe ni de session chiffrée | coquille plus ancienne que `BUREAU_CONTRAT_MIN` | installer la dernière coquille (deployment.md § 3) |
| Windows : « Windows a protégé votre ordinateur » | installateur non signé | « Informations complémentaires » > « Exécuter quand même » **sur un poste de l'équipe seulement**, jamais désactiver SmartScreen ; signer (go-no-go.md) |
| macOS : « impossible de vérifier le développeur » | application non notarisée | clic droit > Ouvrir ; signer et notariser (go-no-go.md) |
| Mobile : pré-alerte ou notifications en erreur « serveur » | la base n'a pas la fonction attendue (`creer_prealerte`, `mes_notifications`) | passer la migration correspondante avant de publier la version |
| Mobile : `JWT issued at future` (PGRST303) | horloge du téléphone en avance | régler l'heure automatique du téléphone |
