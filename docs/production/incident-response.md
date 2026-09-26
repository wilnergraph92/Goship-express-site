# Réponse aux incidents

## Gravité

| Niveau | Exemples | Délai de réaction |
|---|---|---|
| **S1** — tout est arrêté ou des données fuient | base inaccessible ; clé secrète exposée ; un client voit les colis d'un autre ; argent faux | immédiat |
| **S2** — une fonction majeure est cassée | connexion impossible ; scan ou facturation en erreur ; notifications bloquées > 1 h | dans l'heure |
| **S3** — gêne limitée | une page traduite cassée ; un e-mail mal mis en forme ; lenteur | jour ouvré suivant |

## Les cinq temps

1. **Constater** — l'alerte (e-mail GitHub, Supabase, un client, l'équipe). Noter
   l'heure. Relancer `surveiller.sh` (Actions > Surveillance > Run workflow) pour
   voir ce qui échoue.
2. **Contenir** — arrêter le dégât avant de chercher la cause :

   | Situation | Geste |
   |---|---|
   | Une publication du site a tout cassé | revenir au commit précédent (rollback.md § Site) |
   | Des messages partent en boucle ou au mauvais client | `select cron.unschedule('goship-notifications');` (rien ne se perd) ; couper la règle en cause (onglet Notifications, `actif = false`) |
   | Des données s'abîment | prévenir l'équipe : plus aucun scan ni paiement ; ne lancer aucune migration |
   | Une clé secrète a fui | la révoquer chez son émetteur **d'abord** (secrets.md, « Si un secret fuit ») |
   | Un compte est compromis | Supabase > Authentication > Users : réinitialiser le mot de passe, révoquer les sessions ; `changer_role` pour lui retirer ses permissions |
   | Un client voit les données d'un autre | couper l'accès en cause (retirer la règle RLS fautive par une migration corrective, ou le rôle) ; S1 |

3. **Comprendre** — Supabase > Logs, `journal_audit`, `colis_historique`,
   l'historique des workflows, `git log`. Ne jamais copier une donnée de client
   hors de Supabase pour l'analyser.
4. **Réparer** — par le chemin normal : PR → essais → `main` ; migration →
   préproduction → production (deployment.md). Pas de correction à la main dans
   la base en production, sauf événement `CORRECTION` ou fonction de service.
5. **Clore** — `surveiller.sh` vert, contrôles verts, puis une note d'incident
   (modèle ci-dessous), rangée hors du dépôt public si elle cite un client.

## Fuite de données personnelles

Si des données d'un client ont pu être lues par quelqu'un d'autre : noter quoi,
qui, depuis quand ; prévenir les clients concernés ; selon la loi applicable
(États-Unis, République dominicaine, Haïti), informer l'autorité compétente dans
les délais qu'elle fixe. Demander conseil avant de communiquer publiquement.

## Modèle de note d'incident

```
Incident AAAA-MM-JJ — titre court
Gravité : S1/S2/S3
Début (constaté) : …   Fin : …   Durée : …
Impact : qui, quoi, combien (sans nom de client)
Chronologie : heure — fait
Cause :
Correction : PR / migration / réglage
Ce qui empêche que ça revienne :
```
