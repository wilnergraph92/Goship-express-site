# Migrations candidates — Communication Center

Ces fichiers sont des candidates de construction et de vérification locales. Ils
ne font pas partie de `outils/migrations.txt` et ne sont pas des instructions
d'application sur une base distante.

## Séquence actuelle

1. `001-communication-foundation.sql` — porte P-07 synchronisée (demande
   durable, confirmation sous N0 exclusif) et tables des retours fournisseurs.
2. `002-communication-supervision.sql` — RPC de supervision à liste blanche,
   protégé par `communications.view`.
3. `003-communication-consentements.sql` — état courant marketing, historique
   append-only, demandes et tentatives WhatsApp, code chiffré au repos et RPC
   limités au compte client ou au rôle backend.
4. `004-communication-transactionnelle.sql` — modèles transactionnels versionnés,
   liaison aux événements et à la file `notification_envois` existante, historique
   structuré des états, passage par P-07 et arrêt des reprises au résultat incertain.
5. `005-communication-adaptateurs-canaux.sql` — normalisation des réponses Expo,
   Meta, Brevo et Resend vers les états communs ; raccord des retours transactionnels
   normalisés aux tables P-08 existantes et au worker transactionnel existant.
6. `006-communication-p08-worker.sql` — réception générique signée, traitement
   prioritaire P-08 dans une transaction atomique, retrait STOP par empreinte,
   historique des transitions, et rapprochement des reçus Expo dans l'outbox
   existante.
7. `007-communication-interface-operations.sql` — RPC C5 expurgées pour le
   tableau de bord, l'historique filtré, les modèles transactionnels versionnés,
   la consultation Admin des consentements et la reprise bornée des seuls STOP
   entrants idempotents. Les permissions d'écriture/consentement/reprise sont
   attribuées à l'Admin uniquement ; les transmissions incertaines ne sont pas
   relançables.
8. `008-communication-campagnes-marketing.sql` — C6 : campagnes marketing,
   segments, approbations et planification, **sans envoi**. Les consentements
   WhatsApp existants sont réutilisés ; les autres canaux restent inéligibles
   tant qu'ils n'ont pas leur propre source de consentement. La candidate
   redéfinit `permissions_du_role` : l'Admin reçoit
   `communications.campaigns.view`, `.manage` et `.approve` ; le Gérant reçoit
   `.view` et `.manage`, sans approbation. Aucun rôle ne reçoit de permission de
   transmission marketing.
9. `009-communication-identite-edge.sql` — option S-1 candidate : schéma
   `communication_edge`, rôles `communication_webhook` et `communication_worker`
   sans connexion, membres d'`authenticator`. Chaque RPC Edge vérifie
   l'émetteur, l'audience et la durée maximale du JWT, réglés par
   `app.communication_jwt_*` sur `authenticator` ; sans ces réglages, elle échoue
   fermé. La candidate rattache aussi la demande de confirmation WhatsApp à une
   tâche de l'outbox `notification_envois` existante, sans deuxième file. Elle
   exige une session superutilisateur, car elle donne des appartenances à
   `authenticator`.
10. `010-communication-arret-administration.sql` — arrêt d'urgence côté Admin
   (décision C du 23/11/2026). Nouvelle permission `communications.emergency_stop`,
   réservée à l'Admin. RPC `communication_c10_arret_etat`, `_demander` et
   `_confirmer` (qui délèguent aux fonctions de 001, donc toujours en deux appels
   distincts), et `_lever`. La levée prend N0 exclusif puis N0a, exige un motif d'au
   moins 10 caractères et la version affichée, refuse un état modifié entre-temps,
   et s'inscrit au `journal_audit`. Les fonctions de 001 restent réservées à
   `service_role`. Le banc applique 010 après 008 et l'éprouve en dernier
   (`tester_c10_arret_admin`).

Les candidates dépendent de la chaîne officielle existante, notamment des
rôles Supabase, de `public.exiger_permission(text, uuid)` et de la permission
`communications.view`. Au 23/11/2026, cette permission est ajoutée aux rôles
admin et gérant par une modification locale **non commitée** de
`outils/supabase.sql` et de ses deux copies (`supabase-naissance.sql`,
`supabase-suivi-externe.sql`). Ce changement de la chaîne officielle attend
une décision. La RPC rapporte les envois uniquement si la table
correspondante existe ; elle ne fabrique pas de compteurs pendant les étapes où
la file d'envoi n'a pas encore été intégrée. L'état du travailleur est déclaré
non mesurable si les vues `pg_cron` sont absentes.

La candidate 003 n'active aucun canal et n'envoie aucun message. Les durées,
limites de tentatives et de demandes, ainsi que le comportement pour un numéro
partagé, restent sans valeur par défaut ; les RPC échouent fermé tant que les
paramètres correspondants ne sont pas définis par une décision approuvée. Les
codes en attente sont conservés comme secrets Vault plutôt qu'en clair dans les
tables métier. Avant toute intégration, les privilèges Vault effectifs de
`service_role` doivent être vérifiés : la plateforme peut lui donner un accès
direct aux secrets déchiffrés, au-delà de la RPC candidate. Aucun fournisseur
ni worker d'envoi n'est créé ici. Le PostgreSQL embarqué par
`pgserver` ne distribue pas `pgcrypto` : le banc dédié substitue des doublures
non cryptographiques pour contrôler les appels, le format et les permissions ;
il ne valide pas la robustesse de HMAC ni le chiffrement au repos assuré par Vault.
Cette candidate porte uniquement le consentement marketing ; les préférences
transactionnelles restent dans le modèle de notifications existant.

