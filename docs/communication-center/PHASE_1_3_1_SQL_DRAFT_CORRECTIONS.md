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
| 40 l. 176 | **Table `communication_arret`** (nouvelle) | Colonnes `arret_urgence`, `arret_motif`, `arret_le`, `arret_par` dans `communication_reglages`, écrites sans verrou en repli | Table d'une ligne. États `actif`, `arret_demande`, `arret_confirme`. **Contraintes** : `arret_confirme` exige `autorisations_closes_le` et `confirme_le` (dans cet ordre, après `demande_le`) ; `actif` les exige vides. Colonnes de suivi (`tentatives`, `derniere_raison`). |
| 40 l. 332 | `communication_interrupteur_ferme(réglages, état_arrêt, nature, canal)` | Lisait `r.arret_urgence` | Prend l'état d'arrêt : tout état autre que `actif` (ou illisible) ferme tout. Nouvelle nature `lecture_meta`, bloquée par l'arrêt seulement. |
| 40 l. 362 | **`communication_autoriser_sortie(nature, canal)`** (nouvelle) | Chaque appelant prenait N0 et lisait lui-même les réglages | **La porte unique** : elle prend N0 partagé, **puis** lit l'état d'arrêt et les réglages, et marque la transaction (`goship.sortie_autorisee = txid_current()`) |
| 40 l. 385 | **`communication_sortie_autorisee()`** (nouvelle) | — | Vraie seulement dans une transaction qui a passé la porte |
| 41 l. 901 | **`communication_conclure_arret(n0_exclusif)`** (nouvelle, interne) | — | Constat commun. Il ne passe à `arret_confirme` **que** si N0 exclusif est tenu, ou l'a été après la demande, **et** si `communication_transmissions_en_cours() = 0`. Sinon `STOP_PENDING` avec sa raison. |
| 41 l. 953 | `arreter_communications(motif)` | N0 exclusif 5 s, puis **écriture quand même**, réponse `ok` | N0 exclusif 5 s **sans contournement**, puis la ligne d'arrêt (5 s), puis la demande, puis le constat. Réponses : `STOP_CONFIRMED`, `STOP_PENDING` (avec raison) ou `STOP_NOT_CONFIRMED`. `synchronous_commit = on`. |
| 41 l. 1008 | **`confirmer_arret_communications()`** (nouvelle) | — | Nouvelle tentative sûre (même ordre des verrous). Permission `communications.pause`. |
| 41 l. 1039 | **`communication_confirmer_arret_auto()`** (nouvelle, interne) | — | Même chose sans attente (`pg_try_advisory_xact_lock`, `for update nowait`). Appelée au début de chaque passage du travailleur. |
| 41 l. 1061 | **`etat_arret_communications()`** (nouvelle) | — | Lecture pour l'écran (`communications.view`) |
| 41 l. 1079 | `lever_arret_communications(motif)` | Remettait `arret_urgence` à faux | N0 exclusif, puis la ligne d'arrêt, puis `actif` ; journalisée |
| 42 l. 296 | `communication_demander_modele_meta` | Déposait une requête vers Meta sans contrôle propre | **Refuse** (`SORTIE_NON_AUTORISEE`) hors d'une transaction passée par la porte |
| 43 l. 421, 484 | `communication_appel_email`, `communication_appel_whatsapp` | Aucun contrôle propre | **Refusent** hors d'une transaction passée par la porte |
| 43 l. 224 | `communication_reserver` | Relecture sous N5 présentée comme le « dernier contrôle » | Relecture conservée comme **défense de plus** ; l'argument de sûreté est la porte |
| 43 l. 711 | `communication_preparer` | Tenait N0 partagé pendant le lancement (des milliers de lignes possibles) | **Ne prend plus N0** : un lancement ne dépose rien. Il lit l'état d'arrêt simplement. |
| 43 l. 814 | **`communication_rafraichir_modeles_meta()`** (nouvelle) | Les lectures Meta étaient dans `communication_preparer` | Lectures de modèles chez Meta, par la porte (`lecture_meta`) |
| 43 l. 882 | `communication_traiter_un` | Prenait N0 et lisait `arret_urgence` lui-même | Passe par la porte, puis relit les réglages sous le même N0 |
| 43 l. 1135 | Procédure `traiter_communications` | — | Étape 0 : confirmation automatique d'un arrêt en attente. Étapes séparées pour les modèles Meta et pour le lancement. |
| 43 l. 1828 | **`communication_transmissions_en_cours()`** (nouvelle) | — | Requêtes validées encore chez pg_net. **Lecture seule** de `net.http_request_queue` et `net._http_response`. |
| 43 `sante_communications` | Santé | — | Ajoute l'état d'arrêt et les transmissions en cours |

