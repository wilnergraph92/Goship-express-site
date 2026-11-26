# Communication Center — hiérarchie des verrous des candidates 001–010

**Relevé statique du 23/11/2026, par Claude Code.** Ce document décrit l'ordre dans lequel les
candidates prennent leurs verrous, puisque la décision A en fait la base de la Phase 2. C'est la
condition préalable à une revue Q1–Q7 utile. Il ne prouve pas l'absence d'interblocage : le banc local
éprouve certains entrelacements, et la revue humaine reste requise.

## 1. Ordre unique

Une transaction peut sauter des niveaux, mais **jamais revenir à un niveau inférieur**.

| Niveau | Verrou | Mode | Fonctions |
|---|---|---|---|
| **V0** | consultatif `goship-communication:interrupteurs` | partagé : porte `communication_autoriser_sortie` ; exclusif : confirmation et levée de l'arrêt | 001 porte, `communication_confirmer_arret` ; 004/005 boucle des sorties de `traiter_notifications` ; 009 `…_debut_confirmation_whatsapp` (depuis le 23/11/2026) ; 010 `communication_c10_arret_lever` |
| **V0a** | ligne `communication_arret` | `FOR UPDATE` | 001 demande (**seule**, jamais après V0) ; 001 confirmation et 010 levée (après V0) |
| **V1** | consultatif `goship:consent-account:<client>` | exclusif | 003 demande, confirmation, refus et retrait ; 006 traitement P-08 (plusieurs clients **par identifiant croissant**) ; 009 réservation, contexte, lecture du code, début et fin de transmission |
| **V2** | consultatif `goship:whatsapp:<empreinte>`, ou `goship:whatsapp:client:<client>` sans empreinte | exclusif | mêmes fonctions, toujours après V1 |
| **V3** | lignes métier : `communication_evenements_traitement` (`SKIP LOCKED`), `communication_confirmations_whatsapp` et `communication_consentements_clients` (par `client_id`, `id`) | `FOR UPDATE` | 003, 006, 007 (reprise ciblée), 009 |
| **V4** | ligne `notification_envois` (outbox) | `FOR UPDATE`, ou `SKIP LOCKED` pour le travailleur | 004/005 travailleur et retours transactionnels, 006 reçus Expo, 009 |

**Verrous indépendants** (aucun croisement avec V0–V4) : `goship:communication-template:<type>`
(007), `goship:c6:model:<canal>:<clé>` (008), lignes `communication_campagnes_marketing` et
`communication_campagne_segments_marketing` (008, une ligne par appel).

## 2. Règles qui évitent les cycles

1. **Lecture des réponses, puis sorties, dans deux appels.** `traiter_notifications` (004, renommée
   `communication_traiter_notifications_sans_callbacks` par 005) verrouille d'abord les réponses en V4
   `SKIP LOCKED`. S'il en a lu, il **rend la main** avant toute sortie. V0 n'est donc jamais demandé
   après un V4 de réponse dans la même transaction.
2. **La confirmation d'arrêt ne verrouille aucune ligne d'envoi.** Elle compte les lignes `envoi` et
   `incertain` sans verrou ; V0 exclusif n'attend donc jamais V4.
3. **La demande d'arrêt ne prend que V0a.** Elle ne peut pas attendre une transmission en cours.
4. **Une sortie suit l'ordre V0 → V4** : la porte d'abord, puis la ligne relue en `SKIP LOCKED`.
5. **Les transmissions de code par l'Edge suivent l'ordre V0 → V1 → V2 → V3 → V4.** La porte est
   prise au début de la transmission (correction du 23/11/2026, §4).

## 3. Points que la revue doit examiner (Q1–Q7 adaptées)

| # | Point | Où |
|---|---|---|
| L-1 | `traiter_notifications` (005) enchaîne les sorties (V0 partagé, V4 des lignes envoyées) puis les retours transactionnels (V3 `SKIP LOCKED`, puis V4 `FOR UPDATE` **en attente**) **dans la même transaction**. Il faut vérifier qu'aucun détenteur de ce second V4 n'attend V0 ou un V4 déjà tenu. Aucun cycle n'a été trouvé à la lecture. | 005 l. 262–312 et 356–372 |
| L-2 | File d'attente de V0 : une demande partagée qui arrive derrière une demande exclusive en attente doit attendre (H6). Cela peut retarder des sorties pendant une confirmation (3 s au plus), sans faux succès. | 001 |
| L-3 | Une ligne de confirmation passée en `envoi` par l'Edge, sans `requete`, peut être reprise après 10 min par la lecture des réponses du travailleur transactionnel (`SANS_REPONSE`), alors que l'Edge la clôt de son côté. Il faut vérifier que le résultat est toujours `incertain` et qu'aucun résultat accepté n'est perdu. Depuis la décision K, un silence est réessayé pour le transactionnel ; les lignes de confirmation en sont exclues par `communication_confirmation_demande_id` (005 `lire_reponse_envoi`). | 004/005 boucle des réponses ; 009 `…_terminer_…` et `…_recuperer_…` |
| L-4 | Collisions de `hashtextextended` sur 64 bits entre les espaces `goship:*` et `goship-communication:*` : attente parasite possible, jamais de cycle. | toutes |
| L-5 | Effet de `lock_timeout` (2 à 5 s) et du délai d'exécution des rôles (8 s pour `authenticated`, 3 s pour `anon`) sur chaque chemin de l'écran. | 001, 003, 007, 008, 010 |

## 4. Corrections apportées par ce relevé

- **009, `communication_edge_worker_debut_confirmation_whatsapp`** : ce chemin **contournait l'arrêt
  d'urgence**. L'Edge pouvait commencer à transmettre un code WhatsApp après une demande d'arrêt, et
  même après sa confirmation. La fonction passe désormais par `communication_autoriser_sortie` (V0
  partagé) avant tout autre verrou. Elle refuse de commencer avec `raison = ARRET_URGENCE`. Essai
  ajouté au parcours C7.3 du banc.
- **010** : la levée de l'arrêt et l'accès Admin suivent V0 → V0a.
