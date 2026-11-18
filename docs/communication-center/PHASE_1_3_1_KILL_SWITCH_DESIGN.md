# Centre de communication — Phase 1.3.1 : conception de l'arrêt d'urgence

**Date** : 18/11/2026 · **Remplace** : l'arrêt d'urgence de la Phase 1.3 (`arreter_communications` avec repli sans verrou).

> **Rien n'a été exécuté.** Ce document décrit la conception et en donne la démonstration logique. Les essais qui la prouveront (T-01 à T-02, T-01B à T-01E) sont dans `PHASE_1_3_1_TEST_PLAN.md`, **NON EXÉCUTÉS**.
>
> Les faits sur PostgreSQL et pg_net sur lesquels la démonstration s'appuie sont listés au §8 avec leur statut : **rapporté**, et **à éprouver**.

---

## 1. Le défaut de la Phase 1.3 (confirmé)

`arreter_communications` (Phase 1.3, 41 §4.8) faisait trois choses :
1. elle tentait N0 en exclusif pendant 5 s ;
2. en cas d'échec, elle écrivait `arret_urgence = true` **quand même** ;
3. elle répondait `ok: true`.

Une transaction d'envoi pouvait avoir lu « actif » sous N0 partagé, puis valider son envoi **après** cette écriture. La réponse `ok` était donc fausse.

Le retour de fournisseur « pause du canal » (43, `communication_recevoir_evenement`) faisait la même chose.

---

## 2. Principe corrigé

**Un arrêt n'est déclaré réussi (`STOP_CONFIRMED`) que sur preuve.** Trois conditions doivent être réunies :

1. **Fermeture des autorisations** : N0 a été obtenu en **exclusif** dans la transaction qui écrit la demande, ou dans une transaction **postérieure** à sa validation. L'instant est noté dans `autorisations_closes_le`.
2. **Fin des transmissions** : aucune requête déjà validée n'est encore entre les mains de pg_net (`communication_transmissions_en_cours() = 0`).
3. **Durabilité** : l'état est écrit avec `synchronous_commit = on`.

Sinon, la réponse est l'une des deux suivantes, sans jamais « confirmé » :

| Réponse | Sens | État en base |
|---|---|---|
| `STOP_PENDING` | La demande est **durablement écrite**. Toute transaction qui la lit refuse d'autoriser. L'arrêt n'est **pas prouvé** : la raison est `VERROU_NON_OBTENU` ou `TRANSMISSIONS_EN_COURS`. | `arret_demande` |
| `STOP_NOT_CONFIRMED` | Cet appel n'a rien pu écrire, parce qu'un autre arrêt ou une levée tient la ligne. Il faut réessayer. | inchangé |
| `STOP_CONFIRMED` | Les trois conditions sont prouvées. | `arret_confirme` |

**Le délai ne contourne jamais le verrou.** Quand il expire, l'état reste `arret_demande`. L'arrêt se termine proprement par une **nouvelle tentative**, selon la même règle et le même ordre des verrous :
- `confirmer_arret_communications()`, bouton de l'écran, permission `communications.pause` ;
- `communication_confirmer_arret_auto()`, au début de **chaque** passage du travailleur, par une tentative non bloquante de N0 exclusif.

---

## 3. Inventaire des sorties (fait sur le code)

Les seules requêtes sortantes du Centre sont des appels pg_net :

