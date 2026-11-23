# Centre de communication — Phase 1.3.1 : dossier pour la revue indépendante PostgreSQL (Q1–Q7)

**Rédigé le 23/11/2026 par Claude Code, en lecture seule.** Ce dossier prépare le travail du
spécialiste humain PostgreSQL exigé par D5 §8. **Il n'est pas une revue, ne donne aucune réponse aux
questions et ne valide rien.** Aucun SQL, aucun essai et aucune base n'ont été utilisés pour l'établir.

Phase 1.3.1 : **NON VALIDÉE**. Phase 2 : **NON AUTORISÉE**. Brouillons 40–43 : **NON EXÉCUTABLES**.

**Origine des questions.** D5 §6 renvoie à `PHASE_1_3_1_CLARIFICATIONS_ET_RISQUES_RESIDUELS.md` §7.
Ce document est **introuvable** dans le dépôt (vérifié le 21 et le 23/11/2026) ; D5 n'en conserve que
les sept thèmes. Les formulations Q1–Q7 ci-dessous sont donc des **propositions** construites à partir
de ces thèmes, de D5 §8 et du code. La CEO ou le relecteur peut les modifier ; elles ne constituent pas
une décision approuvée.

---

## 1. Objet examiné : version figée

**Décision préalable de la CEO** (fiche `PHASE_1_3_1_DECISIONS_CEO_EN_ATTENTE.md`, décision A) : la
revue porte-t-elle sur les brouillons 40–43, sur les candidates `outils/migrations-candidates/001–009`,
ou sur les deux ? Ce dossier traite des **brouillons**, seul objet que D5 désigne. Les candidates
suivent une construction différente ; elles n'y sont citées que pour mémoire.

Les brouillons ont changé **après** le commit `77cf8e6` (modifications locales non commitées).
Le relecteur doit recevoir exactement les fichiers dont l'empreinte figure ci-dessous. Si les
fichiers changent avant l'envoi, il faut recalculer les empreintes et mettre ce tableau à jour.

| Fichier | Lignes | SHA-256, copie de travail du 23/11/2026 | SHA-256 au commit `77cf8e6` |
|---|---|---|---|
| `40-supabase-communications-fondation.sql` | 1389 | `22d62ac2cded5afcb0cf718fd4389469d5fe2468996a0305078395d418f5e14b` | `bce47e68543788620c6a2be6cde2b1d2e6a20c4eca1f4cc7ee2f396d6555c1e8` |
| `41-supabase-communications-consentement.sql` | 1416 | `2de091dce9848a6a4cf51d64574110add324ea71544af3692011866888a08add` | `435cd0201f87eadbeb30412c413437cb53864ff0739407df5936f5a7ce9d86ec` |
| `42-supabase-communications-campagnes.sql` | 1082 | `9354abc09e69a7897a6a47efd1067a9327925dec44733d2eaa945638c4ec3e59` | identique |
| `43-supabase-communications-envoi.sql` | 2518 | `0709a0f042ac1b3e8d780da518d5d5b2ec911c086338c86f6de2796da7c04130` | `db10c1750aeaf4b7cdd874b0a6b66f3b3dd0a4055006ac49609bd1e9f1fd4eca` |

**Ce qui a changé depuis `77cf8e6`** (copie de travail ; changements postérieurs au rapport D5 du
20/11/2026, donc non décrits par lui) :
- nouveau niveau de verrou **N3c**, la ligne de file d'un retour, pris en `SKIP LOCKED` après
  N1/N3/N3b et avant N4 (40, hiérarchie ; 43 `communication_traiter_evenement`) ;
- **lecture préparatoire sans verrou** dans le temps B, pour connaître les verrous métier à prendre
  avant N3c ;
- dans le temps A, la réception ne fait plus qu'**accuser réception**, avec `synchronous_commit = on` ;
  le traitement métier passe entièrement au temps B ;
- STOP automatique limité à la commande `STOP` entière, après normalisation ; une plainte n'équivaut
  plus à un retrait ; nouvelle source de retrait `desinscription_fournisseur` (40, contrainte) ;
- dans `demander_consentement_communication`, refus d'une isolation autre que `READ COMMITTED` et ajout
  de N3b après N3 (41) ;
- reprise des erreurs transitoires `55P03`, `40P01`, `40001` et `57014` après 1, 2, 5 puis 15 min ;
  passage en `echec` au cinquième échec (43).

Les numéros de ligne ci-dessous renvoient à la **copie de travail** décrite dans le tableau.

## 2. Pièces à transmettre au relecteur (lecture seule)

