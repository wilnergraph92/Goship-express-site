# Centre de communication — Phase 1.3.1 (clôture) : revue de sécurité des migrations 40 à 43

**Code examiné** : commit `0693d5e`, branche `ccr-056ddc8c-m7u4p1`. Les brouillons sont identiques au dernier commit de la branche.

> **Rien n'a été exécuté.** Méthode :
> - lecture du code ;
> - inventaire automatique par analyse statique (`pglast`, le parseur de PostgreSQL, sans serveur) : objets, droits, `SECURITY DEFINER`, `search_path`, références en avant dans les corps `LANGUAGE sql`, garde.
>
> Ce que l'analyse statique **ne prouve pas** : l'existence des colonnes citées, les types, les performances, les comportements à l'exécution.

---

## 1. Vue d'ensemble (vérifiée par l'inventaire)

| Fichier | Tables | Fonctions et procédures | Index | Déclencheurs | Lignes de départ | Objets existants touchés |
|---|---|---|---|---|---|---|
| 40 fondation | 19 | 22 | 6 | 3 | 5 | `permissions_du_role` (remplacée) |
| 41 consentement | 0 | 31 | 0 | 1 | 0 | déclencheur `after update` sur `clients` |
| 42 campagnes | 5 | 21 | 6 | 2 | 0 | — |
| 43 envoi | 4 | 31 | 13 | 1 | 0 | rôle `communication_webhook` (créé), tâche pg_cron (créée **inactive**) |
| **Total** | **28** | **105** (dont 1 procédure) | **25** | **7** | **5** | 3 |

**Résultats de l'inventaire** :
- **28 tables, 28 avec la sécurité par ligne (RLS) activée, 28 avec `revoke all … from anon, authenticated, service_role`.** Aucune règle RLS : aucune lecture ni écriture directe pour un compte. Tout passe par des fonctions.
- **105 fonctions** :
  - **82** sont `SECURITY DEFINER` ;
  - **104** ont `SET search_path = ''` ;
  - **1** n'en a pas : la procédure `traiter_communications`. PostgreSQL interdit une clause `SET` à une procédure qui valide. Elle vide son `search_path` elle-même et n'est exécutable que par son propriétaire.
- **Accès** :
  - **ouvertes aux visiteurs (`anon`)** : 2. `confirmer_consentement_communication` (jeton aléatoire de 256 bits) et `desinscrire_communication` (jeton HMAC) ;
  - **ouvertes aux comptes connectés (`authenticated`)** : 34, ces 2-là comprises. **Chacune contrôle elle-même** son accès : `exiger_permission`, `auth.uid()` ou le jeton (vérifié une par une) ;
  - **rôle dédié** : 1, `communication_recevoir_evenement` → `communication_webhook`, créé **NOLOGIN**. Personne ne peut l'appeler avant la décision S-1.
- **Employé** : aucune permission `communications.*` dans `permissions_du_role` (vérifié) ; toutes les fonctions du Centre le refusent.
- **Références en avant** dans les corps `LANGUAGE sql` (objets créés plus loin dans la chaîne 40 → 43) : **aucune**. Ce point avait été corrigé après la revue n° 1, IR-05.

---

## 2. Revue par migration

### 2.1 Garde (les quatre fichiers)

| Couche | Ce qu'elle protège | Ce qu'elle ne protège pas |
|---|---|---|
| 1. `DO … raise exception` | SQL Editor (une transaction), `psql -v ON_ERROR_STOP=1`, `psql --single-transaction` : rien n'est appliqué | Un client qui continue après l'erreur |
| 2. Tout le contenu dans une chaîne `$brouillon_goship_non_executable$` | Tout client qui comprend les chaînes à dollars : il ne reçoit qu'un `SELECT` de texte. Vérifié : chaque fichier entier = `DoStmt` + `SelectStmt`. | Celui qui recopie le contenu hors de la chaîne |
| 3. Garde d'origine en tête du contenu | Celui qui recopie le contenu (même effet que la couche 1) | Idem couche 1 |
| 4. `pg_terminate_backend(pg_backend_pid())` en tête du contenu | Un découpeur naïf « à chaque point-virgule » : la simulation montre que seuls deux `end` sans effet passent, puis la session se ferme | Un découpeur qui ignore les commentaires (constat IR2-08, LOW, accepté) |

