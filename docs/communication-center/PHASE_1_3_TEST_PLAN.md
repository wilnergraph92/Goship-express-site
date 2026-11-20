# Centre de communication — Phase 1.3 : plan d'essais complété

**Date** : 18/11/2026. Ce plan complète `COMMUNICATION_CENTER_TESTING.md` (groupes 1 à 16 de la Phase 1.2) et ne le remplace pas.

> **STATUT DE TOUS LES ESSAIS : NON EXÉCUTÉ.**
>
> Aucun essai n'a tourné, et aucun n'est marqué réussi. Ils tourneront en Phase 2, **après autorisation écrite du CEO**, sur une base PostgreSQL **jetable** : le harnais existant de `outils/essais-services/`, avec ses doublures d'`auth`, `vault`, `net` et `cron`.
>
> Les fournisseurs seront **simulés** : réponses écrites dans `net._http_response`, aucune requête réelle. Ni la production, ni Brevo, ni Meta ne seront touchés.
>
> Seule vérification faite en 1.3 : l'**analyse statique** des brouillons (parseur de PostgreSQL, sans base). Ce n'est pas un essai.

**Données fictives communes**, reprises du plan 1.2 et complétées :

| Code | Rôle | Contact | Fuseau |
|---|---|---|---|
| C1 | client | HT, fr, `c1@exemple.invalid`, `+509 3…` | — |
| C2 | client | DO, es, `+1 809 …` | — |
| C3 | client | US, en, région « New York » | — |
| C7 | client | US, région « Illinois » | fuseau déclaré `America/Chicago` |
| C8 | client | US, région « Colorado » | fuseau déclaré `America/Denver` |
| C9 | client | US, région « California » | fuseau déclaré `America/Los_Angeles` |
| C10 | client | US, région « Alaska » | fuseau déclaré `America/Anchorage` |
| C11 | client | US, région « Hawaii » | fuseau déclaré `America/Honolulu` (pas d'heure d'été) |
| C12 | client | US, région « Florida » | **aucun** fuseau déclaré ; l'État a deux fuseaux |

Équipe : A1 et A2 (administrateurs), G1 (gérant), E1 (employé).

Le coffre de doublure contient des valeurs d'essai pour : `communication_poivre`, `communication_cle_desinscription`, `communication_cle_webhook`, `communication_email_cle_api`, `communication_expediteur`, `communication_nom`.

**Outil commun de concurrence** : plusieurs connexions `psql` (ou `psycopg`) ouvertes en parallèle. Les pauses sont placées par `pg_sleep` dans une **copie d'essai** de la fonction, jamais dans le brouillon.

**Preuve commune** : la sortie du banc `essai-communications.py` (nombre de vérifications réussies et échouées), le journal de la CI, et la preuve particulière de chaque essai.

**Niveaux de criticité** :
- **BLOQUANT** : un échec interdit toute activation ;
- **ÉLEVÉ** : un échec interdit l'activation du canal concerné ;
- **MOYEN** : un échec doit être corrigé avant la Phase 3.

---