- Les quatre brouillons, à l'empreinte du §1.
- `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` (verrous, preuve, hypothèses H1–H6 et H4′),
  `PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md`, `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`,
  `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md`, `PHASE_1_3_1_TEST_PLAN.md`,
  `PHASE_1_3_1_FINAL_TEST_PLAN.md`, `COMMUNICATION_CENTER_DATABASE.md`.
- Le présent dossier.
- **À ne jamais transmettre** : `assets/js/config.js`, tout fichier sous
  `outils/communication-center-edge/supabase/.temp/`, toute donnée de production ou de client. Les
  brouillons ne contiennent pas de secret (D5 §6), mais ce point doit être vérifié de nouveau avant
  l'envoi.
- Un accord de confidentialité préalable et une déclaration d'indépendance (D5 §6, méthode).

## 3. Hiérarchie des verrous déclarée (40, l. 307–338)

Ordre unique, qu'on peut parcourir en sautant des niveaux mais jamais à rebours :
**N0** interrupteurs (consultatif, partagé pour la porte, exclusif pour l'arrêt et les réglages) →
**N0a** ligne `communication_arret` → **N1** campagne → **N2** `client:<id>` → **N3**
`consentement:<client>:<canal>`, par identifiant croissant → **N3b** `contact:<canal>:<empreinte>` →
**N3c** ligne de `communication_evenements_traitement` (SKIP LOCKED) → **N4** ligne
`communication_envois` → **N5** `compteurs`, global.

Les verrous consultatifs sont posés par `pg_advisory_xact_lock(hashtextextended('goship-communication:'
|| sujet, 0))` (40 l. 342–365). Chaque fonction borne ses attentes par `lock_timeout` (2 à 5 s) ; les
délais d'exécution mesurés le 20/11/2026 sont de 8 s pour `authenticated` et de 3 s pour `anon`.

## 4. Questions Q1 à Q7

Chaque question indique le code concerné, les hypothèses de la preuve d'arrêt, les essais qui
pourraient la trancher et ce que la lecture statique ne prouve pas.

### Q1 — Sous-transactions et rattrapage des erreurs (`57014`, `40P01`, `55P03`)

- **Code** :
  - 41 `confirmer_arret_communications` (l. 1111) : sous-bloc l. 1146–1153 qui attrape
    `query_canceled` puis `others`, et écrit `STOP_PENDING` ;
  - 43 `traiter_communications` (procédure, l. 1189) : boucle des retours l. 1222–1228, qui attrape
    `query_canceled` ; boucle des envois l. 1266–1271, qui n'attrape que `others`, si bien qu'un
    `57014` arrête toute la procédure (IR-25) ; `COMMIT` entre les itérations ;
  - 43 `communication_evenement_a_reprendre` (l. 1875) : classement des erreurs transitoires.
- **Questions proposées** :
  1. Rattraper `query_canceled` dans un sous-bloc PL/pgSQL est-il fiable, quelle que soit l'origine de
     l'annulation : `statement_timeout` du rôle, `pg_cancel_backend`, client PostgREST déconnecté ?
     Après le rattrapage, l'`UPDATE` qui écrit `STOP_PENDING` peut-il encore s'exécuter dans le délai
     restant de l'instruction ?
  2. Après l'annulation du sous-bloc, les verrous pris **avant** lui (N0 exclusif, N0a) restent-ils
     tenus, et ceux pris **dans** le sous-bloc sont-ils bien relâchés ?
  3. Dans la procédure lancée par `pg_cron` (`call`), les `COMMIT` placés entre les sous-blocs
     produisent-ils bien une transaction par retour et par envoi, sans verrou conservé d'une
     itération à l'autre ?
  4. Si `40P01` frappe une sous-transaction, l'état laissé est-il cohérent ? Reprendre `40001` et
     `57014` comme erreurs transitoires est-il sûr ?
- **Hypothèses** : H2 (verrou annulé avec la sous-transaction).
- **Essais** : F-K10, F-K07, F-W05, F-W08.
- **Non prouvé par la lecture** : le comportement réel de PostgreSQL 17 et de Supabase, c'est-à-dire
  le délai d'exécution réel et l'action de PostgREST quand le client se déconnecte.

### Q2 — Verrous consultatifs, partagés et exclusifs (N0)

- **Code** : 40 `communication_verrou` (l. 342), `communication_verrou_interrupteurs` (l. 356, exclusif
  l. 363, partagé l. 365), la porte `communication_autoriser_sortie` (l. 404) et
  `communication_sortie_autorisee` (l. 439).
- **Questions proposées** :
  1. Un verrou exclusif sur N0 est-il accordé seulement quand aucune porte ne tient le verrou partagé
     (H2) ?
  2. Une demande partagée qui arrive après une demande exclusive en attente reste-t-elle derrière elle
     (H6) ? Quel est l'effet sur le débit des portes ?
  3. Avec `READ COMMITTED` et des fonctions `VOLATILE`, une porte ouverte après la fermeture voit-elle
     l'arrêt (H3) ?
  4. Les collisions de `hashtextextended` sur 64 bits entre sujets (`client:`, `consentement:`,
     `contact:`, `interrupteurs`) peuvent-elles créer un interblocage ou une attente parasite ? Ce
     risque est-il acceptable ?
- **Hypothèses** : H2, H3, H6.
- **Essais** : F-K01, F-K02, F-K12.

### Q3 — Verrous posés par les clés étrangères

- **Code** : 40 l. 329–332 et 43 l. 1326 (`envoi_id` sans clé étrangère). D5 (P-08) **retire** toute clé étrangère des retours fournisseurs vers
  `communication_envois`, pour supprimer le `FOR KEY SHARE` implicite pris avant N1/N3 (RF-02).
- **Questions proposées** :
  1. Quelles clés étrangères restantes, sur les tables écrites par la porte, le travailleur, les
     retours, les consentements ou les purges, posent-elles encore un verrou implicite **hors de
     l'ordre** N0 → N5 ?
  2. Sans cette clé étrangère, une référence orpheline vers `communication_envois` est-elle possible,
     par exemple après une purge ? Le code la traite-t-il comme un état normal ?
- **Essais** : F-W01, F-W02.
- **Non prouvé par la lecture** : R-04, les noms et types de colonnes, puisque les brouillons n'ont
  jamais été créés dans une base (F-M02 en premier).

### Q4 — Interblocages entre chemins concurrents

- **Chemins à croiser** : la porte (40 l. 404) ; la demande, le constat et la levée de l'arrêt
  (41 l. 1055, 1111, 1211, `communication_conclure_arret` l. 985, confirmation automatique l. 1166) ;
  le travailleur d'envoi (43 `communication_traiter_un` l. 916, `traiter_communications` l. 1189) ;
  les retours en temps A et B (43 l. 1487, 1641) ; la relance (43 l. 2018) ; les purges (40 l. 1166,
  43 l. 2079 et 2155) ; les consentements (41 l. 108, 238, 289, déclencheur
  `communication_suivre_client` l. 325) ; les campagnes (42 l. 806, 861).
- **Questions proposées** :
  1. Chaque chemin respecte-t-il l'ordre N0 → N5 sans retour en arrière, y compris dans les
     déclencheurs ?
  2. Dans le temps B, la lecture préparatoire sans verrou (43, vers l. 1662) suppose que les champs
     qui fixent l'ordre des verrous sont immuables. Cette hypothèse est-elle garantie par des
     contraintes, ou seulement par le code ?
  3. Le cycle purge (N3 → N3c) contre retour (N3c → N3), décrit dans 43, est-il bien supprimé dans
     tous les cas ?
- **Hypothèses** : H1, H5.
- **Essais** : F-K04, F-W01, F-W02, F-W04, F-C08.

### Q5 — Verrou N3b (contact partagé entre comptes)

- **Code** : définition (40 l. 320–322) ; 41 `demander_consentement_communication` (l. 108 : garde
  `READ COMMITTED` l. 128–132, N3 puis N3b l. 173–175) ; envois de campagne et retours STOP ou code
  (43).
- **Questions proposées** :
  1. N3b, pris après N3, suffit-il à sérialiser le quota de demandes et l'unicité de l'envoi par
     contact quand plusieurs comptes partagent un numéro (N-01, N-02, S-06) ?
  2. Exiger `READ COMMITTED` est-il nécessaire et suffisant pour que chaque instruction relise le
     compteur après l'obtention de N3b ?
  3. Avec plusieurs comptes (N3 par identifiant croissant, puis un seul N3b), l'ordre est-il
     compatible avec tous les chemins de Q4 ?
- **Essais** : F-C06, F-C08, F-C10, F-C11.

### Q6 — Traitement une seule fois (retours fournisseurs et codes)

- **Code** :
  - temps A, 43 `communication_recevoir_evenement` (l. 1487) : unicité `(fournisseur, evenement_id)`
    (l. 1331), `synchronous_commit = on` (l. 1563), simple accusé ;
  - temps B, 43 `communication_traiter_evenement` (l. 1641) : N3c en `SKIP LOCKED`, relecture de
    l'état, puis effets ;
  - reprise : 43 l. 1875 et 1919 ;
  - codes de confirmation : index unique `communication_confirmations_code_numero_idx`
    (40 l. 635).
- **Questions proposées** :
  1. Deux travailleurs concurrents peuvent-ils appliquer deux fois l'effet d'un même retour ?
     L'effet et le passage à `traite` sont-ils dans la même transaction ?
  2. Une interruption entre l'effet et l'écriture de l'état peut-elle conduire à rejouer l'effet ?
  3. Sous insertions concurrentes, l'index unique des codes refuse-t-il toujours un doublon ? L'erreur
     d'unicité est-elle traitée sans perdre la demande ?
- **Essais** : F-W04, F-W05, F-W08, F-C11.

### Q7 — Durabilité de l'arrêt d'urgence

- **Code** : 41 `arreter_communications` (l. 1055 : seulement N0a, `synchronous_commit = on` l. 1069,
  `lock_timeout` 5 s) ; `confirmer_arret_communications` (l. 1111) ; `lever_arret_communications`
  (l. 1211) ; appels `net.http_post` (43 l. 487, 496, 530) ; observation de la file pg_net
  (43 l. 2229–2283).
- **Questions proposées** :
  1. Une demande d'arrêt validée avec `synchronous_commit = on` est-elle durable dans la configuration
     Supabase visée, réplication et restauration comprises ?
  2. Le client doit attendre le `COMMIT` de la demande avant d'appeler le constat, et aucune
     enveloppe ne doit réunir les deux appels (commentaire de 41 l. 964–967). Comment garantir qu'aucun
     appelant (PostgREST, `Prefer: tx=rollback`, client SQL) ne les réunit dans une même transaction ?
  3. Les hypothèses sur pg_net sont-elles exactes pour la version déployée : sortie de file avant
     l'appel, envoi seulement après le `COMMIT`, délai appliqué, aucun réessai automatique, et
     transfert commencé moins de 60 s après la sortie de file ?
- **Hypothèses** : H4, H4′, H2, H3.
- **Essais** : F-K05, F-K06, F-K08, F-K09, F-K10, F-K11.

## 5. Points D5 qui demandent encore une vérification

| Point | État dans les brouillons | Vérification encore nécessaire |
|---|---|---|
| P-07 / RF-01 : demande et constat de l'arrêt séparés | Deux RPC ; la demande ne prend que N0a | Q1, Q7 ; F-K10, F-K11, F-K12 |
| P-08 / RF-02 : retours fournisseurs | Clé étrangère retirée ; temps A et B ; N3c (après D5) | Q3, Q4, Q6 ; F-W01, F-W04, F-W05, F-W08 |
| RF-05 : STOP contre code 131050 | N3 avant toute suppression | Q4 ; F-W02 |
| P-09 / RF-03 : reconnaissance du STOP | `STOP` exact seulement ; les variantes sont classées « ambiguës » | Juriste (liste US/Floride, DO, HT) ; bouton Meta à confirmer ; F-W03 |
| P-05 / N3b, S-06 : un seul message par numéro | N3b | Q5 ; F-C06, F-C08, F-C10 |
| N-01 : plafond de fréquence | Par empreinte (décidé) **et** par compte, tous canaux confondus | Approbation du plafond par compte non établie (fiche CEO, décision H) |
| N-02 : code WhatsApp à 6 chiffres | 60 min, 5 erreurs, limites répétées | Valeurs non approuvées (fiche CEO, décision H) ; F-C11 |
| D2 : numéros partagés | Exclusion prudente | Juriste ; décision CEO (R-09) ; F-C09 |
| P-03 : attentes bornées | `lock_timeout` de 2 à 5 s | Somme des attentes sous 8 s et 3 s : F-K07 |
| Supervision | Agrégats disponibles | État « en cours » non mesuré par le modèle ; F-W06 |
| R-04 : erreurs invisibles à la lecture | Brouillons jamais créés dans une base | F-M02, sur autorisation |
| Non corrigés hors du périmètre D5 | P-10, P-11, P-12, P-13, RF-06, RF-12 à RF-15, RF-18, RF-19 | À planifier avec la Phase 2 |

## 6. Livrable attendu du relecteur (reprise de D5 §6)

Un rapport signé qui :
- traite chaque question Q1 à Q7 et chaque hypothèse H1–H6 et H4′, en la déclarant confirmée,
  réfutée ou à corriger, avec un niveau de gravité ;
- donne un avis sur les spécifications d'essais de concurrence (`isolationtester`) ;
- inclut une déclaration d'indépendance.

Ses propres essais éventuels se font sur une base jetable fournie par GoShip, jamais sur la
production, et seulement après autorisation écrite distincte.

## 7. Ce que ce dossier n'est pas

- Ce n'est pas la revue indépendante : une session Claude ou Codex ne peut pas la remplacer.
- Ce n'est pas une autorisation d'envoyer les pièces ou une demande de devis, ni d'exécuter un essai,
  un brouillon ou une candidate.
- Il ne présume pas que l'objet de la revue est tranché (décision A).
