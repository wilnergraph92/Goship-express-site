# GoShip Express — Centre de communication
# COMMUNICATION_CENTER_TESTING.md — plan d'essais (Phase 1.2)

| | |
|---|---|
| Date | 18 novembre 2026 |
| Statut | **Plan préparé. AUCUN de ces essais n'a été exécuté.** Ils le seront en Phase 2, sur autorisation écrite du CEO. **[1.3]** Complété par `PHASE_1_3_TEST_PLAN.md` (T-01 à T-20), qui fait foi là où les deux diffèrent |
| Où | Base PostgreSQL **jetable** du harnais existant (`outils/essais-services/`), avec les doublures habituelles d'`auth`, `vault`, `net`, `cron` ; fournisseurs **simulés** (réponses écrites dans `net._http_response`) ; jamais la production, jamais un vrai fournisseur |
| Nouveaux bancs prévus | `essai-communications.py` (base), `essai-communications.js` (copie démo), `essai-communications-navigateur.mjs` (navigateur, mode démo, `config.js` vide, appels à `*.supabase.co` coupés) |
| Preuve commune | sortie du banc (nombre de vérifications réussies / échouées), journal de la CI `essais.yml`, et pour chaque groupe la preuve citée |

Données fictives communes (jamais de vraies personnes) :
- **Clients** : C1 (HT, fr), C2 (DO, es), C3 (US, en), C4 (HT, ht), C5 (sans téléphone), C6 (compte
  supprimé).
- **Équipe** : A1, A2 (administrateurs), G1 (gérant), E1 (employé).
- **Adresses et numéros** : `…@exemple.invalid` ; `+509 3xxx xxxx`, `+1 809 …`, `+1 787 …`,
  `+1 876 …`, `+1 305 …`, tous fictifs.
- **Coffre de doublure** : `communication_poivre`, `communication_cle_desinscription`,
  `communication_cle_webhook`, avec des valeurs d'essai.

---

## Groupe 1 — Chaîne de migrations 1 → 43, exécutée deux fois
- **Préconditions** : base jetable vide ; gardes « BROUILLON » remplacées (Phase 2 seulement).
- **Scénario** : appliquer `outils/migrations.txt` + 40 à 43, puis tout rejouer.
- **Attendu** :
  - aucune erreur ; la requête de contrôle de 40 donne
    `tables 18 | permissions_admin 7 | permissions_gerant 5 | employe 0 | tarifs 0 | indicatifs_autorises 0 | campagnes_actives false` ([Corrigé 1.3] : 18 tables) ;
  - au second passage, aucune ligne de réglage remise à zéro, aucune tâche dupliquée ;
  - `goship-communications` reste inactive.
- **Échec si** : erreur, doublon de tâche, réglage réécrit, tâche active.
- **Preuve** : sortie complète, comparaison des comptes avant et après le second passage.
- **En plus** : une exécution d'un brouillon AVEC sa garde doit échouer sur `BROUILLON NON APPROUVÉ`
  sans créer aucun objet — [1.3] avec CHAQUE client, y compris `psql` sans `ON_ERROR_STOP` : T-14.

## Groupe 2 — Permissions, rôle par rôle
- **Préconditions** : comptes A1, A2, G1, E1, C1, et un visiteur.
- **Scénario** : appeler **chaque** fonction ouverte avec chaque rôle ; refaire avec A1 ayant un
  appareil de double authentification inscrit, en session aal1.
- **Attendu** :
  - matrice de SECURITY §2.2 exacte ;
  - G1 refusé sur approuver, reprendre, annuler une campagne approuvée, réglages, quota, identité,
    tarifs, indicatifs, liste d'essai, conservation, approbation de purge, relance ;
  - E1 refusé partout ;
  - session aal1 avec appareil inscrit refusée ;
  - un visiteur ne peut appeler que les trois fonctions publiques.
- **Échec si** : une seule case de la matrice diffère.
- **Preuve** : tableau généré rôle × fonction (ok / `PERMISSION_DENIED`).

## Groupe 3 — Copies des permissions
- **Scénario** : extraire `permissions_du_role` de `supabase.sql`, `supabase-naissance.sql`,
  `supabase-suivi-externe.sql`, 40, et comparer avec `PERMISSIONS_DES_ROLES` (`api.js`) ; relancer
  `supabase-naissance.sql` après 40.
- **Attendu** :
  - cinq copies identiques ;
  - après la relance, les permissions `communications.*` sont toujours là ;
  - `essai-programmes.py`, `essai-suivi-externe.py`, `essai-permissions.py/.js` restent verts.
- **Échec si** : la moindre différence.
- **Preuve** : diff vide, sortie des bancs.

