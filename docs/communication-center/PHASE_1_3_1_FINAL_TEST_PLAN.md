# Centre de communication — Phase 1.3.1 (clôture) : plan d'essais final

**Code visé** : commit `0693d5e` (brouillons 40 à 43, version 1.3.1).

> **Aucun essai n'a été exécuté.** Ce document est un plan, pas un compte rendu.
> Chaque essai est **NON EXÉCUTÉ**. Plusieurs décrivent un « attendu aujourd'hui » qui est un **défaut connu** (F-K10, F-W01, F-C06) : ils ne passeront qu'après la correction proposée.
> Il ne pourra l'être qu'après une autorisation **écrite** de la direction, et **sur une base jetable seulement** :
> - jamais sur la production ;
> - jamais avec une vraie clé Brevo ou Meta.
>
> Les appels sortants sont détournés vers un faux serveur local (`http://127.0.0.1:<port>`), qui note ce qu'il reçoit.

Ce plan **complète** `PHASE_1_3_1_TEST_PLAN.md` (40 essais, tous non exécutés). Il ne le remplace pas. Il ajoute :
- les essais qui éprouvent les **hypothèses de PostgreSQL et de pg_net** dont dépend la preuve de l'arrêt (`PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md`, §5, H1 à H5) ;
- les essais de **migration** ;
- les essais de **séparation** avec le transactionnel ;
- les essais liés à la **base clients actuelle** (71 clients, voir `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`, §8).

---

## 0. Banc commun (préparation, pour tous les essais)

| Élément | Valeur |
|---|---|
| Base | PostgreSQL 17 jetable, avec les extensions de la production (`pg_net` **0.20.4**, `pg_cron`, `pgcrypto`, `supabase_vault`) |
| Habillage | Rôles `anon`, `authenticated`, `service_role`, doublure d'`auth` (comme `essai-services.py`, `DOUBLURES`) |
| Chaîne | `outils/migrations.txt` en entier, **puis** 40 → 43, **sans** leur garde, dans **une seule transaction** (`psql --single-transaction -v ON_ERROR_STOP=1`) |
| Données | 6 comptes fictifs (2 clients HT, 1 DO, 1 US, 1 sans pays, 1 administrateur) ; e-mails `@example.test` ; numéros fictifs `+509 0000 00xx` |
| Réglages du coffre | Clés factices ; adresse des fournisseurs remplacée par le faux serveur (`communication_*_url`) |
| Faux serveur | Note l'heure d'arrivée de chaque requête ; peut **retarder** sa réponse (0 à 90 s) ou **refuser** la connexion |
| Sessions | Au moins 3 connexions `psql` ouvertes en même temps (A, B, C) pour la concurrence |
| Mesure du temps | `clock_timestamp()` côté base ; heure d'arrivée côté faux serveur |

**Règle de lecture** : un essai est **PASS** seulement si **tous** ses critères le sont. Un résultat douteux compte comme **FAIL**. Il doit alors être noté, puis expliqué.

---

## 1. Arrêt d'urgence : hypothèses de PostgreSQL et de pg_net (BLOQUANTS)

### F-K01 — Le verrou exclusif N0 attend la fin de toute porte ouverte (H2)

| | |
|---|---|
| Scénario | Une transaction tient N0 partagé, par la porte `communication_autoriser_sortie`. L'arrêt demande N0 exclusif. |
| Données | Canal e-mail actif, aucune campagne |
| Étapes | 1. Session A : `begin; select public.communication_autoriser_sortie('envoi','email');` (ne pas valider).<br>2. Session B (administrateur) : `select public.arreter_communications('essai F-K01');`.<br>3. Attendre 4 s.<br>4. Lire la réponse de B et la ligne `communication_arret`. |
| Attendu | B répond `STOP_PENDING`, motif `VERROU_NON_OBTENU`, après 3 s environ. `communication_arret.etat = 'arret_demande'`. `autorisations_closes_le` reste vide. |
| PASS si | La réponse n'est **jamais** `STOP_CONFIRMED` tant que A est ouverte. |
| FAIL si | `STOP_CONFIRMED`, ou attente de plus de 6 s, ou aucune demande écrite |
| Statut | **NON EXÉCUTÉ** |

### F-K02 — Une porte ouverte après la fermeture voit l'arrêt (H2, H3)

