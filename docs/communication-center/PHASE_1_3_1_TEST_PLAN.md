# Centre de communication — Phase 1.3.1 : plan d'essais

**Date** : 18/11/2026. Ce plan complète `PHASE_1_3_TEST_PLAN.md` (T-01 à T-20) et `COMMUNICATION_CENTER_TESTING.md` (groupes 1 à 16).

> **ÉTAT RÉEL : AUCUN ESSAI EXÉCUTÉ.**
>
> 0 des 20 essais de la Phase 1.3 ont tourné, et 0 des essais ajoutés ici. Aucun ne doit être déclaré réussi sans exécution réelle et sans la preuve indiquée.
>
> Les essais tourneront **après autorisation écrite et spécifique du CEO**, sur une base PostgreSQL **jetable** :
> - le harnais `outils/essais-services/`, avec les doublures d'`auth`, `vault`, `net` et `cron`, ou un pg_net et un pg_cron réels pointant vers un faux serveur local quand l'essai le demande ;
> - des fournisseurs **simulés** ;
> - des données **fictives** (`…@exemple.invalid`, numéros fictifs) ;
> - jamais la production, ni Brevo, ni Meta.

**Criticité** :
- **BLOQUANT** : un échec interdit toute activation ;
- **ÉLEVÉ** : un échec interdit l'activation du canal concerné ;
- **MOYEN** : à corriger avant la Phase 3.

**Environnements** :
- **E1** : base jetable avec les doublures du harnais ;
- **E2** : base jetable avec pg_net **réel** (version de production, 0.20.4 rapportée) et pg_cron réel, pointés vers un faux serveur HTTP local qui enregistre l'heure de chaque requête reçue ;
- **E3** : E1 avec plusieurs connexions simultanées (psql ou psycopg) et des copies **d'essai** des fonctions, avec des `pg_sleep` placés aux points indiqués. Jamais dans les brouillons.

---

## 1. Les 20 essais de la Phase 1.3 (rappel, inchangés sauf mention)

| ID | Objet | Criticité | Mise à jour 1.3.1 | État |
|---|---|---|---|---|
| T-01 | Arrêt pendant un lot | BLOQUANT | **Résultat attendu modifié** : réponse `STOP_CONFIRMED` ou `STOP_PENDING`, plus jamais `ok`. Aucun commit autorisé après G (`autorisations_closes_le`). | NON EXÉCUTÉ |
| T-01-bis | Procédure et pg_cron | BLOQUANT | Inclut la confirmation automatique au début du passage | NON EXÉCUTÉ |
| T-02 | Arrêt avec 4 travailleurs | BLOQUANT | Le cas « repli » est **supprimé** : remplacé par T-01B | NON EXÉCUTÉ |
| T-03 | Annulation pendant un verrouillage | BLOQUANT | — | NON EXÉCUTÉ |
| T-04 | 4 travailleurs, 100 unités Brevo | BLOQUANT | voir T-03B | NON EXÉCUTÉ |
| T-05 | Débit global | ÉLEVÉ | — | NON EXÉCUTÉ |
| T-06 | 500 après acceptation | BLOQUANT | voir T-04B | NON EXÉCUTÉ |
| T-07 | 429 | ÉLEVÉ | — | NON EXÉCUTÉ |
| T-08 | Suppression d'un client | BLOQUANT | voir T-05B | NON EXÉCUTÉ |
| T-09 | Fuseaux américains | BLOQUANT | voir T-06B | NON EXÉCUTÉ |
| T-10 | Changement d'heure | ÉLEVÉ | — | NON EXÉCUTÉ |
| T-11 | Webhook retardé | ÉLEVÉ | voir T-07C | NON EXÉCUTÉ |
| T-12 | Webhook rejoué | ÉLEVÉ | voir T-07B | NON EXÉCUTÉ |
| T-13 | Appel direct non autorisé | BLOQUANT | Ajouter `communication_autoriser_sortie`, `communication_conclure_arret`, `communication_confirmer_arret_auto`, `communication_transmissions_en_cours` à la liste des fonctions fermées | NON EXÉCUTÉ |
| T-14 | Exécution d'un brouillon | BLOQUANT | voir T-14B | NON EXÉCUTÉ |
| T-15 | Permissions et sécurité par ligne | BLOQUANT | 28 tables (avec `communication_arret`). `service_role` refusé sur toutes les fonctions internes. Nouvelles fonctions : `arreter_communications` et `confirmer_arret_communications` (pause), `etat_arret_communications` (view), `lever_arret_communications` (manage). | NON EXÉCUTÉ |
| T-16 | Non-régression du transactionnel | BLOQUANT | voir T-20B | NON EXÉCUTÉ |
| T-17 | Désinscription prioritaire | BLOQUANT | — | NON EXÉCUTÉ |
| T-18 | Changement de coordonnées | BLOQUANT | — | NON EXÉCUTÉ |
| T-19 | Purge à l'échéance | ÉLEVÉ | — | NON EXÉCUTÉ |
| T-20 | Ordre des verrous des consentements | MOYEN | — | NON EXÉCUTÉ |

