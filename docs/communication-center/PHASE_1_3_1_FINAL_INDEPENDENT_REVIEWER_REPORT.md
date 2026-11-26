> **Rapport de la revue indépendante finale, reproduit tel quel.** Écrit par une session distincte, sans les conclusions de l'auteur, le 20/11/2026.
> Sa comparaison avec l'audit de l'auteur, les désaccords et leur résolution sont dans `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`, §6.
> Les chemins `outils/…` cités au §1 sont les scripts de travail du relecteur. Ils ne sont pas dans le dépôt.

# Revue indépendante finale — brouillons SQL 40 à 43 du Centre de communication

Objet : commit `0693d5e` (branche `ccr-056ddc8c-m7u4p1`, PR #65). Fichiers relus tels qu'ils sont dans ce commit (`git show 0693d5e:<chemin>`).
Les numéros de ligne renvoient à ces fichiers. Aucune requête SQL n'a été exécutée, sur aucune base. Les fichiers du dépôt n'ont pas été modifiés.

Légende :
- **vérifié** : lu dans le code, ou établi par analyse statique (pglast) ;
- **rapporté, non éprouvé** : fait extérieur (PostgreSQL interne, pg_net, Supabase, Meta, Brevo) que je n'ai pas pu tester ;
- **hypothèse** : raisonnement que seul un essai peut confirmer.

---

## 0. Verdict en bref

1. **Arrêt d'urgence.** Je n'ai trouvé **aucun chemin du code** qui fasse écrire ou renvoyer `STOP_CONFIRMED` alors que :
   - (a) une transaction peut encore autoriser puis valider une sortie ;
   - (b) une requête déjà validée peut encore être transmise par pg_net.

   Cette conclusion tient **sous les hypothèses H1 à H5** et sous une précision de H4 (H4′, §3.6). Aucune n'est éprouvée.

   Deux défauts restent :
   - **RF-01 (ÉLEVÉE)** : la demande d'arrêt est écrite dans la **même** transaction que le constat. Une erreur ou un dépassement du délai d'exécution pendant le constat annule **la demande elle-même**.
   - **Aucun interblocage n'est possible entre les fonctions d'arrêt et le reste du Centre.** `communication_observer_sorties` ne peut pas attendre : `FOR UPDATE SKIP LOCKED` dans la sous-requête, et la mise à jour ne porte que sur les lignes déjà verrouillées.
2. **Ailleurs, l'ordre des verrous annoncé est faux.** Les **clés étrangères** prennent un verrou `FOR KEY SHARE` sur la ligne référencée, avant les verrous N1, N3 et N4.
   - **RF-02 (ÉLEVÉE)** : deux retours de fournisseur simultanés pour le **même** envoi (par exemple « sent » et « delivered » de Meta) s'interbloquent. PostgreSQL annule l'un des deux. D'autres cycles existent avec la purge, la relance et l'annulation.
3. **Séparation commercial / transactionnel : confirmée dans le code**, avec une réserve (RF-06). Je n'ai trouvé :
   - aucune lecture d'une clé, d'un expéditeur ou d'un numéro transactionnel ;
   - aucun repli vers eux ;
   - aucune écriture dans `notifications`, `notification_envois`, `notification_regles` ou `messages_recents` ;
   - aucune modification d'`expedier_envoi` ou de `courriel_gabarit` ;
   - rien qui puisse rallumer les e-mails de facture.

   La réserve : la base ne vérifie pas que les valeurs commerciales **diffèrent** des valeurs transactionnelles. Un administrateur peut mettre la même clé sous les deux noms.
4. **Garde des brouillons** : efficace pour le SQL Editor, `psql` et tout client qui comprend les chaînes `$…$`. La couche 4 (`pg_terminate_backend`) ne sert à rien si la connexion passe par un pooler ou se rouvre seule. Dans ce cas, des fonctions SECURITY DEFINER sont créées **sans** que leurs `revoke` s'exécutent (RF-08, simulé).

---

## 1. Méthode et fichiers lus

**Brouillons relus en entier** (extraits du commit dans `src/`) :
- 40, 1331 lignes ;
- 41, 1285 lignes ;
- 42, 1055 lignes ;
- 43, 2052 lignes.

**Analyse statique (pglast, `python3 -I`)** :
- l'enveloppe de chaque fichier se lit comme exactement **2 instructions** : `DO` puis `SELECT` d'une chaîne ;
- la balise de fin n'apparaît pas dans le contenu ;
- le contenu donne 121, 42, 49 et 67 instructions ;
- les **85 corps PL/pgSQL** passent l'analyse syntaxique avec leur vraie signature ;
- inventaire de chaque fonction : langage, SECURITY DEFINER, clauses SET, volatilité ;
- tout appel `net.http_*` contrôle-t-il la porte ? Oui pour les trois appelants ;
- les **28 tables** ont toutes RLS activée et `revoke all … from anon, authenticated, service_role` ;
- toutes les fonctions ont leur `revoke` ;
- simulation d'un découpeur naïf sur « ; » (RF-08).

Scripts et sorties : `outils/analyse.py`, `outils/plpgsql.py`, `outils/naif.py`, `analyse.txt`.

**Existant lu, pour vérifier les dépendances** :
- `outils/supabase.sql` : `clients`, `colis`, `notifications`, `definir_reglage`, `lire_reglage`, `telephone_international`, `permissions_du_role`, droits ;
- `outils/supabase-notifications.sql` : `notification_envois` ;
- `outils/supabase-corrections.sql` : `auditer`, `journal_immuable` ;
- `outils/supabase-compte.sql` : `supprime_le`, `FOR UPDATE` sur `clients` ;
- `supabase-naissance.sql` et `supabase-suivi-externe.sql` : copies de `permissions_du_role` ;
- usages de `net._http_response` dans le dépôt ;
- `.github/workflows/deploy.yml` : `docs/` et `*.sql` sont exclus du site.

**Documents relus seulement pour comparer leurs affirmations au code** :
- `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` (§5 à §8) ;
- recherches ciblées dans les autres `PHASE_1_3_1_*.md`.

**Branche `origin/pixel-meta` (PR #46)** : différence lue (`mesure.js`, `config.js`, `_headers`).

---

## 2. Tableau des constats

| ID | Gravité | Fichier · fonction · lignes | Description | Scénario / preuve logique | Impact | Correction proposée | Preuve | Essai nécessaire |
|---|---|---|---|---|---|---|---|---|
| RF-01 | **ÉLEVÉE** | 41 `arreter_communications` l. 960-1018 ; `communication_conclure_arret` l. 903-957 ; 43 `communication_observer_sorties` l. 1881-1906, `communication_transmissions_en_cours` l. 1917-1932 | La demande (`arret_demande`, l. 1006-1013) et le constat (l. 1016) sont dans **une seule** transaction. Toute erreur levée après l. 1006 annule aussi la demande. | 1) Attentes de 3 s (N0) et 2 s (ligne d'arrêt), puis le constat : une recherche dans `net._http_response` et `net.http_request_queue` **par ligne**. Index sur `id` : non vérifié, hypothèse. Le délai d'exécution du rôle `authenticated` (8 s, rapporté) peut être dépassé : erreur 57014, rien n'est écrit. 2) Recul de l'horloge entre `demande_le` et `confirme_le` (`clock_timestamp()`) : la contrainte l. 194-196 est violée, tout est annulé. 3) Migration rejouée en même temps (RF-09) : l'UPDATE de la ligne attend sans limite (`lock_timeout` mis à `'0'`, l. 998), jusqu'au délai d'exécution. | L'arrêt d'urgence peut **ne rien écrire** au moment où on en a besoin. L'écran reçoit une erreur, pas `STOP_PENDING`, et les envois autorisés **après** cet appel continuent. Déjà noté par les auteurs (R-03, S-03, M3, « MEDIUM ») ; je le relève à ÉLEVÉE : c'est l'écriture principale de l'arrêt, et le correctif est simple. | Isoler le constat dans une sous-transaction : `begin v_resultat := communication_conclure_arret(v_n0); exception when others or query_canceled then v_resultat := jsonb_build_object('etat','STOP_PENDING','raison','CONSTAT_IMPOSSIBLE'); end;`. La demande et `derniere_demande_le` restent écrites. Mieux : deux appels, `demander_arret` (court, validé tout de suite) puis `confirmer_arret_communications`. Remettre l'ancien `lock_timeout` au lieu de `'0'`. | Code (l. 998, 1006-1016) ; documents R-03 et S-03 | Délai d'exécution réel du rôle, avec 10⁴ requêtes récentes dans `net._http_response` ; recul d'horloge simulé ; `pg_cancel_backend` pendant le constat : la demande doit rester écrite (F-K07, plus ces cas). |
| RF-02 | **ÉLEVÉE** | 43 `communication_recevoir_evenement` l. 1444-1452 (insertion de l'événement, clé étrangère `envoi_id`), puis l. 1524-1531 | L'insertion dans `communication_evenements_fournisseur` contrôle la clé étrangère `envoi_id`. PostgreSQL pose alors `FOR KEY SHARE` sur la ligne d'envoi, **avant** N1, N3 et N4. La fonction redemande ensuite cette ligne en `FOR UPDATE` (l. 1531). L'en-tête (« ordre unique ») est donc faux. | **Deux événements pour un même envoi**, W1 et W2 (cas courant : sent, delivered et read de Meta arrivent presque ensemble ; ils sont sérialisés seulement s'ils tombent sur le même des 8 éclats du compteur de débit, soit 1 fois sur 8) : 1) chacun pose `KEY SHARE` sur r ; 2) chacun veut ensuite r en `FOR UPDATE`, qui entre en conflit avec le `KEY SHARE` de l'autre. Pour une campagne, W2 attend aussi N1 tenu par W1. **Cycle** : PostgreSQL annule l'un des deux (40P01) après `deadlock_timeout`. Autres cycles : avec `executer_purge_communication` (personne : N3 tenu, `FOR UPDATE` des envois, 43 l. 1816) ; avec `relancer_envoi_communication` (r en `FOR UPDATE`, l. 1686, puis l'insertion pose `KEY SHARE` sur la campagne que le webhook tient en `FOR UPDATE`) ; avec l'annulation (42 l. 963) pour un envoi en `nouvel_essai`. | Retours perdus : statut, rebond, plainte, désinscription chez le fournisseur, code 131050. Ils ne sont repris que **si** le fournisseur réessaie après une réponse 5xx (rapporté, non éprouvé, en particulier pour Brevo). Sans reprise, on peut continuer d'écrire à quelqu'un qui s'est plaint. | Prendre N1, N3 puis l'envoi en `FOR UPDATE` **avant** d'insérer l'événement : le rejeu reste détecté par l'index unique, l'insertion vient en dernier. Ou retirer la clé étrangère sur `envoi_id`. Dans la relance : prendre la campagne (N1) avant l'envoi. Dans la purge : `NOWAIT` puis `PURGE_RETRY`. | `RI_FKey_check` exécute `SELECT … FOR KEY SHARE` (comportement de PostgreSQL, rapporté) ; ordre lu l. 1444, 1525, 1529, 1531 | Banc d'isolement à deux sessions : deux événements signés pour le même envoi, puis événement et purge, puis événement et relance. Aucun 40P01 attendu. |
| RF-03 | MOYENNE | 43 `communication_est_stop` l. 1291-1300 ; usage l. 1465 | STOP reconnu seulement si **tout le message** est l'un des 13 mots. « Stop please », « STOP pub », « Arrêter les promotions » et le bouton de désinscription d'un modèle marketing Meta (texte du bouton, rapporté) ne sont pas reconnus. | Le client écrit « Stop les messages » : aucune suppression, aucun retrait. Le message est seulement compté comme entrant. | Désinscription ignorée : risque de conformité, et note de qualité du numéro chez Meta. | Reconnaître le **premier mot**, ou la présence d'un mot d'arrêt, dans les quatre langues. Traiter la charge des boutons et `opt-out` côté fonction Edge. Faire valider la liste par le juriste (D-F). | Code | Essais unitaires de `communication_est_stop` sur des phrases réelles ; vérifier la charge Meta d'un bouton de désinscription. |
| RF-04 | MOYENNE | 43 l. 1470-1471 (recherche des clients d'un numéro) ; 40 `communication_empreinte` l. 249-265 ; 42 `communication_raison_exclusion`, `communication_volume_campagne`, `apercu_audience_communication` ; 43 `communication_preparer` | `communication_empreinte` relit le poivre dans le coffre (`vault.decrypted_secrets`) **à chaque appel**. Le traitement d'un STOP parcourt **toute** la table `clients` en calculant un HMAC par ligne. | Avec N clients, un STOP coûte N lectures déchiffrées du coffre. Au-delà du délai (fonction Edge, rôle, fournisseur), la transaction est annulée et le STOP n'est **pas** écrit ; il ne revient que si Meta réessaie (rapporté). Même coût par client dans l'aperçu, le volume, le lancement et l'exclusion. `communication_traiter_un` et `communication_reserver` tiennent N0 partagé plus longtemps, ce qui rend `STOP_PENDING` plus fréquent. | STOP potentiellement non appliqué ; arrêt d'urgence plus souvent « en attente » ; risque de déni de service par un gérant (`apercu_audience_communication`). | Chercher les clients par le **numéro en clair** de la charge : `telephone_international(c.telephone, c.pays) = <numéro>` avec un index d'expression (la fonction est IMMUTABLE). Lire le poivre une fois par instruction (paramètre) ou garder l'empreinte de contact de chaque client dans une colonne. | Code | Mesure avec 20 000 clients et une base jetable : durée du STOP, de l'aperçu, d'un envoi. |
| RF-05 | FAIBLE | 43 l. 1466-1473 (STOP : suppression **puis** N3) contre l. 1528-1552 (code 131050 : N3 **puis** suppression) | Ordre inverse sur la clé unique `communication_suppressions_active_idx` et sur N3. | T1 (STOP du numéro H) insère la suppression (whatsapp, H), puis attend N3(c). T2 (code 131050 pour un envoi vers H) tient N3(c), puis insère (whatsapp, H) et attend l'insertion encore non validée de T1. Interblocage détecté. | Un STOP ou une opposition est annulé, puis repris seulement si Meta réessaie. | Dans la branche STOP : prendre les N3 (identifiants croissants) **avant** d'insérer la suppression. | Code | Banc à deux sessions. |
| RF-06 | MOYENNE | 41 `regler_communications` l. 584-616, `verifier_quota_brevo` l. 625-647 ; 40 `communication_autoriser_sortie` l. 401-404 ; 43 l. 931-933 | La séparation ne tient qu'au **nom** des réglages du coffre. Rien n'empêche `communication_email_cle_api = email_cle_api`, `communication_expediteur = email_expediteur`, `communication_whatsapp_numero_id` ou `_jeton` égal à `whatsapp_numero_id` ou `_jeton`. `brevo_compte_partage = false` est une simple déclaration d'**un** administrateur (texte libre). Si `communication_email_fournisseur = 'resend'`, aucune garde « compte partagé » n'existe, alors que le transactionnel peut lui aussi être sur Resend (`email_fournisseur`). | Un administrateur recopie la clé Brevo transactionnelle sous `communication_email_cle_api` et déclare `brevo_compte_partage = false` : les e-mails commerciaux partent du compte transactionnel. | Plainte ou blocage sur le commercial qui touche les e-mails de colis et de connexion (comportement de Brevo et de Meta rapporté). | Dans `regler_communications` et à la porte : refuser si l'empreinte SHA-256 d'une valeur commerciale égale celle de la valeur transactionnelle correspondante. Quatre yeux pour `brevo_compte_partage = false`. Même garde pour Resend et pour WhatsApp (numéro et WABA). | Code ; clés transactionnelles relevées dans `outils/*.sql` : `email_cle_api`, `email_expediteur`, `email_fournisseur`, `email_nom`, `whatsapp_jeton`, `whatsapp_numero_id`, `whatsapp_version`, `site_url` | Essai : valeurs égales, puis tentative d'allumer `email_actif` (refus attendu). |
| RF-07 | FAIBLE | 41 `verifier_quota_brevo` l. 637, `regler_whatsapp_commercial` l. 660, `verifier_issue_http` l. 1153 (N0 exclusif **sans** `lock_timeout`) ; `regler_communications` l. 549-550 (`lock_timeout` remis à `'0'`, puis `FOR UPDATE` des réglages **sous** N0 exclusif) | Une demande exclusive en file bloque toutes les nouvelles demandes partagées (H5). Une attente sans fin de ces fonctions bloque la porte. | Un administrateur règle le quota pendant un long envoi. Sa demande attend, toutes les portes attendent derrière elle (les travailleurs abandonnent après 2 s) et l'arrêt d'urgence n'obtient pas N0 en 3 s : `STOP_PENDING`. | Sûreté intacte : rien de nouveau n'est autorisé. La confirmation de l'arrêt et l'envoi sont retardés jusqu'au délai d'exécution. | `set_config('lock_timeout','3s',true)` dans toute fonction qui prend N0 exclusif ; remettre la valeur précédente au lieu de `'0'`. | Code | Banc : quota réglé pendant un envoi, puis arrêt. |
| RF-08 | FAIBLE | En-tête de garde de chaque fichier (couche 4, 40 l. 41-45) ; revokes en blocs `DO` (42 l. 1013-1046, 43 l. 2007-2040) | Découpeur naïf sur « ; » qui rouvre la connexion (pooler en mode transaction, pool de connexions) : `pg_terminate_backend` ne ferme que **la** connexion du serveur, et les morceaux suivants s'exécutent ailleurs. | **Simulé** (`outils/naif.py`) : 124, 96, 64 et 143 morceaux sont valides seuls. Fonctions SECURITY DEFINER créées entières : `communication_segment_clients`, `communication_cible`, `communication_frequence_atteinte`, `communication_transmissions_en_cours`… Les revokes de 42 et 43 sont dans des blocs `DO`, donc coupés : ils **ne s'exécutent pas**. Les privilèges par défaut de Supabase (rapporté) laissent ces fonctions à `anon` et `authenticated`. | `communication_segment_clients('{}')` énumère les identifiants de tous les clients. Usage interdit par la documentation, d'où FAIBLE. | Phase 2 : `revoke` en instructions **seules**, juste après chaque `create function` ; ou fonctions internes dans un schéma non exposé. Aucun outil de découpage naïf. | Simulation | Essai T-14 étendu à un pooler (port 6543). |
| RF-09 | FAIBLE | 40 l. 210-212, 1082-1089 ; 41 l. 376-379 (`drop`/`create trigger` sur `public.clients`) ; 42 l. 129-131, 1006-1009 ; 43 l. 1266-1269 | Rejouer une migration (règle du projet) prend `SHARE ROW EXCLUSIVE` sur `clients` et `communication_arret` jusqu'à la fin de la transaction du SQL Editor. | Pendant le rejeu de 41 : inscription (insertion dans `clients`), modification du profil et `supprimer_mon_compte` bloquées. Pendant le rejeu de 40 : l'UPDATE d'`arreter_communications` attend (RF-01). | Indisponibilité courte de l'espace client ; arrêt d'urgence qui échoue pendant un rejeu. | Ne créer le déclencheur que s'il manque (`pg_trigger`, dans un bloc `DO`), et `set lock_timeout` en tête de chaque migration. | Code | Rejeu sur une base jetable avec des écritures concurrentes. |
| RF-10 | FAIBLE | 41 `communication_suivre_client` l. 296-326 | Le déclencheur, sur un chemin **existant** (profil, Google, `supprimer_mon_compte`), attend N3 sans délai. `query_canceled` n'est pas attrapé (IR-16). | Une purge de la personne, ou une confirmation longue, tient N3 : la modification du profil attend, puis échoue au délai d'exécution. | Échec d'une opération de l'espace client à cause du Centre. | `pg_try_advisory_xact_lock`. S'il est occupé, noter « invalidation à reprendre » dans `communication_erreurs` et laisser le travailleur la refaire. | Code | Profil modifié pendant une purge. |
| RF-11 | MOYENNE | 41 `retirer_consentement_client` l. 427-428, `declarer_fuseau_communication` l. 1228-1229, `ajouter_suppression_communication` l. 454-455 ; 40 `executer_purge_communication` l. 1128 ; tables de pg_net | Les motifs en texte libre (« Dites qui a demandé le retrait, et comment ») et les identifiants de clients partent dans `journal_audit`, que la purge **ne peut pas** effacer (`journal_immuable`). Les requêtes pg_net contiennent l'e-mail, le téléphone et le contenu rendu. La réponse de Meta renvoie le numéro (`wa_id`, rapporté). Tout cela reste jusqu'au délai de rétention de pg_net. | Droit à l'effacement exercé : la purge « personne » efface le Centre, mais le journal garde « appel de M. X au 509… ». | Effacement incomplet ; données personnelles dans un journal immuable. | Motifs codés (liste fermée) plus une référence de ticket ; aucune donnée libre dans le journal. Documenter et régler la durée de rétention de pg_net. Inventorier `journal_audit` dans la politique de conservation. | Code | Revue de conformité (juriste) ; essai de purge avec relecture du journal. |
| RF-12 | FAIBLE (dépend de la PR #46) | `origin/pixel-meta` : `assets/js/mesure.js` ; pages `desinscription.html` et `confirmation-communication.html` (pas encore écrites) | Le pixel ne se charge pas sur une adresse qui porte un paramètre secret. Mais sur la page **suivante** du même site (sans paramètre), il part, et `fbevents.js` envoie `document.referrer` (rapporté) : pour le même site, c'est l'adresse complète avec `?t=<jeton>` (`strict-origin-when-cross-origin`). Il en va de même pour `?suivi=GSE-…`. | Le client se désinscrit, puis clique sur « Accueil » : le jeton part chez Meta. | Fuite d'un jeton de désinscription ou de confirmation, et des numéros de colis. Non corrigé (IR-12, M1). | Jeton dans le fragment `#` puis effacé (`history.replaceState`) ; `Referrer-Policy: no-referrer` sur ces pages ; pixel exclu de ces pages ; dans `mesure.js`, ne charger le pixel que si `document.referrer` est vide ou d'un autre site. | Différence de la branche lue | Essai navigateur avec le pixel en mode test ; capture de la requête `facebook.com/tr`. |
| RF-13 | FAIBLE | 43 `communication_courriel_commercial` l. 405 contre `communication_traiter_un` l. 1089 | Le lien de **confirmation** est construit sur `site_url` sans la vérification `https://` que le pied commercial applique. | `site_url` vide : lien relatif `/confirmation-communication.html?t=…`, e-mail parti mais inutilisable. | Confirmation impossible ; jeton consommé pour rien. | Même expression régulière qu'au l. 405 ; refus (`PIED_COMMERCIAL_INCOMPLET`) sinon. | Code | Unitaire. |
| RF-14 | FAIBLE | 43 `communication_frequence_atteinte` l. 190-209 | Le commentaire dit « compte aussi les refusés après remise », mais `echec` est exclu. | Un envoi accepté, puis refusé plus tard par un retour « failed », n'est plus compté dans la fréquence. | Léger dépassement possible de la fréquence. | Ajouter `echec` avec `remis_le` non vide, ou corriger le commentaire. | Code | Unitaire. |
| RF-15 | FAIBLE | 43 `communication_candidats` l. 868-871 | La file pg_net est **partagée** avec le transactionnel. Le commercial cède sa place d'après `notification_envois`, pas d'après la profondeur de `net.http_request_queue`. | `debit_max_minute` à 600 : la file pg_net retarde les e-mails de colis. | Couplage de performance. | Céder aussi quand la file pg_net dépasse un seuil. | Code | Charge mixte sur une base jetable. |
| RF-16 | FAIBLE | Fin de chaque fichier (droits regroupés en §13, §5, §6 et §14) | Si le fichier est exécuté instruction par instruction en validation automatique, les fonctions SECURITY DEFINER restent ouvertes à `anon` et `authenticated` (privilèges par défaut, rapporté) entre leur création et le `revoke`. Exemples : `communication_conclure_arret`, `communication_verrou_interrupteurs`. | Fenêtre de quelques secondes. | Faible. | Revoke juste après chaque création, ou exécution en une seule transaction (SQL Editor : c'est déjà le cas, rapporté). | Code | T-15. |
| RF-17 | FAIBLE | 41 l. 898-899, 979, 988, 1094-1097 (commentaires) | Commentaires inexacts : « Aucune autre table n'est verrouillée » (or le constat verrouille des lignes d'envoi et de lecture Meta, en SKIP LOCKED) ; « 5 s au plus » au lieu de 3 s et 2 s ; levée « SANS délai » alors que `lock_timeout` vaut 5 s. Aucun impact sur le code. | — | Revue future induite en erreur. | Corriger les commentaires. | Code | — |
| RF-18 | INFO | Paramètre PostgREST `Prefer: tx=rollback` | Si le serveur autorise ce paramètre (`db-tx-end = commit-allow-override`, rapporté ; Supabase utiliserait `commit`), un appel peut recevoir `STOP_CONFIRMED` pour une transaction annulée. | — | Faux « confirmé » à l'écran (l'état réel reste juste). | Vérifier le réglage ; l'écran relit `etat_arret_communications` après l'appel. | Rapporté | Appel avec ce paramètre. |
| RF-19 | INFO | 40 `executer_purge_communication` l. 1136-1142 | La purge à l'échéance « consentements » anonymise aussi le **dernier** consentement confirmé d'un client encore actif. | Il ne reçoit plus rien (échec fermé) et doit redonner son accord. | Choix à faire valider (juriste, CEO). | Exclure la dernière ligne par client et canal tant qu'elle est « confirme », ou le documenter. | Code | — |

---

## 3. Arrêt d'urgence — analyse détaillée

### 3.1 Verrous pris, dans l'ordre, fonction par fonction

**Notation des verrous :**
- K0 : clé consultative `hashtextextended('goship-communication:interrupteurs',0)`. « Exclusif » = mode ExclusiveLock (`pg_advisory_xact_lock`) ; « partagé » = ShareLock (`pg_advisory_xact_lock_shared`) ;
- « ligne R » : verrou de ligne sur la ligne R ;
- les verrous de relation (AccessShare, RowExclusive) ne sont cités que s'ils peuvent attendre une DDL.

**Notation des attentes :** « attente ≤ x » = borne posée par `lock_timeout` ; « sans limite » = seulement le délai d'exécution du rôle.

| Fonction | Verrous, dans l'ordre | Attente |
|---|---|---|
| `communication_verrou_interrupteurs(p)` (40 l. 331) | K0, exclusif si `p`, sinon partagé | `lock_timeout` de l'appelant |
| `communication_autoriser_sortie` (40 l. 379) | 1) K0 partagé, tenu jusqu'au COMMIT ou à l'annulation de la (sous-)transaction ; 2) lectures **sans verrou** de `communication_arret` et de `communication_reglages` ; 3) `lire_reglage` (lecture du coffre) ; 4) `set_config` local (marque) | ≤ 2 s (appelants : `communication_traiter_un` et `communication_rafraichir_modeles_meta`, `set lock_timeout = '2s'`) |
| `communication_sortie_autorisee` (40 l. 414) | Aucun | — |
| `arreter_communications` (41 l. 960) | 1) K0 exclusif, dans une sous-transaction, `lock_timeout` 3 s, 55P03 attrapé, puis `v_n0` ; 2) ligne `communication_arret` `FOR UPDATE`, `lock_timeout` 2 s, attrapé : retour `STOP_NOT_CONFIRMED` sans écriture ; 3) `lock_timeout = 0` ; 4) UPDATE de la ligne d'arrêt (déjà à soi) ; 5) INSERT `journal_audit` (pas de clé étrangère, pas d'index unique hors identité : **vérifié**) ; 6) UPDATE de la demande si l'état est `actif` ; 7) INSERT dans le journal ; 8) `communication_conclure_arret` (voir ci-dessous) | 1 : ≤ 3 s · 2 : ≤ 2 s · 4 à 8 : pas d'attente de ligne ; attente de relation possible face à une DDL (RF-09), **sans limite** |
| `confirmer_arret_communications` (41 l. 1024) | 1) K0 exclusif, 3 s, attrapé ; 2) ligne d'arrêt `FOR UPDATE`, 2 s, attrapé ; 3) `lock_timeout = 0` ; 4) `communication_conclure_arret` | idem |
| `communication_confirmer_arret_auto` (41 l. 1058) | Lecture sans verrou de l'état ; puis **tout le corps dans une sous-transaction** (bloc EXCEPTION de la fonction) : 1) `pg_try_advisory_xact_lock(K0)` exclusif, **sans attente** ; 2) ligne d'arrêt `FOR UPDATE NOWAIT` (55P03 renvoie null, la sous-transaction est annulée et le K0 éventuellement obtenu est relâché) ; 3) `communication_conclure_arret` | Aucune attente de verrou |
| `communication_conclure_arret` (41 l. 903) | Ligne d'arrêt (déjà verrouillée par l'appelant) ; lecture de `pg_locks` (verrous internes brefs) ; UPDATE de la ligne d'arrêt (à soi) ; `communication_observer_sorties` ; `communication_transmissions_en_cours` (lectures) ; UPDATE de la ligne d'arrêt ; INSERT dans le journal | Aucune attente de ligne |
| `communication_observer_sorties` (43 l. 1881) | 1) `communication_envois` : sous-requête `FOR UPDATE SKIP LOCKED`, puis UPDATE des **seules** lignes obtenues ; 2) idem sur `communication_modeles_meta` ; lectures MVCC de `net.http_request_queue` | Aucune : une ligne tenue par un autre (y compris en `KEY SHARE` par une insertion qui la référence) est **sautée**, reste non observée et **comptée** (prudent) |
| `communication_en_transmission` (43 l. 1863) | Lectures seules (`net._http_response`, `net.http_request_queue`) | — |
| `communication_transmissions_en_cours` (43 l. 1917) | Lectures seules | — |
| `lever_arret_communications` (41 l. 1098) | 1) K0 exclusif, `lock_timeout` 5 s, **non** attrapé (erreur) ; 2) ligne d'arrêt `FOR UPDATE`, 5 s ; 3) UPDATE ; 4) INSERT dans le journal | ≤ 5 s, puis 5 s |
| `communication_traiter_un` (43 l. 891, `lock_timeout` 2 s) | 0) lecture de l'envoi sans verrou ; 1) **porte** : K0 partagé ; 2) campagne `FOR UPDATE` (N1) ; [UPDATE de la campagne : pause] ; 3) N2 consultatif exclusif `client:<id>` ; 4) N3 consultatif exclusif `consentement:<id>:<canal>` ; 5) envoi `FOR UPDATE SKIP LOCKED` (N4) ; [UPDATE de l'envoi] ; [confirmation : UPDATE de la ligne `communication_confirmations` (jeton)] ; 6) dans `communication_reserver` : N5 consultatif `compteurs`, puis INSERT ON CONFLICT DO UPDATE sur `communication_depenses_jour` (ligne PK), INSERT ON CONFLICT sur `communication_debit_minute` (ligne PK), UPDATE de la campagne ; 7) `net.http_post` (INSERT dans `net.http_request_queue`) ; 8) UPDATE de l'envoi ; [INSERT `communication_erreurs`] ; les clés étrangères de l'envoi ne sont pas touchées | Chaque étape ≤ 2 s ; N4 sans attente |
| Procédure `traiter_communications` (43 l. 1151) | Une transaction par étape et par envoi : 1) `communication_confirmer_arret_auto` puis COMMIT ; 2) `communication_lire_reponses` (envois en `traitement` `FOR UPDATE SKIP LOCKED`, au plus 200 tenus pendant toute la boucle ; incertains SKIP LOCKED ; lectures Meta SKIP LOCKED ; DELETE des compteurs de plus d'un jour) puis COMMIT ; 3) `communication_rafraichir_modeles_meta` (porte K0 partagé, puis `net.http_get` et INSERT `modeles_meta`, clé étrangère `KEY SHARE` sur le modèle) puis COMMIT ; 4) `communication_preparer` (campagne `FOR UPDATE SKIP LOCKED`, INSERT d'audience et d'envois ; **pas** de K0) puis COMMIT ; 5) candidats puis COMMIT ; 6) un envoi par transaction ; 7) `communication_clore_campagnes` (UPDATE) | Aucun verrou gardé d'une transaction à l'autre (**vérifié** : COMMIT hors des blocs EXCEPTION) |
| `net.http_*` : `communication_demander_modele_meta` (42 l. 299), `communication_appel_email` (43 l. 429), `communication_appel_whatsapp` (43 l. 493) | Aucun verrou propre ; refus (`SORTIE_NON_AUTORISEE`) si la marque de la porte manque pour cette transaction, cette nature et ce canal (**vérifié** pour les trois, les seuls appelants de `net.http_*`) | — |
| `communication_recevoir_evenement` (43 l. 1338, 5 s) | 1) INSERT ON CONFLICT dans `communication_webhook_debit` (ligne d'éclat tenue jusqu'au COMMIT ; sauf message entrant) ; 2) INSERT `communication_evenements_fournisseur` (index unique et **clé étrangère sur l'envoi, donc `KEY SHARE` sur l'envoi**) ; *entrant STOP* : 3) INSERT `communication_suppressions` (index unique partiel), 4) N3 par client croissant, 5) INSERT consentements, UPDATE confirmations ; *entrant OUI* : N3, confirmation `FOR UPDATE`, UPDATE, INSERT, UPDATE suppressions ; *statut* : 3) campagne `FOR UPDATE` (N1), 4) N3 si retrait, 5) envoi `FOR UPDATE` (N4), 6) UPDATE envoi, INSERT suppressions et consentements, UPDATE campagne, INSERT d'un envoi (report), UPDATE de la ligne des réglages (pause du canal, en dernier) | ≤ 5 s par attente |
| `changer_statut_campagne('annuler')` (42 l. 840) | Campagne `FOR UPDATE` (N1), puis envois `ORDER BY id FOR UPDATE`, UPDATE, UPDATE campagne, journal | Sans limite |
| `executer_purge_communication` (40 l. 1109) | Ligne de la demande `FOR UPDATE` ; *personne* : N2, N3 e-mail, N3 WhatsApp ; dans `communication_purger_personne_suite` : UPDATE événements, envois `ORDER BY id FOR UPDATE`, UPDATE envois, destinataires, suppressions ; DELETE fenêtres et liste d'essai ; UPDATE consentements ; DELETE confirmations (clé étrangère `ON DELETE SET NULL`, donc UPDATE des envois, déjà à soi) ; DELETE fuseaux ; *confirmations* : envois `ORDER BY id FOR UPDATE`, UPDATE, DELETE | Sans limite |
| `relancer_envoi_communication` (43 l. 1671) | Envoi `FOR UPDATE`, puis INSERT d'un envoi (clés étrangères : **`KEY SHARE` sur la campagne**, le destinataire et l'original) | Sans limite |
| Réglages : `regler_communications` (41 l. 512) | K0 exclusif (10 s, puis BUSY) ; `lock_timeout = 0` ; ligne des réglages `FOR UPDATE` (**sans limite, sous K0 exclusif**) ; UPDATE | voir RF-07 |
| `verifier_quota_brevo`, `regler_whatsapp_commercial`, `verifier_issue_http` | K0 exclusif **sans limite**, puis UPDATE ou INSERT | voir RF-07 |