| | |
|---|---|
| Scénario | L'arrêt obtient N0 exclusif pendant qu'une porte attend N0 partagé. |
| Étapes | 1. Session B : `begin; select public.arreter_communications('F-K02');`. Elle répond `STOP_CONFIRMED` mais n'est **pas** validée : on la tient ouverte par `begin` explicite.<br>2. Session A : `select public.communication_autoriser_sortie('envoi','email');`. A attend.<br>3. Session B : `commit;`.<br>4. Lire la réponse de A. |
| Attendu | A obtient N0 après le COMMIT de B, lit `arret_demande` ou `arret_confirme`, puis refuse (erreur `COMMUNICATIONS_ARRETEES` ou équivalent). `goship.sortie_autorisee` reste vide dans A. |
| Variante | Recommencer avec une **sous-transaction** (`savepoint`) qui échoue dans A après avoir pris N0 partagé. On vérifie que N0 est bien relâché avec la sous-transaction (`pg_locks`). |
| PASS si | A ne marque **jamais** la sortie après la validation de B. |
| FAIL si | A est autorisée, ou A reste bloquée plus de 5 s après le COMMIT de B |
| Statut | **NON EXÉCUTÉ** |

### F-K03 — Aucune attente après N0a (H1, H5)

| | |
|---|---|
| Scénario | Le constat d'arrêt ne doit jamais attendre une autre transaction. |
| Données | 50 envois `en_cours` avec `requete` posée et `sortie_file_vue_le` vide ; 2 lectures de modèle Meta dans le même état |
| Étapes | 1. Session A : `begin; select * from communication_envois where id in (1..25) for update;` (ne pas valider).<br>2. Session C : `begin; select * from communication_modeles_meta for update;` (ne pas valider).<br>3. Session B : `set lock_timeout = 0; select public.arreter_communications('F-K03');`.<br>4. Pendant ce temps, observer `pg_locks` et `pg_stat_activity.wait_event` de B toutes les 100 ms. |
| Attendu | B ne passe **jamais** en attente d'un verrou de ligne (`wait_event_type = 'Lock'`, `transactionid` ou `tuple`). Les 25 envois verrouillés par A ne sont pas observés. Ils comptent comme « en transmission ». B répond `STOP_PENDING`, motif `TRANSMISSIONS_EN_COURS`, en moins de 1 s après N0. |
| Complément H1 | Pendant l'essai, une session D écrit en boucle dans `journal_audit` (`auditer`). B ne doit pas attendre non plus. |
| PASS si | Aucune attente de verrou après N0a ; réponse en moins de 1 s après N0 |
| FAIL si | Toute attente, interblocage (`deadlock detected`), ou `STOP_CONFIRMED` |
| Statut | **NON EXÉCUTÉ** |

### F-K04 — Ordre des verrous et interblocage avec le travailleur

| | |
|---|---|
| Scénario | Quatre travailleurs traitent un lot pendant que l'arrêt est demandé 20 fois de suite. Des webhooks arrivent en même temps. |
| Données | 1 campagne de 200 destinataires fictifs ; faux serveur avec réponse en 200 ms ; webhooks rejoués |
| Étapes | Lancer 4 `call traiter_communications()` en parallèle. En même temps, appeler `arreter_communications`, puis `lever_arret_communications`, en boucle (20 fois). Envoyer 100 webhooks. |
| Attendu | Aucun `deadlock detected` dans le journal du serveur. Chaque réponse d'arrêt vaut `STOP_CONFIRMED`, `STOP_PENDING` ou `STOP_NOT_CONFIRMED`, jamais `ok`. |
| PASS si | 0 interblocage ; 0 requête reçue par le faux serveur **après** l'heure `confirme_le` d'un arrêt confirmé et avant la levée suivante |
| FAIL si | Un seul interblocage, ou une seule requête dans une fenêtre d'arrêt confirmé |
| Statut | **NON EXÉCUTÉ** |

### F-K05 — pg_net : moment où la requête quitte la file, et délai (H4)

| | |
|---|---|
| Scénario | Mesurer le comportement réel de pg_net 0.20.4, dont dépend `communication_en_transmission`. |
| Étapes | 1. `select net.http_post('http://127.0.0.1:<port>/lent', …, timeout_milliseconds := 5000);` puis `commit`.<br>2. Le faux serveur répond après 90 s.<br>3. Toutes les 100 ms, lire `net.http_request_queue` et `net._http_response`.<br>4. Noter l'heure de départ de la file, l'heure d'arrivée au serveur et l'heure de la réponse ou de l'erreur. |
| Attendu | La requête quitte la file **avant** d'arriver au serveur. L'erreur de délai est écrite environ 5 s après la sortie de la file. Il n'y a ni réessai ni seconde arrivée. |
| Variantes | (a) Une transaction **annulée** après `net.http_post` : rien n'arrive au serveur. (b) Le serveur refuse la connexion. (c) On redémarre le travailleur pg_net pendant un appel : noter ce qui arrive. |
| PASS si | Les quatre points de H4 sont vérifiés : sortie avant l'appel ; envoi après COMMIT seulement ; délai compté dès l'appel ; pas de réessai |
| FAIL si | L'un des quatre est faux. Dans ce cas, **la propriété (b) de l'arrêt ne tient plus** : il faut revoir la fenêtre de 120 s. |
| Statut | **NON EXÉCUTÉ** |

