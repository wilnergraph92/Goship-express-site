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
