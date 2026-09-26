# Runbook — les gestes courants

Chaque geste renvoie au document qui l'explique. Tout se fait depuis GitHub
(onglet Actions), le SQL Editor de Supabase, ou un ordinateur de confiance.
**Jamais de secret collé dans une conversation, un ticket ou un commit.**

## Tous les jours (automatique)

| Heure (UTC) | Quoi | Si rouge |
|---|---|---|
| h 07 et h 37 | `surveillance.yml` : site, Auth, `sante()`, suivi public | incident-response.md |
| 5 h 23 | `sauvegarde.yml` (une fois mis en service) | troubleshooting.md § Surveillance |
| chaque minute | pg_cron : `traiter_notifications()` | `sante()` → `en_retard` |
| 11 h 15 | pg_cron : rappels de factures en retard, purge des envois > 180 jours | — |

## Chaque semaine (15 minutes)

1. SQL Editor : `outils/production/controle-securite.sql` → aucune ligne ALERTE.
2. SQL Editor : `outils/production/controle-integrite.sql` → aucune ligne ALERTE ;
   les INFO se lisent (factures sans frais d'avant le 22/09/2026 : normal).
3. Supabase > Advisors > Security et Performance.
4. Actions : la dernière sauvegarde a réussi ; la surveillance tourne encore
   (GitHub la suspend après 60 jours sans activité du dépôt).

## Publier une modification du site

PR → `essais.yml` vert → migrations en base d'abord s'il y en a → fusion →
`deploy.yml` vert (avec le contrôle après publication). Détail : deployment.md § 2.

## Passer une migration

Sauvegarde restaurée → contrôles (état de départ) → préproduction → production,
fichier par fichier dans l'ordre de `outils/migrations.txt` → `sante()` →
contrôles. Détail : deployment.md § 1.

## Revenir en arrière

| Quoi | Geste | Détail |
|---|---|---|
| Site | `git revert` du commit fautif, PR, fusion (2–3 min) ; urgence : *Re-run* du dernier déploiement sain | rollback.md § Site |
| Fonction SQL | nouvelle migration avec l'ancienne définition | rollback.md § Base |
| Messages | `select cron.unschedule('goship-notifications');` ou règle `actif = false` | rollback.md § Notifications |
| Mobile | suspendre le déploiement progressif | rollback.md § Mobile |

## Restaurer une sauvegarde

Dans un projet **neuf**, jamais sur la production en service :
`CIBLE_DB_URL=… bash outils/production/restaurer.sh <dossier> goship-<date> <clé privée>`,
puis chaîne, contrôles, Vault, Auth. Détail : backup.md § Restaurer.

## Comptes de l'équipe

| Geste | Comment |
|---|---|
| Premier administrateur | SQL Editor : `select public.definir_admin('adresse@…');` (le compte doit exister) |
| Donner / retirer un rôle | tableau de bord > Équipe (permission `roles.manage`), ou `changer_role` ; journalisé |
| Départ d'un membre | retirer son rôle (`client`), puis Authentication > Users : révoquer ses sessions ; changer les mots de passe partagés qu'il connaissait |
| Compte de démonstration trouvé en production | vérifier qu'il n'a aucune donnée réelle, puis Authentication > Users > Delete |

## Secrets

Rotation, fuite, inventaire : secrets.md.

| Secret | Rotation conseillée |
|---|---|
| Mot de passe de la base | une fois par an, et au départ de quiconque le connaissait — puis mettre à jour `SUPABASE_DB_URL` |
| Clés des fournisseurs | une fois par an, ou à la moindre fuite |
| Clé de sauvegarde (age) | seulement si elle a pu fuir ; garder l'ancienne tant que des sauvegardes l'utilisent |

## Arrêter / relancer les notifications

- Arrêter tout : `select cron.unschedule('goship-notifications');`
- Relancer : relancer `outils/supabase-notifications.sql` (remet le planificateur ;
  rejouable), puis `select public.sante();` → `notifications: ok`.
- Couper un type de message : onglet Notifications > la règle > désactiver.