## Groupe 4 — Consentement et changement de contact
| Scénario | Attendu | Échec si |
|---|---|---|
| C1 demande, sans confirmer | état `en_attente`, inactif | actif |
| C1 confirme par le lien (bouton) | `confirme`, actif ; jeton marqué utilisé | inactif, jeton réutilisable |
| Même jeton rejoué, jeton altéré, jeton expiré | `ok:false`, aucune ligne | une ligne écrite |
| C1 change d'e-mail après confirmation | ligne `invalide` (source `changement_contact`) avec l'empreinte de l'**ancienne** adresse ; état `invalide` ; **nouvelle adresse inactive** | ligne `retire`, nouvelle adresse active |
| C1 revient à l'ancienne adresse | reste `invalide` (une nouvelle confirmation est exigée) | redevient actif |
| Confirmation en attente puis changement de contact, puis clic | refus | confirmation acceptée |
| C2 WhatsApp : « OUI 1234 » depuis le bon numéro | `confirme` | — |
| Même message depuis un autre numéro, ou mauvais code | rien | confirmation |
| L'équipe saisit un numéro pour C5 | aucun consentement, aucune demande possible par l'équipe | une ligne `demande` ou `confirme` écrite par l'équipe |
| Accord et retrait simultanés (2 connexions) | le retrait gagne | état actif |
| Écran en `ht`, texte attesté seulement en `fr` | `recueil_ouvert = false` ; demande avec `fr` refusée depuis l'écran `ht` | repli silencieux sur `fr` |
| Langue enregistrée | égale à la langue du texte affiché | différente |
| 6 changements en 24 h | le 6ᵉ refusé (`TOO_MANY_CHANGES`) ; un retrait toujours accepté | retrait refusé |
- **Preuve** : lignes du registre (action, source, langue, empreinte) pour chaque scénario.

## Groupe 5 — Conservation et purge
| Scénario | Attendu | Échec si |
|---|---|---|
| Purge à l'échéance, durée null | refus `RETENTION_BLOCKED` | une ligne touchée |
| Demande par A1, approbation par A1 | refus `FOUR_EYES` | approuvée |
| Demande par A1, approbation par A2, exécution | anonymisation ou effacement selon §7.1 ; journal des purges (table, opération, nombre) **sans données** | données dans le journal |
| `update`/`delete` direct sur le registre sans purge | refus `IMMUTABLE_RECORD` | ligne modifiée |
| Réglage `goship.purge_demande` posé avec une demande non approuvée | refus | ligne modifiée |
| Effacement d'une personne (C6) | consentements anonymisés, confirmations effacées, envois et audiences déliés, **empreinte de suppression gardée** | suppression perdue |
- **Preuve** : comptes avant et après, contenu du journal des purges.

## Groupe 6 — Suppressions indépendantes par canal, transactionnel intact
| Scénario | Attendu | Échec si |
|---|---|---|
| STOP WhatsApp de C1 | suppression WhatsApp seulement ; e-mail commercial toujours possible | e-mail bloqué |
| Désinscription e-mail | suppression e-mail seulement | WhatsApp bloqué |
| Rebond définitif, plainte, suppression manuelle | suppression du bon canal, raison exacte ; une plainte seule ne crée pas d'action de consentement `retire` | une suppression croisée ou un retrait implicite |
| Suppressions en place, puis rejouer **tout** `essai-notifications.py` (colis reçu, disponible, factures, bienvenue) | résultats **identiques** à la référence sans suppression | une seule différence |
| `notification_preferences` après STOP | inchangée | modifiée |
- **Preuve** : diff des sorties de `essai-notifications.py`, avec et sans suppressions.

## Groupe 7 — Désinscription et HTML cliquable
| Scénario | Attendu | Échec si |
|---|---|---|
| Rendu de `communication_courriel_commercial` (4 langues) | le HTML, analysé par un analyseur HTML, contient **un élément `<a>`** dont le `href` correspond à `https://…/desinscription.html?t=<id>.<32 car.>` ; aucun `&lt;a` dans le texte ; identité et adresse présentes | pas de `<a>`, lien échappé |
| Clé de signature absente | rendu null, envoi refusé, campagne en pause `PIED_COMMERCIAL_INCOMPLET` | envoi parti |
| Identité ou adresse BLOQUÉES | idem | idem |
| En-têtes | `List-Unsubscribe` présent ; `List-Unsubscribe-Post` seulement avec l'adresse « un clic » | absent |
| Jeton altéré, jeton d'un autre envoi, rejeu | `ok:false` pour les deux premiers ; rejeu sans effet nouveau | effet |
| Client qui a changé d'adresse après l'envoi | c'est l'**ancienne** adresse qui est bloquée ; la nouvelle n'est pas touchée ; pas de retrait si le consentement actif porte sur la nouvelle adresse | nouvelle adresse bloquée |
| Texte brut | contient l'adresse du lien | absente |
- **Preuve** : HTML produit (fichier), résultat de l'analyse, lignes de suppression.

