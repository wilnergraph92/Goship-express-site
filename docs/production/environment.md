# Environnements

| | Développement | Essai (automatique) | Préproduction (staging) | Production |
|---|---|---|---|---|
| **Existe ?** | oui | oui | **outillée, projet à créer** (go-no-go.md, A2) | oui |
| Base | `localStorage` (mode démo) | PostgreSQL jetable (pgserver), recréé à chaque essai | projet Supabase séparé, à créer | projet Supabase `gpfdyslysqjmojgzggib` |
| Site | `python3 -m http.server 8765` ou « Voir le site en local.command » | idem, `config.js` remplacé par une configuration vide | site servi en local avec la configuration de préproduction (jamais commitée) | GitHub Pages : `https://wilnergraph92.github.io/Goship-express-site/` |
| Bureau | `environnements.json` → `local` | `bureau/essais/serveur-essai.js` (`config.js` vide) | — | `environnements.json` → `production` (l'adresse ci-dessus) |
| Mobile | `EXPO_PUBLIC_GOSHIP_ENV=essai` + base d'essai | `essai-mobile.py --serveur` (CI) | profil EAS `staging` (dépôt mobile, PR #2) : adresse et clé publiable de goship-staging à écrire dans `eas.json` | profils `development`, `preview`, `production` |
| Fournisseurs | aucun (envois « annulés — non configuré ») | aucun (pg_net remplacé par une doublure) | comptes de test des fournisseurs | Brevo/Resend, Meta, Expo — **configuration à vérifier** |

## Où est la configuration

Une adresse = un seul endroit :

| Quoi | Où | Public ? |
|---|---|---|
| Adresse et clé *publishable* Supabase du site | `assets/js/config.js` | oui, par conception (protégée par la RLS) |
| Adresse et clé *publishable* Supabase du mobile | `goship-express-app/config.js` (`PRODUCTION`) | oui, embarquée dans l'application |
| Adresse du site pour le bureau | `bureau/config/environnements.json` | oui |
| Adresse du site pour le mobile (mot de passe oublié, fermer un compte) | `goship-express-app/config.js` (`siteUrl`) | oui |
| Clés des fournisseurs, adresse du site dans les e-mails, logo | Vault Supabase (`definir_reglage`, noms visibles dans `controle-securite.sql`) | **non** |
| Chaîne de connexion de la base (sauvegarde) | secret GitHub `SUPABASE_DB_URL`, environnement `production` | **non** |

L'adresse de production du site apparaît donc dans trois fichiers (site, bureau,
mobile). Un changement de domaine se fait dans les trois, et le mobile demande
une nouvelle version publiée (voir rollback.md).

## Identifiants de production (aucun secret)

- Projet Supabase : `gpfdyslysqjmojgzggib` (région, offre et sauvegardes : à
  relever dans Project Settings et à noter ici — non vérifiables depuis le dépôt).
- Dépôt du site : `wilnergraph92/Goship-express-site` (public), branche `main`
  publiée par GitHub Pages.
- Dépôt mobile : `wilnergraph92/goship-express-app`, identifiants
  `com.goshipexpress.app` (Android et iOS).
- Bureau : `com.goshipexpress.bureau`, version 1.0.0.

## Créer la préproduction (à faire une fois)

1. Supabase > New project : `goship-staging`, même région que la production,
   mot de passe de base généré et rangé dans le gestionnaire de mots de passe.
2. SQL Editor : exécuter la chaîne `outils/migrations.txt`, dans l'ordre, puis
   `outils/production/controle-securite.sql` (aucune alerte hors extensions à
   activer : Database > Extensions > `pg_cron`, `pg_net`).
3. Authentication > URL Configuration : Site URL = `http://localhost:8765`,
   Redirect URLs = `http://localhost:8765/**`.
4. Créer un compte d'équipe de test (adresse du domaine de l'entreprise, jamais
   `@goship.demo`), lui donner le rôle avec `select public.definir_admin('…');`.
5. Pour tester le site contre la préproduction : copier `assets/js/config.js`
   hors du dépôt, y mettre l'adresse et la clé *publishable* de `goship-staging`,
   et servir le site avec ce fichier à la place (**ne jamais le commiter** : le
   site en ligne parlerait à la préproduction).
