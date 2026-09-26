# Les notifications de Goship Express

Ce document décrit le système de notifications mis en place en Phase 11 :
comment un événement métier devient un message pour le client, par quels
canaux, avec quelles garanties, et comment comprendre pourquoi un client n'a
rien reçu. Il n'est pas publié avec le site (`docs/` est exclu par
`.github/workflows/deploy.yml`).

Tout vit dans la base : `outils/supabase-notifications.sql`, à exécuter après
`supabase-mobile.sql`. Aucune page (site, tableau de bord, application de
bureau, application mobile) n'envoie de message elle-même.

## 1. Architecture

```
Action métier (scanner, tableau de bord, paiement…)
      │  même transaction
      ▼
Événement déjà écrit par la base
   · colis_historique        (moteur d'événements, Phase 3)
   · evenements_facturation  (file de la facturation, Phase 5)
      │  déclencheur
      ▼
Règle (notification_regles) ── coupée ? rien
      │
      ▼
Notification (table notifications, canal « app »)  ← ce que le client lit
      │  même transaction
      ▼
Envois (notification_envois) : un par canal et par cible
   · téléphone (un par appareil), e-mail, WhatsApp, SMS
   · ou « annule » avec la raison (non configuré, préférence, pas d'adresse)
      │  commit
      ▼
Travailleur (pg_cron, chaque minute) : traiter_notifications()
   1. lit les réponses des fournisseurs (net._http_response)
   2. envoie les envois dus, par lots, les prioritaires d'abord (pg_net)
      │
      ▼
Statut de chaque envoi · journal · centre des envois (tableau de bord)
```

La transaction métier ne fait **jamais** d'appel à un fournisseur : elle écrit
l'événement, la notification et les envois, puis se termine. Si elle est
annulée, rien n'existe ; si un fournisseur est en panne, le colis est quand
même enregistré. Si le moteur de notifications lui-même échouait, le
déclencheur l'attrape : l'opération métier passe, sans notification
(`essai-notifications.py`, partie F).

## 2. Événements utilisés

Seuls des événements qui existaient déjà :

| Source | Événement | Notification (type stable) |
|---|---|---|
| `colis_historique` | `COLIS_RECU` | `shipment_received` |
| | `COLIS_EMBALLE` | `shipment_packed` |
| | `COLIS_EXPEDIE` | `shipment_shipped` |
| | `COLIS_ARRIVE` | `shipment_arrived` |
| | `COLIS_TRANSFERE` | `shipment_transferred` |
| | `COLIS_DISPONIBLE` | `shipment_available` (prioritaire) |
| | `COLIS_LIVRE` | `shipment_delivered` |
| | `ACTION_REQUISE` | `action_required` (prioritaire) |
| | `ACTION_RESOLUE` | `action_resolved` |
| `evenements_facturation` | `FACTURE_CREEE` | `invoice_created` |
| | `PAIEMENT_ENREGISTRE` | `payment_received` |
| | `FACTURE_PAYEE` | `invoice_paid` |
| planificateur (chaque matin) | facture échue | `invoice_overdue` |

Ne notifient jamais : les étapes internes (`COLIS_INSPECTE`, `COLIS_CONSOLIDE`,
`COLIS_CHARGE`), les corrections (`CORRECTION`), les annulations de paiement
ou de facture, et tout ce qui est écrit pendant une reprise de données
(`contexte_reprise()`).

## 3. Règles et matrice des canaux