| Fonction qui dépose la requête | Ligne (brouillon 1.3.1) | Appelée par | Passe par la porte ? |
|---|---|---|---|
| `communication_appel_email` (Brevo, Resend) | 43 §5, `net.http_post` | `communication_traiter_un` seulement | **Oui** : `communication_autoriser_sortie(nature, 'email')`, **puis** vérification `communication_sortie_autorisee()` dans la fonction d'appel |
| `communication_appel_whatsapp` (Meta) | 43 §5, `net.http_post` | `communication_traiter_un` seulement | **Oui**, même double contrôle |
| `communication_demander_modele_meta` (lecture d'un modèle) | 42 §2, `net.http_get` | `communication_rafraichir_modeles_meta` (43 §8.2 bis) | **Oui** : nature `lecture_meta`, même double contrôle |

**Aucune autre** fonction de 40 à 43 n'appelle `net.http_*` (recherche dans les quatre fichiers).

Les fonctions qui **préparent** sans rien déposer ne prennent **pas** N0 :
- le lancement (`communication_preparer`) ;
- la relance manuelle (`relancer_envoi_communication`) ;
- le report (`reporter_destinataire`) ;
- la mise en file d'une confirmation.

Elles créent des lignes `attente` qui passeront **une à une** par la porte. La contrainte est **vérifiée dans le code**, pas seulement convenue : une fonction d'appel lève `SORTIE_NON_AUTORISEE` si la transaction n'est pas passée par la porte (`goship.sortie_autorisee = txid_current()`).

**Le point d'autorisation** est `communication_autoriser_sortie` (40 §3). Ce que fait la porte :
1. elle prend N0 **partagé**, tenu jusqu'au COMMIT ou à l'annulation ;
2. **ensuite seulement**, elle lit `communication_arret.etat` et les réglages. C'est une requête postérieure à l'obtention du verrou, donc un nouvel instantané en lecture validée ;
3. elle décide.

C'est **le dernier contrôle qui compte** pour l'arrêt. La relecture sous N5 (`communication_reserver`) est une défense supplémentaire, pas l'argument de sûreté.

---

## 4. Modèle de verrouillage

| Niveau | Verrou | Mode |
|---|---|---|
| N0 | consultatif `interrupteurs` | partagé : la porte, seulement. Exclusif : arrêt, confirmation, levée, réglages d'envoi (`regler_communications`, quota, numéro, issues HTTP) |
| N0a | la ligne `communication_arret` (FOR UPDATE) | fonctions d'arrêt seulement, **après** N0 |
| N1 → N5 | campagne, client, consentement, envoi, compteurs | inchangés (Phase 1.3) |

**Ordre des fonctions d'arrêt** : N0 (exclusif, tenté), **puis** N0a. Aucune ne prend N0a avant N0, ni une autre table.

La porte ne verrouille **pas** N0a : elle lit `communication_arret` sans verrou (MVCC). Un arrêt n'attend donc jamais une porte pour la ligne, et une porte n'attend jamais un arrêt pour la ligne. Elle n'attend que N0, dans le sens prévu.

**Point de linéarisation de l'arrêt** : l'instant **G** où N0 est accordé en exclusif à une transaction qui tient (ou suit) la demande. Il est noté `autorisations_closes_le`, et devient visible à la validation de cette transaction.

**Point d'effet garanti** : le COMMIT **C** de la transaction qui passe l'état à `arret_confirme`. C'est seulement à ce moment qu'on répond `STOP_CONFIRMED`.

---

## 5. Démonstration

**Hypothèses** (§8) :
- (H1) une transaction autorisée tient N0 partagé de la porte à son COMMIT ;
- (H2) en lecture validée, une requête lancée après l'obtention d'un verrou voit toute transaction validée avant cette obtention, parce que PostgreSQL rend une validation visible avant de relâcher ses verrous ;
- (H3) pg_net n'envoie une requête qu'après le COMMIT de la transaction qui l'a déposée, et jamais si elle est annulée ;
- (H4) pg_net applique `timeout_milliseconds` à un appel en cours.

**Propriété 1** : aucune transaction ne valide une autorisation après G.

À l'instant G, N0 est accordé en exclusif : aucune transaction ne tient N0 partagé (incompatibilité des modes). Toute transaction autorisée **avant** G a donc déjà fini, par validation ou annulation (H1).

Une transaction T qui demande N0 partagé **après** G ne l'obtient qu'après la fin de la transaction X qui tient l'exclusif. Deux cas :
- X a validé la demande, ou la demande avait été validée avant G ;
- X a été annulée, auquel cas `autorisations_closes_le` n'est pas écrit et G ne compte pas.

T lit ensuite l'état par une requête postérieure à l'obtention du verrou. Par H2, elle voit `arret_demande` ou `arret_confirme`. La porte refuse.

**Propriété 2** : après C, aucune requête validée n'est encore en transmission.

À C, `communication_transmissions_en_cours() = 0` a été constaté **après** G. Par la propriété 1, aucune requête n'est déposée après G. Celles qui l'ont été avant G ont toutes, à ce moment, une réponse enregistrée ou un délai écoulé. Par H4, pg_net a alors terminé ou abandonné l'appel.

**Conclusion** : après un `STOP_CONFIRMED`, aucune transaction ne peut produire un nouvel envoi, et aucun envoi déjà autorisé n'est encore en route.

**Critère du CEO : satisfait, sous H1 à H4.**

---

## 6. Scénarios

Notation :
- W, W1, W2 : travailleurs (`communication_traiter_un`) ;
- S : `arreter_communications` ;
- K : `confirmer_arret_communications` ou la confirmation automatique.

**Scénario A — un travailleur commence un envoi avant la demande d'arrêt**
- **Verrous** : W tient N0 partagé, puis N1 à N5 et la ligne d'envoi. S demande N0 exclusif.
- **Ordre** :
  1. W passe la porte (« actif ») ;
  2. S attend N0 ;
  3. W dépose sa requête, valide et relâche tout ;
  4. S obtient N0 (G), écrit `arret_demande` et `autorisations_closes_le`, puis compte les transmissions : 1 (celle de W) ;
  5. S valide et répond `STOP_PENDING / TRANSMISSIONS_EN_COURS` ;
  6. pg_net transmet, puis la réponse de W arrive ;
  7. K constate 0 transmission et passe à `arret_confirme`.
- **Transactions actives à G** : aucune.
- **Autorisé** : le message de W part (autorisé avant G).
- **Interdit** : tout envoi autorisé après G.
- **Arrêt** : en attente, puis confirmé quand la transmission de W est terminée.
- **Doublon** : aucun. Si la réponse de W est perdue, W passe à `incertain` sans nouvel essai (scénario G).

**Scénario B — l'administrateur demande l'arrêt pendant qu'un travailleur tient N0 partagé**
- C'est le scénario A, vu du côté de S. S attend, au plus 5 s, la fin de **cette** transaction, qui ne porte qu'un envoi (quelques millisecondes).
- Les nouvelles demandes de N0 partagé, faites **après** celle de S, attendent derrière S (ordre d'arrivée des demandes, H5 à éprouver). Si H5 était fausse, de nouveaux envois pourraient être autorisés pendant l'attente de S. Ils sont **avant** G, donc légitimes, et S finirait en `STOP_PENDING` faute d'avoir obtenu le verrou. **Aucun faux « confirmé »** dans les deux cas.
- **Doublon** : aucun.

**Scénario C — le verrou exclusif n'est pas obtenu en 5 s**
- **Verrous** : une ou des transactions tiennent N0 partagé plus de 5 s. Un seul chemin le permet : une transaction longue de la porte, par exemple une lecture de modèles Meta lente ou une attente de verrou bornée à 2 s par `lock_timeout`. Le lancement de campagne ne prend plus N0 (1.3.1).
- **Ordre** :
  1. S abandonne l'attente, **sans** contourner le verrou ;
  2. S prend N0a et écrit `arret_demande` (durable) ;
  3. `communication_conclure_arret(false)` répond `STOP_PENDING / VERROU_NON_OBTENU`, avec un **indicatif** du nombre de verrous partagés détenus (`pg_locks`) ;
  4. S valide.
- À partir de là, toute porte qui obtient N0 lit `arret_demande` et refuse. Les transactions **déjà** autorisées peuvent encore valider : elles ont été autorisées avant que la demande ne soit visible.
- K, au plus tard au passage suivant du travailleur ou au clic suivant, obtient N0 (G) et prouve la fermeture. Il répond `STOP_CONFIRMED`, ou `STOP_PENDING / TRANSMISSIONS_EN_COURS` jusqu'à la fin des transmissions.
- **Interdit** : répondre `STOP_CONFIRMED` sans G. La contrainte de la table l'interdit aussi : `arret_confirme` exige `autorisations_closes_le`.
- **Doublon** : aucun.

**Scénario D — deux travailleurs réservent en même temps**
- **Verrous** : W1 et W2 tiennent chacun N0 partagé (compatibles), puis N1 à N4 sur leurs propres lignes, puis N5 (global, exclusif) l'un après l'autre.
- **Ordre** : W1 réserve sous N5 et valide. W2 obtient N5 et voit la réservation de W1 (H2).
- Si S arrive entre les deux : S attend la fin des deux transactions (elles tiennent N0 partagé), puis G.
- **Autorisé** : les deux envois, s'ils ont passé la porte avant G et respectent les plafonds.
- **Interdit** : un dépassement de plafond (sérialisation par N5), ou un envoi autorisé après G.
- **Doublon** : aucun (clé unique par campagne, client et canal ; relecture du statut sous N4).

**Scénario E — reprise d'une campagne après un arrêt confirmé**
- `changer_statut_campagne('reprendre')` reste possible pendant l'arrêt. C'est une transition de **statut**, qui ne dépose rien.
- **Ordre** : la campagne repasse `en_cours` ; W prend un de ses envois ; la porte lit `arret_confirme` et répond `ARRET_URGENCE` ; l'envoi reste `attente`.
- **Autorisé** : la reprise du statut.
- **Interdit** : tout envoi tant que `lever_arret_communications` (administrateur, motif) n'est pas validée.
- **Doublon** : aucun.

**Scénario F — un travailleur a réservé mais n'a pas encore appelé le fournisseur**
- La réservation (N5) et la requête pg_net sont dans **la même transaction**, sous N0 partagé. Il n'existe pas de réservation qui survive à sa transaction.
- **Ordre** : S attend. Soit W valide (réservation et requête ensemble, avant G), soit W est annulé (erreur ou délai de verrou) et rien ne reste : pas de réservation, pas de requête (H3).
- **Interdit** : une réservation validée sans requête qui partirait après G. Ce cas est impossible, parce que c'est la même transaction.
- **Doublon** : aucun.

**Scénario G — le fournisseur a accepté, la réponse réseau est perdue**
- **Ordre** :
  1. W a validé avant G ;
  2. pg_net transmet ;
  3. le fournisseur accepte, mais la réponse est perdue ou le délai expire ;
  4. `communication_lire_reponse` passe l'envoi à `incertain`, sans nouvel essai.
- Pour K, la transmission est terminée une fois le délai HTTP + 60 s écoulé, ou quand une réponse d'erreur est enregistrée. L'arrêt peut alors être confirmé.
- **Autorisé** : l'envoi incertain reste tel quel. Il est rapproché par les retours du fournisseur, ou clos après 72 h.
- **Interdit** : un renvoi automatique, ou une relance pendant l'arrêt. `relancer_envoi_communication` crée une ligne `attente` que la porte refuse.
- **Doublon** : possible **seulement** par une relance manuelle de l'administrateur, après la levée de l'arrêt et avec la case « risque de doublon » cochée. Ce point est inchangé.

---

## 7. Garanties et limites

**Garanties démontrées (sous H1 à H5)** :
1. `STOP_CONFIRMED` signifie qu'aucun envoi ne sera plus autorisé, et qu'aucun envoi autorisé n'est encore en route.
2. Un délai dépassé donne `STOP_PENDING`, jamais `STOP_CONFIRMED`. La table l'interdit aussi par contrainte.
3. Dès que `arret_demande` est validé, aucune porte qui l'obtient ensuite n'autorise rien.
4. Aucune sortie ne peut éviter la porte : les fonctions d'appel le vérifient elles-mêmes.

**Limites** :
1. **H1 à H5 ne sont pas éprouvées** (essais T-01B à T-01E, T-02).
2. Entre `STOP_PENDING` et `STOP_CONFIRMED`, des messages autorisés **avant** la demande peuvent encore partir. C'est le sens même de « en attente », et la réponse le dit.
3. Si pg_net est arrêté, une requête validée reste dans sa file : l'arrêt reste `STOP_PENDING / TRANSMISSIONS_EN_COURS`. C'est honnête, mais l'arrêt ne peut pas être confirmé tant que pg_net ne l'a pas traitée. **Vider la file de pg_net reste interdit** : elle est partagée avec le transactionnel.
4. La « pause du canal » déclenchée par un code de Meta n'est **pas** un arrêt confirmé : elle est écrite sans N0, au mieux, et journalisée comme telle. Seul l'arrêt d'urgence donne la garantie.
5. Un compte propriétaire de la base, dans le SQL Editor, peut tout contourner. C'est vrai pour tout le projet.

---

## 8. Faits sur lesquels repose la démonstration

| # | Fait | Statut | Essai |
|---|---|---|---|
| H1 | Un verrou consultatif de transaction est tenu jusqu'au COMMIT ou à l'annulation ; annulé avec une sous-transaction qui échoue | Documentation de PostgreSQL (rapporté) | T-01C |
| H2 | Lecture validée : chaque requête d'une fonction VOLATILE prend un nouvel instantané. Une validation est visible avant que ses verrous ne soient relâchés. | Documentation et comportement connu de PostgreSQL (rapporté) | T-01C, T-01D |
| H3 | pg_net n'envoie qu'après le COMMIT de la transaction qui a déposé la requête | Documentation de pg_net (rapporté) | T-01-bis, T-01C |
| H4 | pg_net applique `timeout_milliseconds` ; `net.http_request_queue` et `net._http_response` ont la forme supposée | À vérifier sur pg_net 0.20.4 | T-01E |
| H5 | Une nouvelle demande de verrou partagé attend derrière une demande exclusive déjà en attente | Gestionnaire de verrous de PostgreSQL (rapporté) | T-02 |