Les détails complets (préconditions, données, étapes) sont dans `PHASE_1_3_TEST_PLAN.md`.

---

## 2. Nouveaux essais de la Phase 1.3.1

### T-01B — Délai du verrou exclusif N0 : arrêt non confirmé
- **Objectif** : un délai dépassé ne produit **jamais** `STOP_CONFIRMED`, et l'arrêt se termine proprement ensuite.
- **Criticité** : BLOQUANT · **Environnement** : E3
- **Préconditions** : chaîne 1 → 43 dans la copie d'essai, sans garde ; `communication_arret.etat = 'actif'`.
- **Données fictives** : une connexion X qui appelle `communication_autoriser_sortie('lecture_meta', 'whatsapp')` puis `pg_sleep(20)` sans valider (elle tient N0 partagé).
- **Étapes** :
  1. pendant que X dort, A1 appelle `arreter_communications('essai T-01B')` ;
  2. noter la réponse et l'état ;
  3. une connexion Y appelle `communication_autoriser_sortie('campagne', 'email')` ;
  4. X valide ;
  5. A1 appelle `confirmer_arret_communications()` ;
  6. rejouer 1 à 5 avec G1 (gérant), puis avec E1 (employé) ;
  7. tenter `update communication_arret set etat = 'arret_confirme'` en tant que fonction d'essai, sans `autorisations_closes_le`.
- **Résultat attendu** :
  - 1 → au bout d'environ 5 s, `{"etat":"STOP_PENDING","raison":"VERROU_NON_OBTENU","n0_exclusif_obtenu":false}` ; la table est en `arret_demande`, avec `autorisations_closes_le` null ;
  - 3 → Y reçoit `ARRET_URGENCE` ;
  - 5 → `STOP_CONFIRMED` (ou `STOP_PENDING / TRANSMISSIONS_EN_COURS`, puis `STOP_CONFIRMED`) ;
  - 6 → G1 est accepté, E1 est refusé ;
  - 7 → refusé par la contrainte de la table.
- **Conditions d'échec** :
  - `STOP_CONFIRMED` ou `ok:true` à l'étape 1 ;
  - Y autorisée à l'étape 3 ;
  - `arret_confirme` sans `autorisations_closes_le`.
- **Preuve** : les réponses ; la ligne `communication_arret` après chaque étape ; `pg_locks` pendant l'étape 1.
- **État** : NON EXÉCUTÉ

