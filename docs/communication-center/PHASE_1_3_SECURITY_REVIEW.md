# Centre de communication — Phase 1.3 : revue de sécurité

**Date** : 18/11/2026 · **Objet** : brouillons 40 à 43 après les corrections de la Phase 1.3, et leurs points de contact avec l'existant.

> **Méthode** : lecture du code, et inventaire automatique des droits et des fonctions par **analyse statique**. L'analyse a utilisé le parseur de PostgreSQL (`pglast`), sans serveur ni base. **Aucun SQL n'a été exécuté.**
>
> Toute affirmation sur le **comportement à l'exécution** est une attente de conception. Elle est rattachée à un essai de `PHASE_1_3_TEST_PLAN.md`.

---

## 1. Contre-revue de mes propres corrections

J'ai relu les corrections comme un auditeur extérieur. Pour chaque risque cherché : ce que j'ai trouvé, et ce que j'en ai fait.

| # | Risque cherché | Constat | Suite |
|---|---|---|---|
| R1 | Une procédure qui valide (COMMIT) ne peut être ni `SECURITY DEFINER` ni porter de clause `SET` (documentation de PostgreSQL, rapporté). | `traiter_communications` est donc une procédure **sans** search_path figé. | Elle vide son search_path elle-même au départ. Elle n'appelle que des noms `public.` qualifiés. Son exécution est retirée à tous les rôles sauf son propriétaire (43 §14). Elle ne lit aucune donnée elle-même : tout passe par des fonctions `SECURITY DEFINER` à search_path vide. **Risque résiduel faible** : un propriétaire de la base qui modifierait son propre search_path. |
| R2 | Que pg_cron accepte `call` d'une procédure qui valide en interne. | **Non vérifié.** | Essai T-01-bis. Si c'est refusé, il y a un repli documenté : une tâche par seconde qui appelle `communication_traiter_un` sur un seul identifiant (même ordre des verrous, une transaction par appel). |
| R3 | L'équité des verrous : un écrivain exclusif en attente n'est-il pas doublé indéfiniment par de nouveaux lecteurs partagés ? | Le gestionnaire de verrous de PostgreSQL sert les demandes incompatibles dans leur ordre d'arrivée (**rapporté**). | Essai T-02. Repli dans tous les cas : l'arrêt est écrit même sans le verrou, et le contrôle sous N5 le voit. |
| R4 | Un lancement de campagne long (milliers de destinataires) tient N0 en partagé. | L'arrêt d'urgence attendrait jusqu'à 5 s, puis s'écrirait sans le verrou. `regler_communications` refuserait (« occupé ») au-delà de 10 s. | **Accepté.** Un lancement **n'envoie rien** : les envois passent ensuite un par un et relisent l'arrêt. Le message est écrit pour l'utilisateur. |
| R5 | Coût de `communication_brevo_disponible` sous le verrou global N5. | Il lit `auth.users`, `notification_envois` et `notifications` sur 30 jours **à chaque e-mail**. | Acceptable à 20 envois par minute. Il faudra le mesurer en Phase 2 (T-05). Une optimisation par cumul est possible si besoin. |
| R6 | Coût de `communication_fuseau_valide` (lecture de `pg_timezone_names`). | Trop cher pour chaque destinataire. | **Corrigé** : la validité n'est vérifiée qu'à l'écriture. Un nom devenu inconnu du serveur fait rendre null par `communication_prochaine_fenetre` (exception attrapée). |
| R7 | Le webhook compte chaque appel avant de lire la signature : un attaquant peut-il faire écrire la base ? | Non. La fonction n'est plus ouverte à `anon` ; seul le rôle `communication_webhook` (sans connexion) peut l'appeler. | — |
| R8 | « Saturé » ou « refusé » pendant une attaque : un STOP légitime peut-il se perdre ? | Il serait **différé**, pas perdu, **si** le fournisseur réessaie après une erreur temporaire. Ce comportement de Meta et de Brevo n'est **pas vérifié**. | Risque résiduel n° 6 ; vérification avant la Phase 3. |
| R9 | La purge d'une personne recueille ses empreintes **avant** de les effacer. | Oui (40, `executer_purge_communication`). Un compte supprimé n'a plus de contact actuel : seules les empreintes historiques sont trouvées, ce qui suffit. | — |
| R10 | L'effacement de l'empreinte des consentements anonymisés viole-t-il une contrainte ? | Il l'aurait fait. | **Corrigé** : la contrainte admet une empreinte vide **si** la ligne est anonymisée (40, `communication_consentements`). |
| R11 | Le fuseau inconnu exclut tous les clients américains. | Oui, volontairement (échec fermé). | **Signalé au CEO** : tant que la table des États est vide et que les clients ne déclarent rien, aucun envoi commercial aux USA. |
| R12 | 429 = « incertain » par défaut : surcharge d'administration ? | Possible si Brevo limite souvent. | Le débit global vise à l'éviter. Une décision du CEO est possible sur preuve (`verifier_issue_http`). |
| R13 | Le gérant peut-il, par l'arrêt d'urgence, faire plus que couper ? | Non. `arreter_communications` ne fait que poser `arret_urgence = true`. La levée exige `communications.manage` (administrateur). | Conforme à la décision D-D (le gérant met en pause). |
| R14 | Une fonction ouverte aux comptes connectés sans contrôle propre. | Aucune (inventaire §2.4). | — |
| R15 | Un retrait de consentement concurrent d'un envoi. | Le travailleur prend N3. Le retrait attend la fin de l'envoi (le message est « avant » le retrait), ou l'envoi attend le retrait et le voit. | Essai T-17. |
| R16 | La demande d'effacement automatique, à la suppression du compte, peut-elle bloquer la suppression ? | Non. Elle est faite dans le déclencheur, dans son bloc qui attrape toutes les erreurs, comme le reste. | Essai T-08, cas « erreur provoquée ». |

