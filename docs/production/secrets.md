# Secrets

## Règle

Aucun secret dans le dépôt, le site publié, l'application mobile, l'application
de bureau, les variables `EXPO_PUBLIC_*` ou un fichier `.github/workflows/*.yml`.
Le site et les applications n'ont que la clé **publishable** de Supabase, faite
pour être publique : elle ne donne que ce que la RLS autorise.

## Inventaire

| Secret | Où il vit | Qui y accède | Rotation |
|---|---|---|---|
| Clé `service_role` / clé secrète Supabase | tableau de bord Supabase seulement ; **utilisée nulle part** dans le projet | propriétaire du projet | Supabase > Project Settings > API Keys |
| Mot de passe de la base | gestionnaire de mots de passe ; secret GitHub `SUPABASE_DB_URL` (environnement `production`) pour la sauvegarde | propriétaire | Supabase > Database > Reset password, puis mettre à jour le secret GitHub |
| Clés Brevo / Resend, jeton WhatsApp (Meta), jeton d'accès Expo s'il y en a | Vault Supabase (`definir_reglage`) | fonctions SQL d'envoi seulement | chez le fournisseur, puis `select public.definir_reglage('<nom>', '<nouvelle valeur>');` |
| Clé privée de sauvegarde (age) | **hors ligne** : deux copies (gestionnaire de mots de passe + support hors ligne) | propriétaire | nouvelle paire `age-keygen`, nouveau secret `SAUVEGARDE_DESTINATAIRE` ; garder l'ancienne clé tant que des sauvegardes chiffrées pour elle existent |
| Signature Android (keystore de production) | serveurs Expo (EAS credentials) | compte Expo de GoShip Express | ne se change pas sans procédure Google Play (App Signing) |
| Certificats Apple | serveurs Expo (EAS credentials) / compte Apple Developer | propriétaire | EAS gère le renouvellement |
| Comptes GitHub, Supabase, Expo, Apple, Google, Hostinger | propriétaire ; double authentification recommandée partout | propriétaire | — |

## Audit du 26/09/2026 (Phase 12)

Méthode : recherche des motifs `service_role`, `sb_secret_`, JWT (rôle décodé,
valeur jamais affichée), clés privées, jetons GitHub/AWS/Stripe/Brevo/Resend/
SendGrid/Meta, mots de passe affectés, chaînes de connexion Postgres, dans
l'arbre **et tout l'historique Git** des deux dépôts (site : 30 commits ;
mobile : 18). Script : voir le rapport de phase.

| Résultat | Emplacement | Verdict |
|---|---|---|
| Clé Supabase *publishable* (`sb_publishable_…`) | `assets/js/config.js`, `goship-express-app/config.js` | publique par conception — rien à faire |
| Identifiants du compte de **démonstration** | `assets/js/api.js` (`ADMIN_DEMO`), `admin.html` (paragraphe masqué) | valables **uniquement** dans le mode démo local (`localStorage`) ; en ligne le site est en mode `supabase`. Vérifier qu'aucun compte `@goship.demo` n'existe en production : `controle-securite.sql`, section 8 |
| Motif « clé Meta » | `outils/generateur/export/.image-slots.state.json` | faux positif : image encodée en base64 |
| Mot `service_role` | commentaires, essais, SQL (`grant … to service_role`) | aucune clé |
| Clés, keystores, certificats, `.env` | aucun, ni dans l'arbre ni dans l'historique | — |
| Workflows | aucun `secrets.` hors `sauvegarde.yml` ; aucun `pull_request_target` ; permissions `contents: read` par défaut | — |

**Aucun secret n'a été exposé dans Git : aucune rotation n'est nécessaire.**

## Garde-fous automatiques

- `deploy.yml` refuse de publier un site qui contient un fichier de travail
  (`.md`, `.sql`, `.py`, `.env`, clés, sauvegardes) ou une clé secrète
  (`sb_secret_`, JWT `service_role`, clé privée).
- `surveiller.sh` vérifie après chaque publication, puis toutes les 30 minutes,
  que `config.js` et `api.js` publiés ne contiennent aucune clé secrète.
- L'application mobile : `essais/controle-paquet.mjs` (paquet construit) et les
  contrôles de l'APK et de l'app iOS dans `mobile.yml`.
- GitHub : activer *Secret scanning* et *Push protection* (Settings > Code
  security) — gratuit sur un dépôt public.

## Si un secret fuit

1. Le révoquer **chez son émetteur d'abord** (Supabase, Brevo, Meta, GitHub…) :
   une fois révoqué, sa copie ne vaut plus rien.
2. Poser le nouveau là où il vit (tableau ci-dessus), vérifier le service
   (`surveiller.sh`, un essai d'envoi depuis l'onglet Notifications).
3. Chercher l'usage fait pendant l'exposition : Supabase > Logs (API, Auth),
   journaux du fournisseur.
4. Retirer le secret du dépôt. S'il est dans l'historique Git d'un dépôt public,
   la révocation suffit à le neutraliser ; réécrire l'historique (git filter-repo)
   ne se fait qu'en connaissance de cause (tous les clones deviennent incompatibles).
5. Consigner l'incident (incident-response.md).