### T-01C — Travailleur actif pendant l'arrêt : aucun commit après l'arrêt confirmé
- **Objectif** : prouver la propriété 1 (`PHASE_1_3_1_KILL_SWITCH_DESIGN.md` §5).
- **Criticité** : BLOQUANT · **Environnement** : E2 et E3
- **Données fictives** : 50 envois `attente` (clients fictifs de la liste d'essai, fuseaux connus, fenêtre ouverte) ; une copie d'essai de `communication_traiter_un` avec `pg_sleep(0.3)` après `communication_reserver`.
- **Étapes** :
  1. la procédure tourne ;
  2. A1 arrête pendant le 3e envoi ;
  3. relever `xact_commit` et l'heure du COMMIT de chaque transaction d'envoi (journal `log_min_duration_statement = 0` et `log_line_prefix` avec l'heure et l'identifiant de transaction) ;
  4. relever l'heure de réception de chaque requête par le faux serveur ;
  5. A1 appelle `confirmer_arret_communications()` jusqu'à `STOP_CONFIRMED`.
- **Résultat attendu** :
  - toute transaction d'envoi validée a son COMMIT **avant** `autorisations_closes_le` ;
  - aucune requête n'est reçue par le faux serveur après la validation de `STOP_CONFIRMED` ;
  - la première réponse est `STOP_PENDING / TRANSMISSIONS_EN_COURS` si une requête était encore chez pg_net.
- **Conditions d'échec** : un COMMIT d'envoi après `autorisations_closes_le` ; une requête reçue après `STOP_CONFIRMED`.
- **Preuve** : les journaux PostgreSQL (heure de chaque COMMIT) ; le journal du faux serveur ; la ligne `communication_arret`.
- **État** : NON EXÉCUTÉ

### T-01D — Plusieurs travailleurs : aucun contournement de l'arrêt
- **Objectif** : aucune voie de sortie ne passe à côté de la porte.
- **Criticité** : BLOQUANT · **Environnement** : E3
- **Étapes** :
  1. 4 travailleurs plus la rafraîchissement des modèles Meta en parallèle ; arrêt au milieu ;
  2. après `STOP_CONFIRMED`, appeler **directement**, en tant que propriétaire de la base dans une copie d'essai, `communication_appel_email`, `communication_appel_whatsapp` et `communication_demander_modele_meta` **sans** passer par la porte ;
  3. passer la porte avec succès, puis appeler la fonction d'appel dans **une autre** transaction ;
  4. recherche statique : chaque `net.http_` des fichiers 40 à 43 est précédé d'un contrôle `communication_sortie_autorisee()`.
- **Résultat attendu** :
  - 1 → aucune autorisation après G ;
  - 2 et 3 → `SORTIE_NON_AUTORISEE`, aucune ligne dans `net.http_request_queue` ;
  - 4 → 3 appels, 3 contrôles.
- **Conditions d'échec** : une requête déposée sans la marque de la porte de la même transaction.
- **Preuve** : `net.http_request_queue` ; la sortie de la recherche.
- **État** : NON EXÉCUTÉ

### T-01E — Reprise après un arrêt confirmé : envoi bloqué
- **Objectif** : une reprise de campagne ou une relance ne fait rien partir pendant l'arrêt ; seule la levée rouvre.
- **Criticité** : BLOQUANT · **Environnement** : E1
- **Étapes** :
  1. arrêt confirmé ;
  2. A1 « reprendre » une campagne en pause ;
  3. A1 relance un envoi incertain (avec la case de risque) ;
  4. un passage du travailleur ;
  5. G1 tente de lever l'arrêt ;
  6. A1 lève sans motif, puis avec un motif ;
  7. un passage du travailleur.
- **Résultat attendu** :
  - 2 et 3 sont acceptés (statuts seulement) ;
  - 4 → aucun `traitement`, code `ARRET_URGENCE` ;
  - 5 → refusé ; 6 → refusé, puis accepté et journalisé ;
  - 7 → les envois repartent **sous toutes les règles** (fenêtre, consentement, empreinte).
- **Conditions d'échec** : un envoi `traitement` entre 1 et 6.
- **Preuve** : la table des envois ; `journal_audit` (`arret_demande`, `arret_confirme`, `arret_leve`).
- **État** : NON EXÉCUTÉ

### T-01F — Transmissions pg_net et durabilité (complément)
- **Objectif** : `STOP_CONFIRMED` n'est rendu qu'une fois les requêtes validées sorties des mains de pg_net, et l'état survit à un redémarrage.
- **Criticité** : ÉLEVÉ · **Environnement** : E2
- **Étapes** :
  1. arrêter le processus de travail de pg_net (base jetable) ;
  2. valider 3 envois ;
  3. arrêter : attendre `STOP_PENDING / TRANSMISSIONS_EN_COURS = 3` ;
  4. redémarrer pg_net ; attendre les réponses ;
  5. confirmer ;
  6. redémarrer PostgreSQL brutalement juste après la réponse `STOP_CONFIRMED`.
- **Résultat attendu** :
  - 3 → l'état reste en attente tant que pg_net est arrêté ;
  - 5 → `STOP_CONFIRMED` ;
  - 6 → l'état est encore `arret_confirme` après le redémarrage.
- **Preuve** : les réponses ; la ligne après le redémarrage ; la version de pg_net et la forme réelle de `net.http_request_queue` et de `net._http_response` notées.
- **État** : NON EXÉCUTÉ

### T-03B — Quota Brevo, travailleurs concurrents : limite globale respectée
- **Objectif** : aucune lecture concurrente du quota ne permet de le dépasser, sur plusieurs campagnes.
- **Criticité** : BLOQUANT · **Environnement** : E3
- **Préconditions** : disponible = 100 ; deux campagnes A (plafond 70) et B (plafond 70) ; plafond du jour 120.
- **Données fictives** : 300 envois e-mail répartis sur A et B ; 4 travailleurs.
- **Étapes** :
  1. tout traiter ;
  2. rejouer avec des erreurs provoquées (exception dans `communication_appel_email` pour 1 envoi sur 10) ;
  3. rejouer avec des délais de verrou provoqués.
- **Résultat attendu** :
  - total ≤ 100 (quota), A ≤ 70, B ≤ 70, jour ≤ 120 ;
  - les envois en erreur ne consomment rien (réservation annulée avec la transaction) ;
  - aucune réservation sans requête, et aucune requête sans réservation.
- **Conditions d'échec** : un total supérieur à 100 ; une réservation orpheline (`communication_depenses_jour` plus grand que le nombre d'envois `traitement` du jour).
- **Preuve** : les comptes croisés entre `communication_depenses_jour`, `communication_debit_minute` et les envois.
- **État** : NON EXÉCUTÉ