### 3.2 Qui attend qui (graphe d'attente)

**Arrêt S (`arreter_communications` ou `confirmer_arret_communications`) :**
- il n'attend qu'à K0 (≤ 3 s) et à la ligne d'arrêt (≤ 2 s) ;
- ensuite, aucune attente de ligne : le constat est en SKIP LOCKED, le journal n'a pas de clé étrangère ;
- personne ne tient la ligne d'arrêt en attendant K0 : toutes les fonctions qui touchent la ligne prennent K0 **avant** elle, ou n'attendent plus K0 après elle ;
- personne ne lit la ligne d'arrêt **avec** verrou en dehors des fonctions d'arrêt (porte et réservation : lecture simple, **vérifié** l. 396 et l. 257) ;
- donc **aucun cycle ne passe par S**.

**Arrêt S et travailleur W (porte) :**
- W tient K0 partagé et peut attendre N1, N2, N3 et N5 (2 s chacun) ;
- ces verrous sont tenus par d'autres W, l'annulation, la purge ou le webhook, dont **aucun** n'attend K0 ni la ligne d'arrêt ;
- S attend donc au plus la fin de ces W : en pratique ≤ 3 s, sinon `STOP_PENDING`.

**Arrêt S et réglages :**
- un appel de réglage en file d'attente exclusive bloque les portes, et l'arrêt en N0 → `STOP_PENDING` (RF-07) ;
- pas de cycle.

