# Centre de communication — Phase 1.3.1 (clôture) : preuve des verrous de l'arrêt d'urgence

**Objet** : la question posée par la direction. La documentation affirme que les fonctions d'arrêt ne prennent aucun verrou de table après N0 / N0a. Or `communication_conclure_arret()` appelle `communication_observer_sorties()`, qui modifie des lignes de `communication_envois` et de `communication_modeles_meta`.

**Code examiné** : commit `0693d5e`. Les brouillons SQL sont identiques au dernier commit de la branche (`git diff 0693d5e HEAD -- brouillons-sql/` est vide). Les lignes citées sont celles de ce commit.

> **Rien n'a été exécuté.** Cette preuve est un raisonnement sur le code réel. Les points qui dépendent du fonctionnement interne de PostgreSQL ou de pg_net sont marqués **[H]**, avec l'essai qui devra les éprouver (`PHASE_1_3_1_FINAL_TEST_PLAN.md`).

---

## 1. Réponse courte

1. **La documentation est inexacte.** Les fonctions d'arrêt verrouillent bien des lignes de deux tables métier après N0 et N0a, par `communication_observer_sorties()` (43 l. 1881-1904). Deux textes se trompent :
   - `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` l. 85 : « …ni une autre table » ;
   - le commentaire de 41 l. 899 : « Aucune autre table n'est verrouillée ».

   **Correction documentaire** (§6) : P-01 **appliquée** à la clôture (document de conception, correction documentaire autorisée par la mission). P-02, qui touche un brouillon SQL, est **proposée, non appliquée**.
2. **Ce verrouillage ne crée pas d'interblocage**, à une condition : il se fait **uniquement** en `FOR UPDATE SKIP LOCKED` (43 l. 1891 et 1898). La transaction d'arrêt **n'attend jamais** une ligne tenue par une autre. Et, une fois N0a obtenu, elle **n'attend plus rien** (§3). Une transaction qui n'attend jamais ne peut pas fermer un cycle d'attentes.
3. **Elle peut faire attendre d'autres transactions**, jusqu'à son propre COMMIT :
   - le webhook, qui verrouille un envoi précis ;
   - la purge et l'annulation, qui verrouillent des envois par identifiant croissant.

   L'attente est **bornée** : la transaction d'arrêt ne fait plus que des lectures et des écritures sur ses propres lignes. Il n'y a pas de cycle.
4. **`STOP_CONFIRMED` n'est jamais écrit sans N0 exclusif.** Les deux conditions sont dans le code (41 l. 924-939) et dans une contrainte de la table (40 `communication_arret`).

   La garantie « plus rien ne part » repose sur quatre comportements de PostgreSQL et de pg_net **non éprouvés** (§5).

---

## 2. Inventaire des verrous, fonction par fonction (code réel)

Notation :
- **cons.** : verrou consultatif de transaction ;
- **ligne** : verrou de ligne (`FOR UPDATE`, `UPDATE`, `DELETE`) ;
- **attente** : délai maximal d'attente effectivement réglé.

### 2.1 `communication_verrou_interrupteurs(p_exclusif)` — 40 l. 331

| Ordre | Verrou | Mode | Attente |
|---|---|---|---|
| 1 | cons. `hashtextextended('goship-communication:interrupteurs', 0)` = **N0** | `pg_advisory_xact_lock` (exclusif) ou `pg_advisory_xact_lock_shared` (partagé) | Celle de l'appelant (`lock_timeout`) |

### 2.2 `communication_autoriser_sortie(nature, canal)` — 40 l. 379 (la porte)

| Ordre | Opération | Verrou | Attente |
|---|---|---|---|
| 0 | Contrôle de `transaction_isolation` (refus hors READ COMMITTED) | — | — |
| 1 | `communication_verrou_interrupteurs(false)` (l. 395) | **N0 partagé**, tenu jusqu'à la fin de la transaction | Celle de l'appelant : 2 s dans `communication_traiter_un` et `communication_rafraichir_modeles_meta` (clause `SET lock_timeout`) |
| 2 | `select a.etat from communication_arret` (l. 396) | **aucun** : lecture MVCC, nouvelle requête après l'obtention de N0 | — |
| 3 | `select * from communication_reglages` | aucun | — |
| 4 | `set_config('goship.sortie_autorisee', 'txid:nature:canal', true)` (l. 407) | — | — |

### 2.3 `communication_traiter_un(id)` — 43 l. 891 (un envoi)

