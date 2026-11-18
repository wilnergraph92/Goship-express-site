# GoShip Express — Centre de communication
# COMMUNICATION_CENTER_DATABASE.md — version Phase 1.2

| | |
|---|---|
| Date | 18 novembre 2026 |
| Version | **Phase 1.2** — corrige la version Phase 1 après la revue Phase 1.1 |
| Statut | **Conception + brouillons gardés. Rien n'a été exécuté sur aucune base** (production, préproduction ou jetable) |
| Brouillons | `brouillons-sql/40-…-fondation.sql` (14 tables), `41-…-consentement.sql` (0 table), `42-…-campagnes.sql` (5 tables), `43-…-envoi.sql` (3 tables) — 22 tables, 80 fonctions |
| Garde | Chaque fichier commence par `raise exception 'BROUILLON NON APPROUVÉ…'`, première instruction exécutée. Le SQL Editor envoie le fichier en une transaction : une exécution accidentelle s'arrête là, rien n'est appliqué. **La garde reste en place pendant la Phase 1.2** ; elle ne sera remplacée par la garde habituelle « base incomplète » qu'en Phase 2, sur autorisation écrite |

---

## 1. Objets existants touchés — liste complète

1. `permissions_du_role(text)` : redéfinie avec 7 permissions `communications.*` ; toutes les autres
   entrées sont identiques. **Les quatre copies SQL et la copie démo doivent recevoir le même texte en
   Phase 2** (`supabase.sql`, `supabase-naissance.sql`, `supabase-suivi-externe.sql`, `api.js`) [H10].
2. `clients` : **un déclencheur ajouté**, `communication_suivre_client`, après la mise à jour de
   `email`, `telephone`, `pays`, `supprime_le`. Il attrape toutes ses erreurs, les garde dans
   `communication_erreurs`, et ne bloque jamais l'écriture [M13].
3. Une tâche planifiée **ajoutée**, `goship-communications`, créée **inactive**.

Rien d'autre :
- aucune colonne ajoutée à une table existante ;
- aucune fonction existante réécrite (`courriel_gabarit`, `expedier_envoi`, `traiter_notifications`,
  `mon_resume`, `messages_recents` intacts) ;
- aucune règle de sécurité existante modifiée ;
- aucune tâche planifiée existante changée ;
- **aucune écriture** dans `notifications`, `notification_envois`, `notification_preferences`.

