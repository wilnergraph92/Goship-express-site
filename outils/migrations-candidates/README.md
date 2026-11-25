# Migrations candidates — Communication Center

Ces fichiers sont des candidates de construction et de vérification locales.
Depuis le 23/11/2026 (étape C11, autorisée par la CEO), ils **ferment la chaîne
officielle** `outils/migrations.txt`, pour les essais locaux et la CI seulement.
Ce ne sont pas des instructions d'application sur une base distante :
`outils/production/appliquer-chaine.sh` s'arrête avant eux sans
`APPLIQUER_CANDIDATES=oui` (base jetable) et les refuse toujours sur l'adresse de
production ; la sonde de production et `controle-securite.sql` les disent
« réservés aux essais » (critère C14 de `docs/production/go-no-go.md`).

Ils sont rejouables : une chaîne rejouée sur une base existante les réapplique
après les fichiers officiels. La 004 et la 005 enveloppent alors l'adaptateur et
le travailleur les plus récents (corrigé le 23/11/2026, essai « C11 — rejeu de la
chaîne » du banc).

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
   structuré des états, passage par P-07 et état incertain (voir la décision K en 005).
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
11. `011-communication-reglages-decides.sql` — réglages décidés le 23/11/2026
   (H2, H3) pour la candidate 003 : code valable 60 min, 5 erreurs au plus sur
   le numéro, 3 demandes par 24 h par compte et par numéro, numéro partagé
   bloqué. Le fichier ne remplace jamais une valeur déjà réglée. Il est appliqué
   à part par le banc, parce que les essais de 003 vérifient d'abord le refus
   fermé quand aucun réglage n'est fixé (`tester_c9_reglages_et_alertes`).

Corrections du 23/11/2026 (C9) :
- **002** : la supervision lit désormais l'outbox unique `notification_envois`,
  avec ses statuts réels (`attente`, `confirmation`, `envoi`, `envoye`, `livre`,
  `echec`, `incertain`, `annule`), et la tâche `pg_cron` officielle
  `goship-notifications`. Avant, elle lisait la table `communication_envois` des
  brouillons, qui n'existe pas, et des statuts inexistants : le tableau de bord
  ne pouvait jamais afficher de transmission en cours.
- **004, débit du travailleur** : `traiter_notifications` sortait de sa boucle
  après **une seule** transmission par transaction. Comme `pg_cron` l'appelle une
  fois par minute, la plateforme entière n'aurait envoyé qu'un message par minute.
  Ce défaut a été trouvé par `essai-communication-non-regression.py`. Désormais,
  chaque ligne repasse la porte P-07 : l'état de l'arrêt est relu et le lot
  s'interrompt dès qu'un arrêt est demandé. Seul le travailleur rouvre la porte
  entre deux lignes ; un appel d'adaptateur non autorisé reste refusé.
- **004, file bloquée** : une ligne qu'aucun adaptateur ne sert (canal `sms`,
  accepté par l'outbox) faisait sortir la boucle à chaque passage et bloquait
  toutes les lignes suivantes. Elle est maintenant annulée
  (`CANAL_NON_AUTORISE`), et le lot continue.
- **004, travailleurs simultanés** : les lignes du lot sont verrouillées en
  `SKIP LOCKED` juste après N0 partagé (ordre V0 → V4). Avant, elles étaient lues
  sans verrou, et des travailleurs simultanés visaient les mêmes lignes.
