# Centre de communication — Phase 1.3.1 : corrections des brouillons SQL

**Date** : 18/11/2026 · **Fichiers** : `brouillons-sql/40` à `43`, version **1.3.1**

> **Aucune exécution SQL.** Les brouillons restent sous leur garde à trois couches : un bloc `DO` qui lève une exception, puis tout le contenu enfermé dans une chaîne inerte. La seule vérification faite est une **analyse statique**, avec le parseur de PostgreSQL (`pglast`), sans serveur ni base :
> - chaque fichier entier ne contient que `DO` + `SELECT` ;
> - toutes les instructions du contenu sont syntaxiquement lisibles, y compris tous les corps PL/pgSQL.
>
> Cela ne prouve rien sur le comportement à l'exécution : voir `PHASE_1_3_1_TEST_PLAN.md`.

Les numéros de ligne renvoient aux brouillons 1.3.1 (définition de chaque fonction).

---

## 1. Modifications

### 1.1 Arrêt d'urgence (CRITIQUE, constat AF-01)

| Fichier | Objet | Avant (1.3) | Après (1.3.1) |
|---|---|---|---|
| 40 l. 240 | **Table `communication_arret`** (nouvelle) | Colonnes `arret_urgence`, `arret_motif`, `arret_le`, `arret_par` dans `communication_reglages`, écrites sans verrou en repli | Table d'une ligne. États `actif`, `arret_demande`, `arret_confirme`. **Contraintes** : `arret_confirme` exige `autorisations_closes_le` et `confirme_le` (dans cet ordre, après `demande_le`) ; `actif` les exige vides. Colonnes de suivi (`tentatives`, `derniere_raison`). |
| 40 l. 396 | `communication_interrupteur_ferme(réglages, état_arrêt, nature, canal)` | Lisait `r.arret_urgence` | Prend l'état d'arrêt : tout état autre que `actif` (ou illisible) ferme tout. Nouvelle nature `lecture_meta`, bloquée par l'arrêt seulement. |
| 40 l. 426 | **`communication_autoriser_sortie(nature, canal)`** (nouvelle) | Chaque appelant prenait N0 et lisait lui-même les réglages | **La porte unique** : elle prend N0 partagé, **puis** lit l'état d'arrêt et les réglages, et marque la transaction (`goship.sortie_autorisee = txid_current()`) |
| 40 l. 449 | **`communication_sortie_autorisee()`** (nouvelle) | — | Vraie seulement dans une transaction qui a passé la porte |
| 41 l. 847 | **`communication_conclure_arret(n0_exclusif)`** (nouvelle, interne) | — | Constat commun. Il ne passe à `arret_confirme` **que** si N0 exclusif est tenu, ou l'a été après la demande, **et** si `communication_transmissions_en_cours() = 0`. Sinon `STOP_PENDING` avec sa raison. |
| 41 l. 899 | `arreter_communications(motif)` | N0 exclusif 5 s, puis **écriture quand même**, réponse `ok` | N0 exclusif 5 s **sans contournement**, puis la ligne d'arrêt (5 s), puis la demande, puis le constat. Réponses : `STOP_CONFIRMED`, `STOP_PENDING` (avec raison) ou `STOP_NOT_CONFIRMED`. `synchronous_commit = on`. |
| 41 l. 951 | **`confirmer_arret_communications()`** (nouvelle) | — | Nouvelle tentative sûre (même ordre des verrous). Permission `communications.pause`. |
| 41 l. 981 | **`communication_confirmer_arret_auto()`** (nouvelle, interne) | — | Même chose sans attente (`pg_try_advisory_xact_lock`, `for update nowait`). Appelée au début de chaque passage du travailleur. |
| 41 l. 1003 | **`etat_arret_communications()`** (nouvelle) | — | Lecture pour l'écran (`communications.view`) |
| 41 l. 1021 | `lever_arret_communications(motif)` | Remettait `arret_urgence` à faux | N0 exclusif, puis la ligne d'arrêt, puis `actif` ; journalisée |
| 42 l. 285 | `communication_demander_modele_meta` | Déposait une requête vers Meta sans contrôle propre | **Refuse** (`SORTIE_NON_AUTORISEE`) hors d'une transaction passée par la porte |
| 43 l. 405, 465 | `communication_appel_email`, `communication_appel_whatsapp` | Aucun contrôle propre | **Refusent** hors d'une transaction passée par la porte |
| 43 l. 213 | `communication_reserver` | Relecture sous N5 présentée comme le « dernier contrôle » | Relecture conservée comme **défense de plus** ; l'argument de sûreté est la porte |
| 43 l. 673 | `communication_preparer` | Tenait N0 partagé pendant le lancement (des milliers de lignes possibles) | **Ne prend plus N0** : un lancement ne dépose rien. Il lit l'état d'arrêt simplement. |
| 43 l. 761 | **`communication_rafraichir_modeles_meta()`** (nouvelle) | Les lectures Meta étaient dans `communication_preparer` | Lectures de modèles chez Meta, par la porte (`lecture_meta`) |
| 43 l. 829 | `communication_traiter_un` | Prenait N0 et lisait `arret_urgence` lui-même | Passe par la porte, puis relit les réglages sous le même N0 |
| 43 l. 1065 | Procédure `traiter_communications` | — | Étape 0 : confirmation automatique d'un arrêt en attente. Étapes séparées pour les modèles Meta et pour le lancement. |
| 43 l. 1697 | **`communication_transmissions_en_cours()`** (nouvelle) | — | Requêtes validées encore chez pg_net. **Lecture seule** de `net.http_request_queue` et `net._http_response`. |
| 43 `sante_communications` | Santé | — | Ajoute l'état d'arrêt et les transmissions en cours |