Lectures seules d'objets existants :
- `clients`, `colis`, `auth.users` (dates d'envoi), `notification_envois` et `notifications`
  (comptages Brevo et signal C4), `cron.job` ;
- fonctions `adresse_miami()`, `telephone_international()`, `html_echappe()`, `lire_reglage()`,
  `auditer()`, `erreur_metier()`, `exiger_permission()`.

---

## 2. Migration par migration

### 40 — `supabase-communications-fondation.sql`

| Point | Détail |
|---|---|
| Dépend de | chaîne 1→39 : `telephone_international`, `lire_reglage`, `auditer` (avec motif, `supabase-corrections.sql`), `erreur_metier`, `exiger_permission` ; pgcrypto dans `extensions` (`digest`, `hmac`) |
| Appelle plus loin (résolution à l'exécution) | `communication_purger_autres`, `communication_purger_personne_suite` (43) |
| Ordre | 40ᵉ, après `supabase-index-cles.sql` |
| Rejouable | `create table if not exists`, `on conflict do nothing` pour les lignes de départ (les réglages d'un administrateur ne sont jamais remis à zéro), `create or replace function`, `drop trigger if exists` + `create trigger` |
| Effets sur l'existant | `permissions_du_role` (§1) |
| Tables | `communication_reglages`, `_indicatifs`, `_erreurs`, `_textes_consentement`, `_consentements`, `_confirmations`, `_suppressions`, `_destinataires_essai`, `_tarifs`, `_codes_fournisseur`, `_depenses_jour`, `_conservation`, `_demandes_purge`, `_journal_purges` |
| Déclencheurs | immuabilité de `communication_consentements` et `communication_journal_purges` (exception : purge approuvée) |
| Sécurité par ligne | activée sur les 14 tables, **aucune règle**, `revoke all` pour `anon` et `authenticated` |
| Permissions | aides fermées à tous ; `executer_purge_communication` ouverte aux comptes connectés, vérifie `communications.manage` et la demande approuvée |
| Index | consentements (client, canal, date) ; confirmations : jeton unique, demandes en attente par contact, par consentement ; suppressions : active unique (canal, empreinte), par client |
| Concurrence | verrous de transaction `communication_verrou(sujet)` : jour (dépenses), client (fréquence), consentement client+canal ; toujours dans l'ordre jour → campagne → client |
| Idempotence | lignes de départ ; contraintes d'unicité |
| Retour arrière | voir §6 |
| Suppression ou anonymisation | **seulement** par `executer_purge_communication`, demande approuvée par un autre administrateur, durée fixée par le juriste |
| PR #48 | redéfinit aussi `permissions_du_role` → ordonner ; la copie qui passe en second contient les permissions des deux projets |

### 41 — `supabase-communications-consentement.sql`

| Point | Détail |
|---|---|
| Dépend de | 40 ; appelle `communication_demander_envoi_confirmation` (43) à l'exécution |
| Ordre | 41ᵉ |
| Rejouable | fonctions remplacées ; déclencheur recréé |
| Effets sur l'existant | **déclencheur ajouté sur `clients`** (§1) |
| Fonctions | client (3) ; confirmation par lien (publique) ; équipe (3) ; administration (12) |
| Sécurité par ligne | aucune table nouvelle |
| Permissions | 19 fonctions ouvertes aux comptes connectés (chacune vérifie sa permission ou `auth.uid()`) ; `confirmer_consentement_communication` ouverte aux visiteurs (jeton) |
| Concurrence | verrou client+canal dans toutes les écritures de consentement ; `clock_timestamp()` ; retrait prioritaire à égalité |
| Risques du déclencheur | ne bloque jamais ; essais exigés sur l'inscription Google (`creer_profil_client` insère sans mise à jour : il ne se déclenche pas), la modification du profil, `supprimer_mon_compte` (TESTING groupe 15) |
| Retour arrière | `drop trigger communication_suivre_client on clients` dans le script de retrait |
| PR #48 | aucune interaction directe |

### 42 — `supabase-communications-campagnes.sql`

| Point | Détail |
|---|---|
| Dépend de | 41 ; `adresse_miami()` ; `communication_textes_pied_tous()` (43) à l'exécution ; pg_net (`net.http_get`) |
| Ordre | 42ᵉ |
| Rejouable | oui (mêmes procédés) |
| Tables | `communication_modeles`, `_modeles_meta`, `_segments`, `_campagnes`, `_destinataires` |
| Déclencheurs | modèle approuvé figé ; audience figée immuable (exception : purge approuvée) |
| Sécurité par ligne | activée, aucune règle, `revoke all` |
| Permissions | 18 aides fermées ; 3 fonctions de page (aperçu, écriture, transitions) |
| Index | modèles par version remplacée ; images Meta par modèle et date ; campagnes dues ; campagnes par segment ; audience par modèle et par client (l'unicité campagne+client+canal couvre la recherche par campagne) |
| Concurrence | verrou de la ligne de campagne avant toute transition et dans le travailleur |
| Retour arrière | tables gardées ; travailleur coupé |
| PR #48 | aucune |

### 43 — `supabase-communications-envoi.sql`

| Point | Détail |
|---|---|
| Dépend de | 42 ; pg_net (`net.http_post`, `net._http_response`), pg_cron ; `html_echappe` |
| Ordre | 43ᵉ |
| Rejouable | oui ; la tâche planifiée n'est créée que si elle n'existe pas, et **inactive** |
| Tables | `communication_envois`, `_evenements_fournisseur`, `_fenetres_whatsapp` |
| Déclencheurs | retours des fournisseurs immuables (exception : purge approuvée) |
| Sécurité par ligne | activée, aucune règle, `revoke all` |
| Permissions | 18 fonctions fermées ; `relancer_envoi_communication`, `sante_communications` (comptes connectés, avec permission) ; `communication_recevoir_evenement` (visiteur, signature) ; `desinscrire_communication` (visiteur et comptes, jeton) |
| Index | envois dus, en cours, par identifiant du fournisseur, par client et date, **par campagne et statut**, par destinataire, par confirmation, incertains ouverts ; retours par envoi |
| Concurrence | `skip locked` ; verrous du jour, de la campagne et du client ; sous-transaction par envoi (une erreur annule aussi la réservation) |
| Retour arrière | `cron.alter_job(…, active := false)` ; `campagnes_actives = false` |
| Purge | `communication_purger_autres`, `communication_purger_personne_suite`, appelées seulement par 40 |
| PR #48 | première fonction Edge des deux projets : une seule convention (dossier, déploiement, secrets, exclusion par `deploy.yml`) |

---

## 3. États

**Consentement** (`communication_consentements.action`) : `demande` → `confirme` → `retire` ou
`invalide`. L'état est celui de la dernière ligne (à égalité de date, retrait ou invalidation
d'abord). Il n'est **actif** que si cette ligne est `confirme` et porte l'empreinte du contact actuel.

**Campagne** : `brouillon`, `en_attente_approbation`, `programmee`, `en_cours`, `terminee`,
`en_pause`, `annulee`, `echec`. Une seule porte (`changer_statut_campagne`) pour les actions humaines ;
le travailleur lance, termine et met en pause (raisons : `EMPREINTE_CHANGEE`, `MODELE_META_*`,
`PLAFOND_CAMPAGNE_*`, `PIED_COMMERCIAL_INCOMPLET`, `MODELE_INDISPONIBLE`, `CODE_<meta>`) ou renvoie en
attente d'approbation (`AUDIENCE_DEPASSEE`).

**Message** : `attente`, `traitement`, `envoye`, `livre`, `lu`, `echec`, `nouvel_essai`, `supprime`,
`annule`, `abandon`, `incertain` (correspondance avec le cahier des charges : ARCHITECTURE §2.4).

**Modèle** : `brouillon`, `soumis`, `approuve`, `archive` ; image Meta suivie à part (`statut_meta`).

**Purge** : `demandee`, `approuvee` (par un autre administrateur), `refusee`, `executee`.

---

## 4. Index (analyse des requêtes, sans multiplication) [M5]

| Index | Requête servie |
|---|---|
| `communication_envois (prochain_essai_le) where attente/nouvel_essai` | sélection des envois dus |
| `(verrouille_le) where traitement` | lecture des réponses |
| `(fournisseur, message_id) where message_id not null` | rapprochement des retours |
| `(client_id, envoye_le desc)` | fréquence par client |
| `(campagne_id, statut)` | fin de campagne, annulation, statistiques |
| `(destinataire_id)`, `(confirmation_id)` | clés étrangères (leçon de `supabase-index-cles.sql`) |
| `(maj_le) where incertain non clos` | clôture des incertains à 72 h |
| `communication_destinataires (modele_id)`, `(client_id)` | clé étrangère ; effacement d'une personne |
| `communication_campagnes (planifiee_le) where programmee`, `(segment_id)` | lancement ; clé étrangère |
| `communication_modeles (remplace_id)`, `communication_modeles_meta (modele_id, recu_le desc)` | versions ; dernière image Meta |
| `communication_consentements (client_id, canal, cree_le desc, id desc)` | état actuel |
| `communication_confirmations` : jeton unique, en attente par contact, par consentement | confirmation e-mail et WhatsApp |
| `communication_suppressions` : active unique (canal, empreinte), par client | vérification d'envoi ; historique |
| `communication_evenements_fournisseur (envoi_id)` | historique d'un envoi |

Aucun index « au cas où » : chaque index correspond à une requête des brouillons.

---

## 5. Conservation (rappel) [C5]
Durées **BLOQUÉES** (null) jusqu'à l'avis du juriste : `communication_conservation`. Propositions :
SECURITY §7.1. Sans durée, `executer_purge_communication` refuse toute purge à l'échéance ; l'effacement
demandé par une personne reste possible, avec approbation à quatre yeux.

---

## 6. Retour arrière [M9]
- **Avant activation** : couper la tâche, puis le script `retrait-communications.sql` (préparé et relu
  en Phase 2, jamais exécuté sans autorisation). Il :
  - remet `permissions_du_role` dans sa définition **d'avant 40, recopiée littéralement dans le script** ;
  - retire `communication_suivre_client` ;
  - garde les tables.
- **Ne jamais** « relancer `supabase.sql` » pour revenir en arrière : il contiendra les nouvelles
  permissions.
- **Après activation** : on coupe, on ne supprime pas. Les preuves de consentement et les suppressions
  restent ; les liens de désinscription continuent de fonctionner.

---

## 7. Validation des brouillons (première tâche de la Phase 2)
Les brouillons **n'ont jamais été exécutés** (règle des Phases 1, 1.1, 1.2). Points de relecture connus
pour leur première exécution sur base jetable :
1. Garde « BROUILLON » → garde « base incomplète ».
2. Copies des permissions : quatre fichiers SQL + `api.js` ; essai de comparaison.
3. `net.http_get` avec `params` et `timeout_milliseconds` : signature exacte à vérifier sur la version
   de pg_net installée (0.20.4 en production).
4. Méthode de lecture des modèles chez Meta (42 §2) : forme réelle de la réponse, sur un compte d'essai.
5. Forme réelle des retours de Brevo et de Meta, sur des exemples réels (identifiants d'événements).
6. Arithmétique Brevo (24 h, 30 jours) avec volumes simulés ; journal d'Auth (structure à vérifier).
7. Mesure du lancement et de l'aperçu sur 10 000 clients fictifs (coût du HMAC par client).
8. Le déclencheur de `clients` face à Google, au profil, à la suppression de compte.
9. Requête de contrôle de chaque fichier et témoin pour `sonder.sh`.
10. Liste blanche de `controle-securite.sql` : les trois fonctions publiques.