La candidate 004 ne crée pas de deuxième outbox ni de nouveau travailleur. Elle
réutilise `colis_historique`, `notifications`, `notification_regles` et
`notification_envois` du moteur GoShip existant. Les modèles de version 1 sont
initialisés depuis `notification_textes()` ; chaque notification nouvelle
conserve la version et la langue sélectionnées. La vue de l'outbox et le RPC de
prévisualisation n'exposent ni destinataire ni erreur libre. Une réponse
fournisseur absente devient `incertain` et n'est pas réessayée automatiquement.

La candidate 004 ne configure ni n'active de fournisseur et ne lance pas de
travailleur. Elle peut toutefois préparer des lignes dans la file existante à
partir des événements GoShip. Ne l'applique pas dans un environnement où un
travailleur transactionnel est actif. Le banc remplace le point d'envoi dans
chaque base jetable par un adaptateur local, sans appel fournisseur.

La candidate 005 ne configure ni n'active de canal. Elle garde le point d'envoi
historique derrière P-07 et distingue l'acceptation, le refus, la limite de débit,
le rejet définitif et le résultat incertain. Seuls les refus explicites de débit
sont automatiquement réessayés ; délai, réseau, réponse incomplète et 5xx deviennent
incertains. L'adresse e-mail reçoit un contrôle syntaxique minimal avant l'appel
historique ; la validation complète reste celle du fournisseur. Les retours P-08 ne conservent pas la charge brute et ne modifient que
le statut de la transmission déjà rapprochée par l'identifiant fournisseur. La
progression des statuts est monotone ; un callback ne crée jamais une transmission.

Le RPC de réception normalisée est limité au rôle `communication_webhook`, sans
connexion. Il suppose un adaptateur Edge qui authentifie séparément le fournisseur
et signe l'enveloppe normalisée. L'adaptateur Edge local existe désormais sous
`outils/communication-center-edge/`, mais son identité RPC n'est pas approuvée ni
configurée ; aucune réception fournisseur distante n'est disponible ou activée.
Un ticket Expo confirme l'acceptation par Expo, pas la remise au terminal. La
candidate 006 prépare les fonctions de persistance des reçus, qui restent à vérifier
dans le runtime Edge et contre une base locale avec les extensions réelles.

La candidate 006 conserve le travail P-08 et l'effet métier dans le même appel RPC
et la même transaction : les lignes sont prises avec `FOR UPDATE SKIP LOCKED`, les
verrous PostgreSQL restent tenus jusqu'au commit et une interruption annule ensemble
les effets et l'état. Elle n'utilise donc pas de réservation multi-RPC ni de bail
persistant. Le STOP exact crée une suppression par empreinte et retire les
consentements ouverts de tous les comptes partageant ce contact. Les plaintes et
désinscriptions Email restent en échec prioritaire tant que leur correspondance avec
une identité GoShip n'est pas définie dans une candidate approuvée ; elles bloquent
les sorties au lieu d'être acquittées comme traitées. Les reçus Expo sont enregistrés
dans l'outbox `notification_envois` et un journal append-only ; `handoff_confirmed`
ne signifie pas livraison au terminal.

La candidate 006, seule, ne rend pas les rôles `communication_webhook` ou
`communication_worker` assumables par PostgREST et ne décide pas comment l'Edge
s'authentifie vers PostgreSQL.

Mise à jour du 23/11/2026 : la candidate 009 et le client Edge implémentent
désormais une option S-1. Les deux rôles deviennent membres d'`authenticator`, et
l'Edge signe localement des JWT ES256 de courte durée avec une clé fournie par
configuration, sans clé `service_role`. Cette option a passé les essais locaux
(`docs/communication-center/COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md`).
**La décision CEO S-1 reste ouverte** : aucune clé, appartenance ni configuration
n'existe hors des bases locales jetables, et l'intégration réelle à Supabase reste
bloquée jusqu'à cette décision de sécurité.

La candidate 001 fournit `communication_autoriser_sortie` : l'autorisation
prend N0 partagé avant toute ligne N4, exige `READ COMMITTED` et reste tenue
jusqu'au commit de la transmission. La demande d'arrêt est persistée dans un
appel séparé ; la confirmation prend N0 exclusif puis N0a, conserve
`autorisations_closes_le` à chaque reprise et ne confirme pas tant que l'outbox
compte des états `envoi` ou `incertain`. L'adaptateur unique de la candidate
004 consomme le marqueur d'autorisation avant l'appel à l'adaptateur historique.
Le worker intégré traite les réponses avant les nouvelles sorties et ne
verrouille une ligne d'envoi qu'après N0. Ces propriétés restent à vérifier par
le banc local ; elles ne constituent pas une validation opérationnelle.

La vérification locale dédiée est `outils/essais-services/essai-communication-center.py`.
Elle utilise deux bases PostgreSQL locales indépendantes et neuves, les
doublures du dépôt et un adaptateur local de transmission.

La candidate 007 n'ajoute pas de droits au Manager : les vues générales restent
protégées par `communications.view`, tandis que la gestion des modèles, la
lecture des consentements marketing et la reprise ciblée disposent de
permissions Admin distinctes. L'historique, la file, les aperçus et les
consentements omettent les coordonnées, empreintes, codes et charges brutes.
Les reprises ne concernent que des événements entrants STOP explicitement
éligibles ; aucun envoi de fournisseur n'est lancé par la RPC. Cette interface
ne constitue pas une validation de la Phase 1.3.1.

Ces candidates ne valident pas la Phase 1.3.1, n'autorisent pas la Phase 2 et ne
permettent pas d'exécuter les drafts SQL 40–43. Toute intégration dans la chaîne
officielle ou toute opération distante exige une autorisation écrite distincte
et une revue indépendante.