Les verdicts des huit corrections sont dans `PHASE_1_3_TECHNICAL_CORRECTIONS.md`, §1.

---

## 2. Permissions et sécurité PostgreSQL

### 2.1 `SECURITY DEFINER` et `search_path`

Inventaire statique des quatre brouillons :

| Fichier | Fonctions | `SECURITY DEFINER` | Sans `search_path` figé |
|---|---|---|---|
| 40 | 19 | 11 | 0 |
| 41 | 27 | 26 | 0 |
| 42 | 21 | 16 | 0 |
| 43 | 27 (dont 1 procédure) | 20 | **1** : la procédure `traiter_communications` (voir R1) |
| **Total** | **94** | **73** | **1** |

- Les fonctions non `SECURITY DEFINER` sont des aides pures : textes, normalisation, verrous, contrôles de format.
- Toutes les références sont qualifiées (`public.`, `extensions.`, `pg_catalog.`, `net.`, `cron.`, `auth.`).

### 2.2 RLS et tables

- **Sécurité par ligne activée et `revoke all` pour `anon` et `authenticated` sur chacune des 27 tables du Centre** (comptées dans les brouillons : 27 créations, 27 activations, 27 retraits) :
  - les 18 tables de 40, dont 4 nouvelles en 1.3 : `communication_issues_http`, `communication_debit_minute`, `communication_fuseaux_regions`, `communication_fuseaux_clients` ;
  - les 5 tables de 42 ;
  - les 4 tables de 43, dont `communication_webhook_debit`, nouvelle en 1.3.
- **Aucune règle de lecture.** Tout passe par des fonctions.
- Tables **immuables** (déclencheur `communication_immuable`, seule exception : une purge approuvée) :
  - `communication_consentements` ;
  - `communication_journal_purges` ;
  - `communication_destinataires` ;
  - `communication_evenements_fournisseur`.

### 2.3 `anon`, `authenticated`, `service_role`

| Rôle | Ce qu'il peut appeler |
|---|---|
| `anon` | **2 fonctions** : `confirmer_consentement_communication` (jeton aléatoire de 256 bits, usage unique, expiration) et `desinscrire_communication` (jeton HMAC). **`communication_recevoir_evenement` n'est plus ouverte à `anon`** (Phase 1.3). |
| `authenticated` | **32 fonctions** : les 2 ci-dessus, plus 30 qui contrôlent chacune elle-même `exiger_permission(...)` ou `auth.uid()`, et le rôle client là où il le faut (§2.4). |
| `communication_webhook` | **1 fonction** : `communication_recevoir_evenement`. Le rôle est créé **NOLOGIN**, donc personne ne peut l'utiliser tant que le CEO n'a pas choisi le mode d'authentification de la fonction Edge (décision S-1). |
| `service_role` | Les 22 fonctions internes de 43 et la procédure lui sont **retirées**. Celles de 40 à 42 gardent le droit par défaut de Supabase, comme tout le reste du projet. À **retirer aussi en Phase 2** (S-2). Ce n'est pas une faille ouverte : la clé `service_role` n'est utilisée nulle part (`docs/production/secrets.md`). |