### 1.2 Retours des fournisseurs (constats AF-02, AF-06)

| Fichier | Objet | Avant | Après |
|---|---|---|---|
| 43 l. 1571 | Pause du canal sur un code de Meta | Tentait N0 exclusif, puis écrivait « quand même » | Écrit `whatsapp_actif = false` **sans** N0, au mieux. Journal `PAUSE_CANAL_NON_CONFIRMEE`. N'est **jamais** présentée comme un arrêt. |
| 43 l. 1541 | Report d'un destinataire (code de Meta) | Créait un **nouvel envoi** sur un code de sens **non vérifié** | Exige `communication_codes_fournisseur.verifie`. Les actions protectrices restent appliquées même sur un code non vérifié. |

### 1.3 Droits (constat AF-11)

- `service_role` est retiré de **toutes** les fonctions internes de 40, 41 et 42 (il l'était déjà en 43 en Phase 1.3).
- Les nouvelles fonctions internes sont fermées à tous :
  - `communication_autoriser_sortie`, `communication_sortie_autorisee` ;
  - `communication_conclure_arret`, `communication_confirmer_arret_auto` ;
  - `communication_transmissions_en_cours`, `communication_rafraichir_modeles_meta`.
- Les nouvelles fonctions ouvertes contrôlent leur permission elles-mêmes :
  - `confirmer_arret_communications` : `communications.pause` ;
  - `etat_arret_communications` : `communications.view`.

### 1.4 Constats de la revue indépendante (IR-01 à IR-25) corrigés dans les brouillons

Les constats sont ceux de la **revue indépendante n° 1**, faite sur le commit `5b88624`. Leur verdict et leur discussion sont dans `PHASE_1_3_1_INDEPENDENT_SECURITY_AUDIT.md`.

| Constat | Correction | Où (1.3.1) |
|---|---|---|
| IR-01 (HIGH) — l'effacement échouait sur la clé étrangère `confirmation_id` | `on delete set null`, et contrainte assouplie pour un envoi de confirmation **clos** | 43 l. 80 (`communication_envois`) |
| IR-02 (HIGH) — l'UUID du client restait dans `cle` | Clé `campagne:<campagne>:<destinataire>` ; `cle = 'efface:<id>'` à l'effacement | 43 `communication_preparer`, `communication_purger_personne_suite` (l. 1765) |
| IR-03 (HIGH) — message validé après un arrêt « ok » | Refonte de l'arrêt (§1.1) | 40, 41 §4.8, 43 |
| IR-04 — l'arrêt pouvait attendre derrière `communication_reglages` | Table d'arrêt dédiée ; délais 3 s + 2 s ; pause du canal par le webhook écrite **en dernier** | 40 l. 176 ; 41 l. 953 ; 43 webhook |
| IR-05 — 42 ne se créait pas ; un déclencheur fragile en chaîne partielle | `communication_environnement_envoi` en PL/pgSQL ; déclencheur en **trois blocs indépendants** | 42 l. 648 ; 41 l. 278 |
| IR-06 — fournisseur relu à l'appel | Fournisseur de l'envoi seul utilisé ; `CHECK` sur ses valeurs ; recherche par la référence d'abord | 43 l. 80, 421, webhook |
| IR-07 — données gardées après effacement | Audience = retenus seulement (exclus comptés) ; événements entrants sans identifiant de Meta (empreinte) ; empreintes prises par le déclencheur dans `old.*` ; demande de purge vidée après exécution ; champs de levée effacés ; journal des erreurs sans `sqlerrm` ; demande ouverte dès qu'une table cite la personne | 43 `communication_preparer`, webhook, purges ; 41 l. 278 ; 40 l. 994, 1080 ; 42 `communication_campagnes` (`retenus`, `exclusions`) |
| IR-08 — STOP perdu | Débit non appliqué aux messages entrants ; horodatage illisible ou futur ignoré au lieu de refuser | 43 l. 1322 |
| IR-09 — désinscription « ok » sans rien écrire | L'échéance « envois » garde l'empreinte ; « empreintes » l'efface ; réponses `efface` / `lien_expire` distinctes ; jamais « ok » sans écriture | 43 l. 1582, 1694 |
| IR-10 — modèle archivé redevenu modifiable | Empreinte **recalculée** par le déclencheur (insertion et mise à jour) ; archive définitive ; le travailleur revérifie l'empreinte | 42 l. 103 ; 43 l. 882 |
| IR-11 — compte Brevo partagé | E-mail commercial **refusé** tant que le compte est partagé (décision C4) | 41 l. 595 |
| IR-12 — jeton dans le Referer | **Exigence de la Phase 2c** (pages pas encore écrites) : `no-referrer`, jeton dans le fragment, pages exclues de `mesure.js` | Documenté (audit §6) |
| IR-13 — trois interblocages | Désinscription : N3 avant la suppression ; fermeture des incertains en `skip locked` ; purge et annulation verrouillent les envois **par identifiant croissant** | 43 l. 1582, 666, 1765 ; 42 l. 825 |
| IR-14 — relance après rapprochement de l'original | La relance est écartée (`ORIGINAL_REMIS`) | 43 l. 882 |
| IR-15 — « incertain » encore dans la file pg_net | La règle des 10 minutes attend que la requête ait quitté la file | 43 l. 666 |
| IR-16 — déclencheur à bloc unique | Trois blocs ; limite `query_canceled` documentée | 41 l. 278 |
| IR-17 — verrou avant permission | Action et droit minimal vérifiés **avant** tout verrou | 42 l. 825 |
| IR-18 — `service_role` | Retiré de toutes les fonctions internes **et** des 28 tables du Centre ; option `service_role` déconseillée pour la fonction Edge | 40 à 43 |
| IR-19 — empreinte de l'environnement incomplète | Ajout du code des fonctions de rendu et d'appel (`pg_get_functiondef`), du fournisseur et de l'adresse un-clic | 42 l. 648 |
| IR-20 — 401/403, codes Meta | 401/403 → `AUTH_FOURNISSEUR`, puis la campagne passe en pause ; code Meta du corps gardé ; un code non vérifié ne crée plus d'envoi | 43 l. 545, 882, webhook |
| IR-21 — performance sous verrous | Le lancement ne tient plus N0. Le reste est **à mesurer** (essai T-05). | 43 l. 711 |
| IR-22 — découpeur naïf | Couche 4 `pg_terminate_backend(pg_backend_pid())` en tête du contenu (simulation : seule instruction exécutée après deux `end` sans effet) ; remplacement de `permissions_du_role` déplacé en fin de 40 | les 4 fichiers l. ~23 ; 40 l. 1194 |
| IR-23 — fuseaux et indicatifs | Hypothèse « pays du profil » écrite comme telle ; indicatif +1 de moins de 4 chiffres refusé | 40 (fuseau) ; 41 l. 731 |
| IR-24 — conflits entre PR | Documenté (audit §7) | — |
| IR-25 — hypothèses | READ COMMITTED **vérifié** dans `communication_reserver` ; code 57014 retiré ; compteur du webhook en 8 éclats | 43 l. 224, 1135, 1290 |

---

### 1.5 Constats des revues indépendantes n° 2 (IR2-xx) et n° 3 (IR3-xx)

| Constat | Correction | Où |
|---|---|---|
| IR2-01 (HIGH) — confirmé pendant une transmission retardée | Décompte **par requête**, à partir de la sortie de file **observée** (`sortie_file_vue_le`, `communication_observer_sorties`, `communication_en_transmission`) | 43 §13 |
| IR2-02 — requête effacée par la purge | `requete` gardée tant qu'elle n'est pas résolue | 43 purges |
| IR2-03 — levée qui défait un arrêt | `derniere_demande_le` à chaque appui ; levée refusée si un appui est postérieur à son début ; délai de 5 s | 40 `communication_arret` ; 41 |
| IR2-04 — motif trop long | Tronqué à 300 caractères | 41 `arreter_communications` |
| IR2-05 — purge des confirmations bloquée | Envois en attente écartés d'abord ; `PURGE_RETRY` si l'un est en remise | 40 `executer_purge_communication` |
| IR2-06 — STOP perdu sans empreinte | Empreinte calculée **avant** l'enregistrement du rejeu ; erreur levée si elle manque, donc rien n'est enregistré et le fournisseur réessaie | 43 webhook |
| IR2-07 — purge sans N3 | Purge sous N2 puis N3 (e-mail, WhatsApp) ; désinscription relue sous N3 | 40 ; 43 |
| IR2-09 — autorisation +1 | Lue sur le préfixe le plus long ; « 1 » ou « 18 » jamais autorisé | 42 `communication_raison_exclusion` ; 41 |
| IR2-10 — isolation, marque | READ COMMITTED vérifié à la porte ; marque `txid:nature:canal` | 40 porte ; 42, 43 fonctions d'appel |
| IR2-11 — ligne d'arrêt absente | Erreur explicite ; déclencheur qui interdit l'effacement | 40 ; 41 |
| IR2-12 / IR3-04 — compte Brevo partagé | Vérifié à la porte **et** sur le fournisseur figé de chaque envoi | 40 porte ; 43 `communication_traiter_un` |
| IR2-13 — empreinte de l'environnement | Code de 13 fonctions, compte e-mail (empreinte de la clé), version et compte WhatsApp | 42 `communication_environnement_envoi` |
| IR2-14 — pauses en boucle | Seulement les erreurs postérieures à la dernière reprise ; index partiel | 43 |
| IR2-15 — demandes refusées | Empreintes effacées au refus | 41 `approuver_purge_communication` |
| IR2-17 — déclencheur des modèles | `before insert or update` (la modification n'avait pas été enregistrée) | 42 |
| IR3-01 (HIGH) — nouvel essai non compté | `sortie_file_vue_le = null` à chaque nouvelle requête | 43 `communication_traiter_un` |
| IR3-02 — coût du décompte | Filtrage sur les requêtes récentes ou non vues ; trois index partiels | 43 §13 |
| IR3-03 — lectures Meta non comptées | Observées et comptées | 42 `communication_modeles_meta` ; 43 §13 |
| IR3-05 — course de la purge des confirmations | Envois verrouillés par identifiant croissant avant le contrôle | 40 |
| IR3-06 — délai par requête | Délai **maximal** permis + 60 s (120 s) | 43 `communication_en_transmission` |
| IR3-08 — lectures Meta « sans réponse » trop tôt | Même règle que les envois | 42 `communication_lire_modeles_meta` |
| IR3-09 — commentaire d'ordre des verrous | Corrigé (niveau N0a) | 40 §3 |

**Non appliqués (documentés dans l'audit)** :
- IR2-08 (préfixe `--|` sur chaque ligne) ;
- IR3-07 (version de la ligne d'arrêt vue par l'écran : Phase 2c) ;
- IR2-18 (relance d'un envoi effacé : refus d'emblée en Phase 2).

Les corrections des IR3-xx **n'ont pas été revérifiées par une revue indépendante**.

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

---

## 6. Corrections D5 (20/11/2026, autorisées par écrit par la CEO, « D5 approuvé sous conditions »)

Détail, différences avant / après et risques : `PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md`.

| Correction | Fichier, fonction | Résumé |
|---|---|---|
| P-07 | 41 `arreter_communications`, `confirmer_arret_communications`, `communication_conclure_arret` | Demande seule, sans N0 ; constat dans un bloc qui rattrape tout ; `greatest()` sur les horodatages |
| Version | 40 `communication_arret.version` ; 41 `lever_arret_communications(text, bigint)` | Levée refusée si l'état a changé depuis l'affichage ; ancienne signature supprimée ; liste des droits à jour |
| P-03 | 40 `executer_purge_communication` ; 41 consentement, réglages, levée, déclencheur ; 42 campagnes ; 43 relance, désinscription, retours | Toutes les attentes bornées (2 à 5 s) ; plus de `'0'` ; N0 exclusif borné partout (RF-07) ; déclencheur sur `clients` non bloquant (RF-10) |
| P-08 | 43 table `communication_evenements_traitement`, `communication_recevoir_evenement` (temps A), `communication_traiter_evenement` (temps B), `communication_evenement_a_reprendre`, `reprendre_evenement_communication`, procédure ; purges | Retour enregistré puis traité ; reprise ; clé étrangère retirée ; N3 avant la suppression (RF-05) ; relance : campagne avant l'envoi |
| P-09 | 43 `communication_classer_entrant`, `communication_est_stop` | Bouton, liste fermée, premier mot et 5 mots au plus, « ambigu » |
| P-05 | 42 aperçu, volume, index unique partiel ; 43 `communication_preparer`, `communication_traiter_un` (N3b, contrôle du doublon) | Un message par contact et par campagne |
| N-01 (D1) | 43 `communication_frequence_atteinte(uuid, text, text)` + index | Plafond par compte **et** par contact |
| N-02 (D1) | 40 `communication_confirmations` (6 chiffres, `tentatives`, index unique par numéro), réglage `confirmation_code_validite_min` ; 41 `demander_consentement_communication` ; 43 temps B | Code unique par numéro, expiration courte, 5 essais, demandes répétées limitées par compte et par numéro |
| D2 | 42 `communication_raison_exclusion` | `CONTACT_PARTAGE_NON_CONSENTI` (mesure conservatrice, en attente du juriste) |
| Surveillance | 43 `sante_communications` (section `evenements`) | `a_traiter`, `en_retard`, `echec`, `echec_prioritaires`, `ambigus_7j`, `alerte` |

**Contrôle statique (sans exécution)** :
- les 4 fichiers se lisent toujours, en entier, comme la seule garde (`DoStmt` + `SelectStmt`) ;
- les 90 corps PL/pgSQL se relisent avec leur vraie signature ;
- 109 fonctions, toutes avec `search_path` vide et leur `REVOKE` (`permissions_du_role` garde ses droits d'origine, voulu) ;
- 29 tables, toutes avec RLS et `revoke all` ;
- couche 4 de la garde : inchangée (simulation du découpeur naïf).
