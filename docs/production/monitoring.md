# Surveillance, santé, journaux, alertes

## Ce qui est surveillé automatiquement

`outils/production/surveiller.sh` — lecture seule, clé *publishable* seulement,
aucune donnée de client. Lancé :

- **après chaque publication** du site (`deploy.yml`, job `verifier`) ;
- **toutes les 30 minutes** (`surveillance.yml`, à h 07 et h 37) — une fois
  fusionné sur `main` (GitHub ne planifie que la branche par défaut) ;
- à la main : Actions > Surveillance de la production > Run workflow, ou
  `bash outils/production/surveiller.sh [adresse]` depuis un ordinateur.

Deux niveaux : **CRITIQUE** (le service est cassé ou exposé : le workflow
échoue, l'alerte part) et **ATTENTION** (à traiter, le service tient : journal et
résumé du passage, sans alerte).

| Vérification | CRITIQUE si… |
|---|---|
| Pages `index`, `connexion`, `mon-compte`, `admin`, `en/index`, `ht/index` | réponse ≠ 200 après 3 essais espacés de 20 s |
| `api.js`, `config.js` publiés | absents, ou `config.js` sans base configurée |
| Aucune clé secrète publiée | `sb_secret_…` ou un JWT de rôle `service_role` dans `config.js` / `api.js` |
| Fichiers de travail non servis | `CLAUDE.md`, `README.md`, `outils/…sql`, `outils/migrations.txt`, `bureau/package.json`, `docs/…` répondent autre chose que 404 |
| HTTP → HTTPS | avertissement seulement |
| Auth Supabase | `auth/v1/health` ≠ 200 |
| Base | `sante()` : `status ≠ ok`, `pret = false`, ou `notifications = en_retard` (un envoi attend depuis plus de 15 min : pg_cron arrêté ?). `sante()` absente (migration pas encore passée) : avertissement seulement |
| Suivi public | `suivre_colis` ≠ 200 |
| Fonctions du site et de l'application (`mes_permissions`, `mon_resume`, `mes_factures`, `vue_generale`, `types_evenement`, `operations_du_scanner`, `moyens_paiement`, `analytics_synthese`, `creer_prealerte`) | l'une est **absente** (404 PGRST202 : une page ou l'application est cassée) ou **répond à un visiteur** (200) |
| Auth | confirmation des adresses e-mail désactivée (réglage public `auth/v1/settings`) : ATTENTION |

Éprouvé contre un vrai PostgREST : `essai-mobile.py`, section Z (fonction retirée,
fonction ouverte à tort).

### L'audit quotidien (`audit-production.yml`, 6 h 41 UTC)

`outils/production/sonder.sh` : pour chaque fichier de `outils/migrations.txt`,
une fonction témoin appelée comme un visiteur (401 = présente, 404 = absente) ; le
workflow **échoue tant que la chaîne n'est pas complète en production**. Sur une
pull request, il fait rapport sans échouer. Résultat du 26/09/2026 : 9 sur 11
(go-no-go.md).

### Les contrôles hebdomadaires (`controles-production.yml`, lundi 6 h 53 UTC)

`controler.sh` : `controle-securite.sql` et `controle-integrite.sql` en lecture
seule, avec `SUPABASE_DB_URL`. Échoue à la moindre ALERTE ; journal sans donnée,
détail chiffré en artefact. Ne fait rien (avis) tant que le secret n'est pas posé.

`sante()` (`outils/supabase-production.sql`) est la seule fonction ajoutée pour
la surveillance : ouverte aux visiteurs, elle ne rend que
`{status, base, notifications, pret, heure}` — aucun chiffre d'activité.

## Les alertes

| Canal | Comment |
|---|---|
| Workflow en échec | GitHub envoie un e-mail à la personne qui a modifié le workflow en dernier (réglage : GitHub > Settings > Notifications > Actions, « Send notifications for failed workflows only ») |
| Seconde personne | secret `ALERTE_WEBHOOK` : un sujet ntfy.sh (notification sur téléphone : installer l'application ntfy, s'abonner au sujet — un nom long et imprévisible), un webhook Slack ou Discord. Envoyé à chaque CRITIQUE de `surveillance.yml` ; message sans donnée (« CRITIQUE » + lien du journal) |
| Surveillance de la surveillance | secret `HEARTBEAT_URL` (Healthchecks.io, gratuit) : chaque passage réussi l'appelle, chaque échec appelle `/fail`. Réglé sur « période 30 min, grâce 30 min », Healthchecks prévient (e-mail, SMS, plusieurs personnes) si GitHub Actions ne tourne plus |
| Supabase | e-mails d'usage (quota à 80 %), d'incident, de sécurité (*Advisors*) au propriétaire du projet — vérifier l'adresse dans Supabase > Organization > Team |
| Échecs d'envoi de messages | onglet Notifications du tableau de bord, et `controle-integrite.sql` (envois en échec sur 24 h) |

**Limites connues** (voir go-no-go.md) :

- tant que `ALERTE_WEBHOOK` et `HEARTBEAT_URL` ne sont pas posés (go-no-go.md,
  A8), l'alerte passe par l'e-mail d'une seule personne ;
- GitHub peut retarder un workflow planifié de plusieurs minutes, et **suspend
  les workflows planifiés d'un dépôt public sans activité depuis 60 jours**
  (GitHub prévient par e-mail ; réactiver dans l'onglet Actions) ;
- sans `HEARTBEAT_URL`, rien n'alerte si GitHub Actions lui-même s'arrête ;
- au 26/09/2026, l'exécution **planifiée** de `surveillance.yml` n'a pas encore
  été observée (lancée à la main : verte). La vérifier dans l'onglet Actions.

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
| Chaque semaine | le passage du lundi de `controles-production.yml` : vert (sinon lire le journal, déchiffrer le détail) |
| Chaque semaine | Supabase > Advisors (Security, Performance) |
| Chaque mois | Supabase > Usage (base, stockage, sorties, utilisateurs actifs) |
| Chaque jour | `sauvegarde.yml` : les deux jobs verts ; noter RPO/RTO s'ils changent |
| Chaque trimestre | restauration dans un vrai projet Supabase (backup.md) |
