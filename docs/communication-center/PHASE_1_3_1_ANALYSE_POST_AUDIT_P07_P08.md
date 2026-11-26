# GoShip Express — Centre de communication
# Analyse technique post-audit indépendant, Phase 1.3.1 : préparation des corrections P-07 et P-08

| | |
|---|---|
| Date | 20 novembre 2026 |
| Mode | **Lecture seule.** Aucun fichier modifié ou créé dans le dépôt, aucun SQL exécuté, aucun fournisseur contacté, aucun secret lu, aucun commit, aucune fusion, aucun déploiement. |
| Copie analysée | Copie locale du Mac de la CEO (`~/Documents/claude/Goship-express-site`), recoupée avec la copie de la session |
| Commit | `2e9cc9f1d3c1fbe0b2178634ef32112cc47ed431`, branche `ccr-056ddc8c-m7u4p1` (PR #65, brouillon, non fusionnée) |
| Verdict de clôture en vigueur | **NON VALIDÉ** (`PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`, §11) |

> **Ce document n'est qu'une analyse.** Aucune correction n'a été faite. Rien ne sera modifié sans une nouvelle autorisation écrite explicite de la CEO.

**En bref :**
- Les deux défauts graves sont confirmés dans le code, ligne par ligne.
- Les deux corrections peuvent être préparées sans toucher à aucun contrat existant.

**Légende des niveaux de preuve :**
- **[V]** : vérifié dans le code ;
- **[D]** : déduit du comportement attendu de PostgreSQL ;
- **[NE]** : non vérifié par exécution ;
- **[EXT]** : dépend d'un service ou d'une documentation externe.

---

## 1. Fichiers et fonctions examinés

| Fichier | Ce qui a été lu |
|---|---|
| `40-…fondation.sql` | Table `communication_arret` et ses 3 contraintes (l. 176-197) ; déclencheur de ligne permanente (l. 200-212) ; `communication_verrou_interrupteurs` (l. 331) ; `communication_interrupteur_ferme` ; la porte `communication_autoriser_sortie` (l. 379-411) ; `communication_sortie_autorisee` ; `communication_etat_consentement` (l. 590) ; `communication_supprimee` (l. 660) |
| `41-…consentement.sql` | `communication_conclure_arret` (l. 903-957) ; `arreter_communications` (l. 960-1018) ; `confirmer_arret_communications` (l. 1024) ; `communication_confirmer_arret_auto` (l. 1058-1076) ; `etat_arret_communications` ; `lever_arret_communications` (l. 1098-1135) ; déclencheur `communication_suivre_client` (l. 278-380) |
| `42-…campagnes.sql` | `communication_raison_exclusion` (l. 507-570) ; `changer_statut_campagne`, branche `annuler` (l. 840, 951-963) ; table `communication_destinataires` (l. 989-1000) |
| `43-…envoi.sql` | Table `communication_evenements_fournisseur` (l. 1250-1269) ; `communication_mot_simple`, `communication_est_stop` (l. 1279-1300) ; **`communication_recevoir_evenement` en entier** (l. 1338-1597) ; `relancer_envoi_communication` (l. 1671-1700) ; `communication_purger_personne_suite` (l. 1800-1830) ; préparation de l'audience dans `communication_preparer` (l. 781-812) ; `communication_en_transmission`, `communication_observer_sorties`, `communication_transmissions_en_cours` (l. 1863-1932) ; début de la procédure `traiter_communications` (l. 1151-1175) |
| Rapport final | §6 et §11 de `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` ; rapport du relecteur (RF-01 à RF-19) |
| Contrats existants (`main` et copie du Mac) | Empreintes identiques des deux côtés pour `supabase.sql`, `supabase-notifications.sql`, `supabase-courriel-colis.sql`, `-pied.sql`, `-reseaux.sql` et `migrations.txt`. Les 2 commits de `main` absents de la branche (pages SEO) ne touchent **aucun** fichier SQL. |

---

## 2. Preuves

### 2.1 RF-01 : la demande d'arrêt peut être annulée **[V]**

Déroulement actuel de `arreter_communications` : **une seule transaction**, celle de l'appel RPC.

1. Permission `communications.pause`, puis contrôle du motif.
2. N0 exclusif (3 s) dans un bloc d'exception. Un délai dépassé donne `v_n0 = false`.
3. Ligne d'arrêt `FOR UPDATE` (2 s). Un délai dépassé donne `STOP_NOT_CONFIRMED` : rien n'est écrit, et c'est honnête.
4. `lock_timeout = '0'` (l. 998).
5. **L'appui est écrit** (`derniere_demande_le`, l. 1001), puis journalisé.
6. **La demande est écrite** (`etat = 'arret_demande'`, l. 1006-1013), puis journalisée.
7. **Le constat** `communication_conclure_arret(v_n0)` (l. 1016) : **aucun bloc `exception` autour.**

Toute erreur levée à l'étape 7 annule les étapes 5 et 6. Causes possibles :
- **lectures de pg_net** (`net.http_request_queue`, `net._http_response`, 43 l. 1868-1871) : une erreur si le schéma `net` change ou manque **[V]** ;
- **délai d'exécution du rôle** (8 s, rapporté **[EXT]**), avec 3 s + 2 s déjà consommés possibles **[V]** ;
- **contrainte de la table** : `autorisations_closes_le >= demande_le` et `confirme_le >= autorisations_closes_le` (40 l. 194-196), écrits avec `clock_timestamp()` (41 l. 937, 950). Un recul de l'horloge du serveur viole la contrainte **[V]**, et ce recul est possible **[D]** ;
- **annulation** (`pg_cancel_backend`), ou coupure du client avant le COMMIT **[D]**.

**Conséquence :** la ligne reste à `actif`. La porte continue d'autoriser les envois (40 l. 396 : elle ne lit que l'état validé), et l'écran ne reçoit qu'une erreur.