- **004, `texte_notification`** : la fonction lit de nouveau `notification_modeles`
  (modèles modifiables par l'équipe, dont les anniversaires) avant les textes
  fixes ; sans cela, un message d'anniversaire serait parti vide. La langue
  demandée, celle de l'écran ou du client, prime sur la langue retenue à la
  création.
- **005, appareil Expo désinscrit** : le code `DeviceNotRegistered` est conservé
  et l'appareil est oublié, comme dans le moteur officiel.
- **005, décision K** (CEO, 23/11/2026) : les réponses 408, 425 et 5xx, les
  erreurs réseau, les délais dépassés et les silences des fournisseurs sont
  réessayés comme dans le moteur officiel (30 s, 2 min, puis `ABANDON_…`). Seul
  écart restant, volontaire : une limite de débit s'appelle `LIMITE_DEBIT` et non
  `HTTP_429`.
- **007** : `communication_c5_sante` ajoute deux alertes (décision D) :
  `EVENEMENTS_EN_RETARD`, pour un retour non traité depuis plus de 10 min, et
  `ARRET_NON_CONFIRME`, pour un arrêt demandé mais non confirmé depuis plus de
  2 min.

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
fournisseur absente est réessayée par la version de `lire_reponse_envoi` de 005
(décision K).

La candidate 004 ne configure ni n'active de fournisseur et ne lance pas de
travailleur. Elle peut toutefois préparer des lignes dans la file existante à
partir des événements GoShip. Ne l'applique pas dans un environnement où un
travailleur transactionnel est actif. Le banc remplace le point d'envoi dans
chaque base jetable par un adaptateur local, sans appel fournisseur.

La candidate 005 ne configure ni n'active de canal. Elle garde le point d'envoi
historique derrière P-07 et distingue l'acceptation, le refus, la limite de débit,
le rejet définitif et le résultat incertain. Le classement garde « incertain » pour un délai, une erreur réseau, une 5xx ou une
réponse incomplète ; depuis la décision K, `lire_reponse_envoi` réessaie pourtant
les quatre premiers cas pour une notification transactionnelle, comme le moteur
officiel. Restent incertaines, sans reprise : une réponse 2xx sans identifiant de
message et les codes de confirmation WhatsApp. L'adresse e-mail reçoit un contrôle syntaxique minimal avant l'appel
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
persistant. Un message classé STOP crée une suppression par empreinte et retire les
consentements ouverts de tous les comptes partageant ce contact.

Correction P-09 (reportée le 23/11/2026 depuis les brouillons D5) : la classe d'un
message entrant est calculée à la réception par `communication_classer_entrant`
(interne, aucun rôle d'API ne peut l'appeler), sans garder le texte. Désabonnent :
un bouton de désinscription ; un message entier de la liste fermée (« STOP »,
« Stop please », « Arrêter », « Désabonner », « Unsubscribe », « Baja », « Kanpe »,
« Sispann »…) ; un message de 5 mots au plus qui commence par un verbe d'arrêt sans
ambiguïté (« Arrêter les promotions »). Un mot d'arrêt ailleurs dans un message plus
long est classé « ambigu » et ne retire rien ; « Arrêt », « Fin », « Cancel », « End »
et « Quit » ne comptent que seuls (« Arrêt de bus » ou « Cancel my order » ne
désabonnent pas). Les listes restent à valider par le juriste.

Candidate 012 (24/11/2026) — **envoi des campagnes marketing**, par l'outbox unique
`notification_envois`, le travailleur existant et la porte P-07 : l'arrêt d'urgence
s'applique au marketing comme au transactionnel. Une campagne approuvée et planifiée est mise
en file à son heure (`communication_campagnes_lancer`, tâche pg_cron chaque minute) ;
chaque ligne est revérifiée au moment de transmettre (campagne non annulée, consentement,
STOP ou désinscription, contact inchangé) et annulée avec un code `MARKETING_*` sinon.
Règles : un message par contact, campagne et canal (P-05) ; au plus N messages par contact
et par canal sur une fenêtre (N-01, réglage Admin **sans valeur par défaut** : tant qu'il
manque, rien ne part) ; quota par canal ; numéro ou adresse partagé exclu (D2) ; aucun
nouvel essai après un résultat incertain. WhatsApp : modèle Meta réglé par
`whatsapp_modele_marketing`. E-mail : consentement propre au canal donné depuis le compte
(adresse confirmée, texte attesté), lien de désinscription sans connexion et en-tête
`List-Unsubscribe` dans chaque message ; sans adresse officielle du site en https, aucun
e-mail marketing ne part ; sans adresse postale (réglage `courriel_adresse_postale`,
loi CAN-SPAM), non plus. Un plafond facultatif d'e-mails marketing sur 24 heures
(`email_max_jour`) garde la part du quota quotidien du fournisseur qui revient aux
notifications de colis (Brevo gratuit : 300 par jour). L'aperçu d'audience (008) et l'envoi partagent la même règle
d'éligibilité. Les tables gardent des empreintes, jamais un numéro ou une adresse.
Depuis le 25/11/2026 (avis juridique : oppositions reçues « par d'autres voies »), un membre
de l'équipe qui voit les clients enregistre un refus des offres donné au téléphone ou au
comptoir (`communication_opposition_enregistrer`, fiche client du tableau de bord) : le
contact actuel entre dans la liste d'exclusion (raison `opposition_equipe`), l'accord du
canal est retiré (source `opposition_equipe`, ajoutée aussi à la liste de 006 pour que la
chaîne reste rejouable) et chaque demande est gardée dans un journal immuable. Seul le
client peut redonner son accord.

Candidate 009 applicable sans superutilisateur (23 et 24/11/2026), constaté et éprouvé sur
l'image Supabase réelle (`outils/essais-supabase-reel/lancer.sh`, où toute la chaîne passe
par `postgres`). Chez Supabase hébergé, `postgres` n'est pas superutilisateur et le client
n'en a aucun. Depuis PostgreSQL 16, quand `postgres` crée `communication_webhook` (005) et
`communication_worker` (006), il en devient membre avec ADMIN OPTION, sans INHERIT ni SET.
La 009 accepte ce seul membership de créateur et s'en sert pour accorder les deux rôles à
`authenticator` ; tout autre membership reste refusé. Elle s'applique par `postgres` ou par
une session superutilisateur (bancs locaux), et refuse tout autre rôle. Chez Supabase,
`postgres` est de toute façon membre d'`authenticator` (INHERIT et SET) : il atteint déjà ces
rôles par lui, comme `anon`, `authenticated` et `service_role`. Les plaintes et
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

La non-régression `outils/essais-services/essai-communication-non-regression.py`
rejoue tels quels `essai-notifications.py`, `essai-accuses.py`,
`essai-suivi-courriels.py` et `essai-programmes.py` avec ces candidates
appliquées par-dessus la chaîne officielle (une cible ou plusieurs peuvent être
nommées en argument). Un écart voulu par les candidates n'y est accepté que s'il
est inscrit dans `ECARTS_VOLONTAIRES`, avec sa raison et sa valeur exacte.

La candidate 007 n'ajoute pas de droits au Manager : les vues générales restent
protégées par `communications.view`, tandis que la gestion des modèles, la
lecture des consentements marketing et la reprise ciblée disposent de
permissions Admin distinctes. L'historique, la file, les aperçus et les
consentements omettent les coordonnées, empreintes, codes et charges brutes.
Les reprises ne concernent que des événements entrants STOP explicitement
éligibles ; aucun envoi de fournisseur n'est lancé par la RPC. Cette interface
ne constitue pas une validation de la Phase 1.3.1.

Ces candidates ne valident pas la Phase 1.3.1 et ne permettent pas d'exécuter les
drafts SQL 40–43. Leur intégration dans la chaîne officielle (C11) a été autorisée
par la CEO le 23/11/2026 pour les essais locaux et la CI ; toute opération distante
(préproduction, production) exige une autorisation écrite distincte et une revue
indépendante.


Répétition générale sur un projet Supabase d'essai hébergé (jamais la production) :
`outils/essais-supabase-reel/repetition-generale.sh`, lancé depuis un poste avec `psql`.
Il refuse l'adresse de la production, fait retaper la référence du projet, applique la
chaîne deux fois par `postgres`, puis lance `verifier.py` en mode hébergé.
