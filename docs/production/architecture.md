# Architecture de production

```text
        Clients (navigateur)      Équipe (navigateur ou bureau)      Clients (téléphone)
                │                          │                                │
   Site statique GitHub Pages     Application de bureau Electron     Application Expo
   wilnergraph92.github.io/       (bureau/) : une fenêtre sur         (dépôt goship-express-app)
   Goship-express-site/           admin.html DU SITE, chargé en       Android / iOS
   (HTML, CSS, JS, sans build)    ligne — aucune copie, aucune règle
                │                          │                                │
                └──────────────────────────┼────────────────────────────────┘
                                           │ HTTPS, clé publique + jeton de session
                                           ▼
                        Supabase — projet de production gpfdyslysqjmojgzggib
             ┌──────────────┬──────────────┬──────────────┬─────────────────────┐
             │ Auth         │ PostgREST    │ Realtime     │ Storage              │
             │ (comptes,    │ (tables sous │ (colis,      │ (logo des e-mails,   │
             │ sessions)    │ RLS, RPC)    │ factures,    │ espace « site »)     │
             │              │              │ notif.)      │                      │
             └──────────────┴──────┬───────┴──────────────┴─────────────────────┘
                                   ▼
                     PostgreSQL : TOUTES les règles métier
          colis · événements · scanner · factures · paiements · permissions
          tableau de bord · analytics · notifications (moteur + file)
                                   │ pg_cron (chaque minute) + pg_net
                                   ▼
              Fournisseurs : e-mail (Brevo ou Resend) · WhatsApp (Meta) · push (Expo)
```

## Ce qu'il faut retenir

- **Il n'y a pas de serveur d'application.** Le « backend » est Supabase :
  PostgREST expose les tables (protégées par la RLS) et les fonctions SQL
  (`creer_colis`, `executer_operation`, `enregistrer_paiement`, `vue_generale`…).
  Toutes les règles — prix, statuts, transitions, paiements, permissions,
  notifications — vivent dans la base (`outils/*.sql`). Le site, le bureau et le
  mobile n'en ont aucune copie active en production.
- **Une seule base.** Web, bureau et mobile parlent au même projet Supabase. Le
  mode « démonstration » d'`api.js` (tout en `localStorage`) ne s'active qu'en
  local sans configuration ; en ligne, sans configuration, le site se met en
  mode « hors service » et le dit.
- **Les secrets restent côté serveur.** Le site et les applications n'ont que la
  clé *publishable*, faite pour être publique. Les clés des fournisseurs sont
  dans le coffre-fort Vault de Supabase (`definir_reglage`) et ne sont lues que
  par les fonctions SQL qui appellent les fournisseurs.
- **Le bureau n'est qu'une fenêtre sur le site** : une mise en ligne du site met
  à jour le tableau de bord du bureau. Seule sa coquille (fenêtre, impression,
  session chiffrée) a des versions.
- **Le mobile est la seule partie dont les anciennes versions restent en
  service** : une fonction dont il dépend ne change jamais de nom ni de forme de
  réponse (voir CLAUDE.md, « L'application mobile »).

## Dépendances externes et ce qui se passe quand elles tombent

| Dépendance | Si elle tombe | Détection | Voir |
|---|---|---|---|
| GitHub Pages | site, tableau de bord et bureau inaccessibles ; le mobile continue (il parle directement à Supabase) | `surveillance.yml` | incident-response.md |
| GitHub Actions | plus de surveillance, de sauvegarde ni de publication ; le service continue | Healthchecks (`HEARTBEAT_URL`) | monitoring.md |
| Supabase (base, Auth, API) | plus rien ne fonctionne, sauf les pages vitrines | `surveillance.yml` (auth, `sante()`, suivi) | disaster-recovery.md |
| pg_cron | les notifications restent « en attente » : rien ne se perd, rien ne part | `sante()` → `notifications: en_retard` | troubleshooting.md |
| Brevo / Resend / Meta / Expo | l'envoi échoue, est réessayé (30 s, 2 min, 10 min), puis marqué « échec » avec son code ; la notification reste lisible dans l'espace client | onglet Notifications, `controle-integrite.sql` | docs/notifications.md |
| Boutiques d'applications | pas de nouvelle version mobile ; les installées continuent | — | rollback.md |

## Le chemin d'une modification

```text
développement (démo locale, bancs d'essai)
   → pull request : essais.yml, bureau.yml, preproduction.yml (goship-staging)
   → sauvegarde du jour restaurée (sauvegarde.yml)
   → contrôles de la production (controles-production.yml, lecture seule)
   → migrations en production (appliquer-chaine.sh, à la main)
   → audit (audit-production.yml) : chaîne complète
   → fusion sur main : deploy.yml publie et vérifie
   → surveillance.yml toutes les 30 minutes
```