### F-K06 — Aucune transmission après `STOP_CONFIRMED` (propriété b)

| | |
|---|---|
| Scénario | Arrêt pendant que des requêtes sont en file, puis en vol. |
| Étapes | 1. Bloquer le travailleur pg_net (pause du processus, ou file pleine).<br>2. Laisser 10 envois être validés : ils sont en file.<br>3. `arreter_communications` : attendu `STOP_PENDING`, motif `TRANSMISSIONS_EN_COURS`.<br>4. Relâcher pg_net. Le serveur répond en 30 s.<br>5. Rappeler `confirmer_arret_communications` toutes les 10 s. |
| Attendu | `STOP_CONFIRMED` seulement quand toutes les requêtes ont une réponse, **ou** sont sorties de la file depuis plus de 120 s. Le serveur ne reçoit **rien** après `confirme_le`. |
| PASS si | Heure d'arrivée de chaque requête au serveur < `confirme_le` |
| FAIL si | Une seule arrivée après `confirme_le` |
| Statut | **NON EXÉCUTÉ** |

### F-K07 — Durée de l'arrêt sous le délai d'exécution (S-03)

| | |
|---|---|
| Scénario | L'arrêt appelé par l'interface (rôle `authenticated`, `statement_timeout` de la production, 8 s rapportés) |
| Données | 10 000 envois dans `communication_envois`, dont 500 avec `requete` posée ; `net.http_request_queue` de 1 000 lignes |
| Étapes | Appeler `arreter_communications` par l'API REST (`/rest/v1/rpc/…`) avec un jeton d'administrateur fictif, dans 3 situations : rien en cours ; une porte tenue (attente de 3 s) ; ligne d'arrêt tenue (attente de 2 s). |
| Attendu | Réponse en moins de 6 s dans tous les cas. Jamais `canceling statement due to statement timeout`. |
| PASS si | Durée maximale < 6 s, et une demande d'arrêt écrite dans chaque cas |
| FAIL si | Délai d'exécution dépassé. La demande d'arrêt elle-même serait alors perdue (S-03). |
| Statut | **NON EXÉCUTÉ** |

### F-K08 — Un retour d'arrêt ne s'écrit pas sans fermeture (contrainte)

| | |
|---|---|
| Étapes | En propriétaire de la base : `update communication_arret set etat = 'arret_confirme', autorisations_closes_le = null;` |
| Attendu | Refus par la contrainte de la table |
| PASS si | Erreur `check_violation` |
| FAIL si | La ligne est écrite |
| Statut | **NON EXÉCUTÉ** |

### F-K09 — pg_net : délai entre la sortie de file visible et le début du transfert (H4′, revue finale)

| | |
|---|---|
| Scénario | La fenêtre de 120 s suppose que le transfert **commence** moins de 60 s après que la sortie de la requête de la file est devenue visible |
| Données | Lot de 300 requêtes ; faux serveur lent (réponse en 50 s) |
| Étapes | Déposer le lot. Lancer `communication_observer_sorties` toutes les secondes. Noter `sortie_file_vue_le` de chaque envoi et l'heure d'arrivée au faux serveur. |
| Attendu | Pour chaque requête : arrivée au serveur − `sortie_file_vue_le` < 60 s |
| PASS si | Écart maximal < 60 s, avec une marge notée |
| FAIL si | Un écart ≥ 60 s. La propriété (b) de l'arrêt tombe : la fenêtre est à revoir. |
| Statut | **NON EXÉCUTÉ** |

### F-K10 — La demande d'arrêt reste écrite si le constat échoue (RF-01)

| | |
|---|---|
| Scénario | Une erreur ou une annulation pendant `communication_conclure_arret` |
| Étapes | Trois cas :<br>(a) `pg_cancel_backend` sur la session d'arrêt pendant le constat (10 000 lignes récentes dans `net._http_response`) ;<br>(b) `statement_timeout = '1s'` ;<br>(c) une migration rejouée qui tient la ligne d'arrêt. |
| Attendu **aujourd'hui** (brouillon 0693d5e) | La demande est annulée : `communication_arret.etat` reste `actif`. **C'est le défaut RF-01.** |
| Attendu **après correction** (P-07) | `etat = 'arret_demande'` dans les trois cas ; réponse `STOP_PENDING` (`CONSTAT_IMPOSSIBLE`), ou erreur, mais la demande est **validée** ; la porte refuse ensuite toute sortie |
| PASS si | Après correction : la demande est écrite dans les trois cas |
| FAIL si | `etat = 'actif'` après un seul des trois cas |
| Statut | **NON EXÉCUTÉ** |

---

## 2. Migrations (BLOQUANTS)

### F-M01 — Garde des quatre brouillons

