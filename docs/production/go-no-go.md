# GO / NO-GO

## Décision du 26/09/2026 : **NO-GO**

Évaluée à la fin de la Phase 12, sur l'état des deux dépôts et ce qui a pu être
vérifié depuis eux. **Rien n'a été modifié en production** pendant cette
évaluation : aucune migration, aucune donnée, aucun réglage.

Le code est prêt et éprouvé : tous les essais sont verts. Mais plusieurs
critères critiques **n'ont pas pu être vérifiés** sur la production elle-même
(base, sauvegardes, réglages Auth). Un critère non vérifié compte comme non
rempli. Le passage à GO demande des gestes qui touchent aux comptes du
propriétaire (Supabase, GitHub, Apple, Google) : ils sont listés plus bas, dans
l'ordre.

### Par composant

| Composant | Verdict | Ce qui bloque |
|---|---|---|
| Base (Supabase) | **NO-GO** | B1, B2, B3 |
| Site web + tableau de bord | **NO-GO** | dépend de la base (B1) ; B4 |
| Bureau (Windows, macOS) | **NO-GO** pour une distribution ; usage interne actuel inchangé | B7 |
| Mobile (Android, iOS) | **NO-GO** | B1, B6 |

## Critères critiques

| # | Critère | État | Preuve / manque |
|---|---|---|---|
| C1 | Aucun secret dans les dépôts, l'historique, le site publié, les paquets | **vérifié** | audit des deux dépôts, tout l'historique (secrets.md) ; garde-fou de `deploy.yml` ; `controle-paquet.mjs` (mobile) |
| C2 | Tous les essais verts | **vérifié** | 1 035 vérifications sur base réelle (dix bancs), 332 en démonstration, 43 SQL (e-mails, factures) ; mobile 51 + 84, CI Android et iOS (Maestro) verte, installateurs du bureau essayés |
| C3 | La base de production a toute la chaîne de migrations | **non vérifié** | l'état de la base n'est pas visible depuis le dépôt. Le site en ligne (`main`, Phase 10) appelle déjà des fonctions des Phases 2 à 10 → **B1** |
| C4 | Sécurité de la base de production (RLS, droits des visiteurs, verrous, comptes de démonstration) | **non vérifié** | `controle-securite.sql` jamais lancé en production → **B1** |
| C5 | Intégrité des données de production | **non vérifié** | `controle-integrite.sql` jamais lancé en production → **B1** |
| C6 | Sauvegarde existante **et** restauration réussie | **non rempli** | offre et sauvegardes Supabase inconnues ; `sauvegarde.yml` pas en service ; aucune restauration réelle → **B3** |
| C7 | Préproduction | **non rempli** | n'existe pas → **B2** |
| C8 | Auth : *Site URL*, *Redirect URLs*, confirmation d'e-mail, mot de passe | **non vérifié** | le README notait le *Site URL* encore sur `localhost:3000` → **B4** |
| C9 | Surveillance et alertes actives | **non rempli** | `surveillance.yml` écrit et éprouvé, mais GitHub ne le planifie qu'une fois sur `main` → **B5** |
| C10 | Retour arrière possible | **vérifié (site)** / documenté (base, mobile) | site : `git revert` + republication ; base : migrations rejouables, restauration éprouvée sur base d'essai |
| C11 | HTTPS | **non vérifié** | `github.io` impose HTTPS par défaut ; le réseau de l'environnement de travail bloque `github.io` → vérifié automatiquement par le premier contrôle après publication |
| C12 | Mobile signé, publié en test interne | **non rempli** | aucune soumission EAS, pas de fiche de boutique → **B6** |
| C13 | Bureau signé (Windows) et notarisé (macOS) | **non rempli** | → **B7** |

## Bloqueurs et actions

Les actions sont à faire **par le propriétaire des comptes** (elles demandent
ses accès). Aucune ne demande de coller un secret dans une conversation.

