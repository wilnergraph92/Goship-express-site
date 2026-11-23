# Communication Center — dossier de revue indépendante PostgreSQL des candidates (Q1–Q7)

**Rédigé le 23/11/2026 par Claude Code, avec l'autorisation écrite de la CEO.** Ce dossier prépare le
travail du spécialiste humain PostgreSQL exigé avant toute mise en service. **Il n'est pas une revue,
ne répond à aucune question et ne valide rien.** Son auteur a écrit une partie du code examiné : il
ne peut pas en être le relecteur.

Phase 1.3.1 : **NON VALIDÉE**. Brouillons 40–43 : **NON EXÉCUTABLES**. Candidates : **interdites en
préproduction et en production** (critère C14 de `docs/production/go-no-go.md`).

Il remplace, pour l'objet de la revue, `PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md`, qui visait les
brouillons 40–43. Depuis la décision A du 23/11/2026, ce sont les **candidates** qui fondent la
Phase 2 ; les brouillons ne sont plus que des références de conception.

---

## 1. Objet de la revue : version figée

La version examinée est **définie par les empreintes SHA-256 ci-dessous**. Elle est entrée dans Git
avec le commit qui apporte ce dossier, sur la branche `ccr-056ddc8c-m7u4p1` (pull request 65), juste
après `b417029` (intégration C11) ; les candidates n'y diffèrent de `b417029` que par la ligne
d'en-tête de chacune, mise à jour après C11 (commentaire seulement). Le numéro de ce commit est inscrit dans
`COMMUNICATION_CENTER_FEUILLE_DE_ROUTE.md`. Le relecteur vérifie chaque fichier reçu avec :

```bash
shasum -a 256 <chemin>
```

Si un fichier change avant l'envoi, ce tableau doit être recalculé et le dossier daté de nouveau.

### Migrations candidates (objet principal)

| Fichier (`outils/migrations-candidates/`) | Lignes | SHA-256 |
|---|---|---|
| `001-communication-foundation.sql` | 399 | `ce0d0c2599160d36bc6d72033f56a7425f35e03a746edc366a6279b2f299514d` |
| `002-communication-supervision.sql` | 112 | `21abd212557fed1ac8ad974a4362292d98fb23f567be382f12ceba61e6f3bc6c` |
| `003-communication-consentements.sql` | 852 | `9bd0c5ac89cebab2361c759c640958227252dee9c118f578263ff24b4e237e71` |
| `004-communication-transactionnelle.sql` | 835 | `31e94f8e7ce4fb5c7a8af1fd8da87ed579f1342a0f8e746b3f0722675e1f2763` |
| `005-communication-adaptateurs-canaux.sql` | 479 | `a47b859bd3565cf9e7a26987ecedcc43a58e2a42c6c26c91a8b25c26f9c5c226` |
| `006-communication-p08-worker.sql` | 553 | `ff2455bfe128a3866f7e565bb1f86cc7e2160f0bf1d742dd4e7035cda4e9a5dc` |
| `007-communication-interface-operations.sql` | 648 | `99dc48e5c4e1bc13a7afe91c2a277a877ed5175bdbc3b9c9e9e8e179f2774491` |
| `008-communication-campagnes-marketing.sql` | 1372 | `3ca43075d47a68421e29d4bbcb1e79c40104821db9376dc5d1d76141f1d576a3` |
| `009-communication-identite-edge.sql` | 1094 | `28a6a6fac25cde7b96325ec61e802515ac9ac742d3b2ff8b3ebebfb21416d9c2` |
| `010-communication-arret-administration.sql` | 230 | `366457aadb933e0bce4ce8dbb27d637e3543c7d6989164afc5699698f72fcc32` |
| `011-communication-reglages-decides.sql` | 59 | `72302e9aa6ce391146beb534f2f9e0c0ab0d2dff48a66fe400213e67a35150d2` |

### Pièces associées (contexte, garde-fous, essais)