| | |
|---|---|
| Étapes | Exécuter chaque fichier **tel quel** de quatre façons : SQL Editor (une transaction), `psql -v ON_ERROR_STOP=1`, `psql` sans arrêt sur erreur, découpeur naïf au point-virgule (script du banc, T-14C) |
| Attendu | Aucun objet `communication_*` créé, `permissions_du_role` inchangée, aucun rôle et aucune tâche pg_cron ajoutés. Pour le découpeur naïf : session fermée par la couche 4. |
| PASS si | `select count(*) from pg_class where relname like 'communication%'` = 0 après chaque mode |
| FAIL si | Un seul objet créé |
| Statut | **NON EXÉCUTÉ** |

### F-M02 — Chaîne 40 → 43 dans une seule transaction, puis rejouée

| | |
|---|---|
| Étapes | 1. Retirer la garde (copie de travail, hors dépôt).<br>2. Appliquer 40 → 43 en une seule transaction.<br>3. Rejouer les quatre fichiers une seconde fois.<br>4. Rejouer `supabase-double-auth.sql` et `supabase-prealertes-equipe.sql` après. |
| Attendu | Seconde application sans erreur ni changement (rejouable). `permissions_du_role` contient les 7 + 5 permissions du Centre. Rejouer une migration plus ancienne qui redéfinit `permissions_du_role` les **retire** : ce point est à documenter, car c'est une condition de l'ordre des migrations. |
| PASS si | Tout passe, et l'inventaire (28 tables, 105 fonctions, 25 index, 7 déclencheurs) correspond |
| FAIL si | Erreur, ou inventaire différent |
| Statut | **NON EXÉCUTÉ** |

### F-M03 — Retour arrière

| | |
|---|---|
| Étapes | Appliquer le script de retrait (à écrire en Phase 2), puis relancer `essai-services.py`, `essai-notifications.py` et `essai-permissions.py` |
| Attendu | `permissions_du_role` identique à avant 40 ; déclencheur sur `clients` absent ; tâche pg_cron absente ; rôle `communication_webhook` sans droit (S-04) |
| PASS si | Les trois bancs passent comme avant 40 |
| FAIL si | Une différence |
| Statut | **NON EXÉCUTÉ** |

---

## 3. Séparation avec le transactionnel (BLOQUANTS)

### F-T01 — Non-régression des notifications existantes

| | |
|---|---|
| Étapes | Avec 40 → 43 appliquées et le Centre **arrêté**, puis **actif en mode essai** : relancer `essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py` et `essai-alertes-suivi.py` |
| Attendu | Résultats identiques à la chaîne sans 40 → 43. Les e-mails de facture, de paiement et de retard restent **coupés** (`notification_regles`). |
| PASS si | 0 différence |
| FAIL si | Une seule différence |
| Statut | **NON EXÉCUTÉ** |

### F-T02 — Le Centre ne lit aucune clé du transactionnel

| | |
|---|---|
| Étapes | Retirer du coffre toutes les clés `communication_*` et laisser celles du transactionnel (Brevo, WhatsApp). Tenter un envoi d'essai. |
| Attendu | `NON_CONFIGURE`. Le faux serveur ne reçoit rien. |
| PASS si | Aucune requête sortante |
| FAIL si | Une requête part avec une clé du transactionnel |
| Statut | **NON EXÉCUTÉ** |

---

## 3 bis. Retours des fournisseurs (BLOQUANTS, ajoutés après la revue finale)

### F-W01 — Deux retours pour le même envoi, en même temps (RF-02)

| | |
|---|---|
| Données | 1 envoi WhatsApp d'une campagne, statut `traitement` ; deux événements signés `sent` et `delivered`, chacun dans un éclat différent du compteur de débit |
| Étapes | Deux sessions reçoivent les événements concurrents ; vérifier d'abord que chaque RPC ne fait que les enregistrer et renvoie `traite = false`, puis lancer deux travailleurs. Variantes : traitement et purge de la personne ; traitement et relance ; traitement et annulation de la campagne. |
| Attendu dans la version **antérieure à P-08** | `deadlock detected` (40P01) dans au moins un cas. **C'est le défaut RF-02 rapporté à l'époque.** |
| Attendu **après correction** (P-08) | Aucun 40P01 ; les deux événements enregistrés avant traitement ; le travailleur les traite ensuite sans effet double ; statut final `livre` |
| PASS si | 0 interblocage sur 1 000 répétitions |
| FAIL si | Un seul 40P01, ou un événement perdu |
| Statut | **NON EXÉCUTÉ** |

### F-W02 — STOP entrant et code 131050 pour le même numéro (RF-05)