## Groupe 8 — Retours des fournisseurs, signatures, rejeu, STOP tardif
| Scénario | Attendu | Échec si |
|---|---|---|
| Signature fausse, absente, mal formée, charge de plus de 20 000 caractères | `ok:false`, aucune ligne ; `raise log` émis pour une signature fausse | une ligne |
| Clé absente du coffre | tout refusé | accepté |
| Même événement deux fois | Premier appel : `enregistre:true`, `traite:false`, ligne de file `a_traiter` ; second appel : `rejeu:true` ; après passage du travailleur, un seul effet métier | accusé qui prétend que le premier retour est déjà traité, ou double effet |
| Événement daté de +10 min | refusé (`futur`) | accepté |
| **STOP daté d'il y a 5 jours** | réception en file, puis application par le travailleur (suppression + retrait) | événement refusé ou effet jamais repris |
| Plainte tardive | réception prioritaire et suppression du contact/canal visé ; état du consentement inchangé | refusée, perdue ou transformée en retrait sans demande explicite |
| Désinscription fournisseur tardive | réception prioritaire, suppression et retrait explicite idempotents | refusée, perdue ou source de retrait imprécise |
| 131050, 131049, 131048, 131056 (doublures) | action de la table des codes ; 131056 reporté **une seule fois** | autre action, double report |
| Retour « delivered » pour un message incertain, retrouvé par sa référence | rapproché, `livre`, identifiant du fournisseur posé | reste incertain |
| « delivered » après « read » | pas de recul | recul |
| Confirmation WhatsApp forgée sans demande en attente | rien | confirmation |
- **Preuve** : accusé de réception après commit RPC, une ligne de `communication_evenements_fournisseur`, sa ligne de file et les états résultants après le travailleur.

## Groupe 9 — Empreintes de tout le message
- **Préconditions** : campagne approuvée.
- **Scénario** : changer, un par un :
  - champ de campagne, texte d'un modèle, sujet, variables ;
  - image Meta simulée modifiée, statut Meta PAUSED, catégorie UTILITY ;
  - identité légale, adresse postale, expéditeur, nom d'expéditeur, numéro commercial, `site_url` ;
  - version de l'habillage, texte du pied, valeur d'`adresse_miami()` (si validée).
- **Attendu** : refus à l'approbation (`FINGERPRINT_CHANGED`) ; pause au lancement ou pendant l'envoi
  avec la raison exacte ; journal `communication.campagne_bloquee`.
- **Échec si** : un seul changement passe sans blocage.
- **Preuve** : tableau élément → résultat.
- **En plus** : un modèle approuvé ne se modifie pas (`TEMPLATE_LOCKED`) ; un modèle UTILITY est refusé
  dans la voie commerciale.

## Groupe 10 — Concurrence : 4 travailleurs, 10 000 messages
- **Préconditions** : 10 000 clients fictifs confirmés ; deux campagnes sur deux canaux ; plafonds
  global et par campagne fixés en dessous de la demande ; limite WhatsApp par numéro fixée.
- **Scénario** : quatre `traiter_communications()` en parallèle, plusieurs passes, réponses simulées.
- **Attendu** :
  - aucun plafond dépassé (messages et USD, global, campagne, numéro) ;
  - aucun client au-delà de la fréquence ;
  - aucune clé en double, aucun interblocage ;
  - le transactionnel en attente garde la priorité.
- **Échec si** : un seul dépassement ou doublon.
- **Preuve** : sommes de `communication_depenses_jour` comparées aux plafonds, comptes par client, durée
  totale.

## Groupe 11 — Quotas Brevo
| Scénario | Attendu | Échec si |
|---|---|---|
| Quota null, ou sans preuve | disponible 0, raison `QUOTA_NON_VERIFIE` ; e-mail commercial impossible à allumer | envoi |
| Quota 300/24 h, réserve 150, 60 transactionnels envoyés + 20 en attente + 10 connexions (borne basse) | disponible 60 ; `connu` et `estime` séparés | autre valeur, mélange |
| Quota 30 jours | réserve × 30 et volumes du mois comptés | oubli de la connexion ou du transactionnel |
| Réserve ≥ quota | refusé par la contrainte | accepté |
| Compte non partagé | transactionnel non déduit | déduit |
| Quota épuisé en cours de passage | envois reportés d'une heure, code `QUOTA_BREVO_RESERVE` | envoyés |
- **Preuve** : sortie de `communication_brevo_disponible()` par scénario.