### T-04B — Le fournisseur accepte puis renvoie une 5xx : incertain, aucun renvoi automatique
- **Objectif** : vérifier, en conditions réelles de pg_net, la règle « 5xx = incertain ».
- **Criticité** : BLOQUANT · **Environnement** : E2
- **Données fictives** : un faux serveur qui **enregistre** le message puis répond 500 ; un autre qui coupe la connexion après l'avoir reçu.
- **Étapes** :
  1. un envoi ;
  2. dix passages du travailleur ;
  3. un retour simulé `delivered` avec la référence ;
  4. tenter `verifier_issue_http('brevo', 503, 'rejet_temporaire', …)`.
- **Résultat attendu** :
  - le faux serveur a reçu **une seule** requête ;
  - l'envoi est `incertain`, puis `livre` après le retour ;
  - l'étape 4 est refusée (`UNSAFE_RULE`).
- **Conditions d'échec** : plus d'une requête reçue pour la même clé d'envoi.
- **Preuve** : le journal du faux serveur ; la table des envois.
- **État** : NON EXÉCUTÉ

### T-05B — Purge et données dérivées : aucune conservation injustifiée
- **Objectif** : après l'effacement d'une personne, ne restent que les preuves justifiées, et rien de **dérivé** ne la désigne encore.
- **Criticité** : BLOQUANT · **Environnement** : E1, puis E2 pour pg_net
- **Données fictives** : le client fictif C1, avec toutes ses lignes (voir T-08) ; un envoi WhatsApp dont la réponse simulée de Meta contient son numéro (`wa_id`).
- **Étapes** :
  1. effacement (T-08) ;
  2. recherche de **son identifiant**, de **son e-mail**, de **son numéro en clair**, de **ses empreintes** et de **ses identifiants de messages** dans : toutes les tables `public`, `journal_audit`, `net._http_response`, `net.http_request_queue`, `cron.job_run_details`, et les journaux PostgreSQL de la base jetable.