6. Fournisseurs : clés de test (Brevo en mode test, numéro de test WhatsApp),
   posées avec `definir_reglage` dans `goship-staging` seulement.

7. GitHub > Settings > Environments > New environment **`staging`** :
   - secret `STAGING_DB_URL` : chaîne de connexion de goship-staging (Connect >
     *Session pooler*) ;
   - variables `STAGING_SUPABASE_URL` (`https://<ref>.supabase.co`) et
     `STAGING_SUPABASE_CLE` (clé *publishable*, publique par conception).
8. Actions > **Préproduction** > Run workflow : chaîne des migrations
   (`appliquer-chaine.sh`, qui refuse l'adresse de production), contrôles
   (`controler.sh`), essai métier (`essai-metier.sql`, dans une transaction
   annulée : rien ne reste) et sonde de l'API (`sonder.sh`). Le workflow repasse
   sur chaque pull request qui touche `outils/*.sql` ou `outils/production/`.
9. Mobile : dans `eas.json` du dépôt `goship-express-app`, profil `staging`,
   remplacer les deux valeurs `REMPLACER…` ; `eas build --profile staging`.

Toute migration passe par la préproduction avant la production (deployment.md).

## Domaine de production (`https://goshipexpress.net`)

Depuis le 26/10/2026, le site est servi par **Hostinger** à `https://goshipexpress.net`
(`www.` et `http://` y redirigent). GitHub Pages
(`https://wilnergraph92.github.io/Goship-express-site/`) reste publié à l'identique, en
secours. Le **backend reste l'adresse officielle de Supabase**
(`https://gpfdyslysqjmojgzggib.supabase.co`) : un domaine personnalisé pour Supabase
(option payante) n'est **pas** nécessaire.

**Mise à jour.** `deploy.yml` construit et contrôle le site une seule fois, puis le
pousse sur GitHub Pages et, avec `.htaccess`, sur la branche `hostinger` (un commit par
mise en ligne, jamais forcé). Hostinger suit cette branche (déploiement Git automatique
de hPanel, compte GitHub relié une fois) et met goshipexpress.net à jour à chaque commit. Aucun mot de
passe Hostinger n'est rangé dans GitHub. Les pages et les scripts sont servis
`Cache-Control: no-cache` (`.htaccess`) : rien à vider après une mise en ligne.

Les sauvegardes ne dépendent pas du domaine du site (`outils/README-backup.md`,
section K) : rien à changer de ce côté.

Réglages qui portent l'adresse du site :

1. **Supabase Auth** (Authentication > URL Configuration), projet de **production** :
   - *Site URL* = `https://goshipexpress.net`
   - *Redirect URLs* = `https://goshipexpress.net/**` ; pendant la transition,
     garder aussi `https://wilnergraph92.github.io/Goship-express-site/**`, puis la
     retirer ; **jamais** `localhost` en production.
   La préproduction garde ses propres URL (section « Créer la préproduction ») ; le
   développement, `http://localhost:8765`.
2. **Adresse dans les e-mails** (Vault, production) :
   `select public.definir_reglage('site_url', 'https://goshipexpress.net');` et
   `select public.definir_reglage('courriel_icones_url', 'https://goshipexpress.net/');`
3. **`siteUrl` de `assets/js/config.js`** = `https://goshipexpress.net` (fait le
   26/10/2026) : liens « Suivre mon colis » des messages envoyés depuis le tableau de
   bord et QR des étiquettes.
4. **Applications** : l'application de bureau ouvre goshipexpress.net depuis la
   version 1.0.1 (`bureau/config/environnements.json`) ; l'application mobile
   depuis la mise à jour à distance du 26/10/2026 (`siteUrl` de son `config.js`).
   Les postes en 1.0.0 ouvrent encore GitHub Pages tant qu'ils ne sont pas
   réinstallés. `outils/production/surveiller.sh`
   surveille goshipexpress.net par défaut ; le contrôle de `deploy.yml` reçoit
   l'adresse GitHub Pages.
5. Vérifier : inscription, « mot de passe oublié » (le lien doit ouvrir
   `goshipexpress.net`), connexion au tableau de bord, application de bureau.
