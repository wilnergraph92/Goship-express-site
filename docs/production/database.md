# Base de données

PostgreSQL de Supabase, projet `gpfdyslysqjmojgzggib`. **Toutes les règles
métier sont dans la base** (CLAUDE.md, « Les règles métier vivent dans la base ») :
prix, statuts, transitions, paiements, permissions, notifications. Une page, le
bureau ou le mobile ne peuvent que demander ; la base décide.

## Migrations

La chaîne officielle : `outils/migrations.txt` (quinze fichiers). Règles :

- **dans l'ordre** ; relancer un fichier impose de relancer ceux qui le suivent ;
- **rejouables sans risque** : `if not exists`, `create or replace`, valeurs par
  défaut neutres, aucune suppression de donnée. `essai-production.py` le vérifie :
  la chaîne rejouée sur une base peuplée ne change pas une ligne (empreintes md5) ;
- **droits explicites** : chaque fonction retire `execute` à `public` et `anon`,
  puis ne le rend qu'à qui en a besoin (Supabase donne par défaut `execute` à
  `anon` et `authenticated` sur toute nouvelle fonction — les bancs d'essai
  simulent ce comportement) ;
- les six anciens fichiers isolés (`supabase-application`, `-bienvenue`,
  `-code-client`, `-factures`, `-numero-facture`, `-securite`) sont inclus dans la
  chaîne et **refusent de s'exécuter** sur une base à jour ;
- chaque fichier finit par une requête de contrôle ; `controle-securite.sql`
  (section « Migrations ») dit lesquels sont passés.

Procédure de production : deployment.md § 1. Une migration n'a pas de « down » :
on revient en arrière par une nouvelle migration ou une restauration
(rollback.md § Base).

### État de la production (28/09/2026, `audit-production.yml`)