| | |
|---|---|
| Étapes | Session A reçoit le message entrant « STOP » du numéro H ; session B reçoit le retour d'échec 131050 pour un envoi vers H. Vérifier les deux réceptions, puis lancer les traitements en concurrence. |
| Attendu après correction | Les deux RPC accusent seulement la réception ; aucun 40P01 pendant les traitements ; une seule suppression active pour H ; consentements retirés |
| PASS si | 0 interblocage sur 1 000 répétitions |
| FAIL si | Un 40P01 |
| Statut | **NON EXÉCUTÉ** |

### F-W03 — Reconnaissance du STOP (RF-03)

| | |
|---|---|
| Données | `STOP` seul avec casse, espaces extérieurs et ponctuation variables ; phrases déjà citées dans les documents (« Stop please », « stop les messages », « Arrêter les promotions », « Kanpe voye mesaj », « BAJA por favor », « Non merci », « Stopper ») ; message ordinaire contenant STOP ; code exact à six chiffres ; champ bouton Meta dont la forme réelle reste à relever |
| Attendu **après correction** (P-09 préparatoire) | Seul `STOP` entier normalisé déclenche le retrait. Un code valide est `confirmation`. Les variantes non validées, messages contextuels et boutons non vérifiés sont `ambigu`, sans mutation de consentement. La liste linguistique nécessite toujours une validation juridique. |
| PASS si | `STOP` exact et code sont distincts ; aucun faux retrait sur phrase contextuelle, variante non validée, bouton inconnu ou plainte seule |
| FAIL si | Un message ambigu ou une plainte seule écrit un retrait, ou un code est classé STOP |
| Statut | **NON EXÉCUTÉ** |

### Scénarios P-09 complémentaires à intégrer à une prochaine révision

Ces scénarios sont des critères préparatoires, hors du total historique de 78 essais. Ils n'ont pas
été exécutés et exigeront une autorisation de vérification distincte ainsi qu'une base jetable :

| Scénario | Résultat attendu |
|---|---|
| Même événement STOP reçu plusieurs fois avec le même identifiant fournisseur | Rejeu sans deuxième effet métier |
| Deux travailleurs prennent simultanément le même événement | Un seul traitement ; l'autre ne modifie pas le consentement |
| Échec après l'écriture de suppression/retrait, avant le statut final | Transaction entière annulée ; événement récupérable et non marqué `traite` |
| Cinq échecs de traitement | État `echec`, alerte visible, reprise seulement après contrôle administrateur |
| Callback de plainte puis callback unsubscribe | La plainte conserve seulement la suppression ; le callback unsubscribe ajoute une seule action `retire` explicite |
| STOP reçu pour un numéro associé à plusieurs comptes | Vérifier la portée avec une décision métier écrite préalable ; ne pas déduire une règle de ce plan |

### Intégration transversale P-07/P-08/P-09 — scénarios futurs hors des 78 essais

Ces scénarios restent **NON EXÉCUTÉS** et exigent une autorisation distincte pour une base jetable.
Ils ne modifient pas le total historique de 78 essais :

| Scénario | Résultat attendu |
|---|---|
| Kill Switch demandé puis confirmé ; réception et traitement d'un STOP | Réception durable et retrait traitable ; aucune transmission sortante n'est autorisée |
| Kill Switch actif ; callback de désinscription explicite | Suppression/retrait traités par la file, sans appel fournisseur sortant |
| Worker interrompu avant ou pendant le traitement | Aucun événement n'est déclaré traité sans commit ; le statut d'événement en cours reste explicitement non mesuré par le schéma actuel |
| Rejeu, deux workers, échec puis reprise manuelle | Un seul effet métier validé ; historique des tentatives conservé même après remise à zéro du compteur de cycle ; tentative bornée ; reprise auditée sans doublon |
| `sante_communications` face à événements reçus, en attente, échec et traités | Agrégats identiques aux lignes fictives ; dernier run reflète `cron.job_run_details`; champs absents restent `null` |
| Liste des échecs à reprendre | IDs techniques, priorité, compteurs et dates concordent ; la limite de liste est signalée ; aucun contenu ou empreinte n'est exposé |
| Revue de confidentialité de la réponse santé | Aucun numéro complet, ID client/acteur, contenu entrant, code de confirmation, motif libre, secret ou `return_message` n'est exposé |
| Worker non activé | Le statut de planification reste inactif et aucune activité n'est prétendue si aucun run n'est enregistré |
| Échec d'un STOP ou d'une désinscription prioritaire avant l'envoi | **Décision CEO préalable requise** sur la portée du blocage (contact, canal ou sorties) ; ensuite vérifier qu'aucun envoi ne franchit la politique retenue pendant que le retrait reste non traité |
| pg_cron absent | La fonction santé reste lisible et marque l'état du worker non mesurable, sans erreur de relation manquante |

---

## 4. Base clients actuelle et audience (BLOQUANTS avant toute campagne)