Une règle par type (`notification_regles`) : active ou non, priorité, canaux
extérieurs, « sensible » (texte neutre sur l'écran verrouillé). La
notification dans l'espace client part toujours quand la règle est active.
Réglages de départ :

| Notification | Espace client | Téléphone | E-mail | WhatsApp | SMS |
|---|---|---|---|---|---|
| Colis reçu | ✓ | ✓ | ✓ | ✓ (modèle `colis_recu`) | — |
| Emballé, expédié, arrivé, transféré, livré | ✓ | ✓ | — | — | — |
| Colis disponible | ✓ | ✓ | ✓ | ✓ (modèle `colis_disponible`) | — |
| Action requise | ✓ | ✓ (texte neutre) | ✓ | — | — |
| Action résolue | ✓ | ✓ | — | — | — |
| Nouvelle facture | ✓ | ✓ (texte neutre) | ✓ | — | — |
| Paiement enregistré | ✓ | ✓ (texte neutre) | ✓ | — | — |
| Facture payée | ✓ | ✓ (texte neutre) | — | — | — |
| Facture en retard | ✓ | ✓ (texte neutre) | ✓ | — | — |

Un canal coché ne part que s'il est **configuré** (section 6). Aucun SMS :
le projet n'a pas de fournisseur SMS. WhatsApp ne part que pour les types qui
ont un modèle approuvé par Meta (`modele_whatsapp()`).

L'administrateur (`settings.manage`) coupe une règle ou change ses canaux
depuis le tableau de bord, onglet **Notifications** ; chaque changement est
journalisé (`journal_audit`, action `notification.regle`). Relancer la
migration ne remet pas les règles à leur valeur de départ.

## 4. Textes et langues

`notification_textes()` : titre et message de chaque type en français,
anglais, espagnol et créole. Variables permises : `{{numero}}` (colis),
`{{facture}}`, `{{montant}}` — lues dans la base, jamais tapées par un
client ; toute autre `{{…}}` est effacée. Le montant est mis en forme par la
base (`40,00 $`, `$40.00`).

Langue : celle de l'écran quand le client lit (site, application), celle de
son compte (`clients.langue`) pour le téléphone, l'e-mail et WhatsApp, le
français à défaut. La copie démo (`assets/js/api.js`) a les mêmes textes ;
`essai-notifications.py` vérifie qu'ils sont identiques.

## 5. Idempotence, doublons, regroupement

- Une notification par clé unique (`notifications.cle`, index unique) :
  `etape:<id de l'étape>:<type>`, `facture:<id>`, `paiement:<id>`,
  `retard:<id de facture>`. Rejouer un événement, deux traitements en même
  temps : une seule notification.
- Un envoi par (notification, canal, cible) : contrainte unique.
- Le travailleur prend ses envois avec `for update skip locked` : deux
  passages simultanés n'envoient jamais la même ligne deux fois.
- Un paiement qui solde la facture ne donne que « Facture payée » (pas deux
  messages dans la même seconde).
- Un rappel de retard par facture, jamais pour une échéance antérieure à la
  mise en service (`notification_moteur.actives_depuis`), jamais sans échéance.

## 6. Canaux et fournisseurs

Les clés restent dans le coffre-fort de Supabase (Vault), posées dans le SQL
Editor ; aucune ne sort vers une page (le tableau de bord ne voit que
« configuré / non configuré »).

| Canal | Fournisseur | Réglages (SQL Editor) | État |
|---|---|---|---|
| Espace client | la base | aucun | toujours actif |
| Téléphone | Expo Push (`exp.host`) | aucun ; il faut l'application mobile avec un `projectId` EAS et les clés FCM / APNs chez Expo | configuré côté base ; livraison réelle non vérifiable sans ces clés |
| E-mail | Brevo ou Resend | `definir_reglage('email_fournisseur', 'brevo')`, `('email_cle_api', …)`, `('email_expediteur', …)`, `('email_nom', …)` | déjà prévu par `supabase.sql` ; actif dès que les clés sont posées |
| WhatsApp | API WhatsApp Cloud (Meta) | `definir_reglage('whatsapp_jeton', …)`, `('whatsapp_numero_id', …)`, modèles `colis_recu` et `colis_disponible` approuvés | inactif sans jeton |
| SMS | — | aucun fournisseur choisi | non configuré |

Lien des e-mails : `definir_reglage('site_url', 'https://…')`. Seule une adresse
`https://` d'un domaine est acceptée ; sinon l'e-mail part sans bouton.

## 7. File, nouveaux essais, échecs

Statuts d'un envoi (`notification_envois.statut`) :

| Statut | Sens |
|---|---|
| `attente` | à envoyer à `prochain_essai_le` |
| `envoi` | remis à pg_net, réponse pas encore lue |
| `envoye` | **accepté** par le fournisseur (identifiant gardé dans `message_id`) — pas « lu », ni forcément « reçu » |
| `livre` | remise confirmée par le fournisseur — aucun retour branché aujourd'hui (section 9) |
| `echec` | refus définitif, ou trois essais ratés |
| `annule` | jamais parti : `NON_CONFIGURE`, `PREFERENCE`, `SANS_APPAREIL`, `SANS_DESTINATAIRE`, `SANS_MODELE` |

Erreur **temporaire** (délai dépassé, pas de réponse en 10 minutes, 408, 425,
429, 5xx, `MessageRateExceeded`) : nouvel essai 30 s, puis 2 min, puis 10 min
plus tard ; au troisième échec, `echec` avec le code `ABANDON_…`. Erreur
**définitive** (400, 401, 403, 404, 422 : adresse, numéro, jeton ou modèle
invalide) : `echec` tout de suite, jamais réessayé. Un téléphone qu'Expo ne
connaît plus (`DeviceNotRegistered`) est retiré de `appareils`.

Débit : au plus `notification_moteur.lot` envois par passage (50 par défaut),
un passage par minute. Priorité : les règles `haute` passent d'abord.

Conservation : les envois terminés depuis plus de 180 jours sont supprimés
chaque matin (`notifications_quotidiennes`) ; les notifications, historique du
client, restent.

## 8. Préférences, transactionnel et commercial

Le client coupe un canal par catégorie (colis, factures, paiements) dans
« Mon compte » ; sans réglage, tout est actif. La notification dans son
espace ne se coupe pas. Tout est **transactionnel** : il n'y a aucun message
commercial dans le projet. Un futur envoi commercial aurait son propre
consentement et sa propre désinscription, jamais ceux-ci.

## 9. Webhooks (non branchés)

Brevo, Resend et Meta savent signaler la remise réelle d'un message par un
webhook. Ce n'est pas branché : un webhook doit vérifier une signature sur le
corps brut de la requête, ce que PostgREST ne permet pas — il faudrait une
Supabase Edge Function (vérification de la signature et de l'horodatage,
refus des rejeux, puis `update notification_envois set statut = 'livre'`).
En attendant, aucun envoi n'est jamais marqué « livré ».

## 10. Plateformes

- **Site** (« Mon compte ») : liste, badge des non lues, filtres, « tout
  marquer comme lu », réglages des canaux. Mise à jour en direct (table
  `notifications` dans la publication `supabase_realtime`).
- **Tableau de bord** (et l'application de bureau, qui l'affiche) : onglet
  **Notifications** (`reports.view`) — chiffres, alertes, envois filtrés,
  suivi d'une notification, canaux, règles et essai (`settings.manage`). À
  l'enregistrement d'un colis, le dialogue montre ce que la base a prévu ; il
  n'envoie plus rien. Le lien « Envoyer depuis mon WhatsApp » reste pour
  l'envoi à la main quand l'API WhatsApp n'est pas configurée.
- **Application mobile** : la notification du téléphone porte `colis_id` (ou
  `facture_id` et `route`) ; les versions installées ouvrent le colis ou
  l'onglet Factures. `mon_resume` garde sa forme : les versions installées
  voient les envois partis dans « Messages ».

## 11. Sécurité

| Qui | Peut |
|---|---|
| Visiteur | rien |
| Client | lire ses notifications (`mes_notifications`, et la table filtrée par RLS), les marquer lues, régler ses canaux — jamais celles d'un autre |
| Employé | voir les envois d'un colis (`envois_colis`) |
| Gérant (`reports.view`) | centre des envois, suivi, règles en lecture |
| Administrateur (`settings.manage`) | changer une règle, envoyer un essai **à son propre compte**, une fois par minute |

Personne ne peut créer une notification, lancer le travailleur ou choisir le
contenu d'un message depuis une page : `creer_notification`,
`traiter_notifications` et les fonctions des fournisseurs ne sont ouvertes à
aucun compte. `envoyer_email_client` et `envoyer_whatsapp_client`, qui
prenaient le HTML d'une page, ne sont plus ouvertes aux comptes. Les tables
`notification_envois`, `notification_regles`, `notification_preferences` et
`notification_moteur` n'ont aucun accès direct.

Données minimisées : un envoi garde une cible (`appareil:<id>`, `email`,
`whatsapp`), jamais l'adresse, le numéro ou le jeton ; l'erreur gardée est un
code et un texte court du fournisseur. Écran verrouillé : pour une règle
« sensible », le téléphone n'affiche que « Une mise à jour concernant votre
compte est disponible ». Contenus échappés dans l'e-mail (`html_echappe`).

## 12. Mise en service

1. Exécuter `outils/supabase-notifications.sql` (après `supabase-mobile.sql`).
   Contrôle attendu : `regles 13 | declencheurs 2 | ancien_push 0 |
   ouvertes_aux_visiteurs false | planificateur 2`.
2. Si `planificateur` vaut 0 : Database > Extensions > **pg_cron**, puis
   relancer le fichier. Sans lui, les envois attendent (rien n'est perdu).
3. E-mail : poser les réglages de la section 6. WhatsApp : jeton, numéro,
   modèles approuvés.
4. Tableau de bord > Notifications > « Essai vers mon compte » sur chaque
   canal configuré.

## 13. Dépannage : « pourquoi ce client n'a-t-il rien reçu ? »

Tableau de bord > Notifications > « Suivi » sur la ligne : événement → règle →
notification → chaque envoi (statut, essais, code). Ou, dans le SQL Editor :

```sql
select * from notifications where client_id = '<id>' and canal = 'app' order by envoye_le desc limit 5;
select canal, statut, code_erreur, tentative, erreur, prochain_essai_le
  from notification_envois where notification_id = <id>;
select * from cron.job_run_details order by start_time desc limit 5;   -- le travailleur tourne-t-il ?
```

| Symptôme | Cause probable |
|---|---|
| aucune notification | règle coupée, étape interne, colis sans client |
| `annule / NON_CONFIGURE` | clé du fournisseur absente du coffre-fort |
| `annule / SANS_APPAREIL` | le client n'a pas l'application, ou a refusé les notifications |
| `attente` qui dure | pg_cron absent ou arrêté (alerte « file bloquée » au tableau de bord) |
| `echec / HTTP_401` | clé ou jeton du fournisseur invalide |
| `echec / DeviceNotRegistered` | application désinstallée (le téléphone est oublié) |

## 14. Essais

- `outils/essais-services/essai-notifications.py` — base jetable, toutes les
  migrations ; fournisseurs simulés (réponses écrites dans
  `net._http_response`) : règles, idempotence et concurrence, nouveaux essais
  et abandon, multi-canal, panne de pg_net, préférences, sécurité par compte,
  rappels, échappement, forme des réponses démo = base, volume (10 000
  envois, quatre travailleurs en parallèle).
- `outils/essais-services/essai-notifications.js` — la copie démo.
- `outils/essais-services/essai-mobile.py` — l'application mobile sur la
  même base (les notifications incluses).

Impossibles ici : une vraie livraison (clés Expo/FCM/APNs, Brevo, Meta), un
vrai téléphone, un webhook de fournisseur.