### 2.4 Fonctions ouvertes aux comptes et leur contrôle

| Groupe | Fonctions | Contrôle |
|---|---|---|
| Client (soi-même) | `mes_consentements_communication`, `demander_consentement_communication`, `retirer_mon_consentement_communication`, `declarer_fuseau_communication` (sans `p_client`) | `auth.uid()` + rôle `client` + compte non supprimé |
| Équipe : consentements | `consentements_client`, `retirer_consentement_client`, `ajouter_suppression_communication`, `declarer_fuseau_communication` (avec `p_client`), `demander_purge_communication` (personne) | `communications.consents` (administrateur, gérant) |
| Campagnes | `apercu_audience_communication`, `ecrire_campagne_communication`, `changer_statut_campagne` | `communications.create`, `.pause` ou `.approve` selon l'action |
| Arrêt | `arreter_communications` | `communications.pause` (administrateur, gérant) |
| Administration | `lever_arret_communications`, `regler_communications`, `verifier_quota_brevo`, `regler_whatsapp_commercial`, `valider_identite_expediteur`, `verifier_tarif_communication`, `verifier_indicatif_communication`, `verifier_issue_http`, `regler_fuseau_region`, `regler_destinataire_essai`, `lever_suppression_communication`, `regler_conservation_communication`, textes de consentement, `executer_purge_communication`, `demander_purge_communication` (échéance) | `communications.manage` (administrateur) |
| Approbation | `approuver_purge_communication` (et quatre yeux), `relancer_envoi_communication` | `communications.approve` (administrateur) |
| Lecture | `sante_communications` | `communications.view` |

**Employé** : il n'a aucune permission `communications.*`, donc toutes ces fonctions le refusent. Les seules qu'il peut appeler sont celles de tout compte « client » pour soi-même, et elles exigent le rôle `client`.

### 2.5 Les sept permissions et leurs copies

- `permissions_du_role` existe en **trois copies SQL** : `supabase.sql` l. 325, `supabase-naissance.sql` l. 81, `supabase-suivi-externe.sql` l. 70. Il y a aussi une **copie démo** (`PERMISSIONS_DES_ROLES`, `api.js`), et le brouillon 40 en ajoute une.
- En Phase 2, les **cinq** doivent recevoir les sept permissions **ensemble**. Sinon, relancer une ancienne migration retirerait les permissions du Centre. Un essai compare les cinq (T-15).
- `create or replace` garde les droits existants de `permissions_du_role` : lecture pour `authenticated`, refus pour `anon` (`supabase.sql` l. 1437-1440).

### 2.6 Escalade de privilèges

- Aucune fonction du Centre n'écrit `clients.role`. Le rôle ne change que par `changer_role` (existant, `roles.manage`).
- Aucune fonction n'accorde un consentement à la place du client. Un fournisseur ne fait que **confirmer** une demande faite par le client (message venu du numéro concerné).
- Les réglages bloqués (identité, adresse, quota, numéro, tarifs, indicatifs, issues HTTP, fuseaux des États) ne s'écrivent qu'avec `communications.manage` et une preuve écrite, et ils sont journalisés.
- La purge exige deux administrateurs différents (contrainte `approuvee_par <> demandee_par`). Une demande ouverte d'office à la suppression d'un compte a la personne pour demandeur : l'approbation vient forcément d'un autre compte.
- **Limite assumée (inchangée)** : le propriétaire de la base, dans le SQL Editor, peut tout. C'est le cas de tout le projet.

---

## 3. Dépendances avec le système transactionnel