`confirmer_arret_communications` et `communication_confirmer_arret_auto` ont le même schéma, mais elles n'écrivent pas la demande : leur échec ne perd rien **[V]**.

### 2.2 RF-02 : deux retours fournisseur peuvent s'interbloquer **[V] pour l'ordre, [D] pour le blocage**

`communication_recevoir_evenement` traite tout dans une seule transaction, avec `SET lock_timeout = '5s'` (l. 1341). Ordre réel des verrous :

1. Hors message entrant : ligne d'éclat `communication_webhook_debit` (un sur 8), tenue jusqu'au COMMIT (l. 1389-1391).
2. **INSERT dans `communication_evenements_fournisseur`** (l. 1444), dont la colonne `envoi_id` a une **clé étrangère** vers `communication_envois` (l. 1257). PostgreSQL pose alors **`FOR KEY SHARE` sur la ligne d'envoi** **[D]**.
3. Campagne `FOR UPDATE` (N1, l. 1525).
4. N3, si l'événement peut retirer un consentement (l. 1528-1530).
5. Envoi `FOR UPDATE` (N4, l. 1531). **Ce verrou entre en conflit avec le `KEY SHARE` d'une autre transaction** **[D]**.

**Cycle type** : W1 (`delivered`) et W2 (`read`) arrivent pour le même message, dans des éclats différents (7 cas sur 8).
- Les deux passent l'étape 2 : chacune tient `KEY SHARE` sur l'envoi E.
- W1 prend la campagne ; W2 attend la campagne.
- W1 demande E en `FOR UPDATE` et attend le `KEY SHARE` de W2.
- **Cycle.** PostgreSQL annule l'une des deux (40P01) **[D]**.
- Sans campagne (envoi de confirmation), le cycle est direct, à l'étape 5.