**Confirmation automatique K :** aucune attente (try, NOWAIT).

**Levée L :**
- K0 puis ligne d'arrêt, comme S ;
- L contre S : sérialisés, pas de cycle ;
- si L tient la ligne plus de 2 s, S renvoie `STOP_NOT_CONFIRMED` sans écrire (honnête ; voir 3.5).

**Lecture des réponses :**
- SKIP LOCKED partout ;
- tient jusqu'à 200 lignes en `traitement` pendant sa boucle : la purge, l'annulation et le webhook attendent sa fin ;
- elle-même n'attend personne, donc pas de cycle.

**Annulation A, purge P, webhook H, relance R :**
- A contre P : envois verrouillés par identifiant croissant des deux côtés, pas de cycle ;
- **H contre H, H contre P, H contre R, H contre A : cycles possibles par `KEY SHARE`** (RF-02) ;
- STOP contre code 131050 : cycle par l'index unique (RF-05) ;
- tous ces cycles sont **détectés** par PostgreSQL (verrous consultatifs, de ligne et d'index unique) : une transaction est annulée, il n'y a **pas d'attente infinie**.

**Attentes « sans limite »** (bornées seulement par le délai d'exécution du rôle) :
- annulation, purge, relance ;
- réglages qui prennent K0 sans délai ;
- confirmation par lien et désinscription (N3) ;
- partie postérieure de l'arrêt face à une DDL (RF-09).

### 3.3 La question posée : constat d'arrêt, `communication_observer_sorties` et interblocage

`communication_conclure_arret` appelle `communication_observer_sorties`, qui fait des UPDATE dans `communication_envois` et `communication_modeles_meta`. La forme est `UPDATE … WHERE id IN (SELECT … FOR UPDATE SKIP LOCKED)`.

- La sous-requête ne prend **que** les lignes libres et les garde jusqu'au COMMIT. L'UPDATE extérieur ne modifie **que** ces lignes, déjà à soi. Si une version plus récente existe, la relecture (EvalPlanQual) tombe sur la ligne déjà verrouillée par nous. **Aucune attente de ligne n'est possible** (vérifié sur le code ; sémantique de SKIP LOCKED rapportée).
- Ces lignes, une fois prises par S, peuvent faire attendre d'autres transactions : webhook, purge, annulation, relance, insertions qui les référencent. Aucune de ces transactions ne tient quelque chose que S attend encore. **Pas de cycle.**
- Le prix de SKIP LOCKED : une ligne tenue par un autre n'est pas notée « vue hors de la file », donc elle est **comptée**. Effet : `STOP_PENDING` un peu plus long, jamais un faux `STOP_CONFIRMED`.

**Conclusion : pas d'interblocage ni d'attente infinie induits par le constat.** Le seul risque du constat est sa **durée**, à l'intérieur de la transaction de la demande (RF-01).

### 3.4 `STOP_CONFIRMED` : peut-il mentir ?

**Où l'état `arret_confirme` est écrit :** seulement à 41 l. 951-953. Il exige :
- `autorisations_closes_le` non vide (l. 925-939), écrit seulement quand l'appelant a obtenu K0 exclusif (`p_n0_exclusif`, l. 926, 937) ;
- `communication_transmissions_en_cours() = 0` (l. 943) ;
- la contrainte de table l. 194-196, qui rend impossible un état confirmé sans `autorisations_closes_le`.

**(a) Une autorisation peut-elle encore être validée après la confirmation ?**

- **G** est l'instant où K0 est obtenu en exclusif, dans la transaction X, avec l'état `arret_demande` (écrit par X ou déjà validé).
- Toute porte tient K0 partagé jusqu'à sa fin (H1) : à G, aucune transaction autorisée n'est en cours.
- Une porte qui demande K0 après G ne l'obtient qu'après la fin de X. Elle relit l'état **après** l'avoir obtenu, par une nouvelle requête : lecture validée et fonction VOLATILE, ce qui est **vérifié** pour la porte. Par H2, elle voit l'arrêt et refuse.
- `autorisations_closes_le` non vide n'apparaît qu'avec un arrêt demandé validé en même temps ou avant. Il est remis à vide par la levée et par une nouvelle demande depuis `actif` (l. 1010, 1127). Une confirmation **sans** K0, quand `autorisations_closes_le` est déjà posé, reste donc correcte.
- Les trois fonctions qui appellent `net.http_*` vérifient la marque `txid:nature:canal` (vérifié). Une sous-transaction annulée annule à la fois le verrou, la marque (SET LOCAL) et l'INSERT pg_net (rapporté, H1 et H3).

**Contre-exemples cherchés, sans succès :**
- appel HTTP hors de la porte : aucun (pglast, et lecture des 4 fichiers) ;
- marque restée valide sans verrou : non, ils sont annulés ensemble ;
- porte en lecture STABLE : non ;
- lancement de campagne : ne dépose aucune requête ;
- réglage écrit sans K0 (`valider_identite_expediteur`, pause du canal par le webhook) : ne peut que fermer, ou change l'empreinte d'environnement, ce qui met la campagne en pause.

**(b) Une requête validée avant G peut-elle encore partir après la confirmation ?**

- Chaque requête du Centre a son identifiant dans `communication_envois.requete` ou `communication_modeles_meta.requete`. Il est écrit dans la **même** transaction que `net.http_*` (vérifié l. 1105-1111 et 42 l. 326-333).
- Il n'est effacé que si la requête n'est plus « en transmission » : purge `envois`, l. 1743. La purge « personne » le garde (l. 1819).
- Il n'est remplacé que par un nouvel essai, qui n'arrive qu'**après** une réponse reçue (`rejet_temporaire`) : vérifié l. 598-604.
- Une requête est comptée tant qu'elle remplit les trois conditions suivantes : pas de réponse dans `_http_response`, et (encore dans la file, ou jamais vue hors de la file, ou vue hors de la file depuis moins de 120 s).
- Le délai maximal permis vaut 60 s (contrainte de `delai_http_ms`) ; il est passé à chaque `net.http_*` (vérifié).

**Contre-exemples cherchés :**
- statut « envoye » posé par un webhook avant la réponse HTTP : compté par requête quel que soit le statut, donc OK ;
- requête qui n'est plus dans la file ni dans les réponses après un crash (tables UNLOGGED vidées) : comptée 120 s, puis non comptée ; elle n'est jamais partie (rapporté) ;
- **le seul trou logique** : un écart de plus de 60 s entre le moment où le retrait de la file devient **visible** et le **début** réel du transfert curl. Ce n'est pas exclu par le code. C'est un fait interne de pg_net (H4′).

**Conclusion.** **Aucun faux `STOP_CONFIRMED` trouvé dans le code.** La garantie dépend entièrement de H1 à H5 et de H4′ (§3.6). Elle ne couvre **que** le Centre : le moteur transactionnel n'est pas arrêté, ce qui est voulu. L'écran doit le dire.

### 3.5 Les cas demandés

| Situation | Comportement (vérifié dans le code) |
|---|---|
| N0 indisponible ou délai dépassé | `v_n0 = false`. L'arrêt écrit `arret_demande` et répond `STOP_PENDING/VERROU_NON_OBTENU` avec une **indication** tirée de `pg_locks` (non une preuve). Les transactions déjà autorisées peuvent encore valider. Les suivantes refusent. La confirmation vient ensuite : clic, ou `communication_confirmer_arret_auto` au début de chaque passage du travailleur, sans attente. **Réserve RF-01** : si le constat lève une erreur, la demande est perdue. |
| Ligne d'arrêt tenue plus de 2 s (autre arrêt, constat lent, levée) | `STOP_NOT_CONFIRMED / ARRET_CONCURRENT_EN_COURS`, **rien écrit**, pas même `derniere_demande_le`. Honnête, mais l'écran doit **réessayer tout seul**. Contre une levée qui précède : la levée tient K0 et la ligne quelques millisecondes ; l'arrêt suivant obtient K0 après elle, voit `actif` et réarme. Course gagnée par l'arrêt dans les cas normaux. |
| `actif` | La porte autorise selon les interrupteurs. `communication_conclure_arret` renvoie `STOP_NOT_REQUESTED` si on l'appelle par la confirmation. |
| `arret_demande` | Toute porte qui obtient K0 refuse (`ARRET_URGENCE`). La procédure sort de sa boucle. Candidats vides. Le lancement crée seulement des lignes `attente`. La lecture des réponses continue. |
| `arret_confirme` | Idem. Un nouvel appui est daté et journalisé (`derniere_demande_le`). Seule `lever_arret_communications` (administrateur, motif d'au moins 10 caractères) rouvre ; elle refuse si un appui a eu lieu après son début (IR2-03). |
| Réponse HTTP retardée | La requête est comptée jusqu'à sa réponse, ou 120 s après sa sortie de file observée : `STOP_PENDING/TRANSMISSIONS_EN_COURS`, puis confirmation au passage suivant. |
| Réponse HTTP absente | Après la fenêtre, l'envoi passe à `incertain` (jamais renvoyé seul) et n'est plus compté. Si pg_net est arrêté, la requête reste dans sa file : `STOP_PENDING` sans fin (honnête ; aucune procédure prévue pour sortir de cet état sans pg_net). |
| Nouveaux essais | Seulement après un refus **prouvé** sûr. La table `communication_issues_http` est vide, et une 5xx est forcément « incertain ». La nouvelle requête remet `sortie_file_vue_le` à vide. Pendant l'arrêt, un nouvel essai ou une relance crée une ligne `attente` que la porte refuse. |
| Réponse retenue par pg_net plus longtemps que sa durée de conservation | La lecture des réponses passe l'envoi à `incertain` (prudent). Le constat ne compte plus la requête : fin de transfert supposée (H4). |

### 3.6 Dépendances et essais

| # | Fait supposé | Source | Essai proposé (base jetable, Phase 2, après accord) |
|---|---|---|---|
| H1 | Verrou consultatif de transaction tenu jusqu'à la fin ; relâché, **avec** la marque SET LOCAL et l'INSERT pg_net, quand la sous-transaction est annulée | PostgreSQL, rapporté | Porte dans un SAVEPOINT, puis ROLLBACK TO : vérifier `pg_locks`, `current_setting`, `net.http_request_queue` |
| H2 | Une validation est visible avant le relâchement des verrous ; nouvel instantané par requête dans une fonction VOLATILE en lecture validée | PostgreSQL, rapporté | Deux sessions : la session A valide l'arrêt en tenant K0, la session B attend K0 puis lit |
| H3 | pg_net n'envoie qu'après COMMIT ; rien si la transaction est annulée ; aucun nouvel essai interne | pg_net, rapporté | Serveur HTTP local qui note les arrivées |
| H4 | `timeout_milliseconds` borne tout le transfert ; une ligne de réponse est écrite à chaque fin (succès, erreur, délai) ; forme des tables `net.*` ; identifiants jamais réutilisés | pg_net 0.20.4, rapporté | Serveur lent (au-delà de 60 s) ; relever les colonnes et les index de `net.*` (index sur `id` : à vérifier, voir RF-01) |
| **H4′** | Le transfert curl **commence** moins de 60 s après que le retrait de la requête de la file est devenu visible | Non documenté | Lot de plus de 200 requêtes et serveur lent ; comparer l'heure d'arrivée sur le serveur et `sortie_file_vue_le` |
| H5 | Une demande partagée attend derrière une demande exclusive déjà en file | PostgreSQL, rapporté | Trois sessions et `pg_locks.granted` |
| S1 | Délai d'exécution du rôle `authenticated` (8 s), PostgREST sans `tx=rollback` | Supabase, rapporté | Mesure (RF-01, RF-18) |
| S2 | pg_cron exécute `CALL` avec COMMIT dans la procédure | Rapporté | Activer la tâche sur une base jetable |
| S3 | Privilèges par défaut de Supabase sur les nouvelles fonctions et séquences | Rapporté | `\df+`, `\dp` après création |

---

## 4. Migrations 40 à 43

**Commun aux quatre :**
- **Garde.** Bloc `DO` qui lève, puis tout le contenu dans une chaîne `$brouillon_goship_non_executable$` (aucune occurrence intérieure, **vérifié**). Dans la chaîne : le `DO` d'origine, puis `pg_terminate_backend`.
  - SQL Editor, un seul envoi : la transaction implicite échoue, rien n'est appliqué (rapporté).
  - `psql` sans `ON_ERROR_STOP` : un `SELECT` de texte, rien n'est appliqué.
  - Découpeur naïf : voir RF-08.
  - `deploy.yml` exclut `docs/` et `*.sql` (**vérifié**).
- **Réexécution.** `create table if not exists` n'ajoute pas les colonnes nouvelles à une table déjà là. La propriété « rejouable » du projet n'est vraie que pour une base vierge ; en Phase 2, il faudra des `alter table … add column if not exists`.
- **Retour en arrière.** Rien n'est prévu.
  - Retirer le Centre = supprimer 28 tables, environ 80 fonctions, le rôle `communication_webhook`, la tâche pg_cron et le déclencheur `communication_suivre_client` sur `clients`, puis rejouer la `permissions_du_role` de `supabase.sql` (et la chaîne qui suit, par la règle du projet).
  - Les preuves de consentement seraient perdues sans export préalable.
- **Droits (vérifiés) :**
  - toutes les fonctions SECURITY DEFINER ont `set search_path = ''` ;
  - toutes les fonctions internes sont retirées à `public`, `anon`, `authenticated` et `service_role` ;
  - les fonctions ouvertes à `authenticated` exigent une permission ou le rôle `client` ;
  - deux seulement sont ouvertes à `anon`, protégées par un jeton : `confirmer_consentement_communication` (256 bits, SHA-256 seul gardé) et `desinscrire_communication` (HMAC tronqué à 192 bits) ;
  - `communication_recevoir_evenement` n'est ouverte qu'au rôle NOLOGIN `communication_webhook`. Personne ne peut l'appeler tant que la décision n'est pas prise. L'USAGE sur le schéma `public` de ce rôle est à vérifier ;
  - séquences d'identité non retirées (privilèges par défaut, rapporté ; non exposées par PostgREST) : INFO.

| Fichier | Contenu et effets |
|---|---|
| **40 fondation** | 19 tables, toutes avec RLS et revoke. **Côté existant :** `permissions_du_role` remplacée **en dernier** (`CREATE OR REPLACE` garde les droits). C'est une copie mot pour mot plus 7 permissions (**vérifié** contre `supabase.sql`, `supabase-naissance.sql` et `supabase-suivi-externe.sql`). Rejouer l'une de ces deux migrations retire les permissions du Centre : échec fermé, mais `essai-permissions` et la copie démo divergeront tant que la Phase 2 n'a pas aligné les cinq copies. Les fonctions SQL ne citent que des objets existants ou créés avant elles. `executer_purge_communication` (PL/pgSQL) appelle des objets de 42 et 43 à l'exécution. Lit `auth.users` (4 colonnes `*_sent_at`), `notification_envois` et `notifications` en lecture seule. Immuabilité : exception seulement sous une purge approuvée (réglage `goship.purge_demande`, que seule une session SQL directe peut poser). |
| **41 consentement** | Aucune table. **Côté existant :** déclencheur AFTER UPDATE sur `public.clients`. Trois blocs indépendants ; erreurs gardées par leur code seul (RF-09, RF-10). Toutes les fonctions sont en PL/pgSQL, donc pas de problème d'ordre à la création. À l'exécution : `communication_conclure_arret` dépend de 43. Si 41 est en place sans 43, l'arrêt lève une erreur ; sans conséquence, puisque rien ne peut partir. Le bloc 3 du déclencheur journalise 42P01 à chaque suppression de compte tant que 42 et 43 manquent. |
| **42 campagnes** | 5 tables. `communication_empreinte_campagne` (SQL) cite `communication_environnement_envoi` (créée juste avant) et `communication_modeles` : ordre correct. `communication_environnement_envoi` est passée en PL/pgSQL (IR-05) : correct, elle appelle une fonction de 43. Déclencheur de figement des modèles (non SECURITY DEFINER) : n'appelle que des fonctions retirées au public ; il ne fonctionne que si l'écriture passe par une fonction SECURITY DEFINER (prévu en Phase 2). |
| **43 envoi** | 4 tables, rôle `communication_webhook`, tâche pg_cron créée **inactive** (si pg_cron existe). Les fonctions SQL citent `net.*`, ce qui exige pg_net à la création (déjà installé dans le projet). La procédure n'est ni SECURITY DEFINER ni assortie d'une clause SET, ce qui est obligatoire pour faire COMMIT. Exécutable par son propriétaire seul. `search_path` vidé pour la session. |

---

## 5. Séparation commercial / transactionnel — verdict

**Clés du coffre lues par 40 à 43** (relevé exhaustif de chaque `lire_reglage`) :
- `communication_poivre`, `communication_email_fournisseur`, `communication_email_cle_api`, `communication_expediteur`, `communication_nom`, `communication_url_un_clic`, `communication_cle_desinscription`, `communication_cle_webhook`, `communication_whatsapp_jeton`, `communication_whatsapp_numero_id`, `communication_whatsapp_waba_id` ;
- et deux clés **partagées qui ne sont pas des identifiants** : `site_url` (liens) et `whatsapp_version` (version de l'API Graph).

**Clés transactionnelles** relevées dans `outils/*.sql` : `email_cle_api`, `email_expediteur`, `email_fournisseur`, `email_nom`, `whatsapp_jeton`, `whatsapp_numero_id`. **Aucune n'est lue par le Centre.**

| Question | Réponse | Preuve |
|---|---|---|
| Envoi avec des identifiants ou un expéditeur transactionnels ? | **Non par le code.** Mais **possible par la configuration** (RF-06). | Clés ci-dessus ; `communication_appel_email` et `communication_appel_whatsapp` lèvent `NON_CONFIGURE` si une clé manque |
| Repli vers le transactionnel ? | **Non.** Seuls replis : le **nom** de fournisseur `brevo` par défaut et `v23.0` | 43 l. 453-454, 509-510 ; 42 l. 327 |
| Compte Brevo partagé ? | Fermé par défaut (`brevo_compte_partage = true`), vérifié à l'allumage, à la porte et sur le fournisseur figé de l'envoi. Levée par une simple déclaration (RF-06) | 41 l. 593 ; 40 l. 401 ; 43 l. 931 |
| Écrit dans `notifications`, `notification_envois`, `notification_regles`, `messages_recents` ? | **Non** (lectures seules : quota, candidats, santé) | Recherche dans les 4 fichiers |
| Change le comportement des notifications existantes ? | Pas leurs règles ni leurs fonctions. **Effets indirects** : déclencheur sur `clients` (RF-09, RF-10), `permissions_du_role`, file pg_net partagée (RF-15), lectures de `notification_envois` et `auth.users` à chaque réservation e-mail | — |
| Rallume les e-mails de facture ? | **Non** : `notification_regles` et `expedier_envoi` ne sont pas touchés | Recherche dans les 4 fichiers |

**Verdict : séparation CONFIRMÉE au niveau du code**, avec la réserve RF-06 (aucune garde contre des valeurs identiques) et les couplages indirects ci-dessus.

---

## 6. État des corrections demandées

| Correction | État | Preuve |
|---|---|---|
| Interblocages et ordre des verrous | **PARTIEL** | Corrigé : un envoi par transaction ; campagne avant envoi ; verrouillage par identifiant croissant ; SKIP LOCKED dans le constat et la lecture. **Restent** : RF-02 (`KEY SHARE` des clés étrangères, en particulier deux événements pour un même envoi), RF-05. Tous détectés par PostgreSQL, sans attente infinie. |
| Limites et budgets globaux de Brevo | **PARTIEL** | Réservation sous N5, quota recalculé à chaque e-mail (43 l. 253-305), fenêtres glissantes, réserve et transactionnel déduits. **Non vérifiable** : le vrai quota (déclaration manuelle), les e-mails d'authentification (borne basse). Coût des lectures sous N5 (RF-04). |
| Issues incertaines et doublons | **CORRIGÉ dans le code** | 5xx et 429 donnent « incertain », jamais de nouvel essai seul (43 l. 575-619) ; « sans réponse » seulement hors fenêtre ; relance manuelle avec risque coché ; relance écartée si l'original a été remis. **Non vérifiable** : idempotence chez les fournisseurs. Risque résiduel accepté : une remise tardive après une relance. |
| Événements STOP et désinscriptions | **PARTIEL** | Corrigé : rejeu, âge non limité, entrant exempté du débit, erreur plutôt que perte (IR2-06), lien HMAC. **Restent** : RF-03, RF-04, RF-05, RF-02. |
| Minimisation et effacement des données personnelles | **PARTIEL** | Purge « personne » complète sur les tables du Centre, empreintes ramassées avant anonymisation, clé `efface:`. **Restent** : RF-11 (journal immuable, tables pg_net), sauvegardes, durées bloquées. |
| Fuseaux horaires | **CORRIGÉ (échec fermé)** | Fuseau déclaré, sinon HT, DO, ou État américain à fuseau unique avec preuve ; sinon exclu ; calcul par nom IANA (43 l. 158-188). Hypothèse : pays du profil = résidence pour HT et DO. |
| Limite de débit des webhooks | **PARTIEL** | Compteur en base, 8 éclats, entrant exempté. Compté **avant** la signature : un flot faux sature les retours légitimes (réponse 5xx). Fonction Edge non écrite ; reprise par les fournisseurs non vérifiée. |
| Permissions et SECURITY DEFINER | **CORRIGÉ dans le code** (vérifié par pglast) | Restent RF-08 et RF-16 (mode d'exécution) ; rôle webhook non décidé. |
| Événements Meta et Brevo | **PARTIEL / NON VÉRIFIABLE** | Statuts sans recul, rapprochement des incertains, report seulement sur un code vérifié (tous `verifie = false`). Signification des codes non vérifiée ; Brevo ne signe pas (rapporté). |
| Liens de confirmation et de désinscription ; pixels (PR #46) | **PARTIEL** | Jetons forts, à usage unique ou HMAC, confirmation au clic seulement, aucun pixel dans l'habillage. **Restent** : RF-12 (Referer vers Meta), RF-13, jeton dans la query plutôt que dans le fragment, suivi d'ouverture et de clics de Brevo non désactivé (rapporté). |
| Arrêt d'urgence (porte unique, N0, constat) | **PARTIEL** | Logique juste sous H1 à H5 et H4′. RF-01 ouvert. |

---

## 7. Ce que j'ai vérifié comme correct

- Une seule porte de sortie : les 3 appelants de `net.http_*` exigent la marque `txid:nature:canal` posée sous K0 partagé ; la porte relit l'état **après** le verrou et vérifie la lecture validée.
- `arret_confirme` est impossible sans `autorisations_closes_le` (code et contrainte) ; `autorisations_closes_le` n'est posé que sous K0 exclusif ; les délais mènent à `STOP_PENDING`, jamais au contournement.
- Le constat ne peut pas attendre de ligne (SKIP LOCKED) ; les fonctions d'arrêt prennent toujours K0 avant la ligne d'arrêt ; `communication_confirmer_arret_auto` ne bloque jamais ; la procédure ne garde aucun verrou d'une étape à l'autre.
- Les requêtes sont comptées par identifiant, quel que soit le statut ; le nouvel essai remet l'observation à zéro ; la purge garde l'identifiant tant qu'il est en transmission ; les lectures Meta sont comptées aussi.
- 28 tables avec RLS et revoke ; toutes les fonctions SECURITY DEFINER avec `search_path` vide ; revoke de toutes les fonctions internes, `service_role` compris ; ordre de création compatible avec la validation des corps SQL.
- `permissions_du_role` est identique aux trois copies existantes, plus les 7 permissions ; l'employé et le client n'en ont aucune.
- Aucune écriture dans le moteur transactionnel ; aucune clé transactionnelle lue ; aucun repli.
- Les brouillons ne partent pas sur le site (`deploy.yml`) ; garde efficace pour les clients corrects.

---

## 8. Limites de cette revue

- **Rien n'a été exécuté.** Toutes les propriétés de concurrence viennent de la lecture du code et de la sémantique de PostgreSQL telle que je la connais (rapportée, non éprouvée). En particulier :
  - `KEY SHARE` posé par les clés étrangères ;
  - SKIP LOCKED face à `KEY SHARE` ;
  - mise à niveau d'un verrou de ligne et file d'attente des verrous ;
  - `lock_timeout` sur les verrous consultatifs ;
  - possibilité d'attraper `query_canceled`.
- Le fonctionnement interne de **pg_net** (ordre retrait, transfert, réponse ; index ; durée de conservation ; reprise après redémarrage) et les réglages de **Supabase** (délai d'exécution, privilèges par défaut, PostgREST, pg_cron) sont **rapportés, non éprouvés**.
- Les comportements de **Meta** et de **Brevo** (nouveaux essais des webhooks, codes 131xxx, bouton de désinscription, suivi par défaut, signature) sont **rapportés, non éprouvés**. Aucune de leurs API n'a été appelée.
- Les fonctions de Phase 2 annoncées mais absentes ne sont pas évaluées : `approuver_modele_communication` (elle devra passer par la porte), fonction Edge, pages `desinscription.html` et `confirmation-communication.html`.
- Les gravités sont mon jugement. RF-01 et RF-02 sont classés ÉLEVÉE à cause de la fonction touchée (arrêt d'urgence, signaux de désinscription) ; ils ne sont pas exploitables à distance.
- Les documents de conception n'ont été lus que pour comparer leurs affirmations. Leurs écarts avec le code sont signalés : RF-17, et l'en-tête de 43 §9 sur l'« ordre unique » (RF-02).