| Migration | Production |
|---|---|
| `supabase.sql` à `supabase-rapports.sql` (1 à 12) | présentes (fonction témoin de chacune) ; chaîne entière relancée par le propriétaire le 28/09/2026, contrôle de `supabase-rapports.sql` : `5 \| 0 \| true \| true` |
| `supabase-compte.sql` (13, « Supprimer mon compte » de l'application) | exécuté par le propriétaire le 28/09/2026 ; contrôle : `1 \| false \| 1` |
| `supabase-regroupement.sql` (14, sortir des colis d'une facture regroupée) | exécuté par le propriétaire le 28/09/2026 ; contrôle : `1 \| false` |
| `supabase-connexion.sql` (15, profil d'un compte ouvert avec Google) | exécuté par le propriétaire le 29/09/2026 ; contrôle : `2 \| false \| true` |

Une fonction témoin présente ne dit pas que son fichier est à sa **dernière**
version : `controles-production.yml` (section « Migrations » de
`controle-securite.sql`) le dit. Passer la chaîne : deployment.md § 1
(`appliquer-chaine.sh`, préproduction d'abord).

## Tables (16)

| Domaine | Tables |
|---|---|
| Comptes | `clients` (rôle, code client), `appareils` (jetons push) |
| Colis | `colis`, `colis_historique` (événements, immuables), `prealertes` |
| Facturation | `factures`, `facture_lignes`, `factures_numeros`, `paiements`, `evenements_facturation` |
| Notifications | `notifications`, `notification_envois`, `notification_regles`, `notification_preferences`, `notification_moteur` |
| Audit | `journal_audit` |

Vue : `colis_details` (`security_invoker`). Comptes Supabase : `auth.users`,
`auth.identities` (sauvegardés avec le reste, backup.md).

## Sécurité dans la base

- **RLS activée sur toutes les tables**, plus de trente règles. Aucune règle ne teste un nom
  de rôle : elles demandent une permission (`peut('shipments.update')`…).
- **Verrous** (déclencheurs) : `verrou_statut` (le statut d'un colis ne change que
  par un événement), `evenement_immuable` (un événement ne se modifie pas),
  `verrou_role` (le rôle ne change que par `changer_role`), `garde_facture`
  (payé, statut et solde ne s'écrivent que par les paiements).
- **Visiteurs (`anon`)** : deux fonctions seulement, `suivre_colis` (suivi public,
  sans nom ni adresse) et `sante()` (aucune donnée métier).
- **Fonctions `security definer`** : toutes avec `set search_path = ''`.

`outils/production/controle-securite.sql` vérifie tout cela en lecture seule ;
chaque ligne a un verdict `OK`, `INFO` ou `ALERTE`.

## Intégrité

`outils/production/controle-integrite.sql` (lecture seule) cherche : lignes
orphelines, doublons (codes clients, numéros de colis et de factures, clés de
paiement et de notification), argent (payé = somme des paiements non annulés,
trop-payé, montants négatifs, facture « payée » avec un solde, colis sur deux
factures actives), statuts, files bloquées. Les exemples ne montrent que des
numéros, jamais un nom ou une adresse. À lancer avant et après chaque migration,
et une fois par semaine (runbook.md).

Une base avec des lignes orphelines **ne se restaure pas** : les clés
étrangères sont recréées après les données et les refusent. Un contrôle
d'intégrité vert est donc une condition des sauvegardes utilisables (backup.md).
Toute correction de données se fait par les fonctions de service ou un
événement `CORRECTION`, dans une migration relue, idempotente, passée en
préproduction ; jamais par un `DELETE`.

## Suivi public : limite de débit

`suivre_colis` est ouverte aux visiteurs (c'est le suivi public) et ne rend ni nom
ni adresse. Supabase ne limite pas le débit **par fonction** : ses limites
portent sur l'Auth (connexions, e-mails) et le projet entier. Ce qu'on peut faire,
par ordre de coût :

1. **Numéros de colis tirés au hasard** (partie « Facultatif » de `supabase.sql`,
   prête, désactivée) : essayer les numéros voisins ne donne plus rien. Les colis
   déjà enregistrés gardent leur numéro. Décision du propriétaire (étiquettes,
   habitudes de l'équipe) — non activée.
2. Une limite dans la fonction elle-même (compteur par adresse IP, lue dans
   `request.headers`) : possible, mais c'est une règle nouvelle sur une fonction
   dont dépendent les applications installées — à ne faire qu'avec un essai
   dédié et une période d'observation.
3. Un pare-feu devant l'API (proxy) : hors de la pile actuelle.

Aucune de ces mesures n'est appliquée au 26/09/2026 (go-no-go.md, M6).

## Index

Les index vivent avec les fonctions qui s'en servent (`supabase-tableau-de-bord.sql`,
`supabase-analytics.sql`, `supabase-mobile.sql`, `supabase-notifications.sql`…).
`essai-production.py` (section E) vérifie que les index attendus existent après
la chaîne. Supabase > *Advisors > Performance* signale les requêtes lentes et les
index manquants sur les vraies données.

## Tâches planifiées (pg_cron)

| Tâche | Quand | Ce qu'elle fait |
|---|---|---|
| `goship-notifications` | chaque minute | `traiter_notifications()` : envoie la file, lit les réponses, réessaie |
| `goship-notifications-jour` | 11 h 15 UTC | rappels de factures en retard, purge des envois terminés de plus de 180 jours |

Sans pg_cron, rien ne part mais rien ne se perd ; `sante()` répond
`notifications: en_retard` dès qu'un envoi attend depuis plus de 15 minutes.

## Capacité (limites connues)

| Quoi | Limite | Quand agir |
|---|---|---|
| Codes clients `GSE-` + 4 chiffres | 9 000 comptes | vers 8 000 : passer à 5 chiffres (README, « Le format des codes clients ») |
| Numéros de facture `AAAA-MM-NNNN` | 10 000 factures par mois | — |
| Numéros de colis | séquence, sans limite pratique | — |
| Envois de notifications | purgés après 180 jours | — |
| Journal d'audit, événements | jamais purgés (voulu) | surveiller la taille (Supabase > Database > Usage) |
| Base Supabase | selon l'offre (500 Mo en gratuit, 8 Go inclus en Pro) | alerte d'usage Supabase à 80 % |

Volume éprouvé par les bancs d'essai : 10 000 envois de notifications traités par
quatre travailleurs en parallèle (`essai-notifications.py`) ; analytics sur 10 000
colis, 100 000 événements et 5 000 factures (`essai-analytics.py`, section K).
Aucune mesure sur les vraies données n'a pu être faite depuis le dépôt.