**Autres cycles :**
- avec `relancer_envoi_communication` : E en `FOR UPDATE` (l. 1686), puis INSERT qui pose `KEY SHARE` sur la campagne (clé étrangère `campagne_id`), dans l'ordre inverse du webhook **[V]** + **[D]** ;
- **RF-05** : un STOP insère la suppression (l. 1466), **puis** prend N3 (l. 1472). Le code 131050 prend N3 (l. 1529), **puis** insère la même suppression (l. 1545). C'est un cycle par l'index unique **[V]** + **[D]**.

**Comment une plainte ou une désinscription se perd.**
- L'annulation défait **tout**, y compris la ligne d'anti-rejeu de l'étape 2 **[V]**. Le retour n'est donc pas perdu *dans la base*. Il est rejoué seulement si :
  - la fonction Edge (pas encore écrite) répond une 5xx ;
  - **et** le fournisseur réessaie **[EXT]**. C'est rapporté pour Meta, incertain pour Brevo.
- Une attente de plus de 5 s (55P03) a le même effet.
- **Rien ne garde la trace d'un échec définitif** : c'est une perte silencieuse possible.

### 2.3 Problèmes moyens **[V]**

- **STOP** : `communication_est_stop` (l. 1291) compare le message **entier** normalisé à 13 mots. « Stop please » n'est pas reconnu, « STOP » l'est.
- **Doublons** : l'unicité de l'audience est `(campagne_id, client_id, canal)` (42 l. 1000). L'insertion de `communication_preparer` (43 l. 790-798) ne dédoublonne pas par `cible_empreinte`. Deux comptes avec le même numéro recevront donc deux envois, avec deux clés différentes (`campagne:<c>:<destinataire>`). La revérification à l'envoi (43 l. 990) ne compare pas les envois entre eux. Rappel : 2 numéros sont partagés en production, d'après le relevé agrégé du 20/11/2026.

---

## 3. Proposition pour P-07 : une demande d'arrêt qui survit à tout

**Principe : séparer la demande et le constat en deux transactions.** Écrire la demande ne requiert **pas** N0 : la porte prend N0 partagé **puis** relit l'état (40 l. 395-396). Toute porte qui lit après le COMMIT de la demande refuse donc **[V]** + **[D]**. Le verrou N0 exclusif ne sert qu'à **prouver** que les portes ouvertes avant la demande sont terminées, c'est-à-dire au constat.

### 3.1 Nouvelle fonction `demander_arret_communications(p_motif)` (brouillon 41)