Ces essais rejouent, **sur des données fictives**, la forme réelle de la base relevée le 20/11/2026 (`PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`, §8) : 71 clients actifs, 5 sans pays, 10 aux États-Unis, 2 numéros partagés chacun par deux comptes.

### F-C01 — Un client existant ou nouveau n'est jamais dans l'audience sans consentement confirmé

| | |
|---|---|
| Données | 71 clients fictifs, sans aucune ligne dans `communication_consentements` |
| Étapes | Créer une campagne e-mail, puis une campagne WhatsApp, en mode réel ; calculer l'audience |
| Attendu | 0 destinataire retenu ; 71 exclus, chacun avec sa raison (`SANS_CONSENTEMENT_CONFIRME`, ou une raison qui la précède : `SANS_DESTINATAIRE`, `SUPPRIME`) |
| PASS si | 0 retenu |
| FAIL si | Au moins 1 retenu |
| Statut | **NON EXÉCUTÉ** |

### F-C02 — Une inscription nouvelle ne crée aucun consentement

| | |
|---|---|
| Étapes | Créer un compte par l'inscription du site, puis par « Continuer avec Google » ; compléter le profil (nom, téléphone, pays, ville, langue) |
| Attendu | Aucune ligne dans `communication_consentements`. `communication_etat_consentement` vaut `aucun` pour les deux canaux. |
| PASS si | 0 ligne |
| FAIL si | Une ligne, quelle qu'elle soit |
| Statut | **NON EXÉCUTÉ** |

### F-C03 — Double consentement : la demande seule ne suffit pas

| | |
|---|---|
| Étapes | Le client demande (`demander_consentement_communication`) ; on calcule l'audience ; il confirme par le lien ; on recalcule |
| Attendu | Exclu après la demande (`SANS_CONSENTEMENT_CONFIRME`) ; retenu seulement après la confirmation, et seulement si le fuseau est connu |
| PASS si | Les deux états sont exacts |
| FAIL si | Retenu après la demande seule |
| Statut | **NON EXÉCUTÉ** |

### F-C04 — Changement de contact, de pays ou de région après un consentement

| | |
|---|---|
| Étapes | Client confirmé (e-mail et WhatsApp). Changer, l'un après l'autre : son e-mail, son téléphone, son pays, sa région. Supprimer son compte. |
| Attendu (41 l. 278 à 380) | **Changement d'e-mail** : consentement e-mail invalidé ; WhatsApp inchangé.<br>**Changement de téléphone** : l'inverse.<br>**Changement de pays** : fuseau déclaré effacé (`FUSEAU_INCONNU` s'il n'y a pas de fuseau par défaut). Consentement WhatsApp invalidé **si** le numéro international change : `telephone_international(telephone, pays)` déduit le préfixe du pays pour un numéro local (cas à éprouver : numéro saisi avec ou sans indicatif). Consentement e-mail gardé.<br>**Changement de région** : fuseau déclaré effacé ; consentements gardés.<br>**Suppression du compte** : les deux consentements invalidés, purge demandée.<br>Dans tous les cas, l'écriture dans `clients` réussit. |
| PASS si | Chaque état est exact, et aucune écriture dans `clients` n'échoue |
| FAIL si | Un ancien accord vaut encore pour le nouveau contact, ou l'écriture du client échoue |
| Statut | **NON EXÉCUTÉ** |

### F-C05 — Fuseau inconnu : clients des États-Unis et sans pays

| | |
|---|---|
| Données | 10 clients US (sans fuseau déclaré, table `communication_fuseaux_regions` vide), 5 sans pays, tous avec un consentement confirmé |
| Attendu | 15 exclus, avec la raison `FUSEAU_INCONNU`. Aucun fuseau deviné d'après l'indicatif ou le pays. |
| PASS si | 15 exclus pour cette raison |
| FAIL si | Un seul retenu |
| Statut | **NON EXÉCUTÉ** |

### F-C06 — Numéro partagé par deux comptes (nouveau constat S-06)

| | |
|---|---|
| Données | 2 clients avec le **même** numéro, tous deux confirmés pour WhatsApp |
| Étapes | Calculer l'audience WhatsApp d'une campagne ; compter les envois préparés pour ce numéro |
| Attendu **aujourd'hui** (brouillon 0693d5e) | 2 destinataires, donc 2 messages au même numéro : l'unicité porte sur (campagne, client, canal), 42 l. 1000. **Ce résultat est le défaut à corriger.** |
| Attendu **après correction** (P-05) | 1 seul message par numéro et par campagne |
| Complément | Un STOP envoyé depuis ce numéro supprime l'empreinte du numéro : les deux comptes sont bloqués (attendu, et correct). |
| PASS si | Après correction : 1 seul envoi par empreinte de contact |
| FAIL si | 2 envois |
| Statut | **NON EXÉCUTÉ** |

### F-C07 — Désinscription d'un nouveau client

