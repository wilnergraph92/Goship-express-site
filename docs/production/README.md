# GoShip Express — la production

Ce dossier dit comment la plateforme tourne en production, comment la mettre
à jour, la surveiller, la sauvegarder, la restaurer et revenir en arrière. Il
est écrit pour qu'une personne autorisée qui ne connaît pas l'historique du
projet puisse agir seule. `docs/` n'est jamais publié sur le site
(`deploy.yml` l'exclut).

| Document | Pour… |
|---|---|
| [go-no-go.md](go-no-go.md) | **l'état actuel : peut-on mettre en production ?** Bloqueurs et actions |
| [runbook.md](runbook.md) | les gestes courants, pas à pas : déployer, revenir en arrière, restaurer, vérifier |
| [checklist-release.md](checklist-release.md) | la liste à cocher avant chaque mise en production |
| [architecture.md](architecture.md) | ce qui tourne où, qui parle à qui |
| [environment.md](environment.md) | développement, essai, préproduction, production : adresses et identifiants |
| [deployment.md](deployment.md) | comment chaque composant part en ligne (site, base, bureau, mobile) |
| [secrets.md](secrets.md) | où vit chaque secret, ce qui est public, l'audit, la rotation |
| [database.md](database.md) | migrations, RLS, fonctions, intégrité, index, capacité |
| [backup.md](backup.md) | sauvegardes : ce qui existe vraiment, comment restaurer |
| [disaster-recovery.md](disaster-recovery.md) | scénarios de panne, RPO, RTO |
| [monitoring.md](monitoring.md) | surveillance, santé, journaux, alertes |
| [incident-response.md](incident-response.md) | que faire quand ça casse |
| [rollback.md](rollback.md) | revenir à la version précédente, composant par composant |
| [releases.md](releases.md) | versions, étiquettes, journal des changements, GO / NO-GO |
| [troubleshooting.md](troubleshooting.md) | symptômes connus et leur cause |

Outils (tous dans `outils/`, jamais publiés) :

| Outil | Rôle |
|---|---|
| `outils/migrations.txt` | la chaîne officielle des migrations, dans l'ordre |
| `outils/supabase-production.sql` | `sante()` : la base répond-elle, la file avance-t-elle ? |
| `outils/production/controle-securite.sql` | RLS, fonctions, droits des visiteurs, comptes, verrous, migrations — **lecture seule** |
| `outils/production/controle-integrite.sql` | rattachements, doublons, argent, statuts, files — **lecture seule** |
| `outils/production/surveiller.sh` | le site et la base répondent-ils ? (surveillance et contrôle après publication) |
| `outils/production/sauvegarder.sh` / `restaurer.sh` | sauvegarde chiffrée et sa restauration (`RESTAURATION_ESSAI=1` : épreuve sur PostgreSQL ordinaire) |
| `outils/production/sonder.sh` | quelles migrations sont en production, vu de l'extérieur (clé publique, lecture seule) |
| `outils/production/controler.sh` | les deux contrôles en lecture seule ; sortie publiable, détail chiffré |
| `outils/production/appliquer-chaine.sh` | la chaîne des migrations, arrêt au premier échec, refus de la production sans confirmation |
| `outils/production/essai-metier.sql` | le parcours métier complet sur la préproduction, dans une transaction annulée |
| `outils/production/doublures-supabase.py` | un PostgreSQL ordinaire habillé en projet Supabase neuf (épreuve de restauration) |
| `outils/essais-services/essai-production.py` | éprouve tout ce qui précède sur une base jetable |

Workflows GitHub Actions : `deploy.yml` (publication + contrôle après
publication), `essais.yml` (tous les bancs d'essai), `surveillance.yml`
(toutes les 30 minutes, alerte à une seconde personne, battement externe),
`audit-production.yml` (chaque jour), `controles-production.yml` (chaque lundi),
`preproduction.yml` (à la demande et sur les PR qui touchent `outils/`),
`sauvegarde.yml` (chaque nuit, sauvegarde + restauration d'épreuve, une fois
configuré), `bureau.yml` (application de bureau, signée si les certificats sont
posés). Toutes les actions sont épinglées par empreinte (`dependabot.yml`). L'application mobile a les siens dans
son dépôt (`goship-express-app/.github/workflows/mobile.yml`).