### 1.2 Retours des fournisseurs (constats AF-02, AF-06)

| Fichier | Objet | Avant | Après |
|---|---|---|---|
| 43 l. 1411 | Pause du canal sur un code de Meta | Tentait N0 exclusif, puis écrivait « quand même » | Écrit `whatsapp_actif = false` **sans** N0, au mieux. Journal `PAUSE_CANAL_NON_CONFIRMEE`. N'est **jamais** présentée comme un arrêt. |
| 43 l. 1453 | Report d'un destinataire (code de Meta) | Créait un **nouvel envoi** sur un code de sens **non vérifié** | Exige `communication_codes_fournisseur.verifie`. Les actions protectrices restent appliquées même sur un code non vérifié. |

### 1.3 Droits (constat AF-11)

- `service_role` est retiré de **toutes** les fonctions internes de 40, 41 et 42 (il l'était déjà en 43 en Phase 1.3).
- Les nouvelles fonctions internes sont fermées à tous :
  - `communication_autoriser_sortie`, `communication_sortie_autorisee` ;
  - `communication_conclure_arret`, `communication_confirmer_arret_auto` ;
  - `communication_transmissions_en_cours`, `communication_rafraichir_modeles_meta`.
- Les nouvelles fonctions ouvertes contrôlent leur permission elles-mêmes :
  - `confirmer_arret_communications` : `communications.pause` ;
  - `etat_arret_communications` : `communications.view`.

### 1.4 Constats de la revue indépendante corrigés dans les brouillons

Voir `PHASE_1_3_1_INDEPENDENT_SECURITY_AUDIT.md`, §5 : chaque constat retenu y est rattaché à sa correction ou à sa décision.

---

## 2. Compatibilité PostgreSQL

| Point | Exigence | Statut |
|---|---|---|
| `pg_advisory_xact_lock_shared` / `pg_advisory_xact_lock` / `pg_try_advisory_xact_lock` sur une même clé `bigint` (`hashtextextended`) | PostgreSQL 11 ou plus | Documenté (rapporté) |
| Procédure avec COMMIT, ni `SECURITY DEFINER` ni clause `SET` | PostgreSQL 11 ou plus | Documenté (rapporté) ; T-01-bis |
| `set_config('synchronous_commit', 'on', true)` dans une fonction, qui vaut jusqu'au COMMIT | Réglage local à la transaction | Documenté (rapporté) ; T-01F |
| `txid_current()` dans une sous-transaction : identifiant de la transaction principale | — | Documenté (rapporté) ; T-01D |
| Lecture de `net.http_request_queue`, `net._http_response` | Forme des tables de pg_net 0.20.4 | **À vérifier** (T-01F) |
| `for update nowait` et `lock_not_available` (55P03) | — | Documenté |

Aucune extension nouvelle n'est demandée. Aucune fonction ni table existante du transactionnel n'est modifiée.

---

## 3. Risques de migration

| Risque | Parade |
|---|---|
| Chaîne interrompue entre 40 et 43 : des fonctions de 41 appellent des fonctions de 43 (`communication_demander_envoi_confirmation`, `communication_transmissions_en_cours`, purge) et échouent tant que 43 manque | **Appliquer 40 à 43 dans une seule transaction** en Phase 2 (un fichier concaténé, ou `psql --single-transaction` sur la concaténation). Rien n'est appelé par une page avant la Phase 2c. Essai T-14B. |
| Le déclencheur `communication_suivre_client` (41) s'exécute dès 41, avant 43 | Toutes ses erreurs sont attrapées et gardées : l'écriture du client n'est jamais bloquée (T-14B) |
| Rejouer un fichier | `create … if not exists`, `on conflict do nothing` pour la ligne d'arrêt et les réglages, `create or replace function` : la ligne d'arrêt n'est **jamais** remise à `actif` par un rejeu |
| Ancien état `arret_urgence` (1.3) | N'a jamais existé en base : aucun brouillon n'a été exécuté. Aucune reprise de données n'est nécessaire. |

---

## 4. Retour arrière

- **Avant activation** :
  - le script de retrait de la Phase 2 (`retrait-communications.sql`, jamais exécuté sans autorisation) retire en plus l'exécution des fonctions d'arrêt et de la porte ;
  - il **garde** la table `communication_arret` (trace de qui a arrêté et levé).
- **Après activation** : on ne retire rien. L'arrêt d'urgence **est** le premier geste de retour arrière (`arreter_communications`), puis la tâche est coupée (`cron.alter_job(…, active := false)`).

---

## 5. Ce qui n'a pas été fait

- Aucune exécution, sur aucune base.
- Aucune modification hors de `docs/communication-center/`.
- Aucune modification du transactionnel, de pg_net ou de pg_cron.
- Les copies de `permissions_du_role` hors du dossier ne sont pas modifiées : cinq copies sont à aligner en Phase 2, avec autorisation.