### T-01 — Arrêt d'urgence pendant un lot d'envois
- **Objectif** : après le COMMIT de `arreter_communications`, aucun nouvel envoi n'est validé.
- **Criticité** : BLOQUANT
- **Préconditions** :
  - chaîne 1 → 43 appliquée (gardes de brouillon retirées dans la copie d'essai) ;
  - campagne de C1 à C4 en cours ;
  - interrupteurs allumés **sur la base jetable** ;
  - mode essai, avec la liste d'essai contenant les clients fictifs ;
  - fuseaux connus et fenêtre ouverte (horloge de la base réglée).
- **Données simulées** :
  - 50 envois `attente` ;
  - une copie d'essai de `communication_traiter_un` avec `pg_sleep(0.2)` juste après la réservation (N5).
- **Étapes** :
  1. `call traiter_communications()` dans la connexion W ;
  2. pendant le 3e envoi, A1 appelle `arreter_communications('essai T-01')` dans la connexion A ;
  3. noter l'heure du COMMIT de A ;
  4. laisser W finir.
- **Résultat attendu** :
  - A attend la fin de l'envoi en cours de W (au plus 0,2 s), puis valide ;
  - les envois validés **après** le COMMIT de A : **0** ;
  - W s'arrête au premier `ARRET_URGENCE` ;
  - les envois restants sont toujours en `attente` ;
  - la réponse de A dit `envois_en_cours_attendus = true` et donne le nombre de `traitement`.
- **Preuve** : la table des envois avec `remis_le` comparée à l'heure du COMMIT de A ; le journal `communication.arret_urgence`.
- **Statut** : NON EXÉCUTÉ

### T-01-bis — La procédure valide après chaque envoi, appelée par pg_cron
- **Objectif** : vérifier que pg_cron accepte `call public.traiter_communications()` avec des COMMIT internes, et que pg_net reçoit chaque requête dès son COMMIT.
- **Criticité** : BLOQUANT (sinon, le repli documenté s'applique)
- **Préconditions** : pg_cron et pg_net **réels** dans la base jetable (pas de doublure), pointant vers un faux serveur local.
- **Données simulées** : 5 envois.
- **Étapes** :
  1. activer la tâche **sur la base jetable seulement** ;
  2. attendre un passage.
- **Résultat attendu** :
  - `cron.job_run_details` affiche un succès ;
  - les 5 requêtes apparaissent dans `net.http_request_queue` une par une (horodatages distincts) ;
  - aucune erreur « invalid transaction termination ».
- **Preuve** : `cron.job_run_details` ; les journaux du faux serveur.
- **Statut** : NON EXÉCUTÉ

### T-02 — Arrêt pendant que quatre travailleurs tournent
- **Objectif** : l'arrêt vaut pour **tous** les travailleurs, sans cache.
- **Criticité** : BLOQUANT
- **Préconditions** : celles de T-01, avec 400 envois `attente`.
- **Données simulées** : quatre connexions W1 à W4, chacune appelant en boucle `communication_traiter_un` sur les candidats (même copie d'essai, `pg_sleep(0.05)`).
- **Étapes** :
  1. lancer W1 à W4 ;
  2. après environ 40 envois, A1 appelle `arreter_communications` ;
  3. refaire avec G1 (gérant) ;
  4. refaire en tenant artificiellement N0 partagé plus de 5 s dans W1, pour forcer le **repli**.
- **Résultat attendu** :
  - aucune ligne passe en `traitement` après le COMMIT de l'arrêt ;
  - avec le repli, au plus **une** ligne par travailleur, déjà au-delà du contrôle N5 au moment de l'écriture, et la réponse dit `envois_en_cours_attendus = false` ;
  - E1 (employé) est refusé ;
  - la levée par G1 est refusée ; la levée par A1 sans motif est refusée.
- **Preuve** : la table des envois ; `pg_locks` relevé pendant l'attente (l'arrêt attend, les lecteurs suivants attendent l'arrêt) ; les refus de permission.
- **Statut** : NON EXÉCUTÉ

### T-03 — Annulation d'une campagne pendant un verrouillage
- **Objectif** : aucun interblocage, aucun double envoi.
- **Criticité** : BLOQUANT
- **Préconditions** : campagne en cours, 20 envois.
- **Données simulées** : une copie d'essai de `communication_traiter_un` avec `pg_sleep(1)` **après** N4.
- **Étapes** :
  - **Cas A** : W commence un envoi (il tient N1 → N4), puis A1 appelle `changer_statut_campagne(id, 'annuler', 'essai T-03')`.
  - **Cas B** : A1 ouvre une transaction, appelle `annuler` sans valider, puis W tente un envoi ; A1 valide 1 s après.
  - **Cas C** : 200 répétitions aléatoires des deux, avec les quatre travailleurs, une désinscription et des retours de fournisseur simulés.
- **Résultat attendu** :
  - cas A : l'annulation attend la fin de W ; le message de W est `traitement` ; les autres sont `annule` ;
  - cas B : W attend, puis lit `annulee` et n'envoie rien (ou `lock_not_available` après 2 s, envoi annulé en entier) ;
  - cas C : **0 erreur 40P01** dans les journaux ; aucun envoi `traitement` dont la campagne était `annulee` au moment de sa validation.
- **Preuve** : les journaux PostgreSQL (`deadlock detected` absent) ; `communication_erreurs` ; la table des envois.
- **Statut** : NON EXÉCUTÉ

### T-04 — Quatre travailleurs sur le quota Brevo
- **Objectif** : la somme des réservations ne dépasse jamais le disponible.
- **Criticité** : BLOQUANT (e-mail)
- **Préconditions** :
  - quota vérifié dans la base jetable, réglé pour que `communication_brevo_disponible()` rende **100** ;
  - plafonds du jour et de la campagne très hauts ;
  - `debit_max_minute` à 600.
- **Données simulées** : 1 000 envois e-mail `attente` ; quatre connexions.
- **Étapes** :
  1. W1 à W4 traitent en parallèle jusqu'à épuisement ;
  2. refaire avec un e-mail transactionnel inséré dans `notification_envois` au milieu.
- **Résultat attendu** :
  - exactement **100** envois `traitement` ;
  - les autres restent en `attente` avec le code `QUOTA_BREVO` ;
  - `communication_depenses_jour` (e-mail) augmente de 100 ;
  - au second passage, **99** (le transactionnel est retiré d'abord).
- **Preuve** : les comptes ; l'ordre des `remis_le` ; la valeur de `communication_brevo_disponible()` avant et après.
- **Statut** : NON EXÉCUTÉ

### T-05 — Débit global par minute
- **Objectif** : `debit_max_minute` vaut pour tous les travailleurs réunis.
- **Criticité** : ÉLEVÉ
- **Préconditions** : `debit_max_minute = 20` ; quota haut.
- **Données simulées** : 200 envois ; quatre travailleurs ; horloge figée sur une minute.
- **Étapes** :
  1. lancer les quatre ;
  2. avancer l'horloge d'une minute ;
  3. relancer ;
  4. mesurer aussi la durée d'une réservation (coût de `communication_brevo_disponible` sous N5).
- **Résultat attendu** :
  - 20 envois au plus par minute, toutes connexions confondues ;
  - les suivants sont reportés à la minute suivante (`DEBIT_MINUTE`) ;
  - la durée mesurée est notée (seuil à fixer en Phase 2).
- **Preuve** : `communication_debit_minute` ; les `remis_le` groupés par minute ; les durées.
- **Statut** : NON EXÉCUTÉ

### T-06 — Réponse HTTP 500 après acceptation du message
- **Objectif** : ne jamais renvoyer automatiquement.
- **Criticité** : BLOQUANT
- **Préconditions** : un envoi e-mail parti (`traitement`).
- **Données simulées** :
  - `net._http_response` : `status_code = 500` ;
  - puis un retour Brevo signé `delivered` avec la référence `communication:<id>`.
- **Étapes** :
  1. lecture des réponses ;
  2. cinq passages du travailleur ;
  3. arrivée du retour ;
  4. tentative de relance par G1, puis par A1 sans la case « risque », puis avec.
- **Résultat attendu** :
  - statut `incertain` (`INCERTAIN_HTTP_500`), aucun nouvel envoi après les cinq passages ;
  - le retour le rapproche en `livre` ;
  - relance : G1 refusé ; A1 sans case refusé (`DUPLICATE_RISK`) ; A1 avec case → un **nouvel** envoi, journalisé ;
  - `verifier_issue_http('brevo', 500, 'rejet_temporaire', …)` est refusé (`UNSAFE_RULE`).
- **Preuve** : la table des envois ; `journal_audit` ; le refus.
- **Statut** : NON EXÉCUTÉ

### T-07 — Réponse HTTP 429
- **Objectif** : 429 est incertaine par défaut, et réessayée seulement sur une règle prouvée.
- **Criticité** : ÉLEVÉ
- **Préconditions** : `communication_issues_http` vide.
- **Données simulées** : réponses 429, 400, 401, délai dépassé.
- **Étapes** :
  1. 429 sans règle ;
  2. A1 saisit `verifier_issue_http('brevo', 429, 'rejet_temporaire', '<page officielle, date>')` ;
  3. trois 429 de suite ;
  4. une 400 ;
  5. un délai dépassé.
- **Résultat attendu** :
  - 1 → `incertain` ;
  - 3 → `nouvel_essai` à 2 min, 10 min, 1 h, puis `abandon` ;
  - 4 → `echec` ;
  - 5 → `incertain` ;
  - la saisie sans preuve est refusée ;
  - G1 ne peut pas saisir de règle.
- **Preuve** : la table des envois ; `communication_issues_http` ; `journal_audit`.
- **Statut** : NON EXÉCUTÉ

### T-08 — Suppression d'un client et données résiduelles
- **Objectif** : vérifier l'inventaire de `PHASE_1_3_TECHNICAL_CORRECTIONS.md` §6, table par table.
- **Criticité** : BLOQUANT
- **Préconditions** : C1 avec un consentement confirmé, des envois de chaque statut, des retours des fournisseurs, une fenêtre WhatsApp, un fuseau déclaré, une suppression `desinscription` active, une ligne d'essai.
- **Données simulées** : une capture complète des lignes de C1 avant l'opération.
- **Étapes** :
  1. C1 supprime son compte (`supprimer_mon_compte('SUPPRIMER')`, déclencheur existant) ;
  2. vérifier qu'une demande de purge « personne » est née (demandeur = C1) ;
  3. A1 tente d'approuver et d'exécuter : refus si A1 est aussi le demandeur, sinon approuvée ;
  4. A2 exécute ;
  5. chercher l'identifiant de C1, son e-mail, son numéro et chacune de ses empreintes dans **toutes** les tables du schéma `public` ;
  6. refaire avec une **erreur provoquée** dans le déclencheur (table de demandes renommée dans la copie d'essai).
- **Résultat attendu** :
  - l'identifiant de C1 n'apparaît plus dans aucune table du Centre ;
  - empreintes restantes : **seulement** dans `communication_consentements` (preuve) et `communication_suppressions` (active) ;
  - envois en attente → `supprime` (`EFFACEMENT`) ;
  - le journal des purges compte les lignes **sans aucune donnée** ;
  - étape 6 : la suppression du compte réussit et l'erreur est dans `communication_erreurs` ;
  - **hors Centre** (relevé, non corrigé) : `journal_audit`, `net._http_response` ; leur contenu est noté dans le rapport d'essai.
- **Preuve** : la recherche exhaustive (requête générée sur toutes les colonnes texte, uuid et jsonb) avant et après.
- **Statut** : NON EXÉCUTÉ

### T-09 — Fuseaux américains multiples
- **Objectif** : chaque destinataire est traité selon son heure locale réelle.
- **Criticité** : BLOQUANT
- **Préconditions** :
  - `heure_debut = 9`, `heure_fin = 19`, `marge_fenetre_min = 15` ;
  - `communication_fuseaux_regions` : « New York » → `America/New_York`, saisi avec sa preuve dans la base jetable.
- **Données simulées** : C1, C2, C3, C7 à C12 ; l'horloge fixée au **15/01/2027 à 14 h 00 UTC** (hiver).
- **Étapes** :
  1. `communication_fuseau` et `communication_prochaine_fenetre` pour chacun ;
  2. un passage du travailleur.

| Client | Fuseau attendu | Heure locale | Attendu |
|---|---|---|---|
| C3 New York | America/New_York | 9 h 00 | part |
| C7 Chicago | America/Chicago | 8 h 00 | reporté à 15 h 00 UTC |
| C8 Denver | America/Denver | 7 h 00 | reporté à 16 h 00 UTC |
| C9 Los Angeles | America/Los_Angeles | 6 h 00 | reporté à 17 h 00 UTC |
| C10 Anchorage | America/Anchorage | 5 h 00 | reporté à 18 h 00 UTC |
| C11 Honolulu | America/Honolulu | 4 h 00 | reporté à 19 h 00 UTC |
| C2 Santo Domingo | America/Santo_Domingo | 10 h 00 | part |
| C1 Port-au-Prince | America/Port-au-Prince | 9 h 00 | part |
| C12 Floride, sans fuseau | **null** | — | écarté, `FUSEAU_INCONNU` |

  3. Refaire à **23 h 50 UTC** : New York à 18 h 50 → **reporté au lendemain** (la marge de 15 min dépasse 19 h).
- **Résultat attendu** : le tableau ci-dessus ; aucun client n'est servi à l'heure de New York par défaut.
- **Preuve** : la sortie des deux fonctions ; la table des envois.
- **Statut** : NON EXÉCUTÉ

### T-10 — Changement d'heure saisonnier
- **Objectif** : les règles IANA de la date s'appliquent.
- **Criticité** : ÉLEVÉ
- **Données simulées** :
  - horloge au **15/07/2027 à 13 h 00 UTC** (été) : New York 9 h (heure d'été), Chicago 8 h, Honolulu 3 h ;
  - horloge au soir du **13/03/2027** et au matin du **14/03/2027** (changement d'heure aux USA, dates **à reconfirmer** sur la base IANA du serveur au moment de l'essai) ;
  - même chose pour Haïti.
- **Étapes** : calculer la prochaine fenêtre la veille au soir du changement.
- **Résultat attendu** :
  - en été, New York part à 13 h 00 UTC et non à 14 h 00 ;
  - la veille du changement, la prochaine fenêtre tombe à 9 h **locale** le lendemain, quelle que soit l'heure UTC ;
  - Honolulu ne change pas.
- **Preuve** : la sortie de `communication_prochaine_fenetre` ; la version de tzdata du serveur notée.
- **Statut** : NON EXÉCUTÉ

### T-11 — Webhook retardé
- **Objectif** : la fenêtre de 24 h part de l'heure réelle du message.
- **Criticité** : ÉLEVÉ
- **Données simulées** :
  - message entrant de C1 avec `survenu_le` à **10 h 00**, reçu à **18 h 00** ;
  - puis un message `survenu_le` à 9 h 00 reçu à 18 h 05 ;
  - puis un message sans `survenu_le` ;
  - puis un STOP sans `survenu_le`.
- **Étapes** : appeler `communication_recevoir_evenement` avec la signature d'essai, **en tant que** `communication_webhook`.
- **Résultat attendu** :
  - `dernier_entrant` = 10 h 00 (pas 18 h 00), donc la fenêtre se ferme le lendemain à 10 h 00 ;
  - après le message de 9 h : toujours 10 h 00 ;
  - sans horodatage : fenêtre inchangée ;
  - le STOP s'applique quand même (suppression et retrait) ;
  - `survenu_le` illisible (`"abc"`) → `{ok:false, format:true}`, sans recopie de la valeur ;
  - `survenu_le` à plus de 5 min dans le futur → refusé.
- **Preuve** : `communication_fenetres_whatsapp` ; les réponses de la fonction.
- **Statut** : NON EXÉCUTÉ

### T-12 — Webhook rejoué
- **Objectif** : un événement rejoué ne refait rien.
- **Criticité** : ÉLEVÉ
- **Données simulées** : le même `delivered`, le même STOP et le même « OUI 1234 », chacun envoyé deux fois ; puis un `delivered` arrivé après un `read`.
- **Résultat attendu** :
  - la deuxième réponse est `{ok:true, rejeu:true}` ;
  - une seule ligne de retour par événement ;
  - un seul retrait par STOP ;
  - la confirmation ne crée qu'une ligne « confirme » ;
  - le `delivered` tardif ne fait pas reculer `lu`.
- **Preuve** : les comptes de `communication_evenements_fournisseur` et de `communication_consentements`.
- **Statut** : NON EXÉCUTÉ

### T-13 — Appel direct de la fonction SQL par un utilisateur non autorisé
- **Objectif** : vérifier que seuls le rôle prévu et la signature ouvrent la porte, et que le débit est borné.
- **Criticité** : BLOQUANT
- **Étapes** :
  1. appeler `communication_recevoir_evenement` par l'API avec la clé publique (`anon`), avec un jeton client, puis avec un jeton d'administrateur ;
  2. appeler `communication_traiter_un`, `communication_reserver`, `traiter_communications` et les fonctions de purge internes avec chaque rôle ;
  3. en tant que `communication_webhook`, envoyer 700 appels mal signés en une minute (avec `webhook_max_minute = 600`).
- **Résultat attendu** :
  - 1 et 2 → `permission denied for function`, **avant** l'entrée dans la fonction ;
  - 3 → les 600 premiers refusés sans écriture métier ; les suivants → `sature` ;
  - aucun texte du coffre dans aucune réponse ni aucun journal.
- **Preuve** : les codes d'erreur ; `communication_webhook_debit` ; les journaux.
- **Statut** : NON EXÉCUTÉ

### T-14 — Tentative d'exécution d'un brouillon non approuvé
- **Objectif** : aucun client courant ne peut créer un objet à partir d'un brouillon.
- **Criticité** : BLOQUANT
- **Préconditions** : une base jetable **vide** ; un instantané du catalogue (`pg_class`, `pg_proc`, `pg_trigger`, `pg_roles`, `cron.job`, `pg_namespace`).
- **Étapes** : passer **chacun** des fichiers 40 à 43, **tels qu'ils sont dans le dépôt**, avec :
  1. `psql -f` sans `ON_ERROR_STOP` (autocommit) ;
  2. `psql -v ON_ERROR_STOP=1 -f` ;
  3. `psql --single-transaction -f` ;
  4. une requête unique à plusieurs instructions (`psycopg`, comme le SQL Editor) ;
  5. un découpeur naïf sur « ; » qui continue après une erreur (pour **mesurer** la limite connue).
- **Résultat attendu** :
  - 1 à 4 → catalogue **identique** à l'instantané, et le message `BROUILLON NON APPROUVÉ` est affiché ;
  - 5 → résultat **consigné** tel quel (limite documentée) ; en cas d'objets créés, ils sont listés dans le rapport.
- **Preuve** : la différence de catalogue avant et après chaque client (vide pour 1 à 4).
- **Statut** : NON EXÉCUTÉ

### T-15 — Permissions et RLS
- **Objectif** : chaque rôle n'atteint que ce qui lui revient ; les cinq copies des permissions sont identiques.
- **Criticité** : BLOQUANT
- **Étapes** :
  1. pour **chacune** des 94 fonctions et procédures et **chacun** des rôles (visiteur, C1, E1, G1, A1, A1 sans double authentification aal2, `service_role`, `communication_webhook`), appeler et noter le résultat ;
  2. `select` direct sur les 27 tables avec `anon` et `authenticated` ;
  3. comparer les cinq copies de `permissions_du_role` (`supabase.sql`, `supabase-naissance.sql`, `supabase-suivi-externe.sql`, brouillon 40, `api.js`) ;
  4. `controle-securite.sql`, section 6 : seules `confirmer_consentement_communication` et `desinscrire_communication` sont ouvertes aux visiteurs.
- **Résultat attendu** :
  - la matrice de `PHASE_1_3_SECURITY_REVIEW.md` §2.4, à l'identique ;
  - E1 refusé partout ;
  - G1 refusé sur `approve` et `manage` ;
  - aucune lecture directe de table ;
  - les cinq copies sont égales.
- **Preuve** : la matrice produite par le banc, comparée à celle du document.
- **Statut** : NON EXÉCUTÉ

### T-16 — Non-régression des notifications transactionnelles
- **Objectif** : rien ne change pour le transactionnel.
- **Criticité** : BLOQUANT
- **Étapes** :
  1. `essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py`, `essai-courriel-colis.py`, `essai-courriel-pied.py`, `essai-mobile.py`, avant et après l'ajout de 40 à 43 ;
  2. un colis reçu, une facture payée et un compte créé **pendant** que les quatre travailleurs du Centre tournent ;
  3. 60 e-mails transactionnels en attente (> `attente_transactionnel_max`).
- **Résultat attendu** :
  - 1 → les mêmes résultats, au chiffre près ;
  - 2 → les notifications partent comme avant, sans attente sur un verrou du Centre ;
  - 3 → `communication_candidats` ne rend rien tant que la file transactionnelle n'est pas revenue sous le seuil ;
  - `mon_resume` et `messages_recents` gardent leur forme exacte ; aucune ligne du Centre dans `notifications` ni dans `notification_envois`.
- **Preuve** : la comparaison des sorties des bancs ; `pg_locks` pendant l'étape 2.
- **Statut** : NON EXÉCUTÉ

### T-17 — Désinscription et priorité du retrait
- **Objectif** : un retrait gagne toujours, même en même temps qu'un envoi.
- **Criticité** : BLOQUANT
- **Étapes** :
  1. C1 retire son consentement pendant qu'un travailleur tient N2 pour C1 (pause d'essai après N2) ;
  2. inversement, le retrait commence et le travailleur arrive ;
  3. lien de désinscription d'un vieil envoi (90 jours), puis du même lien une seconde fois ;
  4. STOP WhatsApp **et** confirmation « OUI » dans la même seconde ;
  5. lien d'un envoi anonymisé par une purge.
- **Résultat attendu** :
  - 1 → le retrait attend la fin de cet envoi (au plus un message « avant » le retrait), puis plus aucun envoi ;
  - 2 → le travailleur lit le retrait et écarte l'envoi (`SANS_CONSENTEMENT_CONFIRME`) ;
  - 3 → efficace les deux fois (idempotent) ;
  - 4 → l'état final est « retiré » (à heure égale, le retrait passe devant) ;
  - 5 → `{ok:true}`, sans rien révéler.
- **Preuve** : `communication_consentements` (ordre, `cree_le`) ; la table des envois.
- **Statut** : NON EXÉCUTÉ

### T-18 — Changement de coordonnées du client
- **Objectif** : un nouveau contact n'hérite jamais d'un consentement ; un fuseau déclaré tombe avec la région.
- **Criticité** : BLOQUANT
- **Étapes** :
  1. C1 confirmé par e-mail change d'adresse **entre** le gel de l'audience et l'envoi ;
  2. C2 change de numéro ;
  3. C7 (fuseau déclaré) déménage de l'Illinois en Floride ;
  4. un changement de profil fait en même temps qu'un envoi à ce client ;
  5. une erreur provoquée dans le déclencheur.
- **Résultat attendu** :
  - 1 → l'envoi est `supprime` (`CONTACT_CHANGE`), avec une ligne « invalide » portant l'**ancienne** empreinte, et rien n'est envoyé à la nouvelle adresse ;
  - 2 → idem pour WhatsApp ; l'e-mail n'est pas touché ;
  - 3 → le fuseau déclaré est effacé, donc `FUSEAU_INCONNU` ;
  - 4 → aucun interblocage (le déclencheur ne prend que N3) ;
  - 5 → le profil est enregistré et l'erreur est gardée.
- **Preuve** : `communication_consentements`, `communication_fuseaux_clients`, la table des envois, `communication_erreurs`.
- **Statut** : NON EXÉCUTÉ

### T-19 — Purge à l'échéance (complément)
- **Objectif** : les catégories respectent les durées et la règle « suppression active jamais effacée ».
- **Criticité** : ÉLEVÉ
- **Étapes** :
  1. durées **null** → toute purge par échéance est refusée (`RETENTION_BLOCKED`) ;
  2. durées d'essai saisies **dans la base jetable** avec une référence fictive marquée « ESSAI » → purger `envois`, `destinataires`, `empreintes`.
- **Résultat attendu** :
  - audiences anonymisées même si elles ont des envois ;
  - empreintes effacées sur les seuls consentements anonymisés ;
  - suppressions levées effacées, suppressions actives gardées ;
  - journal des purges sans données.
- **Preuve** : les comptes avant et après ; `communication_journal_purges`.
- **Statut** : NON EXÉCUTÉ

### T-20 — Ordre des verrous des fonctions de consentement (complément)
- **Objectif** : aucun interblocage entre « demander » et « confirmer » pour le même client.
- **Criticité** : MOYEN
- **Étapes** : 500 paires concurrentes `demander_consentement_communication` / `confirmer_consentement_communication` (deux onglets du même client), plus des confirmations WhatsApp.
- **Résultat attendu** : 0 erreur 40P01 ; l'état final est toujours cohérent (au plus une demande active).
- **Preuve** : les journaux PostgreSQL ; `communication_confirmations`.
- **Statut** : NON EXÉCUTÉ

---

## Correspondance avec les groupes de la Phase 1.2

| Groupe 1.2 | Essais 1.3 qui le précisent |
|---|---|
| 1 (chaîne et garde) | T-14 ; contrôle de 40 : `tables 18` (au lieu de 14) |
| 2, 3 (permissions) | T-13, T-15 |
| 4 (consentement, contact) | T-17, T-18, T-20 |
| 5 (purge) | T-08, T-19 |
| 8 (retours, rejeu, STOP) | T-11, T-12, T-13 |
| 10 (concurrence) | T-01 à T-05 |
| 11 (quotas Brevo) | T-04 |
| 13 (incertains) | T-06, T-07 |
| 15 (non-régression) | T-16 |

**Rappel** : aucun de ces essais n'a été exécuté. Aucun ne sera marqué réussi sans exécution réelle et sans la preuve indiquée.
