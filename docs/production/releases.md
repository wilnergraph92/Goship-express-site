# Versions et mises en production

## Numérotation

| Composant | Version | Étiquette Git | Où elle est écrite |
|---|---|---|---|
| Site + base | date de mise en production, `AAAA.MM.JJ` (un suffixe `.2` si deux le même jour) | `site-2026.10.01` sur `main` (dépôt du site) | `CHANGELOG.md` |
| Bureau | SemVer `1.0.0` : majeur = contrat du pont incompatible, mineur = fonction ajoutée, correctif | `bureau-v1.0.0` (dépôt du site) | `bureau/package.json` |
| Mobile | SemVer `1.0.0` pour les gens + numéro de build (EAS, incrémenté tout seul) | `mobile-v1.0.0` (dépôt `goship-express-app`) | `app.json` > `version` |

Le site et la base vont ensemble : une étiquette `site-…` désigne à la fois les
pages et l'état de `outils/` à appliquer. La base n'a pas d'autre numéro : ce
qui y est passé se lit dans `controle-securite.sql` (section « Migrations »).

Aujourd'hui : **aucune étiquette, aucune release** dans les deux dépôts. La
première sera posée à la première mise en production après GO (go-no-go.md).

## Candidat (RC)

Avant une mise en production :

1. Geler `main` (plus de fusion sauf correctif du RC).
2. Étiquette `site-AAAA.MM.JJ-rc1` ; `bureau-vX.Y.Z-rc1` et/ou
   `mobile-vX.Y.Z-rc1` si ces composants changent.
3. La préproduction reçoit les migrations du RC ; tests de production
   (checklist-release.md) sur la préproduction ; mobile en test interne
   (TestFlight, Play *Internal testing*) branché sur… la production — il n'existe
   pas encore de profil EAS `staging` (go-no-go.md, recommandation R2).
4. Un défaut → correctif → `rc2`.

## Ordre de mise en ligne

1. Sauvegarde vérifiée (backup.md).
2. **Base** : migrations (deployment.md § 1), contrôles, `sante()`.
3. **Site** : fusion sur `main` → `deploy.yml` → contrôle après publication vert.
4. Étiquette `site-AAAA.MM.JJ` sur le commit publié ; `CHANGELOG.md`.
5. **Bureau** (si la coquille change) : installateurs distribués, étiquette, puis
   `BUREAU_CONTRAT_MIN` s'il le faut.
6. **Mobile** : EAS build + submit, déploiement progressif, étiquette.
7. Surveillance renforcée 24 h : `surveiller.sh` à la main après 1 h, Supabase
   Logs, onglet Notifications, retours de l'équipe.

## Journal des changements

`CHANGELOG.md` à la racine (non publié sur le site : `deploy.yml` l'exclut). Une
entrée par mise en production, écrite pour l'équipe : ce qui change pour elle et
pour les clients, les migrations passées, ce qu'il faut régler à la main.

## Décision GO / NO-GO

Avant chaque mise en production : checklist-release.md cochée, et la décision
écrite dans go-no-go.md (qui, quand, GO ou NO-GO, pourquoi). **GO seulement si
tous les critères critiques sont vérifiés** ; un critère non vérifiable compte
comme non rempli.
