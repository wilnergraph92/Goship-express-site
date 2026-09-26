# Reprise après sinistre

## Objectifs

| | Aujourd'hui | Une fois `sauvegarde.yml` en service | Avec Supabase Pro + PITR |
|---|---|---|---|
| **RPO** (données qu'on accepte de perdre) | **inconnu** : aucune sauvegarde vérifiée (backup.md) | 24 h (une sauvegarde par nuit) | quelques minutes |
| **RTO** (temps pour revenir en service) | **inconnu** : aucune restauration réelle faite | estimé 2 à 4 h pour la base et le site ; **1 à 3 jours pour le mobile** si l'adresse Supabase change | idem, sauf restauration sur place (sans changement d'adresse) : moins d'1 h |

Les estimations de RTO ne sont **pas mesurées** : les remplacer par la durée
réelle de la première restauration (backup.md, « Tester »).

Perte de 24 h, concrètement : les colis reçus, les scans, les paiements et les
comptes créés depuis la dernière nuit. Ils se reconstituent depuis les étiquettes
imprimées, les reçus et les e-mails de notification envoyés — d'où l'intérêt d'une
offre avec PITR dès que l'activité le justifie.

## Scénarios

### 1. Données effacées ou abîmées (erreur humaine, migration ratée)

1. **Arrêter l'écriture** : prévenir l'équipe (plus de scan), et si c'est une
   migration, ne pas lancer le fichier suivant.
2. Mesurer : `controle-integrite.sql` (lecture seule).
3. Petit périmètre (quelques lignes) : restaurer la dernière sauvegarde dans la
   **préproduction**, y retrouver les lignes, et les réécrire en production par
   les fonctions de service (`creer_colis`, `enregistrer_paiement`…) ou un
   événement `CORRECTION` — jamais par un `UPDATE` qui contournerait les verrous.
4. Grand périmètre : restauration complète (scénario 2) ou, avec PITR, retour à
   un instant donné depuis Supabase > Database > Backups.

### 2. Projet Supabase perdu (suppression, suspension de paiement, compte compromis)

1. Nouveau projet Supabase (même région), extensions `pg_cron` et `pg_net`.
2. Restaurer la dernière sauvegarde (backup.md, « Restaurer »), rejouer la chaîne,
   contrôles, Vault, réglages Auth.
3. **Changer l'adresse et la clé *publishable*** :
   - site : `assets/js/config.js` → PR → `main` (le bureau suit : il charge le site) ;
   - mobile : `goship-express-app/config.js` → **nouvelle version** sur les
     boutiques (revue Apple : 1 à 3 jours). Les applications installées restent
     en panne jusque-là.
4. Sessions : tous les utilisateurs se reconnectent (nouveaux jetons). Les mots de
   passe restent valables (`auth.users` restauré).

Pour éviter l'étape 3 côté mobile : un domaine personnalisé Supabase
(`api.goshipexpress.com`, option payante) permet de changer de projet sans changer
d'adresse (go-no-go.md, recommandation R4).

### 3. GitHub Pages indisponible, ou dépôt/compte GitHub compromis

- Pages en panne : le mobile continue (il parle à Supabase directement) ; site,
  tableau de bord et bureau sont inaccessibles. Aujourd'hui l'adresse est
  `wilnergraph92.github.io` : **aucune bascule possible**, il faut attendre
  GitHub. Avec un domaine personnalisé (`www.goshipexpress.com`, DNS chez
  Hostinger), on peut publier les mêmes fichiers ailleurs (Hostinger, tout
  hébergement statique) et changer le DNS (go-no-go.md, recommandation R3).
- Compte GitHub compromis : changer le mot de passe, révoquer les sessions et
  jetons, vérifier les derniers commits de `main` et les workflows, puis faire
  tourner `SUPABASE_DB_URL` (mot de passe de la base) — secrets.md.

### 4. Fournisseur de messages en panne (Brevo, Resend, Meta, Expo)

Rien à faire : les envois sont réessayés puis marqués « échec » avec leur code ;
les notifications restent lisibles dans l'espace client et l'application. Si la
panne dure, changer de fournisseur e-mail (`definir_reglage`) — docs/notifications.md.

### 5. Clé privée de sauvegarde perdue

Les sauvegardes existantes sont illisibles. Tout de suite : nouvelle paire
`age-keygen`, nouveau secret `SAUVEGARDE_DESTINATAIRE`, sauvegarde manuelle,
restauration d'essai. D'où les deux copies hors ligne (backup.md).

### 6. Panne de région Supabase

Un projet Supabase vit dans une seule région. Attendre le retour du service
(status.supabase.com), ou scénario 2 dans une autre région si la panne dure.

## Contacts et accès à avoir sous la main

Hors du dépôt, dans le gestionnaire de mots de passe : accès propriétaire
GitHub, Supabase, Expo, Apple Developer, Google Play Console, Hostinger, Brevo /
Resend, Meta ; la clé privée de sauvegarde ; le mot de passe de la base. Au moins
**deux personnes** doivent pouvoir y accéder (go-no-go.md, recommandation R6).