| Contrat gelé | Ce que fait le Centre | Écriture ? |
|---|---|---|
| `notification_envois` | **Lit** la file en attente (priorité au transactionnel : `communication_candidats`) et les envois e-mail (quota Brevo). `sante_communications` lit les refus `ADRESSE_BLOQUEE`. | **Non** |
| `notifications` | **Lit** les e-mails envoyés (quota Brevo). | **Non** |
| `messages_recents`, `mon_resume` | Rien. Le commercial n'entre jamais dans le fil de l'application. | **Non** |
| `expedier_envoi`, `courriel_gabarit` | Rien. Le commercial a son propre habillage (`communication_courriel_commercial`) et ses propres appels. | **Non** |
| Notifications de colis, de paiement, de compte | Rien. Aucun déclencheur du Centre sur `colis_historique` ni sur `evenements_facturation`. | **Non** |
| E-mails d'authentification | **Lit** `auth.users` (quatre dates) pour estimer leur volume (borne basse). | **Non** |
| pg_net (partagé) | Le Centre y **dépose** ses propres requêtes et lit **ses** réponses, par identifiant. La file et le réglage de durée de pg_net ne sont **pas** modifiés (l'arrêt d'urgence ne vide pas la file : §2 des corrections). | Ses requêtes seulement |
| pg_cron (partagé) | Une tâche de plus, `goship-communications`, **inactive**. | Une tâche, inactive |
| Le coffre (`lire_reglage`) | Lit **ses** clés (`communication_*`). Aucun repli sur les clés du transactionnel. | **Non** |
| `clients` | Un déclencheur **après** mise à jour (`communication_suivre_client`) qui n'écrit **que** dans les tables du Centre et **ne bloque jamais** l'écriture du client. Il porte une colonne de plus en 1.3 (`region`). | Tables du Centre seulement |

**Conclusion** : aucune correction de la Phase 1.3 ne modifie un système gelé, et aucune n'a dû s'arrêter pour cette raison. Les trois points où la minimisation des données **dépendrait** d'un système partagé sont signalés au CEO sans y toucher : durée de pg_net, `journal_audit`, journaux des fournisseurs.

---

## 4. PR #46 et PR #48 (réexaminées le 18/11/2026, sans y toucher)

| PR | État constaté | Points de contact avec le Centre | Ordre proposé |
|---|---|---|---|
| **#46** (pixel Meta, branche `pixel-meta`) | Ouverte, non fusionnée. 14 commits de retard sur `main`. 92 fichiers. | **Mêmes fichiers** que la future mention « Communications commerciales » de la politique de confidentialité (`build.py`, `confidentialite.html` × 4). Un lien de campagne avec `utm_*` chargera le pixel. Les pages `confirmation-communication.html` et `desinscription.html` (Phase 2c) ne doivent charger **aucun** script de mesure (le jeton est dans l'adresse). | **Avant** la Phase 2c du Centre (pages et politique) : rebasée sur `main`, puis les pages du Centre l'excluent explicitement. |
| **#48** (Centre de Commandement IA, branche `ccr-1b1dd194-g07lcu`) | Ouverte. **Un seul fichier** : l'audit de la Phase 0 de ce projet (aucun SQL, aucune fonction Edge pour l'instant). 13 commits de retard. | Prévoit : `ia.commander` dans `permissions_du_role` et ses copies ; une migration en fin de chaîne ; une fonction Edge ; le principe « clé `service_role` utilisée nulle part ». **Même liste de permissions et même convention de fonction Edge** que le Centre. | Le premier des deux projets qui **écrit** sa migration pose les permissions des deux dans les cinq copies. L'autre ajoute les siennes. **Une seule convention de fonction Edge** (dossier, secrets, exclusion par `deploy.yml`, rôle de connexion dédié plutôt que `service_role`), décidée **une fois** par le CEO. |

**Rien n'a été fusionné, modifié ni fermé.**

---

## 5. Risques résiduels de sécurité

| # | Risque | Gravité | Traitement |
|---|---|---|---|
| 1 | Le comportement réel des verrous, de la procédure et de pg_cron n'est **pas éprouvé**. | Élevée tant que non éprouvé | T-01 à T-05, sur base jetable, avant toute activation |
| 2 | Messages déjà dans la file de pg_net au moment d'un arrêt : non rappelés. | Moyenne | Signalé ; nombre rendu à l'administrateur ; vider la file partagée = décision du CEO (non recommandé) |
| 3 | Mode d'authentification de la fonction Edge (rôle dédié ou `service_role`). | Moyenne | **Décision S-1 du CEO** avant la Phase 3 |
| 4 | `service_role` garde l'exécution par défaut des fonctions internes de 40 à 42. | Faible | S-2 : retrait en Phase 2 |
| 5 | Données personnelles hors du Centre (pg_net, `journal_audit`, fournisseurs). | Moyenne | Juriste et CEO |
| 6 | Réessai des fournisseurs après une erreur temporaire du webhook. | Moyenne | Vérification documentaire avant la Phase 3 |
| 7 | Outils qui découpent le SQL naïvement et continuent après une erreur. | Faible | Limite de la garde, documentée ; T-14 |
| 8 | Brevo : idempotence non confirmée ; partage du quota non prouvé. | Moyenne | Restent bloquants pour l'e-mail commercial (quota à 0 sans preuve) |