| | |
|---|---|
| Étapes | Client confirmé, message d'essai reçu par le faux serveur ; il clique sur le lien de désinscription (visiteur `anon`), puis rejoue le même lien |
| Attendu | Suppression enregistrée pour l'empreinte du contact ; consentement retiré ; campagne suivante : `SUPPRIME`. Le rejeu répond « déjà désinscrit » sans erreur. |
| PASS si | Exclu de la campagne suivante |
| FAIL si | Retenu, ou réponse « ok » sans écriture (IR-16) |
| Statut | **NON EXÉCUTÉ** |

---

## 4 bis. Essais ajoutés ou révisés par les corrections D5 (20/11/2026)

Les corrections D5 (`PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md`) changent le résultat attendu de plusieurs essais, et en ajoutent 13. **Tous restent NON EXÉCUTÉS.** Leur exécution demande une décision écrite distincte de la CEO.

### Essais révisés

| Essai | Avant D5 | Attendu après D5 |
|---|---|---|
| T-01 à T-01I (`PHASE_1_3_1_TEST_PLAN.md`) | Un appel `arreter_communications` | **Deux appels** : `arreter_communications` (répond `STOP_REQUESTED`), puis `confirmer_arret_communications` jusqu'à `STOP_CONFIRMED`. Mêmes garanties. |
| F-K07 | Durée d'un appel d'arrêt sous 6 s | Chaque appel de l'écran (`arreter_` : 5 s au plus ; `confirmer_` : 3 + 2 s ; `lever_` : 3 + 3 s) sous les 8 s **mesurés** du rôle `authenticated` ; `desinscrire_communication` sous les 3 s du rôle `anon` |
| F-K10 | « Attendu aujourd'hui : demande annulée (défaut RF-01) » | La demande, validée par son propre appel, **reste écrite** dans les cinq cas ; la confirmation répond `STOP_PENDING / CONSTAT_IMPOSSIBLE` |
| F-W01 | « Attendu aujourd'hui : 40P01 (défaut RF-02) » | 0 interblocage : plus de clé étrangère vers l'envoi ; statuts sans N1 |
| F-W02 | Cycle STOP / 131050 (RF-05) | N3 avant la suppression des deux côtés : 0 cycle |
| F-W03 | Reconnaissance STOP | `STOP` entier normalisé ; code à six chiffres distinct ; variantes et boutons non validés classés `ambigu` ; plainte sans retrait implicite |
| F-C06 | « Attendu aujourd'hui : 2 messages (défaut S-06) » | 1 message par contact et par campagne ; si un compte du numéro n'a pas consenti : 0 (règle D2) |

### Essais ajoutés