- `communications.pause` (administrateur, gérant) ; motif d'au moins 5 caractères ; `synchronous_commit = on`.
- **Aucun N0.** Seule la ligne d'arrêt est prise en `FOR UPDATE`, `lock_timeout` de 5 s. Si le délai est dépassé : `STOP_NOT_CONFIRMED / ARRET_CONCURRENT_EN_COURS`, rien n'est écrit, et l'écran réessaie seul.
- `derniere_demande_le`, le journal, puis, si l'état est `actif`, `arret_demande`. Une `version` est incrémentée (voir 3.3).
- Elle ne fait **rien d'autre** : ni pg_net, ni observation, ni constat. Il reste peu de causes d'échec : la ligne, `auditer`, le délai.
- Elle répond `STOP_REQUESTED`, et la transaction RPC valide la demande.
- Avantage de plus : plus aucune attente exclusive de 3 s qui bloque toutes les portes (l'hypothèse H6 de la revue).

### 3.2 Le constat reste `confirmer_arret_communications()`, rendu tolérant

- Ordre inchangé : N0 exclusif (3 s), puis la ligne (2 s).
- `communication_conclure_arret` est appelé **dans un bloc** `begin … exception when others or query_canceled then … end`. En cas d'erreur, on note `derniere_raison = 'CONSTAT_IMPOSSIBLE'` et le SQLSTATE, puis on répond `STOP_PENDING`. La demande est déjà validée dans la transaction précédente.
- Dans `conclure`, les horodatages deviennent `greatest(clock_timestamp(), demande_le)` et `greatest(clock_timestamp(), autorisations_closes_le)` : un recul d'horloge ne viole plus la contrainte.
- **L'écran enchaîne** : `demander_…`, puis `confirmer_…` toutes les 2 à 5 s jusqu'à `STOP_CONFIRMED`. Le travailleur, de son côté, confirme au début de chaque passage (`communication_confirmer_arret_auto`, inchangée).
- `arreter_communications` peut rester comme raccourci (demande, puis constat protégé par le même bloc). Mais **seul l'enchaînement en deux appels garantit** la demande face à une coupure du client ou à un échec du COMMIT **[D]**. L'interface de la Phase 2c doit donc utiliser les deux appels.

**Écartés** :
- une transaction autonome (`dblink`, `pg_background`) : extension et identifiants en plus ;
- un COMMIT dans une procédure : impossible par RPC.

### 3.3 États et concurrence

| Transition | Qui | Verrous | Garantie |
|---|---|---|---|
| `actif` → `arret_demande` | `demander_…` | ligne seule | Toute porte qui lit après le COMMIT refuse **[D]** |
| `arret_demande` → `arret_confirme` | `confirmer_…`, travailleur | N0 exclusif → ligne | Inchangé : contrainte, et zéro transmission en cours |
| `arret_confirme` → `arret_confirme` | `demander_…` | ligne | Seul `derniere_demande_le` change |
| `arret_*` → `actif` | `lever_…` | N0 exclusif → ligne | **Modifié** : elle reçoit `p_version_attendue`, la version **affichée à l'écran**, et refuse si la ligne a changé depuis |

**Course demande / levée** (constat nouveau de cette analyse).
- Aujourd'hui, une demande qui a écrit son appui juste **avant** le début de la levée, mais l'a validé **pendant** l'attente de la levée, passe le contrôle `derniere_demande_le > v_debut` (41 l. 1119) **[V]**. La levée défait alors un arrêt que l'administrateur ne pouvait pas voir.
- Ce défaut existait déjà ; ce ne sont pas les corrections qui le créent.
- La version attendue ferme ce cas, et ferme aussi IR3-07 (constat L4).
- Pas d'interblocage : la demande ne prend que la ligne, et la levée prend N0 puis la ligne. Il y a un seul verrou commun, donc pas de cycle **[D]**.

### 3.4 Garanties que les essais devront démontrer

- **G1, demande durable** : après un COMMIT de `demander_…`, l'état ne vaut jamais `actif`, sauf par une levée. Cela doit tenir avec : `pg_cancel_backend` pendant le constat, `statement_timeout = 1s`, le schéma `net` renommé, un recul d'horloge simulé (horodatages truqués dans une copie de banc), une migration rejouée qui tient la ligne.
- **G2** : aucune porte n'autorise après avoir lu `arret_demande`.
- **G3** : `arret_confirme` n'est atteint qu'avec N0 exclusif et zéro transmission. C'est inchangé.
- **G4** : une levée ne défait jamais une demande que son écran ne montrait pas.
- **G5** : aucun interblocage entre demande, confirmation, levée, porte et travailleur, sur 10 000 entrelacements.

---

## 4. Proposition pour P-08 : retours fournisseurs sans interblocage ni perte silencieuse

### 4.1 Deux temps : réception durable, puis traitement

**Temps A, `communication_recevoir_evenement` (court, toujours validé) :**
- forme, débit, signature : inchangés ;
- l'envoi visé est retrouvé par une **lecture sans verrou** ;
- pour un message entrant, l'empreinte du numéro et la **classe** du message sont calculées tout de suite : stop, confirmation avec son code, ou autre. **Le texte brut n'est jamais gardé** (minimisation IR-07 conservée) ;
- INSERT dans `communication_evenements_fournisseur`, avec `on conflict … do nothing` (anti-rejeu inchangé) ;
- **la clé étrangère sur `envoi_id` est retirée** ; la colonne et son index sont gardés. Les envois ne sont jamais effacés, seulement anonymisés (43 l. 1810-1816) **[V]**, donc la clé n'apporte rien à l'intégrité, et c'est elle qui pose le `KEY SHARE` caché ;
- **le traitement est tenté tout de suite, dans un bloc** `begin … exception when others then …`. Un 40P01, un 55P03 ou toute autre erreur n'annule que ce bloc **[D]** : l'événement reste écrit, son état passe à « à reprendre », et la fonction répond `ok`. Le fournisseur n'a donc pas besoin de réessayer.

**Temps B, le traitement :**
- une nouvelle table `communication_evenements_traitement` contient l'identifiant de l'événement, son état (`a_traiter`, `traite`, `echec`), le nombre de tentatives, le dernier code et les dates. **Elle ne contient aucune donnée personnelle.** C'est une table à part parce que `communication_evenements_fournisseur` reste **immuable** (déclencheur l. 1266) ;
- le travailleur reprend les événements `a_traiter` en `FOR UPDATE SKIP LOCKED`, par identifiant croissant, une transaction chacun ;
- après N tentatives : `echec`, compté dans `sante_communications`, et une alerte.

### 4.2 Un seul ordre de verrous pour tous les chemins qui touchent un envoi

Ordre : **N1** (campagne), seulement si l'action modifie la campagne ou crée un envoi (`pause_campagne`, `reporter_destinataire`) → **N3** (consentements, par client croissant) → **N4** (envoi, `FOR UPDATE`) → **ensuite seulement**, les écritures dans `communication_suppressions` et `communication_consentements`.

Corrections, toutes dans le brouillon 43 :
- **Statuts courants** (`sent`, `delivered`, `read`) : plus de N1. Cela supprime aussi la file d'attente de tous les retours d'une campagne derrière sa ligne.
- **STOP entrant (RF-05)** : N3 pour tous les clients du numéro, **avant** l'insertion de la suppression.
- **`relancer_envoi_communication`** : la campagne (N1), **puis** l'envoi.
- **Purge d'une personne** : ordre déjà correct (N2 → N3 → envois croissants). Le `NOWAIT` suggéré par le relecteur, suivi de `PURGE_RETRY`, reste facultatif.
- **En-tête de 43** (l. 1333-1335, « ordre unique ») : le texte devra décrire l'ordre réel.

**Pourquoi il n'y a plus de cycle [D] :**
- aucun chemin ne tient l'envoi avant N1 ou N3 ;
- plus aucun verrou caché n'est posé, faute de clé étrangère ;
- l'index unique des suppressions n'est touché qu'après N3, dans tous les chemins.

Si un cycle subsistait malgré tout, il serait **rattrapé** par le bloc du temps A et par la reprise du temps B. Ce serait un retard, jamais une perte.

### 4.3 Garanties

- **Jamais perdu en silence** : un événement signé et validé reste en base jusqu'à `traite` ou `echec` visible, avec alerte.

  Seul cas restant : la transaction du temps A elle-même échoue (coupure, délai). L'événement n'est alors pas enregistré, la fonction Edge doit répondre une 5xx, et l'on dépend des réessais du fournisseur **[EXT]**. Ce temps A ne fait qu'une insertion et une lecture : le risque est faible.
- **Idempotence** :
  - l'unicité `(fournisseur, evenement_id)` est inchangée ;
  - le traitement est verrouillé par sa ligne de suivi et ne s'applique qu'une fois ;
  - les écritures gardent `on conflict do nothing`.
- **Traçabilité** : événement immuable, plus l'historique du traitement (tentatives, codes).
- **Un STOP reçu pendant un envoi** : `communication_raison_exclusion` est revérifiée avant chaque envoi (43 l. 990) **[V]**.
- **Délai d'application** : un STOP traité tout de suite au temps A ne dépend de la reprise du travailleur (chaque minute) qu'en cas d'échec.

---

## 5. Les deux problèmes moyens

### 5.1 STOP (P-09)

Une nouvelle fonction `communication_classer_entrant(texte)` répond `stop`, `confirmation` ou `autre`, après normalisation (`communication_mot_simple`, inchangée). Les règles :

1. **Message entier** égal à un mot ou une phrase d'une **liste fermée**, dans les quatre langues : les 13 mots actuels, plus `QUIT`, `END`, `REVOKE`, `OPT OUT`, `OPTOUT`, `STOP PLEASE`, `STOP ALL`, `ARRETER LES MESSAGES`, `NE PLUS RECEVOIR`, `DESINSCRIVEZ MOI`, `KANPE VOYE MESAJ`, `NO MAS`, `DARSE DE BAJA`…
2. **Premier mot** égal à un mot d'arrêt **et** message court (5 mots au plus) **et** aucune négation (`NE`, `PAS`, `NO`, `NOT`, `PA`). Cela couvre « Stop please » et « Stop les pubs ».
3. **Bouton de désinscription de Meta** (charge structurée, pas du texte) : toujours `stop`.
4. **Jamais** sur une simple mention : « mon colis s'est arrêté » ou « pourquoi le stop à Miami ? » ne déclenchent rien.
5. **Ambigu** (un mot d'arrêt ailleurs, ou un message long) : on ne désinscrit pas. On garde un compteur, sans le texte, pour la revue humaine.

**À valider par le juriste [EXT]** : la liste, et l'obligation américaine d'honorer une révocation « par tout moyen raisonnable », avec ses mots imposés (STOP, QUIT, END, REVOKE, OPT OUT, CANCEL, UNSUBSCRIBE). Cette règle est citée de mémoire : à confirmer.

### 5.2 Doublons de contact (P-05)

- **Au calcul de l'audience** (43 l. 781-812) : parmi les retenus, un seul par `(canal, cible_empreinte)`, avec `distinct on` et le plus petit identifiant client gardé. Les autres sont comptés dans `exclusions` sous `canal:CONTACT_EN_DOUBLE`, sans identifiant gardé (IR-07 respecté).
- **Garantie en base** : un index unique partiel sur `communication_destinataires (campagne_id, canal, cible_empreinte) where retenu and cible_empreinte is not null`. La purge met l'empreinte à null : l'index n'empêche donc pas l'effacement **[V]**.
- **À l'envoi** (`communication_traiter_un`) : si un autre envoi de la même campagne, vers la même empreinte, est déjà `traitement`, `envoye`, `livre`, `lu` ou `incertain`, l'envoi passe à `supprime / CONTACT_EN_DOUBLE`. Ce contrôle couvre un contact devenu commun après le gel de l'audience.
- **Pour l'e-mail** : même règle. Aujourd'hui, 0 e-mail est partagé.
- **Consentement** : il est vérifié **par client**. Le compte gardé est le premier compte **consentant**, car le dédoublonnage se fait après `communication_raison_exclusion`. Un STOP depuis le numéro bloque les deux comptes : comportement inchangé (40 l. 660).

---

## 6. Régression, sécurité et dépendances

| Point | Effet des corrections | Niveau |
|---|---|---|
| Séparation marketing / transactionnel | Aucune lecture, écriture ou redéfinition de `notifications`, `notification_envois`, `messages_recents`, `expedier_envoi`, `courriel_gabarit`. Toutes les modifications sont dans des objets `communication_*` des brouillons. | [V] contrats identiques ; [NE] non-régression (F-T01) |
| Permissions | `demander_arret_communications` : `communications.pause` (administrateur, gérant). Fonctions du travailleur et de la table de traitement : fermées à tous, `service_role` compris. **Aucune nouvelle permission**, `permissions_du_role` inchangée, l'employé n'a toujours rien. | [V] conception |
| RLS, `SECURITY DEFINER` | Nouvelle table : RLS activée, `revoke all`, aucune règle. Nouvelles fonctions : `security definer`, `search_path = ''`, chaque `revoke` juste après la création (RF-08 / RF-16). Rien d'ouvert aux visiteurs : liste blanche de `controle-securite.sql` inchangée. | [V] conception |
| Consentement, suppression, conservation | Le temps A ne garde ni le texte, ni le numéro en clair. La table de traitement ne garde aucune donnée personnelle, et la purge d'une personne doit en effacer les codes. Retirer la clé étrangère ne change pas la purge, qui passe par `envoi_id` (l. 1806-1809). | [V] code de la purge ; durées : juriste |
| PostgreSQL **[D]** | `KEY SHARE` posé par une clé étrangère ; 40P01, 55P03 et `query_canceled` rattrapables en PL/pgSQL ; verrous consultatifs et sous-transactions ; file d'attente des verrous ; lecture validée ; `distinct on` et index partiels | à éprouver |
| pg_net **[EXT]** | H4 et H4′ inchangées par ces corrections. Le constat tolère maintenant un schéma `net` absent. | F-K05, F-K09 |
| Fournisseurs **[EXT]** | Réessais de Meta et de Brevo ; forme du bouton de désinscription | Phase 3 |

---

## 7. Essais de concurrence indispensables

Tous restent à faire, sur une base jetable et après autorisation écrite.

**Outil recommandé :** `isolationtester`, le banc d'entrelacements de PostgreSQL, qui donne des ordres déterminés pas à pas. À défaut, un banc Python à deux ou trois connexions, avec barrières (`pg_advisory_lock` de banc), répété 1 000 à 10 000 fois.

| Essai | Scénario | Réussi si |
|---|---|---|
| F-K10 (étendu) | Demande validée, puis constat interrompu : annulation, délai, `net` renommé, horloge truquée, migration rejouée | G1 : état ≠ `actif` dans tous les cas |
| F-K11 (nouveau) | Demande et levée entrelacées pas à pas, dont « appui avant le début de la levée, validé pendant son attente » | G4 : la levée refuse si la version a changé ; aucun 40P01 |
| F-K01 à F-K03, F-K08 | Inchangés ; plus la demande sans N0 face à des portes ouvertes | G2, G3 |
| F-W01 | `sent`, `delivered` et `read` simultanés pour le même envoi, avec ou sans campagne | 0 erreur 40P01 visible ; 3 événements traités ; statut final `lu` |
| F-W02 | STOP entrant et code 131050, même numéro | 0 cycle ; une seule suppression active |
| F-W04 (nouveau) | Retour en même temps qu'une relance, une purge d'une personne, l'annulation d'une campagne ou le travailleur | Aucun cycle ; si une attente dépasse 5 s, l'événement est repris, jamais perdu |
| F-W05 (nouveau) | Erreur forcée dans le traitement (déclencheur de banc), puis reprise | L'événement reste `a_traiter`, il est traité **une seule fois** ensuite, puis `echec` visible après N tentatives |
| F-W03 | Phrases d'arrêt réelles et phrases pièges | 100 % des demandes d'arrêt reconnues ; 0 faux positif retenu par le juriste |
| F-C06 et F-C08 (nouveau) | Contact partagé au gel ; contact devenu partagé après le gel | 1 envoi par empreinte et par campagne |
| F-T01, F-T02, F-M02 | Non-régression du transactionnel ; chaîne 40 → 43 dans une seule transaction | 0 différence |

---

## 8. Plan de correction ordonné

Rien ne sera fait sans l'autorisation écrite de la CEO.

1. **P-07** (brouillon 41) :
   - `demander_arret_communications` ;
   - le bloc de protection dans `confirmer_…` et `arreter_…` ;
   - `greatest()` dans `communication_conclure_arret` ;
   - la `version` et `p_version_attendue` dans `lever_…`, plus la colonne dans 40 `communication_arret` ;
   - P-03 : `lock_timeout` borné partout où N0 exclusif est pris ;
   - P-02 : commentaires.
2. **P-08** :
   - **brouillon 43** : clé étrangère retirée, table `communication_evenements_traitement`, temps A et temps B dans `communication_recevoir_evenement`, nouvelle étape de la procédure `traiter_communications`, ordre du STOP (RF-05), `relancer_envoi_communication`, en-tête des verrous ;
   - **brouillon 40** : `sante_communications` (compteurs), purge de la table de traitement.
3. **P-09** (brouillon 43) : `communication_classer_entrant`, liste à faire valider.
4. **P-05** (brouillons 42 et 43) : index unique partiel ; `distinct on` dans `communication_preparer` ; contrôle à l'envoi.
5. **Documents** : `PHASE_1_3_1_KILL_SWITCH_DESIGN.md`, la preuve des verrous, le plan d'essais (ajout de F-K11, F-W04, F-W05, F-C08) et `README.md`.
6. **Revue indépendante** de ces seules corrections, puis Phase 2 sur base jetable, si la CEO l'autorise.

---

## 9. Complexité et validations humaines

| Correction | Ampleur estimée | Risque |
|---|---|---|
| P-07 | Faible : environ 100 lignes, 1 fonction nouvelle, 4 modifiées | Moyen : c'est le cœur de l'arrêt |
| P-08 | **Moyenne à élevée** : environ 300 à 400 lignes ; refonte d'une fonction de 260 lignes ; 1 table ; 1 étape du travailleur | Élevé : concurrence |
| P-09 | Faible | Juridique, plus que technique |
| P-05 | Faible | Faible |
| Banc de concurrence | **Le plus gros morceau** | — |

En ordre de grandeur, et sans engagement : 1 à 2 jours pour P-07 et P-05, 2 à 4 jours pour P-08, 2 à 4 jours pour le banc d'essais.

**Validations humaines nécessaires :**
- **un spécialiste de PostgreSQL** : verrous des clés étrangères, rattrapage de 40P01, 55P03 et `query_canceled` en sous-transaction, file d'attente des verrous consultatifs, specs `isolationtester` ;
- **pg_net** : H4 et H4′ ;
- **le juriste** : liste des mots d'arrêt, révocation aux États-Unis et en Floride, conservation de la table de traitement ;
- **la CEO** : décision S-1 (authentification de la fonction Edge), comportement attendu de l'écran (deux appels, réessai automatique).

---

## 10. Contrôle final

| Question | Réponse |
|---|---|
| Workspace inchangé ? | **Oui.** Copie du Mac : commit `2e9cc9f`, branche `ccr-056ddc8c-m7u4p1`, 0 fichier modifié, 0 *stash*. Seules des lectures y ont été lancées (`sed`, `grep`, `shasum`, `git rev-parse` et `status`). |
| Fichiers créés ? | **Aucun dans le dépôt**, ni sur le Mac ni dans la copie de la session. Ce fichier a été créé ensuite, à la demande écrite de la CEO, puis rangé dans `docs/communication-center/` à sa demande. |
| Commit analysé | `2e9cc9f1d3c1fbe0b2178634ef32112cc47ed431` |
| Identique au commit annoncé ? | **Oui**, sur le Mac comme dans la copie de la session. Empreintes des 4 brouillons identiques des deux côtés. |
| Écarts entre le rapport final et le code ? | **Aucun écart sur les faits.** Les lignes citées pour RF-01, RF-02 et RF-03 correspondent au code. Les en-têtes de 41 (l. 898-899) et de 43 (l. 1333-1335) restent faux, comme le rapport le signale déjà (P-02 et RF-02). **Un point nouveau** : la course demande / levée du §3.3, qui existait déjà. |
| P-07 et P-08 faisables sans toucher aux contrats existants ? | **Oui [V].** Tout reste dans les objets `communication_*` des brouillons 40 à 43. Aucun fichier de `outils/`, aucune table ni fonction transactionnelle, aucune permission. |
| Écart à signaler | Dans la copie **de la session** (pas sur le Mac), un `git fetch` de la branche et de `main` a été lancé. Il n'a mis à jour que des références distantes : aucune branche locale, aucun fichier. |

---

**Aucune correction n'a été faite. Aucune Phase 2 n'est autorisée par ce document.**

**ANALYSE TERMINÉE — EN ATTENTE DE L'AUTORISATION ÉCRITE DE LA CEO**
