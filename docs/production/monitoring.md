# Surveillance, santé, journaux, alertes

## Ce qui est surveillé automatiquement

`outils/production/surveiller.sh` — lecture seule, clé *publishable* seulement,
aucune donnée de client. Lancé :

- **après chaque publication** du site (`deploy.yml`, job `verifier`) ;
- **toutes les 30 minutes** (`surveillance.yml`, à h 07 et h 37) — une fois
  fusionné sur `main` (GitHub ne planifie que la branche par défaut) ;
- à la main : Actions > Surveillance de la production > Run workflow, ou
  `bash outils/production/surveiller.sh [adresse]` depuis un ordinateur.

| Vérification | Échec si… |
|---|---|
| Pages `index`, `connexion`, `mon-compte`, `admin`, `en/index`, `ht/index` | réponse ≠ 200 après 3 essais espacés de 20 s |
| `api.js`, `config.js` publiés | absents, ou `config.js` sans base configurée |
| Aucune clé secrète publiée | `sb_secret_…` ou un JWT de rôle `service_role` dans `config.js` / `api.js` |
| Fichiers de travail non servis | `CLAUDE.md`, `README.md`, `outils/…sql`, `outils/migrations.txt`, `bureau/package.json`, `docs/…` répondent autre chose que 404 |
| HTTP → HTTPS | avertissement seulement |
| Auth Supabase | `auth/v1/health` ≠ 200 |
| Base | `sante()` : `status ≠ ok`, `pret = false`, ou `notifications = en_retard` (un envoi attend depuis plus de 15 min : pg_cron arrêté ?). `sante()` absente (migration pas encore passée) : avertissement seulement |
| Suivi public | `suivre_colis` ≠ 200 |

`sante()` (`outils/supabase-production.sql`) est la seule fonction ajoutée pour
la surveillance : ouverte aux visiteurs, elle ne rend que
`{status, base, notifications, pret, heure}` — aucun chiffre d'activité.

## Les alertes

| Canal | Comment |
|---|---|
| Workflow en échec | GitHub envoie un e-mail à la personne qui a modifié le workflow en dernier (réglage : GitHub > Settings > Notifications > Actions, « Send notifications for failed workflows only ») |
| Supabase | e-mails d'usage (quota à 80 %), d'incident, de sécurité (*Advisors*) au propriétaire du projet — vérifier l'adresse dans Supabase > Organization > Team |
| Échecs d'envoi de messages | onglet Notifications du tableau de bord, et `controle-integrite.sql` (envois en échec sur 24 h) |

**Limites connues** (voir go-no-go.md) :

- l'alerte passe par l'e-mail d'une seule personne : pas d'astreinte, pas de SMS ;
- GitHub peut retarder un workflow planifié de plusieurs minutes, et **suspend
  les workflows planifiés d'un dépôt public sans activité depuis 60 jours**
  (GitHub prévient par e-mail ; réactiver dans l'onglet Actions) ;
- aucune surveillance depuis l'extérieur de GitHub : si GitHub Actions tombe, rien
  n'alerte. Un service externe gratuit (UptimeRobot, Better Stack…) qui interroge
  la page d'accueil et `rpc/sante` couvrirait ce cas (go-no-go.md, recommandation R7).

## Les journaux

| Où | Ce qu'on y trouve | Durée |
|---|---|---|
| Supabase > Logs (API, Postgres, Auth) | chaque requête, erreurs SQL, connexions | selon l'offre (1 jour en gratuit, 7 en Pro) |
| `journal_audit` (table) | qui a changé quoi : colis, factures, paiements, rôles, règles de notification | sans limite |
| `colis_historique` | chaque événement d'un colis, avec son auteur | sans limite |
| `notification_envois` | chaque envoi, sa réponse fournisseur, son code d'erreur | 180 jours |
| GitHub Actions | publications, essais, surveillance, sauvegardes | 90 jours |
| Bureau | `journal` du pont (sur le poste) | local |

Aucun de ces journaux ne contient de mot de passe, de jeton complet, de clé
`service_role` ni de clé de fournisseur : les pages et les applications ne les
connaissent pas, et les fonctions d'envoi ne gardent que le code de réponse
(docs/notifications.md). Les journaux GitHub d'un dépôt public sont **publics** :
aucun workflow n'y écrit de donnée de client (la sauvegarde n'affiche que des
tailles de fichiers).

## Contrôles périodiques (à la main)

| Quand | Quoi |
|---|---|
| Chaque semaine | `controle-integrite.sql` et `controle-securite.sql` dans le SQL Editor : aucune ligne `ALERTE` |
| Chaque semaine | Supabase > Advisors (Security, Performance) |
| Chaque mois | Supabase > Usage (base, stockage, sorties, utilisateurs actifs) |
| Chaque trimestre | restauration d'essai (backup.md) |
