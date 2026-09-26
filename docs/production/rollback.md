# Revenir en arrière

Règle générale : **on revient en arrière en avançant** — un nouveau commit, une
nouvelle migration, une nouvelle version — jamais en réécrivant l'historique de
`main` ni en effaçant des données.

## Site (et tableau de bord, et bureau)

Le site publié est exactement le contenu de `main`.

1. Trouver le dernier commit sain : `git log --oneline main` (ou l'étiquette
   `site-AAAA.MM.JJ` de la version précédente, releases.md).
2. `git revert <commit fautif>` (ou `git revert -m 1 <commit de fusion>` pour une
   PR fusionnée par *merge*), sur une branche, PR, fusion. `deploy.yml` republie
   en 2 à 3 minutes.
3. Urgence : Actions > « Mettre le site en ligne » > le dernier déploiement sain >
   *Re-run all jobs* republie cet état-là (le prochain push sur `main` le
   remplacera — faire le `revert` quand même).
4. Le bureau suit tout seul (il charge le site).

**Attention** : revenir à un site plus ancien est sans risque pour la base (elle
accepte les anciennes pages). Revenir à un site plus récent que la base ne l'est
pas (deployment.md).

## Base

Pas de « down migration ». Selon le cas :

| Cas | Geste |
|---|---|
| Une fonction nouvelle se comporte mal | nouvelle migration qui remet l'ancienne définition (`create or replace`, copiée depuis le fichier de la version précédente : `git show <étiquette>:outils/<fichier>.sql`), passée en préproduction puis en production |
| Une règle de notification pose problème | la couper (`actif = false`) depuis l'onglet Notifications ; au pire `cron.unschedule('goship-notifications')` |
| Une migration a échoué à mi-chemin | chaque fichier est rejouable : corriger la cause, relancer **ce fichier** puis les suivants |
| Des données ont été abîmées | disaster-recovery.md, scénario 1 |
| Tout est perdu | disaster-recovery.md, scénario 2 |

Validé : la restauration (outils éprouvés par `essai-production.py` F et K, et
chaque nuit par la restauration d'épreuve une fois ses secrets posés). **Pas
encore validé en conditions réelles** : un retour arrière de fonction SQL en
production, et une restauration dans un vrai projet Supabase (go-no-go.md, A3b).

Une colonne ou une table ajoutée n'est jamais retirée en urgence : elle ne gêne
pas les anciennes versions.

## Bureau (coquille)

Réinstaller l'installateur de la version précédente (artefacts de `bureau.yml`,
ou release `bureau-vX.Y.Z`). Si `BUREAU_CONTRAT_MIN` a été relevé dans `admin.js`,
le baisser aussi (rollback du site) : sinon le tableau de bord ignore l'ancienne
coquille et se comporte comme dans un navigateur (plus d'impression directe ni de
session chiffrée).

## Mobile

Une version publiée ne se retire pas des téléphones.

| Moment | Geste |
|---|---|
| Déploiement progressif en cours | **suspendre** le déploiement (Play Console > Production > Halt rollout ; App Store Connect > Pause phased release) |
| Déjà publiée à 100 % | publier une version corrigée (numéro de build supérieur) ; Android peut aussi repromouvoir l'ancien paquet avec un nouveau numéro |
| Le problème vient de la base | corriger la base (plus rapide que les boutiques) |

C'est pourquoi une fonction dont le mobile dépend ne se renomme pas et ne change
pas de forme de réponse (CLAUDE.md, « L'application mobile »).

## Notifications

Un message parti ne se rattrape pas. Couper la règle ou le planificateur (plus
haut), puis, si nécessaire, envoyer un message correctif par le même canal.