| Ordre | Opération (ligne) | Verrou | Attente |
|---|---|---|---|
| 1 | Lecture de l'envoi | aucun | — |
| 2 | La porte (l. 924) | **N0 partagé** | 2 s |
| 3 | `communication_campagnes … for update` (l. 937) | **ligne N1** | 2 s |
| 4 | `communication_verrou('client:…')` (l. 952) | **cons. N2** | 2 s |
| 5 | `communication_verrou('consentement:…')` (l. 953) | **cons. N3** | 2 s |
| 6 | `communication_envois … for update skip locked` (l. 956) | **ligne N4** | aucune (SKIP LOCKED) |
| 7 | `communication_reserver` → `communication_verrou('compteurs')` (l. 253) | **cons. N5** | 2 s |
| 8 | Écritures : dépenses, débit, campagne, confirmation, envoi | lignes déjà tenues, ou lignes de compteurs sous N5 | 2 s |
| 9 | `net.http_post` dans `communication_appel_email` ou `communication_appel_whatsapp`, après le contrôle `communication_sortie_autorisee` (l. 449, 506) | — | — |

### 2.4 `arreter_communications(motif)` — 41 l. 960

| Ordre | Opération (ligne) | Verrou | Attente |
|---|---|---|---|
| 1 | `lock_timeout = 3s` (l. 978) puis `communication_verrou_interrupteurs(true)` | **N0 exclusif**, tenté | **3 s** ; échec attrapé → `v_n0 = false` (le verrou n'est pas pris) |
| 2 | `lock_timeout = 2s`, puis `communication_arret … for update` (l. 990) | **ligne N0a** | **2 s** ; échec → `STOP_NOT_CONFIRMED`, rien n'est écrit |
| 3 | `lock_timeout = 0` (l. 998) | — | — |
| 4 | `update communication_arret` (date de l'appui) ; `auditer` (insertion dans `journal_audit`) | sa propre ligne ; insertion | aucune |
| 5 | Si `actif` : `update communication_arret` (demande) | sa propre ligne | aucune |
| 6 | `communication_conclure_arret(v_n0)` (l. 1016) | voir 2.5 | voir 2.5 |

### 2.5 `communication_conclure_arret(p_n0_exclusif)` — 41 l. 903

| Ordre | Opération (ligne) | Verrou | Attente |
|---|---|---|---|
| 1 | Lecture de `communication_arret` | ligne déjà tenue par l'appelant | — |
| 2 | Lecture de `pg_locks` (indication) | aucun | — |
| 3 | `update communication_arret` (fermeture des autorisations, tentatives) | sa propre ligne | aucune |
| 4 | **`communication_observer_sorties()` (l. 942)** | **lignes de `communication_envois` et de `communication_modeles_meta`**, en `FOR UPDATE SKIP LOCKED` (43 l. 1891, 1898) | **aucune** : une ligne déjà verrouillée par une autre transaction est **sautée**, pas attendue |
| 5 | `communication_transmissions_en_cours()` (l. 943) | aucun : lectures, y compris de `net._http_response` et `net.http_request_queue` | — |
| 6 | `update communication_arret` → `arret_confirme` (l. 952), seulement si les conditions 1 et 2 sont remplies ; `auditer` | sa propre ligne ; insertion | aucune |

### 2.6 `communication_observer_sorties()` — 43 l. 1881

```sql
update public.communication_envois set sortie_file_vue_le = clock_timestamp()
 where id in (select e.id from public.communication_envois e
               where e.requete is not null and e.sortie_file_vue_le is null
                 and not exists (select 1 from net.http_request_queue q where q.id = e.requete)
               for update skip locked);
```

La sous-requête verrouille les lignes **libres** et **saute** celles qui sont tenues. L'UPDATE extérieur ne touche que les identifiants retournés, déjà verrouillés par la transaction elle-même : il n'attend rien. Même forme pour `communication_modeles_meta`.

**Conséquence d'une ligne sautée** : sa date d'observation reste vide, et `communication_en_transmission` la compte alors comme « en transmission ». L'arrêt reste `STOP_PENDING` : l'erreur va dans le sens prudent.

### 2.7 `communication_en_transmission` / `communication_transmissions_en_cours` — 43 l. 1863, 1917

Fonctions `LANGUAGE sql STABLE` : **lectures seulement**, aucun verrou. Le délai pris en compte est fixé à 120 s, soit le maximum permis de 60 s plus 60 s.

### 2.8 `confirmer_arret_communications()` — 41 l. 1024 ; `communication_confirmer_arret_auto()` — 41 l. 1058

| | Verrou N0 | Ligne N0a | Ensuite |
|---|---|---|---|
| Confirmation manuelle | exclusif tenté, 3 s | 2 s, puis `lock_timeout = 0` | `communication_conclure_arret` (2.5) |
| Confirmation automatique | `pg_try_advisory_xact_lock` : **jamais d'attente** (l. 1071) | `for update nowait` : **jamais d'attente** (l. 1072) | idem. Une exception `lock_not_available` annule le bloc et rend `null`. |

### 2.9 `lever_arret_communications(motif)` — 41 l. 1098

N0 exclusif, puis ligne N0a, avec 5 s d'attente au plus (`lock_timeout`, l. 1112) pour chacun. **Aucun autre verrou.**

### 2.10 Les autres transactions qui verrouillent des envois

| Fonction | Verrous sur les envois | Attend-elle ? |
|---|---|---|
| `communication_lire_reponses` (43 l. 666) | `for update skip locked` (l. 690, 744) | Non |
| `communication_recevoir_evenement` (43 l. 1322) | **D'abord un `FOR KEY SHARE` caché sur l'envoi**, posé par la clé étrangère de l'insertion de l'événement (l. 1257, 1444). Ensuite N1 campagne (l. 1525), N3, puis **l'envoi `for update`** (l. 1531). *[Ajouté après la revue finale, RF-02 : deux retours pour le même envoi s'interbloquent entre eux. Cela ne concerne pas l'arrêt, qui ne demande jamais ces verrous.]* | **Oui**, 5 s au plus (clause `SET lock_timeout`) |
| `changer_statut_campagne('annuler')` (42 l. 825) | N1, puis les envois de la campagne par identifiant croissant | **Oui** (délai de l'appelant) |
| Purge d'une personne / à l'échéance (40, 43) | N2, N3, puis les envois par identifiant croissant | **Oui** |
| `relancer_envoi_communication` (43) | l'envoi d'origine `for update` | **Oui** |

---

## 3. Démonstration : pas d'interblocage avec l'arrêt

**Définition.** Un interblocage est un cycle T1 → T2 → … → T1 où chaque transaction **attend** un verrou tenu par la suivante. PostgreSQL le détecte et annule une des transactions, mais un cycle reste un défaut de conception.

**Lemme 1 — après N0a, une transaction d'arrêt n'attend plus.** C'est vrai pour l'arrêt, la confirmation manuelle et la confirmation automatique. Après l'obtention de la ligne N0a, leur code ne fait que :
- lire, en MVCC : `communication_arret` (déjà tenue), `pg_locks`, `communication_reglages`, les tables de pg_net ;
- écrire sur des lignes **déjà tenues** par elle-même (`communication_arret`) ;
- verrouiller des lignes **en SKIP LOCKED** (`communication_observer_sorties`) ;
- insérer dans `journal_audit` (`auditer`).

Aucune de ces opérations n'attend un verrou tenu par une autre transaction. Pour `journal_audit`, c'est vrai sous réserve qu'elle n'ait ni index unique en conflit ni déclencheur qui verrouille : le déclencheur existant `journal_immuable` ne porte que sur UPDATE et DELETE. **[H1]**

**Lemme 2 — avant N0a, elles n'attendent que N0 puis N0a, dans cet ordre, et pour un temps borné** : 3 s, puis 2 s. La confirmation automatique n'attend pas du tout.

**Lemme 3 — N0a n'est pris que par les quatre fonctions d'arrêt**, toujours **après** une tentative sur N0. Aucune fonction ne prend N0a puis N0.

**Théorème.** Aucun cycle d'attentes ne contient une transaction d'arrêt.

Supposons qu'une transaction d'arrêt S soit dans un cycle. Alors S **attend** quelque chose. Par le lemme 1, elle n'a pas encore N0a. Elle attend donc N0, ou N0a. Elle ne tient alors que N0, ou rien : dans tous les cas, elle ne tient aucune ligne d'envoi ni de modèle Meta.

- **S attend N0.** S ne tient **rien**. Personne ne peut l'attendre : le cycle est impossible.
- **S attend N0a, en tenant N0 en exclusif.** Elle attend une transaction S' qui tient N0a. S' est une transaction d'arrêt (lemme 3) qui tient N0a, donc qui n'attend plus rien (lemme 1). La chaîne s'arrête : il n'y a pas de cycle.
- **S attend N0a en ne tenant rien.** Personne ne l'attend : le cycle est impossible.

**Ce que l'arrêt peut faire subir aux autres.** Tant que la transaction d'arrêt n'est pas validée :
- un webhook, une purge, une annulation ou une relance peuvent **attendre** une ligne d'envoi verrouillée par `communication_observer_sorties`. Comme l'arrêt n'attend plus rien (lemme 1), l'attente se termine à son COMMIT, en quelques millisecondes en pratique ;
- les nouvelles transactions d'envoi attendent N0 (2 s au plus), puis réessaient au passage suivant.

**Différence avec la documentation.** La règle « N0 puis N0a, aucune autre table » est fausse. La règle **juste** est : « N0, puis N0a, puis seulement des verrous de ligne en SKIP LOCKED, qui n'attendent jamais. »

---

## 4. Démonstration : pas de nouvelle sortie après `STOP_CONFIRMED`

**Point d'autorisation.** Toute requête sortante est déposée par :
- `communication_appel_email` (43 l. 449) ;
- `communication_appel_whatsapp` (43 l. 506) ;
- `communication_demander_modele_meta` (42 l. 314).

Chacune **refuse** (`SORTIE_NON_AUTORISEE`) si la marque `txid:nature:canal` de **sa** transaction est absente. La marque n'est posée que par la porte (40 l. 407), **après** N0 partagé (l. 395) et la lecture de l'état (l. 396).

**Propriété (a) : aucune autorisation après la fermeture.** Soit G l'instant où N0 est accordé en exclusif à une transaction qui écrit `autorisations_closes_le` (41 l. 938, seulement si `p_n0_exclusif`).

À cet instant, aucune transaction ne tient N0 partagé : les modes sont incompatibles. **[H2]** Toute transaction autorisée avant G est donc finie, et sa requête est déjà déposée ou annulée.

Une porte qui obtient N0 partagé après G l'obtient après le COMMIT de la transaction qui tenait l'exclusif. Elle lit l'état par une requête postérieure, et voit `arret_demande`. **[H3]** Elle refuse.

**Propriété (b) : aucune transmission après `STOP_CONFIRMED`.** `arret_confirme` n'est écrit (41 l. 952) que si `communication_transmissions_en_cours() = 0`, constaté **après** G.

Une requête R déposée avant G est comptée tant qu'elle n'a pas de réponse **et** qu'elle remplit une de ces conditions :
- elle est dans la file de pg_net ;
- elle n'a pas encore été vue hors de la file ;
- elle a été vue hors de la file il y a moins de 120 s.

Si pg_net la retire de la file **avant** de l'appeler, et applique son délai (≤ 60 s) à partir de là **[H4]**, alors l'appel est fini à l'instant de vérification. Après G, aucune requête nouvelle n'apparaît (propriété a).

**Ce que la base garantit seule** :
- jamais `arret_confirme` sans `autorisations_closes_le` : c'est une contrainte de la table ;
- jamais de fermeture sans N0 exclusif : c'est le code de 41 l. 924-939.

**Cas particuliers** :

| Cas | Ce qui se passe |
|---|---|
| N0 indisponible | `STOP_PENDING / VERROU_NON_OBTENU`. La demande est écrite. Les portes qui la lisent refusent. Une nouvelle tentative (manuelle, ou automatique à chaque passage) termine l'arrêt. |
| Ligne N0a indisponible | `STOP_NOT_CONFIRMED`, rien n'est écrit, il faut réessayer |
| Réponse HTTP retardée | La requête reste comptée jusqu'à la réponse, ou jusqu'à 120 s après qu'on l'a vue hors de la file. L'arrêt reste en attente. |
| Réponse HTTP absente | Même règle. L'envoi devient `incertain` (sans nouvel essai) seulement après ce délai (43 `communication_lire_reponses`). |
| Délai d'attente dépassé | Jamais de succès : `STOP_PENDING` ou `STOP_NOT_CONFIRMED`. L'état écrit dit ce qui est prouvé. |
| Délai d'exécution des comptes connectés dépassé (8 s chez Supabase, rapporté) | La transaction d'arrêt est **annulée en entier**, demande comprise : erreur à l'écran, il faut réessayer. Jamais de faux succès, mais l'arrêt peut ne pas s'écrire du premier coup (risque R-03 de l'audit). |

---

## 5. Garanties qui dépendent de PostgreSQL ou de pg_net (à éprouver)

| # | Hypothèse | Si elle est fausse | Essai |
|---|---|---|---|
| H1 | L'insertion dans `journal_audit` n'attend aucun verrou | L'arrêt pourrait attendre après N0a. Pas de cycle prouvé, mais une attente possible. | F-K03 |
| H2 | Un verrou consultatif exclusif n'est accordé que si aucun verrou partagé n'est tenu sur la même clé ; il est relâché à la fin de la transaction, et annulé avec une sous-transaction qui échoue | La propriété (a) tombe | F-K01, F-K02 |
| H3 | Une validation est visible avant que ses verrous soient relâchés ; en READ COMMITTED, chaque requête d'une fonction VOLATILE prend un nouvel instantané | La propriété (a) tombe | F-K02 |
| H4 | pg_net (version 0.20.4 en production, rapportée) retire la requête de sa file **avant** l'appel, n'envoie qu'après le COMMIT, applique `timeout_milliseconds` dès le début de l'appel, ne réessaie pas seul, et n'envoie rien pour une transaction annulée | La propriété (b) tombe | F-K05, F-K06 |
| H5 | `FOR UPDATE SKIP LOCKED` dans une sous-requête d'UPDATE n'attend jamais | Le lemme 1 tombe | F-K03 |
| H4′ | *(revue finale)* Le transfert curl **commence** moins de 60 s après que la sortie de la requête de la file est devenue visible | La fenêtre de 120 s ne couvre plus le transfert : la propriété (b) tombe | F-K09 |
| H6 | *(revue finale)* Une demande partagée de N0 attend derrière une demande exclusive déjà en file | Seulement des retards (`STOP_PENDING`), jamais un faux succès | F-K01 (variante) |

**Défaut trouvé par la revue finale, hors des hypothèses : RF-01.** `arreter_communications` écrit la demande (41 l. 1006-1013), puis appelle le constat (l. 1016), **sans** bloc `exception` autour. Si le constat lève une erreur ou est annulé (délai d'exécution, recul de l'horloge contre la contrainte, attente face à une migration rejouée), **la demande est annulée avec lui**. Cela ne contredit pas les propriétés (a) et (b) : on n'obtient pas de faux `STOP_CONFIRMED`. Mais l'arrêt peut ne rien écrire. Correction proposée : P-07 (`PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`, §9.2). Essai : F-K10.

---

## 6. Corrections proposées (P-01 appliquée, car documentaire ; les autres NON appliquées)

| # | Fichier | Proposition |
|---|---|---|
| P-01 | `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` l. 85 | Remplacer « …ni une autre table » par « …puis, dans `communication_conclure_arret`, des verrous de ligne sur `communication_envois` et `communication_modeles_meta`, **uniquement en SKIP LOCKED** (jamais d'attente) » |
| P-02 | `brouillons-sql/41-…` l. 899 (commentaire) | Même correction |
| P-03 | 41 `arreter_communications` l. 998, `confirmer_arret_communications` | Laisser `lock_timeout` à 2 s au lieu de 0 après N0a. Une attente imprévue échouerait vite (erreur, pas de faux succès) au lieu de durer. À peser : l'échec annule aussi la demande. |
| P-04 | Essai F-K03 | Éprouver H1 et H5 dans la base jetable avant toute activation |

---

## 7. Après les corrections D5 (20/11/2026)

| Point | Effet sur la preuve |
|---|---|
| La demande (`arreter_communications`) ne prend plus N0, seulement la ligne d'arrêt | Un verrou de moins dans la demande, et aucune nouvelle attente. Le constat garde l'ordre N0 puis ligne. Pas de cycle : la demande et la levée n'ont que la ligne en commun **[D]**. |
| Constat dans un bloc qui rattrape tout | Les propriétés (a) et (b) sont inchangées. Un constat en erreur ne peut plus annuler la demande (RF-01 fermé, **si** le rattrapage de `query_canceled` fonctionne comme attendu : F-K10, spécialiste). |
| `lock_timeout = 0` retiré (2 s) | S-02 et P-03 appliqués |
| Clé étrangère `envoi_id` retirée ; ordre N1 → N3 → N3b → N4, puis les écritures dans les suppressions | RF-02 et RF-05 fermés **par conception** (F-W01, F-W02, F-W04) ; le constat de l'arrêt n'en dépendait pas |
| Nouveau niveau N3b (`contact:<canal>:<empreinte>`) | Pris par le travailleur après N3, avant N4 ; jamais par l'arrêt |