### 2.2 Tableau par fichier

| Critère | 40 | 41 | 42 | 43 |
|---|---|---|---|---|
| Transaction et échec | Une seule transaction si le lanceur l'impose : SQL Editor, `--single-transaction`. **Exigence de la Phase 2** : appliquer 40 à 43 **dans une seule transaction** (essai F-M02). | idem | idem | idem |
| Dépendances | Existant : `telephone_international`, `lire_reglage`, `auditer`, `erreur_metier`, `exiger_permission`, `peut`, `extensions.hmac` et `digest`, `clients` | 40 ; fonctions de 43 appelées **à l'exécution** (PL/pgSQL), donc rien ne manque à la création | 40, 41 ; `html_echappe`, `adresse_miami` (existants) | 40 à 42 ; pg_net, pg_cron |
| En chaîne partielle | 40 seul : tables et fonctions sans effet. Aucune page n'appelle le Centre avant la Phase 2c. | 40 + 41 : le déclencheur sur `clients` est actif. Chacun de ses trois blocs attrape ses erreurs : l'écriture du client n'est **jamais** bloquée, mais la demande de purge échoue (journal) | 40 à 42 : rien n'envoie (le travailleur est en 43) | — |
| Contraintes et déclencheurs | Immuabilité des consentements et du journal des purges, sauf purge approuvée ; ligne d'arrêt permanente ; contraintes d'état de `communication_arret` | `communication_suivre_client` (après mise à jour de `email`, `telephone`, `pays`, `region`, `supprime_le`) | Modèles figés (empreinte recalculée, archive définitive) ; audiences immuables | Retours des fournisseurs immuables ; `fournisseur` en liste fermée ; contrainte des confirmations |
| Fonctions et droits | Aides fermées à tous ; `executer_purge_communication` (permission `communications.manage`) | 30 fonctions ouvertes, chacune avec sa permission ; aides fermées | 3 ouvertes (aperçu, écriture, transitions), avec permission **avant** tout verrou | 2 ouvertes (relance, santé) ; webhook (rôle dédié) ; désinscription (visiteur, jeton) ; travailleur, procédure et aides fermées, `service_role` compris |
| RLS et accès direct | 19 tables fermées | — | 5 fermées | 4 fermées |
| Effets sur l'existant | **`permissions_du_role` remplacée** (en fin de fichier) : + 7 permissions pour l'administrateur, + 5 pour le gérant. Les droits existants de la fonction sont gardés par `create or replace`. | **Déclencheur sur `clients`** : n'écrit que dans les tables du Centre. Il prend N3 (verrou consultatif) dans la transaction du client. | — | **Rôle `communication_webhook`** (objet global du serveur) ; **tâche pg_cron inactive** ; lit `notification_envois`, `notifications` et `auth.users` |
| Retour arrière | Remettre `permissions_du_role` à sa définition d'avant (texte recopié dans le script de retrait de la Phase 2) ; garder les tables | Supprimer le déclencheur sur `clients` | Rien d'existant n'est touché | Désactiver ou supprimer la tâche ; retirer le droit du rôle ; le rôle peut rester (NOLOGIN) |
| Pertes ou fuites de données | Empreintes HMAC (poivre au coffre) ; aucune donnée en clair dans les tables, hors identifiants des comptes | Le numéro de document n'est jamais touché ; le déclencheur prend les empreintes dans `old.*` | L'audience ne garde que les retenus | Les corps des requêtes pg_net contiennent e-mail et numéro jusqu'à leur purge par pg_net (environ 6 h, rapporté) : **hors du Centre** |

---

## 3. Séparation marketing / transactionnel (vérifiée dans le code)