## Groupe 12 — Classement des numéros
| Numéro (fictif) | Territoire attendu | Marketing |
|---|---|---|
| +509… | HT | bloqué tant que non vérifié |
| +1 809 / 829 / 849… | DO | bloqué tant que non vérifié |
| +1 787 / 939… | PR | bloqué |
| +1 876 / 658… | JM | bloqué |
| +1 305… (avant chargement NANPA) | NANP_AUTRE | bloqué |
| Après `verifier_indicatif_communication` avec preuve + tarif | territoire ouvert | ouvert seulement avec les deux |
- **Échec si** : un +1 classé « US » sans liste officielle, ou un territoire ouvert sans preuve.
- **Preuve** : tableau généré.

## Groupe 13 — Issues incertaines
| Scénario | Attendu | Échec si |
|---|---|---|
| Pas de réponse en 10 min ; délai dépassé ; erreur réseau | `incertain` | `echec` ou nouvel essai |
| [1.3] Réponse 5xx ; réponse 429 sans règle prouvée | `incertain` (T-06, T-07) | nouvel essai automatique |
| 72 h sans retour | reste `incertain`, `incertain_clos_le` posé | renvoyé |
| Retour tardif avec la référence | rapproché | — |
| Relance par G1 | refusée | acceptée |
| Relance par A1 sans cocher le risque | refusée `DUPLICATE_RISK` | acceptée |
| Relance par A1 avec le risque coché et un motif | nouvel envoi `…:relance:1`, soumis à toutes les règles ; journal | règles contournées |
- **Preuve** : états et journal d'audit.

## Groupe 14 — Volume après approbation
| Scénario | Attendu | Échec si |
|---|---|---|
| Volume au lancement ≤ approuvé + 10 % | lancement | — |
| Volume > approuvé + 10 % | retour `en_attente_approbation`, `AUDIENCE_DEPASSEE`, approbation effacée, journal | envoi |
| Volume > plafond de messages, ou coût > plafond | idem | envoi |
| Variable manquante pour un client | client exclu, raison `VARIABLE_MANQUANTE:<nom>` | message avec `{{` |
| `{{ prenom }}` (espaces) à l'enregistrement | refusé `VARIABLE_MAL_ECRITE` | accepté |
| Paramètre WhatsApp multi-lignes | envoi écarté `PARAMETRE_WHATSAPP_INVALIDE` | envoyé |
| Segment `actifs_jours = -3`, `"abc"`, `pays = ["FR"]` | refusé `INVALID_SEGMENT` | accepté |

## Groupe 15 — Non-régression des systèmes existants
- **Scénario** : chaîne complète + 40 à 43, puis les bancs existants :
  - `essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py` ;
  - `essai-mobile.py`, avec les sections **K** (suppression de compte), **L** (inscription Google)
    et **M** (profil complet) ;
  - `essai-programmes.py`, `essai-suivi-externe.py`, `essai-double-auth.py`, `essai-production.py`.
- **En plus** : déclencheur de `clients` volontairement cassé (doublure) → la mise à jour du profil
  passe quand même et une ligne apparaît dans `communication_erreurs`.
- **Attendu** :
  - tous les bancs existants verts, à l'identique ;
  - `mon_resume` et `messages_recents` gardent leur forme exacte ;
  - aucune ligne commerciale dans `notifications`.
- **Échec si** : une seule différence.
- **Preuve** : sorties complètes ; diff de forme JSON.

## Groupe 16 — Mode démonstration
- **Préconditions** : site local, `config.js` vide, appels Supabase coupés.
- **Scénario** : parcourir les 11 vues avec A1, G1, E1 (E1 ne voit pas l'onglet) ; consentement simulé
  dans « Mon compte » ; tenter un envoi.
- **Attendu** :
  - formes de réponse identiques à la base (`essai-communications.js`) ;
  - aucun envoi (`MODE_DEMO`) ;
  - 4 langues affichées ;
  - aucune erreur de console.
- **Échec si** : forme différente, envoi simulé présenté comme réel, texte non traduit.
- **Preuve** : sortie du banc navigateur, captures pour une personne.

---

## Hors base jetable (Phase 3, autorisation distincte)
- **Brevo** : en-tête bac à sable (`X-Sib-Sandbox: drop`, à confirmer), puis destinataires de la liste
  d'essai seulement.
- **Meta** : numéro d'essai et destinataires d'essai enregistrés chez Meta ; confirmer la lecture des
  modèles et la forme des retours.
- **Fonction Edge** : servie en local avec des exemples réels de charges et de signatures.