| # | Bloqueur | Action | Doc |
|---|---|---|---|
| B1 | État de la base de production inconnu | **A4** : lancer `controle-securite.sql` et `controle-integrite.sql` dans le SQL Editor (lecture seule, rien n'est modifié) ; noter les lignes ALERTE et la section « Migrations ». Puis **A5** : appliquer la chaîne manquante après A3 | deployment.md § 1 |
| B2 | Pas de préproduction | **A2** : créer `goship-staging` (gratuit), y passer la chaîne, les contrôles | environment.md |
| B3 | Aucune sauvegarde vérifiée | **A1** : relever l'offre et les sauvegardes Supabase (Database > Backups). **A3** : clé age, environnement `production`, secrets, lancer `sauvegarde.yml`, **restaurer** dans un projet vide | backup.md |
| B4 | Réglages Auth non vérifiés | **A6** : *Site URL* = adresse de production, *Redirect URLs* sans `localhost`, confirmation d'e-mail, mot de passe ≥ 6 ; essai « mot de passe oublié » | README, « Les cinq réglages » |
| B5 | Surveillance pas encore active | **A7** : fusionner la PR #13 **après A5** → `deploy.yml` vérifie le site publié, `surveillance.yml` démarre | monitoring.md |
| B6 | Mobile non publié | **A8** : comptes Apple Developer et Google Play, `eas credentials`, fiches des boutiques, `eas build` + `submit` en test interne, parcours de fumée, puis déploiement progressif ; fusionner la PR mobile #2 après A5 | deployment.md § 4 |
| B7 | Bureau non signé | **A9** : certificat de signature de code Windows ; compte Apple Developer ID + notarisation ; secrets de signature dans l'environnement `production` | deployment.md § 3 |

Ordre : A1 → A2 → A3 → A4 → A5 → A6 → A7, puis A8 et A9 indépendamment.

## Risques

### Critiques (bloquants, ci-dessus)
B1 à B7.

### Moyens (à traiter avant ou juste après GO)
| # | Risque | Action |
|---|---|---|
| M1 | `main` sans protection : un push direct publie sans essais | Settings > Branches : exiger une PR et `essais.yml` vert sur `main` |
| M2 | *Secret scanning* / *Push protection* non vérifiés | Settings > Code security : les activer (gratuit, dépôt public) |
| M3 | Une seule personne a les accès et reçoit les alertes | deuxième administrateur (GitHub, Supabase), gestionnaire de mots de passe partagé |
| M4 | Adresse `github.io` : pas de bascule possible si GitHub Pages tombe ; changer d'hébergeur changerait l'adresse du mobile et du bureau | domaine personnalisé (R3) |
| M5 | Fournisseurs de messages non configurés ou non vérifiés : les clients ne reçoivent rien hors de « Mon compte » | mise en service prudente (deployment.md, « Premier passage ») |
| M6 | Suivi public sans limite de débit, numéros de colis qui se suivent : le volume d'activité peut être estimé | numéros tirés au hasard (partie facultative de `supabase.sql`) ; limite de débit Supabase |
| M7 | Sauvegarde conservée dans GitHub seulement (90 jours) | copie mensuelle hors ligne (backup.md) |
| M8 | Actions GitHub citées par étiquette (`@v4`), pas par empreinte | épingler par SHA, Dependabot pour les mettre à jour |

### Faibles (non bloquants)
| # | Risque | Note |
|---|---|---|
| L1 | 14 vulnérabilités « modérées » dans les dépendances de **construction** du mobile (outils Expo) ; `decode-uri-component` (déni de service) | aucune n'est exploitable depuis l'application publiée ; suivre les mises à jour d'Expo |
| L2 | Le site en ligne sert encore `CLAUDE.md`, `.htaccess`… (ancien `deploy.yml`) | aucun secret dedans (le dépôt est public de toute façon) ; corrigé à la fusion de la PR #13 |
| L3 | Les identifiants du mode démonstration sont dans `api.js` et `admin.html` | valables seulement en local sans configuration ; C4 vérifie qu'aucun compte `@goship.demo` n'existe en production |
| L4 | Pas de fournisseur de paiement intégré (lien de paiement manuel) | aucune donnée de carte ne passe par la plateforme |
| L5 | Journaux Supabase courts sur l'offre gratuite | `journal_audit` garde l'essentiel sans limite |

## Recommandations (après GO)

| # | Recommandation |
|---|---|
| R1 | Offre Supabase Pro + PITR dès que l'activité le justifie (RPO de quelques minutes au lieu de 24 h) |
| R2 | Profil EAS `staging` et variables d'essai pour tester le mobile contre la préproduction |
| R3 | Domaine personnalisé pour le site (`www.goshipexpress.com`, DNS chez Hostinger, enregistrement CNAME vers GitHub Pages) : l'adresse ne dépend plus de l'hébergeur |
| R4 | Domaine personnalisé Supabase (`api.goshipexpress.com`) : changer de projet sans republier le mobile |
| R5 | SMTP personnalisé dans Supabase Auth, domaine authentifié (SPF, DKIM, DMARC) |
| R6 | Deux personnes avec tous les accès, dans un gestionnaire de mots de passe partagé |
| R7 | Surveillance externe (UptimeRobot, Better Stack) de la page d'accueil et de `rpc/sante`, alerte par SMS |
| R8 | Répétition annuelle de la reprise après sinistre (disaster-recovery.md, scénario 2) dans un projet temporaire |

## Historique des décisions

| Date | Décision | Par | Motif |
|---|---|---|---|
| 26/09/2026 | NO-GO | évaluation de la Phase 12 | B1 à B7 |
