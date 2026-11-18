# Centre de communication — Phase 1.3 : corrections techniques

**Date** : 18/11/2026 · **Branche** : `ccr-056ddc8c-m7u4p1` (PR #65, brouillon) · **Base examinée** : commit `07c46df` (fin de la Phase 1.2)

> **Rien n'a été exécuté.** Aucun SQL n'a tourné, ni en production ni sur une base de test. Aucun déploiement, aucun envoi, aucune connexion à Brevo ou à Meta.
>
> La seule vérification automatique est une **analyse statique** du texte des brouillons. Elle a été faite avec `pglast` / libpg_query, la bibliothèque qui contient le parseur de PostgreSQL, sans aucun serveur ni aucune base. Elle établit trois choses :
> - chaque fichier, pris en entier, ne contient plus que deux instructions inertes ;
> - chaque instruction du contenu est syntaxiquement lisible ;
> - les 67 corps PL/pgSQL sont lisibles.
>
> Elle ne prouve **pas** que le code fonctionne. Les noms de colonnes, les types et les comportements à l'exécution ne seront prouvés que par les essais sur base jetable, après autorisation : voir `PHASE_1_3_TEST_PLAN.md`.

Les références « avant » renvoient aux brouillons de la Phase 1.2 (commit `07c46df`). Les références « après » renvoient aux fichiers actuels de `brouillons-sql/`. Les numéros de ligne indiqués sont ceux des définitions.

---

## 0. Méthode

1. **Relecture** :
   - les rapports des Phases 0, 1, 1.1 et 1.2 ;
   - les quatre brouillons 40 à 43, en entier : 3 974 lignes avant cette phase ;
   - le plan d'essais.
2. **Diagnostic** : chaque problème est confronté au code **actuel**, et non à l'énoncé ni aux anciens numéros de ligne.
3. **Lectures complémentaires** :
   - les lanceurs SQL du projet (`essai-services.py`, `appliquer-chaine.sh`, `epreuve-restauration.sh`) ;
   - `docs/production/secrets.md` ;
   - la table `clients` (`supabase.sql`) ;
   - `lieux.js` ;
   - les branches des PR #46 et #48.
4. **Documentation publique** consultée sur trois points :
   - pg_cron : une tâche ne tourne qu'en un exemplaire à la fois ;
   - PostgreSQL : une procédure ne peut pas valider (COMMIT) si elle est `SECURITY DEFINER` ou si elle porte une clause `SET` ;
   - Brevo et Resend : leurs clés d'idempotence.

   Chaque fait repris ici est marqué **rapporté** tant qu'il n'est pas éprouvé.
5. **Corrections** : dans les brouillons et les documents du dossier seulement.
6. **Contre-revue** : `PHASE_1_3_SECURITY_REVIEW.md`, §1.

---

## 1. Diagnostic des huit problèmes

| # | Problème | Verdict | Preuve dans le code de la Phase 1.2 |
|---|---|---|---|
| C1 | Arrêt d'urgence | **CONFIRMÉ** | 43 l. 533 : `select * into r` **une seule fois** au début de `traiter_communications()`. 43 l. 643 : le contrôle du canal lit cette copie (`r.email_actif`). `communication_reserver` (43 l. 182) relit les réglages, mais **ne teste ni** `campagnes_actives`, **ni** `email_actif` / `whatsapp_actif`. Tout le passage est **une seule transaction**, et pg_net n'envoie ses requêtes qu'**après** le COMMIT. Un arrêt validé pendant le passage n'empêchait donc pas les envois suivants du même lot. |
| C2 | Interblocage worker / annulation | **CONFIRMÉ, et plus large que décrit** | Le travailleur verrouille la ligne d'envoi (43 l. 637, `for update of ev skip locked`), puis le client (l. 640), puis le jour et la campagne (`communication_reserver` l. 183 et 187). `changer_statut_campagne('annuler')` verrouille la campagne (42 l. 782), puis met à jour les envois (l. 879) : **cycle**. **Deuxième cycle, non signalé** : le verrou du jour reste pris jusqu'à la fin du lot. Au tour suivant, le travailleur A prend `client:Y` en tenant `jour`. Le travailleur B, qui tient `client:Y`, attend `jour`. **Troisième cycle** : `confirmer_consentement_communication` (41 l. 192) verrouille la ligne de confirmation **avant** le verrou du consentement (N3). `demander_consentement_communication` prend N3 **avant** d'annuler ces lignes. Le webhook entrant fait de même (43 l. 978). |
| C3 | Quota Brevo et débit | **CONFIRMÉ** | 43 l. 632 : `v_brevo` est calculé **une fois** par passage, hors de tout verrou, puis décompté **en mémoire** (l. 691, 786). Deux travailleurs partent de la même estimation. Le débit `lot_par_minute` (l. 637) est **par passage**, pas global. **Atténuation trouvée, rapportée** : pg_cron ne lance jamais deux exécutions de la **même** tâche en même temps. Le risque demande donc un second lanceur (appel manuel, seconde tâche). La conception ne doit pas s'appuyer sur cette atténuation. |
| C4 | 5xx et double envoi | **CONFIRMÉ** | 43 l. 454 : `(p_code = 429 or p_code >= 500) and tentative < 3` → `nouvel_essai`, avec le commentaire « refus temporaire SÛR ». C'est faux pour une 5xx. |
| C5 | Purge et minimisation | **CONFIRMÉ** | 43 l. 1201 : la purge d'une personne efface `client_id` et `message_id`, mais **garde** `cible_empreinte`, `requete` et `empreinte_contenu` des envois. 43 l. 1205 : les audiences gardent `cible_empreinte`. 43 l. 1167 : une audience n'est effacée que si **aucun** envoi ne la cite, c'est-à-dire presque jamais. Les fenêtres WhatsApp (clé = empreinte) et les retours des fournisseurs ne sont **jamais** touchés pour une personne. Les empreintes des consentements anonymisés sont gardées **sans fin**. |
| C6 | Fuseaux américains | **CONFIRMÉ, et plus large** | 43 l. 115-118 : `else 'America/New_York'` s'applique aux USA **et à tout autre pays**. À 9 h à New York, il est 6 h à Los Angeles et 4 h à Honolulu. |
| C7 | Webhook et fenêtre WhatsApp | **CONFIRMÉ** | 43 l. 1297 : `grant … to anon`, avec une seule porte, le HMAC. Aucune limite de débit dans la base. 43 l. 959-960 : `dernier_entrant = now()`, l'heure de **réception**. 43 l. 931 : `(p ->> 'survenu_le')::timestamptz` sans garde ; une valeur illisible lève une erreur qui recopie la valeur. |
| C8 | Garde des migrations | **CONFIRMÉ (partiellement protégé)** | Chaque fichier commence par `do $brouillon$ … raise exception`, suivi de 29 à 87 instructions **exécutables** (comptées par analyse statique). Avec les lanceurs du projet (`psql -v ON_ERROR_STOP=1` dans `essai-services.py` l. 171 ; `--single-transaction` dans `appliquer-chaine.sh` l. 49) et avec le SQL Editor (une transaction), la garde arrête tout. Avec `psql -f` **sans** `ON_ERROR_STOP` (autocommit, comportement par défaut), l'erreur s'affiche et **toutes les instructions suivantes s'exécutent**. |

**Constats supplémentaires**, trouvés pendant le diagnostic et corrigés :

| # | Constat | Gravité | Preuve (Phase 1.2) |
|---|---|---|---|
| X1 | Un message « incertain » cessait d'être compté dans la fréquence par client et dans la limite du numéro WhatsApp. | Élevée | 43 l. 155 et 204 : `coalesce(envoye_le, verrouille_le)`. `verrouille_le` est remis à vide à la lecture de la réponse (l. 452-470). |
| X2 | Un STOP pour un numéro partagé par plusieurs comptes prenait les verrous dans un ordre quelconque. | Moyenne | 43 l. 964 : boucle sans `order by`. |
| X3 | Le travailleur appelait `communication_lire_modeles_meta()` même avec les campagnes coupées. | Faible | 43 l. 547, avant le test `campagnes_actives`. |
| X4 | Les compteurs techniques n'avaient pas de nettoyage. | Faible | Tables nouvelles en 1.3. |

---

## 2. Correction 1 — Arrêt d'urgence

**Cause** : les interrupteurs étaient lus une fois, dans une transaction longue, et n'avaient aucun instant d'effet défini face aux travailleurs.

**Correction** :

| Élément | Où (après) |
|---|---|
| Réglage `arret_urgence` (avec `arret_motif`, `arret_le`, `arret_par`), né à `false`. Il n'est **pas** modifiable par `regler_communications`. | 40 l. 180 |
| Verrou **N0 « interrupteurs »** : **partagé** pour toute transaction qui envoie ou prépare un envoi ; **exclusif** pour qui écrit un interrupteur ou un réglage d'envoi. | 40 l. 341 `communication_verrou_interrupteurs` |
| Une seule règle de décision : `communication_interrupteur_ferme(réglages, nature, canal)`. Réglages illisibles = fermé. | 40 l. 358 |
| `arreter_communications(motif)` est permise à l'administrateur et au gérant (`communications.pause` : couper ne peut que protéger). Elle prend N0 en exclusif, 5 s au plus, puis écrit l'arrêt **avec ou sans** le verrou. Elle rend le nombre de messages déjà remis au fournisseur et journalise. | 41 l. 842 |
| `lever_arret_communications(motif ≥ 10)` : administrateur seulement (`communications.manage`), journalisée. | 41 l. 878 |
| `regler_communications`, `verifier_quota_brevo`, `regler_whatsapp_commercial` et `verifier_issue_http` prennent N0 en exclusif. | 41 |
| Le travailleur traite **un envoi par transaction**. `communication_traiter_un` prend N0 partagé, **puis** lit les réglages, **puis** décide. `communication_reserver` relit les réglages sous N5 : c'est le dernier contrôle, et il voit un arrêt écrit sans verrou. | 43 l. 797, l. 213 |
| `communication_candidats` ne propose rien si l'arrêt est posé. La procédure sort de sa boucle au premier `ARRET_URGENCE`. `communication_preparer` (lancements, appels à Meta) s'arrête aussi. | 43 l. 760, l. 659 |

**Pourquoi c'est sûr** : un envoi n'est validé que dans une transaction qui tient N0 en partagé et qui a lu les réglages **après** l'avoir obtenu. L'arrêt prend N0 en exclusif. Il attend donc la fin des transactions d'envoi en cours (une ligne chacune, quelques millisecondes), et toute transaction qui commence ensuite attend sa fin puis lit `arret_urgence = true`. **L'instant d'effet de l'arrêt est son COMMIT** : après lui, aucune transaction ne peut valider un envoi.

**Messages déjà transmis** : ceux validés avant l'arrêt sont dans la file de pg_net, ou déjà partis. Ils **ne sont pas rappelés**. La file de pg_net est partagée avec le transactionnel, et y toucher modifierait un système gelé. Leur nombre (`statut = 'traitement'`) est rendu par `arreter_communications` et journalisé. Ce qui attend reste `attente` : rien n'est perdu, et rien ne part avant la levée de l'arrêt.

**Repli** : si N0 n'est pas obtenu en 5 s, ce qui ne devrait pas arriver avec des transactions d'une ligne, l'arrêt est écrit quand même (une coupure ne doit jamais échouer). Le contrôle sous N5 le voit au plus tard au prochain envoi. La réponse le dit (`envois_en_cours_attendus = false`).

**Cache** : il n'y en a aucun. Les réglages sont relus à chaque envoi, après N0 et sous N5. Aucune valeur n'est gardée d'un envoi à l'autre.

**Avant / après** :

| | Phase 1.2 | Phase 1.3 |
|---|---|---|
| Lecture des interrupteurs | une fois par passage | à chaque envoi, sous verrou, et une seconde fois sous N5 |
| Interrupteur général et interrupteurs de canal | contrôlés hors réservation | contrôlés dans la décision **et** dans la réservation |
| Instant d'effet | aucun défini | le COMMIT de l'arrêt (attente des envois en cours) |
| Arrêt global | inexistant (seulement `campagnes_actives`) | `arret_urgence` : campagnes, confirmations, appels à Meta |

**Essais** : T-01, T-02.

---

## 3. Correction 2 — Ordre des verrous

**Cartographie (après)** — ordre unique, défini en 40 §3 :

| Niveau | Verrou | Pris par |
|---|---|---|
| N0 | consultatif `interrupteurs`, partagé ou exclusif | travailleur (partagé) ; réglages, arrêt, quota, numéro, issues HTTP, webhook « pause canal » (exclusif) |
| N1 | ligne `communication_campagnes` (FOR UPDATE) | travailleur, lancement, transitions (42 `changer_statut_campagne`), webhook |
| N2 | consultatif `client:<id>` | travailleur, purge d'une personne |
| N3 | consultatif `consentement:<client>:<canal>` (plusieurs clients : par identifiant croissant) | travailleur, fonctions de consentement (41), déclencheur `communication_suivre_client`, webhook (STOP, confirmation, plainte), désinscription |
| N4 | ligne `communication_envois` (FOR UPDATE) | travailleur (relue sous verrou), lecture des réponses, annulation, relance, webhook, purge |
| N5 | consultatif `compteurs` (global) | `communication_reserver` seulement |

**Règle** : une transaction peut sauter un niveau, jamais revenir en arrière.

Ce qui rendait l'ordre impossible à tenir avant : une transaction pour **tout** le lot, donc des verrous de plusieurs envois tenus ensemble. Désormais, la procédure valide après **chaque** envoi : aucun verrou ne survit d'un envoi au suivant.

**Fonctions corrigées** :
- `communication_traiter_un` (43 l. 797) : lit l'envoi **sans** verrou, puis N0 → N1 → N2 → N3 → N4 (relu, `skip locked`) → N5.
- `communication_recevoir_evenement` (43 l. 1199) : lit l'envoi sans verrou, puis N0 exclusif seulement pour un code « pause canal », **décidé avant** tout autre verrou, puis N1 → N3 → N4.
- STOP : N3 pour chaque compte, par identifiant croissant (43 l. 1302).
- `confirmer_consentement_communication` (41 l. 201) et la confirmation WhatsApp : lecture sans verrou, puis N3, puis la ligne est verrouillée et relue.
- `changer_statut_campagne` (42) : déjà N1 → N4 ; l'ordre est maintenant commun avec le travailleur (note 42 l. 782).
- Pause, reprise : N1 seul.
- Lancement (`communication_preparer`) : N0 partagé → N1 (`skip locked`) → lignes neuves.
- Clôture : N1 seul.
- Lecture des réponses : N4 seul.
- Purge d'une personne : N2 d'abord.

**Démonstration du scénario du CEO** (« A verrouille un envoi ; l'admin annule ; A veut la campagne ; l'annulation veut l'envoi ») : la première étape est désormais **impossible**. A ne peut verrouiller l'envoi (N4) qu'en tenant déjà la campagne (N1). Il reste deux ordres possibles :
- **A prend N1 en premier.** `annuler` attend N1. A finit son envoi (quelques ms, le message passe en `traitement`) et valide. `annuler` obtient N1, relit, annule les envois encore `attente` ou `nouvel_essai`. Le message de A est compté comme parti.
- **`annuler` prend N1 en premier.** A attend N1 (2 s au plus, `lock_timeout`). `annuler` valide. A obtient N1, lit `annulee` et n'envoie rien. Ou bien son délai expire, son envoi est annulé en entier et rien n'est parti.

Aucun cycle n'est possible : les deux prennent N1 avant N4.

**Interblocage tout de même détecté**, par une fonction future qui violerait l'ordre : PostgreSQL annule l'une des transactions (code 40P01). La procédure attrape l'erreur pour **cet envoi seulement**. Sa sous-transaction est annulée, avec la réservation N5 et la requête pg_net (qui n'est envoyée qu'au COMMIT). Rien n'est parti et l'envoi repasse au tour suivant : **pas de double envoi**. Même traitement pour `lock_not_available` (délai de verrou) et `query_canceled`.

**Transactions courtes** : une ligne par transaction ; `lock_timeout` de 2 s pour le travailleur, 5 s pour le webhook et l'arrêt, 10 s pour les réglages.

**Essais** : T-03 (et T-02 pour l'arrêt concurrent).

---

## 4. Correction 3 — Quota Brevo et débit global

**Correction** (`communication_reserver`, 43 l. 213, sous N5) :
1. relecture des réglages : arrêt et interrupteurs ;
2. plafonds de la campagne ;
3. plafonds globaux du jour ;
4. **débit global par minute** : nouvelle table `communication_debit_minute` (40 l. 737) et réglage `debit_max_minute` (40 l. 190), tous travailleurs et tous canaux confondus ;
5. limite quotidienne du numéro WhatsApp ;
6. **quota Brevo recalculé ici**, à chaque réservation (`communication_brevo_disponible()`), puis incrémentation des compteurs.

N5 est tenu jusqu'au COMMIT de l'envoi. Le travailleur suivant ne l'obtient qu'après ce COMMIT, et sa requête suivante voit la réservation validée : en lecture validée (READ COMMITTED), chaque requête d'une fonction VOLATILE prend un nouvel instantané.

**Démonstration (quatre travailleurs, 100 unités)** : soit D(t) la valeur de `communication_brevo_disponible()` sous N5. Chaque réservation qui réussit vérifie D ≥ 1, puis ajoute 1 à `communication_depenses_jour` (e-mail), qu'elle soustrait de D. Les réservations sont **sérialisées** par N5, et chacune voit toutes les précédentes validées. Donc après k réservations, D = 100 − k. La (k+1)-ième n'est permise que si 100 − k ≥ 1. Au plus 100 réussissent, quel que soit le nombre de travailleurs. Une transaction annulée n'a rien ajouté.

**Points de conception** :
- **Partage du quota** : rien ne prouve que Brevo sépare le commercial du transactionnel. Tant que `brevo_compte_partage` est vrai (valeur par défaut), le transactionnel connu, la file transactionnelle, l'authentification (borne basse) et la **réserve** sont retirés d'abord.
- **Quota non démontrable** : non vérifié, ou vérifié il y a plus de `brevo_quota_validite_jours` (30 par défaut, choix de GoShip à confirmer). Le disponible vaut alors **0** : le commercial est bloqué (`QUOTA_A_REVERIFIER`, 40 l. 789).
- **Réconciliation** : une réservation n'existe que dans la transaction de son envoi. Elle est validée avec lui ou annulée avec lui : il n'y a pas de réservation « expirée ». Un refus, un incertain ou un nouvel essai ne la rendent pas : l'estimation reste au-dessus du réel, ce qui est prudent. La vérification du compte réel chez Brevo reste manuelle (`verifier_quota_brevo`). Une lecture automatique demandera une autorisation (Phase 3).
- **Débit** : `debit_max_minute` (20 par défaut) est une valeur de conception, **pas** une limite des fournisseurs. Celles de Brevo et de Meta ne sont pas vérifiées.

**Coût** : `communication_brevo_disponible` est recalculée sous un verrou global à chaque e-mail. C'est acceptable à 20 envois par minute. Une version plus rapide (cumul tenu à jour) est possible en Phase 2 si les mesures le demandent.

**Essais** : T-04, T-05.

---

## 5. Correction 4 — Réponses 5xx et 429

**Correction** (`communication_lire_reponse`, 43 l. 516) :
- 2xx → `envoye` ;
- **5xx → `incertain`**, toujours. Une 5xx ne peut jamais être notée autrement : `verifier_issue_http` (41 l. 905) refuse toute règle contraire ;
- 429 → `incertain` par défaut. Elle ne devient « refus temporaire » (nouvel essai) **que** si une ligne de `communication_issues_http` (40 l. 706), saisie **avec la page officielle** du fournisseur, le dit ;
- autres 4xx → `echec` ;
- délai dépassé, réseau ou pas de réponse → `incertain`.

Un incertain **n'est jamais renvoyé automatiquement**. La procédure de rapprochement est inchangée :
- les retours des fournisseurs le rattachent par la référence `communication:<id>` ;
- après 72 h sans preuve, il est clos ;
- seul l'administrateur peut le relancer (`relancer_envoi_communication`), avec un motif et en cochant explicitement « risque de doublon ».

**Corrélation et idempotence** : la référence (`X-Mailin-custom`, `biz_opaque_callback_data`) sert à la **corrélation**. Ce n'est **pas** une clé d'idempotence, et le texte le dit désormais.

Ce que disent les fournisseurs (rapporté, non éprouvé) :
- **Brevo** documente une clé d'idempotence, mais son emplacement exact et sa durée de validité ne sont pas confirmés ;
- **Resend** documente un en-tête `Idempotency-Key` valable 24 h ;
- **Meta** : aucune n'a été trouvée pour l'API WhatsApp.

**Aucune clé n'est utilisée** : même vérifiée, une clé ne protège que pendant sa durée de validité. L'utiliser, et assouplir la règle des 5xx, sont des décisions du CEO sur preuve.

**Prix de la prudence** : des 429 répétées produiraient des incertains, qui demandent une action de l'administrateur. Le débit global (correction 3) est là pour les éviter.

**Essais** : T-06, T-07.

---

## 6. Correction 5 — Données personnelles et minimisation

**Inventaire après effacement d'une personne** (`executer_purge_communication` type « personne », 40, puis `communication_purger_personne_suite`, 43 l. 1589). **La demande naît d'office** quand le compte est supprimé : le déclencheur `communication_suivre_client` (41 l. 322) l'enregistre avec la personne comme demandeur. Un administrateur, forcément un autre compte, l'approuve.

| Table | Effacé | Anonymisé | Gardé (preuve) | Justification de ce qui est gardé |
|---|---|---|---|---|
| `communication_consentements` | — | client, contexte, motif, auteur | action, dates, version et empreinte du texte, **empreinte du contact** | Prouver qu'un envoi passé avait un consentement. L'empreinte est effacée à l'échéance « empreintes » (**BLOQUÉE**, juriste). |
| `communication_confirmations` | toutes ses lignes | — | — | Plus utiles après la décision. |
| `communication_suppressions` | — | client, motif | **empreinte**, canal, raison, dates | Faire respecter la désinscription (ne plus écrire à ce contact). Si la suppression est levée, effacement à l'échéance « empreintes » (BLOQUÉE). |
| `communication_envois` | — | client, contact, identifiant du fournisseur, requête pg_net, empreinte du contenu ; les envois encore en attente passent à `supprime` | statut, canal, territoire, dates, coût estimé | Statistiques et dépenses, sans lien vers la personne. |
| `communication_destinataires` | — | client, contact | campagne, canal, langue, retenu ou raison | Composition anonyme de l'audience. |
| `communication_evenements_fournisseur` (de ses envois) | — | identifiant du message, référence, identifiant d'événement (remplacé par `efface:<id>`) | type, code, dates | Statistiques de remise. |
| `communication_fenetres_whatsapp` | ses fenêtres, retrouvées par ses empreintes **recueillies avant** l'anonymisation | — | — | Aucune utilité. |
| `communication_fuseaux_clients` | son fuseau déclaré | — | — | Aucune utilité. |
| `communication_destinataires_essai` | sa ligne | — | — | Aucune utilité. |
| `communication_journal_purges` | — | — | nombre de lignes par table et opération | Preuve de l'effacement, **sans** aucune donnée. |
| Compteurs (dépenses, débit, retours par minute), campagnes, modèles, segments, tarifs, codes, réglages | — | — | tout | Aucune donnée personnelle. |

**Hors du Centre** (gelés, signalés et non modifiés) :
- **`journal_audit`** (immuable, existant) : garde l'identifiant du client pour les actions de l'équipe (`communication.consentement_retire`, `suppression_manuelle`, `fuseau_client`). C'est la politique actuelle du projet, appliquée aussi par `supprimer_mon_compte`.
- **pg_net** : `net.http_request_queue` garde le corps des requêtes (adresse e-mail, numéro) jusqu'à leur envoi, et `net._http_response` garde les réponses selon le réglage de durée de pg_net. La réponse de Meta contient le numéro (`wa_id`, rapporté). Ce réglage est **partagé** avec le transactionnel.
- **Brevo et Meta** : ils gardent leurs propres journaux, en tant que sous-traitants.

Ces trois points sont des **décisions du CEO et du juriste**.

**À l'échéance** (`communication_purger_autres`, 43 l. 1534) :
- les envois perdent aussi l'empreinte du contact, la requête et l'empreinte du contenu ;
- les audiences sont **anonymisées**, et non plus effacées sous condition ;
- nouvelle catégorie **« empreintes »** : efface l'empreinte des consentements déjà anonymisés et les suppressions **levées**. Une suppression **active** n'est jamais effacée par l'échéance.

**Durées** : toutes **BLOQUÉES** (null) tant que le juriste ne les a pas fixées. Aucune n'est inventée.

**Essai** : T-08.

---

## 7. Correction 6 — Fuseaux horaires

**Correction** :
- `communication_fuseau(client, canal)` (40 l. 896) ;
- les tables `communication_fuseaux_regions` (vide, 40 l. 861) et `communication_fuseaux_clients` ;
- `regler_fuseau_region` et `declarer_fuseau_communication` (41 l. 934, 961).

Ordre de détermination :
1. fuseau **déclaré** (par le client, ou par l'équipe sur sa parole), valable tant que pays et région n'ont pas changé ;
2. HT → `America/Port-au-Prince`, DO → `America/Santo_Domingo` (un seul fuseau IANA par pays) ;
3. US → le fuseau de son État, **seulement** si cet État est enregistré avec sa preuve et n'a qu'un fuseau ;
4. sinon **inconnu**, et l'envoi est écarté (`FUSEAU_INCONNU`, 42 l. 529).

WhatsApp : un numéro d'un autre territoire que le pays du profil exige un fuseau déclaré.

**Pourquoi** : `clients.region` contient l'État (liste de `lieux.js`), mais plusieurs États ont plusieurs fuseaux : Floride, Texas, Tennessee, Kentucky, Indiana, Michigan, Kansas, Nebraska, les Dakotas, Oregon, Idaho, Alaska. Ni le pays ni l'indicatif ne prouvent le fuseau. La table des États est **vide** : aucun fait n'est recopié de mémoire.

**Heure d'été** : la fenêtre (`communication_prochaine_fenetre`, 43 l. 139) se calcule avec le **nom** IANA (`at time zone`), donc avec les règles de la date concernée. 9 h et 19 h existent tous les jours dans ces fuseaux. Une **marge** (`marge_fenetre_min`, 15 min) évite d'entamer un envoi juste avant la fin de la fenêtre, parce que pg_net envoie quelques secondes après la validation. Un nom inconnu du serveur rend null et l'envoi est écarté.

**Prix de la prudence** : tant que la table des États est vide et que les clients n'ont rien déclaré, **aucun client américain ne reçoit d'envoi commercial**. Les comptes de l'équipe destinataires d'essai doivent aussi avoir un fuseau.

**Essais** : T-09, T-10.

---

## 8. Correction 7 — Webhooks et horodatage

**A. Sécurité** (`communication_recevoir_evenement`, 43 l. 1199) :
- **Accès** : la fonction **n'est plus ouverte à `anon`**. Seul le rôle `communication_webhook`, créé **sans connexion** (43 l. 1705), peut l'appeler. Les droits par défaut de Supabase (anon, authenticated, service_role) sont retirés (43 l. 1747). Un appel direct par l'API publique est refusé par PostgreSQL avant d'entrer dans la fonction. Il y a donc deux portes : le rôle, puis la signature HMAC.
  - **Décision du CEO avant la Phase 3** : comment la fonction Edge s'authentifiera. Soit par un rôle de connexion dédié, avec son mot de passe dans les secrets de la fonction Edge (recommandé : moindre privilège). Soit par la clé `service_role`, aujourd'hui « utilisée nulle part » d'après `docs/production/secrets.md`.
- **Débit** : table `communication_webhook_debit`, au plus `webhook_max_minute` appels par minute et par fournisseur. Le compte est fait **avant** la lecture du coffre, donc aussi pour les appels mal signés. Au-delà, la réponse est « saturé », sans traitement, et la fonction Edge répond une erreur temporaire. Que Meta et Brevo réessaient alors est **rapporté, à vérifier**.
- **Format** : 20 000 caractères au plus, objet JSON, identifiant d'événement présent (200 caractères au plus), type dans une liste fermée, horodatage lisible. Sinon, refus propre `format` qui ne recopie pas la valeur.
- **Rejeu** : clé unique `(fournisseur, evenement_id)`. Un événement déjà reçu ne refait rien. Un STOP rejoué est sans effet nouveau. Une confirmation rejouée est sans effet (code déjà utilisé).
- **Secrets** : aucune valeur du coffre dans les réponses ou les journaux. Les refus ne disent pas pourquoi.

**B. Fenêtre de 24 h** :
- elle part de `survenu_le`, l'heure réelle du message fournie par le fournisseur, bornée à `now()` ;
- elle ne recule jamais (`greatest`, 43 l. 1295) : un événement ancien ou reçu dans le désordre ne la prolonge pas ;
- sans horodatage, la fenêtre n'est pas touchée, mais le STOP s'applique toujours ;
- l'heure réelle est aussi gardée dans le `contexte` des retraits et confirmations WhatsApp.

**Démonstration** : un message est envoyé à 10 h et reçu à 18 h. `survenu_le` vaut 10 h, donc `dernier_entrant` vaut 10 h, et la fenêtre se ferme à 10 h le lendemain, pas à 18 h. Si un message de 9 h arrive ensuite, `greatest(10 h, 9 h)` donne 10 h : la fenêtre reste inchangée.

**Essais** : T-11, T-12, T-13.

---

## 9. Correction 8 — Garde des brouillons

**Comportement des clients** :

| Client | Garde de la Phase 1.2 (DO seul) | Garde de la Phase 1.3 |
|---|---|---|
| SQL Editor de Supabase (une requête, une transaction ; rapporté) | arrêt, rien appliqué | arrêt, rien appliqué |
| `psql -v ON_ERROR_STOP=1 -f` (essais du projet) | arrêt | arrêt |
| `psql --single-transaction` (`appliquer-chaine.sh`) | arrêt, annulation | arrêt, annulation |
| `psql -f` **sans** ON_ERROR_STOP (autocommit) | **les 29 à 87 instructions suivantes s'exécutent** | erreur du DO, puis un **SELECT d'un texte** : rien n'est créé |
| Outil d'IA disposant d'un accès SQL | dépend de l'outil | une seule requête utile, inerte |
| Découpeur naïf sur « ; », qui continue après une erreur | des morceaux s'exécutent | des morceaux du contenu peuvent encore s'exécuter (**limite connue**) |

**Correction** (en-tête de 40 l. 1-40, et des trois autres fichiers) :
1. le bloc DO qui lève une exception est gardé ;
2. **tout le contenu** est enfermé dans une chaîne `$brouillon_goship_non_executable$ … $brouillon_goship_non_executable$`. Le fichier entier n'est plus que **deux instructions** : `DO` puis `SELECT '<texte>'` (vérifié par analyse statique sur les quatre fichiers) ;
3. la garde d'origine est recopiée en tête du contenu, pour qui le sortirait de la chaîne.

La balise n'apparaît nulle part dans le contenu (vérifié).

**Rejeté** : `set session characteristics as transaction read only` en tête. Derrière le pooler de transactions de Supabase (port 6543), un réglage de **session** peut rester sur une connexion partagée et rendre la production en lecture seule pour l'application.

**Séparation** :
- **brouillon** : `docs/communication-center/brouillons-sql/`, chaîne inerte et garde, jamais dans `migrations.txt` ;
- **migration approuvée** : après l'accord écrit du CEO, copiée dans `outils/` **sans** la chaîne, avec la garde « base incomplète », toujours non exécutée ;
- **migration exécutable** : éprouvée sur base jetable, inscrite dans `migrations.txt`, puis passée en production sur un GO écrit.

**Protocole d'épreuve** (après autorisation) : T-14. On fait passer chaque brouillon par chaque client sur une base jetable, puis on compare le catalogue (tables, fonctions, déclencheurs, rôles, tâches pg_cron) avant et après : il doit être identique.

---

## 10. Ce qui n'a PAS changé

- Les contrats gelés : `notification_envois`, `notifications`, `messages_recents`, `expedier_envoi`, `courriel_gabarit`, `mon_resume`, les notifications de colis, de paiement et de compte, et les e-mails d'authentification. Aucun brouillon ne les modifie. Le Centre **lit** `notification_envois`, `notifications` et `auth.users` pour le quota et la priorité, sans rien y écrire.
- Les sept permissions et leur répartition (gérant : view, create, test, pause, consents ; employé : aucune).
- Le circuit d'approbation, le consentement confirmé par le contact, la priorité du retrait.
- Tous les réglages nés éteints ou bloqués :
  - campagnes, canaux et confirmations coupés ;
  - mode essai ;
  - plafonds à 0 ;
  - tâche pg_cron inactive ;
  - quota, numéro, identité et adresse à null ;
  - tarifs, issues HTTP et fuseaux des États vides ;
  - `arret_urgence` à false. Il ne bloque pas, puisque tout est déjà coupé.