| Essai | Scénario et données | Étapes | Attendu | PASS si / FAIL si |
|---|---|---|---|---|
| **F-K11** Course demande / levée | Arrêt confirmé, version 7 affichée à l'écran de la levée | Entrelacement pas à pas : S1 levée (N0, puis attente de la ligne) ; S2 demande (ligne, appui, COMMIT : version 8) ; S1 obtient la ligne. Puis l'ordre inverse, et les permutations. | S1 refuse (`STOP_STATE_CHANGED`) ; dans l'ordre inverse, la demande réarme l'arrêt | PASS : l'arrêt n'est jamais levé avec une version périmée ; aucun 40P01. FAIL sinon. |
| **F-K12** Demande sans N0 | 3 portes ouvertes (N0 partagé tenu, transactions non validées) | Appeler `arreter_communications` ; puis ouvrir une 4ᵉ porte | Demande validée sans attendre les portes ; la 4ᵉ porte refuse (`ARRET_URGENCE`) ; `confirmer_` répond `STOP_PENDING` tant que les 3 portes sont ouvertes | PASS : demande en moins de 100 ms et 4ᵉ porte refusée |
| **F-W04** Retour et chemins concurrents | Un envoi de campagne | Recevoir un retour `complaint` (RPC commitée, `traite=false`), puis lancer son traitement en même temps qu'une relance, une purge de la personne, une annulation de campagne et un autre travailleur ; 1 000 répétitions | La réception ne prend pas les verrous métier ; 0 cycle pendant le traitement ; si une attente dépasse son délai, le retour reste `a_traiter` puis est repris | PASS : 0 « deadlock detected », 0 retour perdu |
| **F-W05** Reprise et unicité | Retour et ligne `a_traiter` commités, sans lancer le travailleur ; puis déclencheur de banc qui fait échouer `communication_traiter_evenement` 2 fois ; enfin `pg_terminate_backend` du travailleur au milieu d'un traitement | Laisser le travailleur passer 6 fois | L'événement reste récupérable après l'interruption ; effets (suppression, retrait) appliqués **une seule fois** ; après 5 échecs forcés : `echec` | PASS : un effet par retour ; `tentatives` exactes ; accusé initial sans `traite=true` |
| **F-W06** Surveillance et reprise manuelle | 1 retour `echec` de priorité 1, 1 retour en attente depuis 11 min | Lire `sante_communications` ; appeler `reprendre_evenement_communication` en administrateur, en gérant, en employé | `alerte = true`, compteurs exacts ; reprise permise à l'administrateur seul ; journalisée | PASS : chiffres et droits exacts |
| **F-W07** Purge par date | Retours anciens : `a_traiter`, `echec`, `traite` | `communication_purger_autres(…, 'evenements_fournisseur', …)` | Seuls les `traite` sont effacés (avec leur ligne de traitement) | PASS : `a_traiter` et `echec` gardés |
| **F-W08** Échec du temps A | Base qui refuse l'insertion du retour ou de sa ligne de file (déclencheur de banc) | Appeler `communication_recevoir_evenement` | Une **erreur** remonte ; le retour et sa ligne de file sont atomiques ; jamais `ok` sans les deux | PASS : aucune réponse positive sans paire persistée ; commit avec `synchronous_commit = on` |
| **F-C08** Contact devenu commun après le gel | 2 comptes consentants ; le numéro de B devient celui de A après le lancement | Deux travailleurs en même temps | 1 envoi ; l'autre `supprime / CONTACT_EN_DOUBLE` (sous N3b) | PASS : 1 seule requête au faux serveur |
| **F-C09** Règle D2 | A consentant, B non, même numéro | Aperçu, lancement, envoi | A et B exclus (`CONTACT_PARTAGE_NON_CONSENTI` pour A) ; B jamais consentant | PASS : 0 message ; aucun consentement de B |
| **F-C10** Fréquence par contact | A et B consentants, même numéro, `frequence_max_jour = 1`, deux campagnes le même jour | Lancer les deux | 1 seul message au numéro dans la journée | PASS : le plafond vaut pour le numéro |
| **F-C11** Code de confirmation | A et B demandent en même temps pour le même numéro ; puis 5 codes faux ; puis un code expiré | Forcer, dans le banc, un tirage identique pour les deux | Le 2ᵉ tire un autre code (index unique) ; la réponse « OUI <code de A> » ne confirme que A ; 5 codes faux annulent les deux demandes ; un code expiré est refusé | PASS : jamais de confirmation pour le mauvais compte |
| **F-S01** Inventaire des droits | Les 4 brouillons corrigés | Inventaire `pglast` (fonctions, `SECURITY DEFINER`, `search_path`, `REVOKE`, RLS) comparé à la matrice du rapport D5 ; attentes bornées de chaque fonction | Identique à la matrice | PASS : 0 écart |
| **F-S03** Empreinte des contrats | Base jetable avec la chaîne complète | Empreinte de `pg_get_functiondef` de `expedier_envoi`, `courriel_gabarit`, `traiter_notifications`, `envoyer_email_client`, `envoyer_whatsapp_client`, `lire_reglage`, des tables `notifications`, `notification_envois`, `notification_regles`, `messages_recents` et de leurs règles RLS, avant puis après 40 → 43 | Identiques ; `permissions_du_role` ne diffère que par les lignes du Centre | PASS : 0 différence |

## 5. Récapitulatif

| Groupe | Essais | Gravité | Exécutés |
|---|---|---|---|
| Arrêt d'urgence (hypothèses et RF-01) | F-K01 à F-K10 | BLOQUANT | **0** |
| Migrations | F-M01 à F-M03 | BLOQUANT | **0** |
| Séparation | F-T01, F-T02 | BLOQUANT | **0** |
| Retours des fournisseurs | F-W01 à F-W03 | BLOQUANT | **0** |
| Base clients et audience | F-C01 à F-C07 | BLOQUANT avant toute campagne | **0** |
| Ajoutés par D5 | F-K11, F-K12, F-W04 à F-W08, F-C08 à F-C11, F-S01, F-S03 | BLOQUANT | **0** |
| **Total de ce plan** | **38** | | **0** |
| Plan précédent (`PHASE_1_3_1_TEST_PLAN.md`) | 40 | | **0** |
| **Total général** | **78** | | **0** |

**Ordre proposé**, si la direction l'autorise par écrit sur une base jetable :
1. F-M01 ;
2. F-M02 ;
3. F-K05 et F-K09, car si H4 ou H4′ tombe, la conception de l'arrêt est à revoir avant tout le reste ;
4. F-K01, F-K02, F-K03, F-K08, F-K10, F-K11, F-K12 ;
5. F-K06, F-K04, F-K07 ;
6. F-W01 à F-W08, puis F-T01, F-T02, F-S01, F-S03 ;
7. F-C01 à F-C11 ;
8. le plan précédent.

**Aucun de ces essais n'est déclaré réussi.**