| Fichier | Lignes | SHA-256 (inchangé depuis `b417029`) |
|---|---|---|
| `outils/migrations.txt` (chaîne : 39 fichiers officiels, puis les 11 candidates) | 64 | `acd310d873792f814024f45527345ca4405684ec4800e60b0a8f957e937dbf3c` |
| `outils/production/appliquer-chaine.sh` (garde-fou C11) | 84 | `3e5f943d89361f26a4de30a691f902897090a2ddc531130fd47fd4b485bf982e` |
| `outils/production/controle-securite.sql` | 345 | `5b66f3f0f95a506e2e14f1315680c46479a411db27108fbb1d3821816afbff53` |
| `outils/production/sonder.sh` | 172 | `828960fc4cdf98c3ab9c93a832397f7070495a29fe8cffd8ad8021461cad8fb1` |
| `outils/essais-services/essai-communication-center.py` (banc) | 3136 | `849eda87d96b12e8329e157e44f755beb45a4a0713a9afab4a41ad626cb5bda0` |
| `outils/essais-services/essai-communication-non-regression.py` | 165 | `e269a0e131d3ca22232a15ba146ed5d14e50178aaae658ce5ea0d01e76211920` |
| `outils/essais-services/essai-services.py` (doublures communes) | 704 | `541da8dd0404a1a9ccd23e3cf423a22f59182e2e2605e13c747949ed22d19de9` |

Arbre Git du dossier `outils/communication-center-edge/` (fonctions Edge, hors `.temp/`) à
`b417029` : `a6447ad75fe8616e0f3d0878dbb0bb0bc569a5f7`.

Les fichiers officiels que les candidates redéfinissent ou enveloppent (`supabase-notifications.sql`,
`supabase-courriel-colis.sql`, `supabase-lieu-reception.sql`, `supabase-anniversaires.sql`,
`supabase.sql`) font partie du contexte : le relecteur les lit au même commit.

## 2. Pièces à transmettre (lecture seule)

- Les fichiers du §1, au commit qui apporte ce dossier (une archive `git archive <commit> outils/migrations-candidates
  outils/production outils/essais-services outils/communication-center-edge outils/*.sql
  outils/migrations.txt` suffit ; **exclure** `outils/communication-center-edge/supabase/.temp/`).