| Exigence | Résultat | Preuve |
|---|---|---|
| Pas d'envoi avec les identifiants transactionnels | **Vérifié** | Clés lues par le Centre : seulement des `communication_*`, plus `site_url` et `whatsapp_version` (réglages non secrets). Aucune lecture des clés e-mail ou WhatsApp du transactionnel (recherche exhaustive des appels `lire_reglage`). |
| Pas de repli sur les expéditeurs transactionnels | **Vérifié** | `communication_appel_email` : clé, expéditeur ou nom absents → `NON_CONFIGURE`. Aucune branche de repli. |
| Aucune écriture dans `notifications`, `notification_envois`, `notification_regles`, `messages_recents` | **Vérifié** | Aucun `insert`, `update` ni `delete` sur ces tables dans 40 à 43 (recherche) |
| Pas de changement des notifications existantes | **Vérifié dans le code** | `expedier_envoi`, `courriel_gabarit` et `traiter_notifications` ne sont ni redéfinis ni appelés. Aucun déclencheur sur `colis_historique` ni sur `evenements_facturation`. **À éprouver** : essai F-T01, non-régression. |
| Les e-mails de facture restent coupés | **Vérifié** | Aucune référence aux règles de facture ni à `notification_regles` dans 40 à 43 |
| Interaction indirecte | **Documentée** | Le Centre **lit** la file transactionnelle (il lui cède la place) et les e-mails envoyés (quota Brevo). Il partage pg_net et pg_cron. L'e-mail commercial est **refusé** tant que le compte Brevo est partagé (décision C4). |

---

## 4. Constats de cette revue (auteur)

| # | Gravité | Fichier / fonction / ligne | Constat | Proposition (non appliquée) |
|---|---|---|---|---|
| S-01 | LOW (documentation) | `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` l. 85 ; 41 l. 899 (commentaire) | « Aucune autre table n'est verrouillée » est faux : `communication_observer_sorties` verrouille des lignes, en SKIP LOCKED. Sans conséquence sur la sûreté (`PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md`). | Corriger les deux textes (P-01, P-02) |
| S-02 | LOW | 41 `arreter_communications` l. 998 | `lock_timeout = 0` après N0a : une attente imprévue n'aurait pas de limite | P-03 (2 s), à peser |
| S-03 | MEDIUM | 41 `arreter_communications` | Délai d'exécution des comptes connectés (8 s, rapporté) : 3 s + 2 s d'attente plus le constat. S'il est dépassé, la demande d'arrêt elle-même est annulée. | Mesurer (F-K07) ; si besoin, écrire la demande dans une transaction à part |
| S-04 | LOW | 43 rôle `communication_webhook` | Un rôle est un objet **global** du serveur : il survit à un retour arrière de la base et peut entrer en conflit d'un projet à l'autre | Le nommer ou le documenter dans le script de retrait de la Phase 2 |
| S-05 | LOW | 43 `communication_en_transmission` | Repose sur la forme interne des tables de pg_net (`net.http_request_queue`, `net._http_response`) et sur leurs identifiants. Si l'extension est recréée, des identifiants réutilisés pourraient correspondre à d'anciens envois. | Éprouver sur pg_net 0.20.4 (F-K05) ; noter la version dans le script |
| S-06 | MEDIUM (avant toute campagne WhatsApp) | 42 `communication_destinataires` l. 1000 : `unique (campagne_id, client_id, canal)` | L'unicité porte sur le **client**, pas sur le **contact**. Deux comptes qui ont le même numéro (ou le même e-mail) et qui ont tous deux confirmé recevraient **deux fois** le même message. **Fait relevé en production le 20/11/2026** (comptage agrégé) : 2 numéros de téléphone sont chacun partagés par au moins deux clients actifs ; 0 e-mail partagé. Pour WhatsApp, un message en double coûte deux fois et pèse sur la note de qualité du numéro. Le STOP est, lui, bien traité : la suppression porte sur l'empreinte du contact et bloque les deux comptes. | P-05 : dédoublonner l'audience par `(campagne, canal, empreinte du contact)` au calcul, en gardant le premier client retenu et en comptant l'autre parmi les exclus (raison `CONTACT_EN_DOUBLE`). Essai F-C06. |
| S-07 | LOW (observation) | `outils/supabase.sql` l. 535 ; aucune synchronisation trouvée dans `outils/*.sql` | `clients.email` n'est pas modifiable par le client. Aucune migration ne recopie dans `clients` un e-mail changé dans `auth.users`. L'invalidation du consentement e-mail (41 l. 300) ne se déclenche donc que sur un changement de `clients.email` lui-même. Ce n'est pas un défaut du Centre, mais le Centre écrit à `clients.email`. Un client qui change son e-mail de connexion continuerait d'être écrit à l'ancienne adresse. **Non vérifié** : un changement fait à la main dans le Table Editor. | Décider la source de vérité de l'e-mail avant la Phase 2c ; essai F-C04 |

Les constats de la revue indépendante finale sont rapportés et comparés dans `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`.