- **Résultat attendu** :
  - Centre : seules l'empreinte du consentement (preuve) et celle d'une suppression **active** restent ;
  - **hors Centre**, consigné et non corrigé dans cette phase : `journal_audit` (identifiant), pg_net (numéro et e-mail en clair jusqu'à l'échéance de pg_net). Chaque occurrence est listée dans le rapport d'essai, pour la décision du juriste et du CEO.
- **Conditions d'échec** : une donnée **dans le Centre** autre que les deux preuves ; une occurrence hors Centre qui n'est pas consignée.
- **Preuve** : la requête de recherche exhaustive et sa sortie avant et après.
- **État** : NON EXÉCUTÉ

### T-06B — Destinataire américain sans fuseau fiable : envoi bloqué
- **Objectif** : aucun envoi sans heure locale sûre.
- **Criticité** : BLOQUANT · **Environnement** : E1
- **Données fictives** :
  - C12 (Floride, sans fuseau) ;
  - C13 (US, région vide) ;
  - C14 (US, région « Texas » enregistrée par erreur avec un fuseau invalide `America/Nowhere` en contournant la fonction d'écriture) ;
  - C15 (pays HT, numéro WhatsApp +1 305) ;
  - C16 (pays vide).
- **Étapes** : aperçu d'audience, lancement, puis passage du travailleur.
- **Résultat attendu** : les 5 sont écartés (`FUSEAU_INCONNU`) ; C14 aussi (fenêtre null, exception attrapée) ; aucun n'est servi à l'heure de New York.
- **Conditions d'échec** : un seul envoi `traitement` pour C12 à C16.
- **Preuve** : la table des destinataires (raisons) ; la table des envois.
- **État** : NON EXÉCUTÉ

### T-07B — Webhook rejoué ou falsifié : rejet
- **Objectif** : aucun événement non authentifié n'a d'effet ; un rejeu n'a pas d'effet nouveau.
- **Criticité** : BLOQUANT · **Environnement** : E1
- **Étapes** :
  1. appel avec la clé publique (`anon`), avec un jeton client, avec un jeton administrateur ;
  2. appel par `communication_webhook` avec une signature fausse, avec une signature calculée sur un **autre** corps, et avec la signature d'un corps modifié d'un seul caractère ;
  3. rejeu exact d'un STOP, d'un « OUI 1234 », d'un `delivered` ;
  4. faux `inbound` signé avec la bonne clé mais pour un numéro sans demande en attente ;
  5. un code Meta **non vérifié** `reporter_destinataire`.
- **Résultat attendu** :
  - 1 → `permission denied`, avant l'entrée dans la fonction ;
  - 2 → `{ok:false}`, sans aucune écriture métier (seul le compteur par minute change) ;
  - 3 → `{ok:true, rejeu:true}`, sans effet ;
  - 4 → aucun consentement créé ;
  - 5 → **aucun** nouvel envoi créé (1.3.1 : il faut un code vérifié).
- **Conditions d'échec** : un effet métier en 1, 2, 4 ou 5 ; un double effet en 3.
- **Preuve** : les comptes des tables touchées avant et après.
- **État** : NON EXÉCUTÉ

### T-07C — Webhook retardé ou désordonné : état cohérent
- **Objectif** : l'ordre de réception ne change pas le résultat.
- **Criticité** : ÉLEVÉ · **Environnement** : E1
- **Données fictives** : pour un même envoi, `sent` (10 h 00), `delivered` (10 h 01), `read` (10 h 05), reçus dans les 6 ordres possibles ; pour un même numéro, des messages entrants à 9 h, 10 h et 11 h reçus dans le désordre ; un STOP daté de 10 h reçu après un « OUI » daté de 11 h.
- **Résultat attendu** :
  - statut final `lu` dans les 6 ordres, avec `envoye_le`, `livre_le` et `lu_le` égaux aux heures **réelles** ;
  - fenêtre WhatsApp = 11 h ;
  - consentement : l'état final reflète le **dernier événement reçu** (le STOP, retrait).

  Ce dernier comportement est **à décider** : faut-il ordonner par l'heure réelle, et donner la priorité au retrait ? Il est signalé au rapport d'audit.
- **Conditions d'échec** : un statut qui recule ; une fenêtre calculée sur l'heure de réception.
- **Preuve** : la table des envois ; `communication_fenetres_whatsapp` ; `communication_consentements`.
- **État** : NON EXÉCUTÉ

### T-14B — Migration interrompue : comportement documenté et sûr
- **Objectif** : savoir exactement ce qui se passe si la chaîne 40 → 43 (version de la Phase 2, sans la chaîne englobante) s'arrête entre deux fichiers.
- **Criticité** : BLOQUANT · **Environnement** : E1
- **Étapes** : appliquer seulement 40 ; 40 + 41 ; 40 + 41 + 42. Pour chaque cas :
  1. mettre à jour un client (e-mail, pays, suppression du compte) ;
  2. appeler `demander_consentement_communication`, `executer_purge_communication` et `arreter_communications` ;
  3. appliquer la suite ;
  4. rejouer la chaîne entière.
- **Résultat attendu** :
  - 1 → l'écriture du client réussit toujours ; les erreurs sont gardées dans `communication_erreurs` ;
  - 2 → erreurs **franches** (fonction manquante), **aucune** donnée à moitié écrite (chaque appel est une transaction) ;
  - 3 et 4 → aucune erreur, aucune donnée dupliquée.
  - Recommandation vérifiée : en Phase 2, **appliquer 40 à 43 dans une seule transaction**.
- **Conditions d'échec** : une écriture de client bloquée ; un objet ou une donnée à moitié créée.
- **Preuve** : la sortie de chaque application ; `communication_erreurs`.
- **État** : NON EXÉCUTÉ

### T-20B — Régression des notifications transactionnelles : contrats préservés
- **Objectif** : le transactionnel est identique, même sous charge du Centre **et** pendant un arrêt d'urgence.
- **Criticité** : BLOQUANT · **Environnement** : E2
- **Étapes** :
  1. les bancs existants (`essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py`, `essai-courriel-colis.py`, `essai-courriel-pied.py`, `essai-mobile.py`) avant et après 40 à 43 ;
  2. colis reçu, paiement et création de compte pendant que 4 travailleurs du Centre tournent **et** qu'un arrêt est en attente (`STOP_PENDING`, N0 exclusif demandé) ;
  3. comparer la forme exacte de `mon_resume`, `messages_recents`, `notification_envois`, `notifications`, les sorties d'`expedier_envoi` et de `courriel_gabarit`.
- **Résultat attendu** :
  - 1 → mêmes résultats au chiffre près ;
  - 2 → les envois transactionnels partent sans attendre aucun verrou du Centre. N0 n'est jamais demandé par le transactionnel : relever `pg_locks` ;
  - 3 → identiques ; aucune ligne du Centre dans les tables transactionnelles.
- **Conditions d'échec** : une différence ; une attente d'un processus transactionnel sur un verrou du Centre.
- **Preuve** : les sorties des bancs ; `pg_locks` ; les comparaisons.
- **État** : NON EXÉCUTÉ

---

## 3. Récapitulatif

| Groupe | Essais | Exécutés |
|---|---|---|
| Phase 1.3 | T-01, T-01-bis, T-02 à T-20 (21) | **0** |
| Phase 1.3.1 | T-01B, T-01C, T-01D, T-01E, T-01F, T-03B, T-04B, T-05B, T-06B, T-07B, T-07C, T-14B, T-20B (13) | **0** |
| **Total** | **34** | **0** |

Ordre recommandé, après autorisation :
1. T-14 et T-14B (garde, chaîne) ;
2. T-01-bis (procédure) ;
3. T-01B à T-01F et T-02 (arrêt) ;
4. T-03, T-03B, T-04 (concurrence) ;
5. tous les autres ;
6. T-20B en dernier, puis **à chaque** changement.