- `COMMUNICATION_CENTER_VERROUS_CANDIDATES.md` (hiérarchie V0–V4, règles anti-cycle, points L-1 à L-5).
- `COMMUNICATION_CENTER_PLAN_ESSAIS_CANDIDATES.md` (ce qui est prouvé, ce qui ne l'est pas).
- `COMMUNICATION_CENTER_DECISIONS_DELEGUEES.md` (décisions A à K et journal des changements).
- `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` (hypothèses H1–H6 et H4′, toujours valables pour la porte
  V0), `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` et `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md`
  (constats d'origine), `PHASE_1_3_1_CORRESPONDANCE_BROUILLONS_CANDIDATES.md`.
- Le présent dossier.
- **À ne jamais transmettre** : `assets/js/config.js`, tout fichier `.temp/` ou `.branches/`, toute
  donnée de production ou de client. Les candidates ne contiennent aucun secret ; ce point doit être
  vérifié de nouveau sur l'archive avant l'envoi.
- Un accord de confidentialité et une déclaration d'indépendance, avant l'envoi.

## 3. Ce qui a changé depuis l'audit final (à examiner en priorité)

L'audit final indépendant (1.3.1) portait sur les brouillons. Les points suivants sont **nouveaux** ou
**reviennent sur une conclusion d'audit**. Aucun n'a été examiné par une personne indépendante.

| # | Changement | Où | Pourquoi le relecteur doit le regarder |
|---|---|---|---|
| R-1 | **Décision K** : une notification transactionnelle est réessayée après 408, 425, 5xx, erreur réseau ou silence (30 s, 2 min, puis `ABANDON_…`) | 005 `lire_reponse_envoi` (l. 399) | Revient sur le constat H8 de l'audit 1.3 (« jamais de nouvel essai après une 5xx ») pour le transactionnel seulement. Risque accepté par la CEO : un message reçu deux fois. Restent `incertain` : 2xx sans identifiant, codes WhatsApp. |
| R-2 | Arrêt d'urgence côté Admin, **avec levée** | 010 (l. 81–230) | La levée n'existait pas dans les brouillons. Ordre V0 exclusif → V0a, motif d'au moins 10 signes, version affichée exigée. |
| R-3 | La transmission d'un code WhatsApp par l'Edge passe par la porte de l'arrêt | 009 `…_debut_confirmation_whatsapp` (l. 642) | Ce chemin **contournait** l'arrêt avant la correction du 23/11/2026. |
| R-4 | Cinq régressions du moteur transactionnel corrigées | 004 boucle des sorties (l. 679), 004 `texte_notification`, 005 | Débit d'un message par minute, travailleurs simultanés sur les mêmes lignes, modèles ignorés, langue ignorée, appareils Expo désinscrits conservés. |
| R-5 | `texte_notification` privilégiée **fermée** aux visiteurs et aux comptes | 004 (fin de la fonction) | Était appelable par un visiteur sans compte (trouvé à l'intégration C11). |
| R-6 | Au rejeu de la chaîne, 004 et 005 enveloppent **la version la plus récente** de l'adaptateur et du travailleur | 004 bloc `$renommage$`, 005 bloc `$worker$` | Avant : la version du premier passage restait enveloppée ; une correction ultérieure n'aurait jamais pris effet sur une base existante. La reconnaissance de l'enveloppe se fait par une recherche de texte dans `prosrc` : le relecteur dira si c'est assez robuste. |
| R-7 | La contrainte de statut de l'outbox garde `confirmation` au rejeu | 004 bloc `$statuts$` | Avant : la migration échouait au rejeu dès qu'une ligne avait ce statut. |
| R-8 | Candidates en fin de chaîne officielle, sous garde-fou | `migrations.txt`, `appliquer-chaine.sh`, `controle-securite.sql`, `sonder.sh` | Le garde-fou est un script : il ne protège pas un collage manuel dans le SQL Editor (seule la procédure écrite le fait). |

## 4. Questions Q1 à Q7, réécrites pour les candidates

Les numéros de ligne renvoient à la version figée du §1. Les verrous sont nommés comme dans
`COMMUNICATION_CENTER_VERROUS_CANDIDATES.md` : **V0** consultatif `goship-communication:interrupteurs`
(partagé pour la porte, exclusif pour la confirmation et la levée) → **V0a** ligne
`communication_arret` → **V1** consultatif `goship:consent-account:<client>` → **V2** consultatif
`goship:whatsapp:<empreinte>` → **V3** lignes métier → **V4** ligne `notification_envois`.

### Q1 — Sous-transactions, rattrapage des erreurs et délais

- **Code** : 001 `communication_confirmer_arret` (l. 191 ; rattrapages `lock_not_available` l. 211 et
  219) ; 010 `communication_c10_arret_lever` (l. 149 ; l. 179) ; 004 `traiter_notifications` (l. 679 ;
  `lock_not_available` l. 735 et 750, `others` l. 798) ; 006 `communication_recevoir_evenement` (l. 153,
  `others` l. 184) ; 009 (l. 233).
- **Questions** :
  1. Les rattrapages `when others` (006 l. 184, 004 l. 798, 009 l. 233) peuvent-ils masquer une
     annulation (`57014`) ou un interblocage (`40P01`) et laisser un état incohérent ou une ligne
     verrouillée trop longtemps ?
  2. Après un `lock_not_available` attrapé dans la confirmation d'arrêt, la demande (V0a) reste-t-elle
     écrite et l'état renvoyé (`STOP_PENDING`) est-il toujours exact ?
  3. Les `lock_timeout` (2 à 5 s) cumulés sur un même appel restent-ils sous les délais d'exécution
     des rôles (8 s pour `authenticated`, 3 s pour `anon`) ?
- **Hypothèses** : H2.
- **Essais du banc** : P-07 (« confirmation concurrente reste en attente sous N0 », « échec de
  confirmation ne supprime pas la demande validée ») ; P-08 (« interruption annule les effets et
  planifie une reprise »).
- **Non prouvé** : l'annulation par PostgREST quand le client se déconnecte ; le délai réel sur Supabase.

### Q2 — Verrou V0 partagé et exclusif

- **Code** : 001 `communication_verrou_interrupteurs` (l. 43), porte `communication_autoriser_sortie`
  (l. 63, exige `READ COMMITTED` l. 72), `communication_sortie_autorisee` (l. 111).
- **Questions** :
  1. Un V0 exclusif n'est-il accordé qu'une fois toutes les portes ouvertes refermées (H2) ? Une porte
     demandée après un exclusif en attente reste-t-elle derrière lui (H6) ?
  2. Le marqueur de transaction `goship.sortie_autorisee` / `goship.sortie_consommee`
     (`set_config(…, true)`) peut-il être réutilisé ou falsifié par un appelant qui n'a pas passé la
     porte (même transaction, fonction `security definer` appelée ensuite) ?
  3. Collisions de `hashtextextended` sur 64 bits entre `goship:*` et `goship-communication:*` :
     attente parasite seulement, ou risque réel (L-4) ?
- **Hypothèses** : H2, H3, H6.
- **Essais du banc** : P-07 (« une autorisation transactionnelle ne peut être consommée deux fois »,
  « nouvelle sortie refusée après confirmation sans appel adaptateur »).

### Q3 — Verrous implicites des clés étrangères

- **Code** : 009 clé `notification_envois_confirmation_demande_fk` vers
  `communication_confirmations_whatsapp` (`on delete cascade`, l. 53–65) ; tables de 003 et 006 ;
  contraintes de l'outbox (004 `$statuts$`).
- **Questions** :
  1. Une clé étrangère écrite par la porte, le travailleur, les retours P-08 ou les consentements
     pose-t-elle un `FOR KEY SHARE` implicite **hors de l'ordre** V0 → V4 ?
  2. La suppression en cascade d'une confirmation WhatsApp vers l'outbox peut-elle verrouiller une
     ligne `notification_envois` (V4) avant un V1/V2/V3 ?
- **Essais du banc** : aucun dédié. **À spécifier** (§5 du plan d'essais).

### Q4 — Interblocages entre chemins concurrents

- **Chemins à croiser** : porte (001 l. 63) ; demande, confirmation et levée (001 l. 125 et 191,
  010 l. 111–149) ; travailleur (004 l. 679 enveloppé par 005 l. 375, qui enchaîne sorties puis retours
  transactionnels : point **L-1**) ; retours transactionnels (005 l. 160 et 251) ; P-08 (006 l. 153,
  257, 365) ; reçus Expo (006 l. 467) ; consentements (003 l. 321, 543, 659, 706) ; Edge (009 l. 445,
  563, 641, 722, 839) ; reprise ciblée (007) ; campagnes (008 l. 640, 963, 1097).
- **Questions** :
  1. Chaque chemin, déclencheurs compris, respecte-t-il V0 → V4 sans retour en arrière ?
  2. **L-1** : dans `traiter_notifications` (005), le second V4 `FOR UPDATE` des retours, pris après
     les sorties dans la même transaction, peut-il attendre un détenteur qui attend V0 ou un V4 déjà
     tenu ?
  3. **L-3** : une ligne de confirmation passée en `envoi` par l'Edge, sans `requete`, est relue après
     10 min par le travailleur (`SANS_REPONSE`). Depuis la décision K, ce silence est réessayé pour le
     transactionnel ; la ligne de confirmation en est exclue par sa colonne
     `communication_confirmation_demande_id`. Le résultat reste-t-il `incertain`, sans résultat
     accepté perdu ni second code envoyé ?
- **Hypothèses** : H1, H5.
- **Essais du banc** : P-07 (« envoi déjà autorisé termine sans deadlock ») ; P-08 (« deux workers
  concurrents terminent sans double effet », « SKIP LOCKED ne double-traite pas »).

### Q5 — Contact partagé entre comptes (V1 puis V2)

- **Code** : 003 `communication_consentement_demander_whatsapp` (l. 321) et suivantes ; réglages D2
  (`politique_contact_partage = 'bloquer'`, 011) ; 006 traitement P-08 de plusieurs clients par
  identifiant croissant.
- **Questions** :
  1. V1 par compte, puis V2 par empreinte, sérialisent-ils le quota de demandes et l'unicité du code
     quand plusieurs comptes partagent un numéro (N-02, D2) ?
  2. Plusieurs V1 pris par identifiant croissant, puis un seul V2 : l'ordre est-il compatible avec
     tous les chemins de Q4 ?
  3. L'index unique des codes et le rattrapage `unique_violation` (003 l. 485) suffisent-ils sous
     insertions concurrentes, sans perdre la demande ?
- **Essais du banc** : consentements (« numéro partagé bloqué tant que la politique CEO est absente »,
  « limite de demandes répétées testée avec valeur synthétique ») ; P-08 (« STOP retire les deux
  consentements du contact partagé »).

### Q6 — Traitement une seule fois

- **Code** : 006 `communication_recevoir_evenement` (l. 153 : réception, unicité, `synchronous_commit`
  l. 238) et `communication_traiter_evenement` (l. 257) ; reprise (l. 365) ; reçus Expo (l. 467) ;
  retours transactionnels (005 l. 160).
- **Questions** :
  1. L'effet d'un retour et son passage à « traité » sont-ils dans la même transaction, pour qu'un
     second travailleur ou une reprise ne l'applique jamais deux fois ?
  2. Le rejeu d'un même reçu Expo ou d'un même statut fournisseur reste-t-il sans effet dans tous les
     entrelacements, pas seulement en séquence ?
  3. La progression monotone des statuts (`envoi` → `envoye` → `livre`, jamais à rebours) est-elle
     garantie par le code seul, ou aussi par une contrainte ?
- **Essais du banc** : P-08 (« rejeu P-08 idempotent », « rejeu du même reçu Expo idempotent »,
  « transition Expo contradictoire refusée »).

### Q7 — Durabilité et vérité de l'arrêt d'urgence

- **Code** : 001 `communication_demander_arret` (l. 125 : V0a seul, `synchronous_commit = on` l. 139,
  `lock_timeout` 5 s) ; `communication_confirmer_arret` (l. 191 : compte les lignes `envoi` et
  `incertain` sans les verrouiller) ; 010 (demande, confirmation, levée par l'Admin) ; travailleur
  004/005 ; Edge 009.
- **Questions** :
  1. Une demande validée avec `synchronous_commit = on` est-elle durable dans la configuration Supabase
     visée, réplication et restauration comprises ?
  2. Comment garantir qu'aucun appelant (PostgREST, `Prefer: tx=rollback`, client SQL, écran Admin)
     ne réunit demande et confirmation dans une même transaction ?
  3. Après `STOP_CONFIRMED`, une transmission peut-elle encore partir par un chemin autre que la porte :
     pg_net déjà en file, Edge, reprise d'une ligne `attente` ? Les hypothèses H4 et H4′ sur pg_net
     tiennent-elles pour la version déployée ?
  4. Depuis la décision K, une ligne réessayée repasse en `attente` : la confirmation de l'arrêt
     doit-elle aussi compter ces lignes, ou la porte suffit-elle à les retenir ?
- **Hypothèses** : H2, H3, H4, H4′.
- **Essais du banc** : P-07 (série complète) ; C10 ; C7.3 (« aucune transmission de code ne commence
  après la demande d’arrêt », « crash après début de transmission devient incertain sans reprise »).

## 5. Livrable attendu du relecteur

Un rapport signé qui :
- traite chaque question Q1 à Q7, chaque point R-1 à R-8 et L-1 à L-5, et chaque hypothèse H1–H6
  et H4′, en la déclarant confirmée, réfutée ou à corriger, avec un niveau de gravité ;
- donne un avis sur les essais de concurrence à écrire (`isolationtester` ou équivalent, §5 du plan
  d'essais) ;
- inclut une déclaration d'indépendance.

Ses propres essais se font sur une base jetable fournie par GoShip, jamais sur la production, et
seulement après une autorisation écrite distincte.

## 6. Ce que ce dossier n'est pas

- Ce n'est pas la revue : une session Claude ou Codex ne peut pas la remplacer.
- Ce n'est pas une autorisation d'envoyer les pièces, ni de demander un devis, ni d'appliquer les
  candidates ailleurs que sur une base jetable.
- Il ne lève pas le critère C14 et ne valide pas la Phase 1.3.1.
