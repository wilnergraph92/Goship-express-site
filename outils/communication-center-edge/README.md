# C4 — composants Edge locaux du Communication Center

Ce projet Supabase local est rangé sous `outils/` afin que ses sources ne soient
pas copiées dans l'artefact public par `.github/workflows/deploy.yml`.
La CLI Supabase peut viser ce projet avec `--workdir
outils/communication-center-edge`. Aucun environnement distant n'est lié ici.

## État des composants

- `communication-webhooks` : vérifie Meta sur le corps brut, l'en-tête Bearer
  configuré de Brevo et la signature Svix/Resend ; normalise les événements et
  attend la confirmation positive du RPC avant de répondre 200.
- `communication-expo-receipts` : accepte uniquement un lot interne de tickets
  déjà accepté par Expo et âgé d'au moins 15 minutes ; limite les lectures à la
  fenêtre de conservation de 24 heures. Une réponse `ok` signifie que FCM/APNs
  a pris en charge le message, pas que le terminal l'a affiché.
- `communication-worker` : point d'entrée local protégé par un jeton d'appel
  interne distinct. Il traite P-08, réconcilie Expo, traite les demandes de
  confirmation WhatsApp liées à l'outbox, puis appelle l'outbox transactionnelle
  existante, qui conserve la porte P-07.
- `worker-orchestrator.mjs` et `worker-adapters.mjs` : orchestration et appels
  RPC testables. Le worker Edge appelle les fonctions SQL candidates avec un JWT
  ES256 signé localement par l'adaptateur à partir d'une clé configurée. Sans
  configuration explicitement autorisée, les appels échouent fermés.
- `whatsapp-template-adapter.mjs` : prépare un modèle Meta de confirmation avec
  le code transmis seulement dans le corps de la requête fournisseur. Le nom du
  modèle et les paramètres Meta restent configurés à l'exécution. La reprise
  s'appuie sur une liste bornée de codes Meta explicitement temporaires ; un
  429 non reconnu reste incertain. Sans configuration complète, le worker ne
  réserve aucune nouvelle demande.
- `supabase-rpc.mjs` : transport PostgREST borné aux rôles attendus, avec la clé
  publishable/anon et sans clé de service.

## Raccordements bloqués

La candidate `006-communication-p08-worker.sql` fournit le RPC générique de
réception, le traitement atomique de la file P-08, le retrait STOP, le journal des
transitions, ainsi que les RPC de reçus Expo et d'outbox. La candidate
`009-communication-identite-edge.sql` relie maintenant, dans la transaction de
demande, une confirmation à l'outbox existante et réserve son code au worker
authentifié. Les candidates restent hors de la chaîne officielle, comme les
candidates 001–008. Le draft 43 ne doit pas être exécuté.

L'option S-1 prépare les rôles `communication_webhook` et
`communication_worker`, leurs memberships PostgREST dédiés et une validation
des claims applicatifs. Cela reste du SQL candidat local : aucune appartenance,
clé ou configuration distante n'est activée par ce dépôt. Le client RPC signe
des JWT ES256 à courte durée avec la clé privée fournie par configuration,
utilise seulement une clé publishable/anon Supabase et refuse le rôle
`service_role`. Sans une clé correspondante explicitement approuvée côté
PostgREST et sans les valeurs de configuration requises, les appels échouent
fermés.

Le sender WhatsApp exige `META_WHATSAPP_ACCESS_TOKEN`,
`META_WHATSAPP_PHONE_NUMBER_ID`, `META_WHATSAPP_API_VERSION` et
`META_WHATSAPP_CONFIRMATION_TEMPLATE`. Aucun nom de modèle de confirmation
WhatsApp n'est versionné ou approuvé dans le dépôt. Ces variables ne sont pas
configurées ici ; aucun message réel ni appel fournisseur n'est effectué par
les tests locaux. Aucune garantie d'idempotence fournisseur n'est revendiquée.

Le traitement P-08 candidat conserve la réservation, les effets métier et l'état
final dans un seul appel RPC/transaction : les verrous de ligne `SKIP LOCKED`
restent détenus jusqu'au commit, et une interruption annule les effets avec
l'état. Il n'y a pas de réservation multi-RPC ni de bail persistant. Les
événements de plainte et de désinscription Email restent en échec prioritaire
tant que leur correspondance à une identité GoShip n'est pas définie ; ils
bloquent la sortie et ne sont pas déclarés traités.

Les événements de désinscription de contact Resend/Brevo ne sont pas convertis
en retrait GoShip : ils ne sont pas nécessairement rattachés à un envoi
`notification_envois` existant et les candidates actuelles ne définissent pas
le rapprochement compte/contact autorisé. Aucun rapprochement par courriel ni
aucune règle métier n'est inventé ici.

## Tests locaux

Les handlers partagés peuvent être exercés sans Deno, CLI Supabase, base
distante, fournisseur, secret réel ou message réel :

```text
node --test outils/essais-services/essai-communication-edge.mjs
```

Mise à jour du 23/11/2026, qui remplace le constat initial « CLI Supabase et Deno
non disponibles » : une stack Supabase locale `goship-communication-center-local`
a été démarrée pendant l'incrément C7.3 (PostgreSQL 17.12, PostgREST 16.5,
Kong 2.8.1, GoTrue 2.198.0). D'après le compte rendu de Codex, les vérifications
suivantes y ont réussi : JWT ES256 valide accepté, jeton altéré rejeté, appel
croisé refusé en 403, et Edge servie répondant 401 pour un jeton invalide et 503
pour une configuration absente. Ces vérifications ne sont pas reproductibles
depuis le dépôt, faute de procédure versionnée. Le **parcours de succès de l'Edge
servie n'est pas validé**. Le runtime Edge est arrêté. Le 23/11/2026 à
07:32 UTC, les conteneurs `db`, `rest`, `auth` et `kong` ont été arrêtés sans
suppression, car leurs ports étaient publiés sur toutes les interfaces. Un
nouveau démarrage doit d'abord limiter ces ports à `127.0.0.1` et fait l'objet
d'une autorisation distincte. Détails et limites :
`docs/communication-center/COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md`.

Le démarrage local a créé `supabase/.temp/`, qui contient un fichier de secrets
de démarrage du runtime Edge local. Depuis le 23/11/2026, Git l'ignore grâce à
la règle `**/supabase/.temp/` du `.gitignore` racine : ne jamais forcer son
ajout (`git add -f`). Il est exclu de la publication, puisque `deploy.yml`
exclut `outils`.

Aucun déploiement n'est effectué. Les essais SQL des candidates s'exécutent sur
des bases PostgreSQL locales jetables ; ils ne rendent aucune candidate
exécutable à distance. Les fonctions `pgcrypto`/Vault simulées par ce banc
valident le chemin applicatif et les permissions, pas les propriétés
cryptographiques du service réel.

## Gouvernance

Phase 1.3.1 : **NON VALIDÉE**. Phase 2 : **NON AUTORISÉE**. SQL drafts 40–43 :
**NON EXÉCUTABLES**. Les fichiers ici sont du code local de préparation ; ils
n'activent aucun canal, webhook, ordonnanceur ou worker distant.
