# Centre de communication — Phase 1.3.1 : audit de sécurité indépendant

**Dates** : 18 au 20 novembre 2026
**Objet** : vérifier sur le code réel les corrections de la Phase 1.3, corriger l'arrêt d'urgence, chercher les risques encore ouverts.
**Brouillons à la fin de la phase** : commit `0693d5e`, branche `ccr-056ddc8c-m7u4p1` (PR #65, brouillon).

> **Rien n'a été exécuté.** Aucun SQL, ni en production ni sur une base de test. Aucune migration appliquée. Aucun fournisseur contacté. Aucun secret créé. Aucun déploiement. Aucune PR fusionnée.
>
> Toutes les vérifications sont **statiques** : lecture du code, et analyse avec le parseur de PostgreSQL (`pglast`, sans serveur).

---

## 1. Résumé exécutif

1. **L'arrêt d'urgence de la Phase 1.3 était dangereux, comme le CEO l'avait relevé.** Après 5 s sans verrou, il écrivait l'arrêt quand même et répondait « ok ». La revue indépendante n° 1 l'a confirmé (IR-03), avec un scénario où un message est validé après la réponse.

   Il est **reconçu** (`PHASE_1_3_1_KILL_SWITCH_DESIGN.md`) :
   - une porte unique pour toute requête sortante ;
   - une table d'arrêt à trois états ;
   - « confirmé » **seulement** sur preuve ;
   - un délai qui donne `STOP_PENDING`, jamais un succès ;
   - une nouvelle tentative sûre, manuelle ou automatique.
2. **Trois revues indépendantes** ont été menées par des sessions distinctes, sans le contexte de l'auteur, avec la consigne de **casser** le travail (§3).

   **Chacune a trouvé de vrais défauts que l'auteur n'avait pas vus**, dont trois successifs dans l'arrêt d'urgence lui-même (IR-03, IR2-01, IR3-01). Tous sont corrigés dans les brouillons.
3. **Les corrections de la Phase 1.3 n'étaient pas toutes exactes.** Sur huit, la revue n° 1 en a trouvé plusieurs incomplètes ou fausses :
   - l'effacement d'une personne échouait sur une clé étrangère (IR-01) ;
   - l'identifiant du client survivait dans la clé d'envoi (IR-02) ;
   - la migration 42 ne se créait pas (IR-05) ;
   - trois interblocages restaient possibles (IR-13) ;
   - un STOP WhatsApp pouvait être perdu (IR-08).
4. **Risques ouverts à la fin de la phase** (§6) : **0 CRITICAL, 0 HIGH, 5 MEDIUM, 9 LOW**. C'est l'état connu après la revue n° 3. Les corrections faites **après** cette revue n'ont pas été revérifiées par une revue indépendante.
5. **Verdict : CONDITIONAL — INDEPENDENT REVIEW PENDING** (§8). Les dernières corrections (constats IR3-xx) attendent une vérification indépendante, et **aucun des 40 essais n'a été exécuté**.

---

## 2. Méthodologie

| Étape | Qui | Ce qui a été fait |
|---|---|---|
| Relecture et contre-revue | L'auteur des brouillons | Lecture intégrale de 40 à 43 ; inventaire des sorties (`net.http_*`) ; reconception de l'arrêt ; contre-revue (constats AF-01 à AF-11, `PHASE_1_3_1_SQL_DRAFT_CORRECTIONS.md`) |
| Revue indépendante n° 1 | Une session distincte (agent d'audit de sécurité), **sans** le contexte ni les conclusions de l'auteur | Les brouillons de la Phase 1.3 (commit `5b88624`), la liste de contrôle du CEO (§4.1 à §4.8), les PR #46 et #48. **25 constats** (IR-01 à IR-25). |
| Corrections | L'auteur | Corrections dans les brouillons (commit `2ca00cf`) |
| Revue indépendante n° 2 | Une **nouvelle** session distincte | L'arrêt d'urgence corrigé, puis la vérification d'IR-01 à IR-25 et la recherche de défauts nouveaux. **18 constats** (IR2-01 à IR2-18). |
| Corrections | L'auteur | Commit `37148d6` |
| Revue indépendante n° 3 | Une **troisième** session distincte | La propriété de l'arrêt, la vérification d'IR2-xx, et le diff. **9 constats** (IR3-01 à IR3-09). Interrompue deux fois par une limite d'usage, puis reprise. |
| Corrections | L'auteur | Commit `0693d5e` : **non revérifié** de façon indépendante |

**Limites de l'indépendance (déclarées)** :
- les trois revues sont des **sessions** différentes, sans le contexte de l'auteur ;
- elles n'ont **pas** été faites par un humain, ni par un modèle différent ;
- elles réduisent le biais de confirmation, sans valoir une revue humaine par un spécialiste de PostgreSQL.

Les consignes données aux revues demandaient explicitement de chercher des contre-exemples, et ne contenaient pas les conclusions de l'auteur. La revue n° 2 a reçu les résumés des constats de la revue n° 1 pour les vérifier. La revue n° 3 a reçu ceux de la revue n° 2.

Les rapports complets des trois revues sont gardés hors du dépôt, dans l'espace de travail de la session (fichiers `RAPPORT-revue-independante*.md`).

---

## 3. Fichiers réellement inspectés

- **Brouillons** `brouillons-sql/40` à `43` : lus intégralement à chaque tour, par l'auteur et par chaque revue.
- **`outils/supabase.sql`** :
  - `clients`, `permissions_du_role`, `exiger_permission`, `lire_reglage` ;
  - les droits de colonnes du client ;
  - les droits sur `permissions_du_role`.
- **Autres fichiers d'`outils/`** :
  - `supabase-double-auth.sql` (`peut`) ;
  - `supabase-compte.sql` (`supprimer_mon_compte` : un seul UPDATE) ;
  - `supabase-corrections.sql` (`auditer`, `journal_immuable`) ;
  - `supabase-notifications.sql` (`notification_envois`) ;
  - `supabase-naissance.sql` et `supabase-suivi-externe.sql` (copies de `permissions_du_role`, identiques à celle de `supabase.sql` d'après un `diff`).
- **Lanceurs** :
  - `essai-services.py` (`ON_ERROR_STOP=1`) ;
  - `appliquer-chaine.sh` (`--single-transaction`) ;
  - `epreuve-restauration.sh`.
- **Déploiement et politiques** :
  - `docs/production/secrets.md` (clé `service_role` « utilisée nulle part ») ;
  - `.github/workflows/deploy.yml` (exclut `docs/`, `*.sql`, `*.md`) ;
  - `build.py` (`Referrer-Policy`) ;
  - `assets/js/lieux.js` (États américains).
- **PR #46** (`origin/pixel-meta`), **PR #48** (`origin/ccr-1b1dd194-g07lcu`), **PR #65** : différences avec `main`.

---

## 4. Audit des corrections de la Phase 1.3 (point 4 de la consigne)

| # | Domaine | Constat sur le code de la Phase 1.3 | État à la fin de la 1.3.1 |
|---|---|---|---|
| 4.1 | Ordre des verrous et interblocages | L'ordre N0 → N5 annoncé n'était **pas** tenu partout. Trois cycles restaient : désinscription contre retour de plainte ; purge contre lecture des réponses ; purge contre annulation (IR-13). Un nouveau est apparu ensuite : purge sans N3 (IR2-07). | **Corrigé** : désinscription sous N3 avant l'insertion ; fermeture des incertains en `skip locked` ; purge et annulation verrouillent les envois par identifiant croissant ; purge sous N2 et N3. La revue n° 3 n'a trouvé **aucun cycle**. **Reste à éprouver** (T-03, T-20). |
| 4.2 | Quota Brevo et limites globales | Réservation atomique sous N5 **correcte** (revues n° 1 et 2). Défauts annexes : fournisseur relu à l'appel (IR-06) ; compte partagé avec le transactionnel (IR-11, IR2-12, IR3-04). | **Corrigé** : fournisseur figé sur l'envoi ; e-mail commercial refusé tant que le compte est partagé, à l'allumage, à la porte et à chaque envoi. READ COMMITTED vérifié. |
| 4.3 | 5xx et incertains | Règle « 5xx = incertain » **correcte**. Défauts : « incertain » posé alors que la requête était encore dans la file pg_net (IR-15) ; relance envoyée après le rapprochement de l'original (IR-14) ; 401/403 consommant l'audience (IR-20). | **Corrigé** |
| 4.4 | Données personnelles | L'effacement d'une personne **échouait** (IR-01). L'UUID restait dans la clé (IR-02). Données gardées : exclus de l'audience, entrants WhatsApp, fenêtres, demandes de purge, champs de levée (IR-07). Désinscription « ok » sans rien écrire (IR-09). Purge des confirmations bloquée (IR2-05). Requête effacée en vol (IR2-02). | **Corrigé dans le Centre.** **Ouvert hors du Centre** : `journal_audit`, pg_net, fournisseurs (M2, §6). Durées **toujours BLOQUÉES** (juriste). |
| 4.5 | Fuseaux horaires | Plus de New York par défaut ; un fuseau inconnu bloque l'envoi ; nom IANA ; marge : **correct**. Pays du profil pris comme preuve pour HT et DO (IR-23). Indicatif +1 court (IR-23, IR2-09). | Hypothèse HT/DO **écrite comme telle** ; indicatifs +1 de moins de 4 chiffres refusés ; autorisation lue sur le préfixe le plus long |
| 4.6 | Webhooks | Accès par rôle dédié, HMAC sur le texte brut et rejeu : **corrects**. Défauts : STOP perdu (débit, horodatage, empreinte : IR-08, IR2-06) ; pause du canal sur la ligne des réglages (IR-04) ; code non vérifié créant un envoi (IR-20) ; identifiant Meta gardé (IR-07). | **Corrigé.** Reste : le comportement de la fonction Edge (réponse 5xx, réessai du fournisseur), qui n'est pas encore écrite (M5). |
| 4.7 | Garde des migrations | Le bloc DO seul ne protégeait pas `psql` sans `ON_ERROR_STOP` (Phase 1.3, couche 2) ; un découpeur naïf exécutait le remplacement de `permissions_du_role` (IR-22). | **Quatre couches**. Simulation : un découpeur sur « ; » ne peut exécuter que deux `end` sans effet, puis la fermeture de sa propre session. **Limite** : un découpeur qui ignore les commentaires (IR2-08, LOW). |
| 4.8 | Permissions PostgreSQL | `SECURITY DEFINER` et `search_path` vides **corrects**. Défauts : `service_role` gardait ses droits (IR-18) ; verrou avant permission (IR-17). | **Corrigé** : `service_role` retiré des fonctions internes et des 28 tables ; l'employé n'a aucun accès (vérifié par les trois revues) |

---

## 5. Comparaison des analyses et désaccords

**Ce que l'auteur n'avait pas vu** (trouvé par les revues) :
- IR-01 (clé étrangère) ;
- IR-02 (UUID dans la clé) ;
- IR-05 (création de 42) ;
- IR-08 (STOP perdu) ;
- IR-09 (désinscription silencieuse) ;
- IR-13 (trois cycles) ;
- IR2-01 et IR3-01 (fin des transmissions) ;
- IR2-03 (levée concurrente) ;
- IR2-06 (rejeu d'un STOP) ;
- IR2-17 (une modification de l'auteur jamais enregistrée).

**L'auto-revue ne suffisait donc pas**, comme le CEO l'avait anticipé.

**Ce que l'auteur avait trouvé seul**, et qu'une revue a confirmé :
- le repli de l'arrêt (AF-01, = IR-03) ;
- la pause du canal (AF-02, ≈ IR-04) ;
- le lancement qui tenait N0 (AF-03, = IR-21) ;
- `service_role` (AF-11, = IR-18) ;
- le code non vérifié (AF-06, ≈ IR-20).

**Désaccords et choix documentés** :

| Constat | Position de la revue | Position retenue | Raison |
|---|---|---|---|
| IR2-08 | Préfixer chaque ligne du contenu par `--|` | **Non appliqué** (LOW, ouvert) | Gain faible (outil très improbable), coût élevé : brouillons illisibles et analyse statique à refaire. La limite est déclarée et mesurée par l'essai T-14C. |
| IR-12 | Corriger maintenant (`no-referrer`, jeton dans le fragment) | **Exigence de la Phase 2c** | Les pages n'existent pas encore ; rien à corriger en SQL |
| IR-16 | `pg_try_advisory_xact_lock` et file de reprise dans le déclencheur | **Blocs séparés seulement** | Fixer un `lock_timeout` dans le déclencheur toucherait la transaction du client, qui est du code existant. Le risque est faible, N3 n'étant tenu que quelques millisecondes. |
| IR2-16 / IR3-03 | Compter les lectures Meta, ou redéfinir STOP_CONFIRMED | **Comptées** | Plus simple et plus fort |
| IR3-07 | La levée doit comparer l'état vu par l'écran | **Partiel** : refus si un appui est postérieur au début de la levée ; un appui bloqué plus de 2 s répond `STOP_NOT_CONFIRMED` (vrai) | Le comportement est honnête, sans faux succès |

---

## 6. Risques encore ouverts (classification du CEO)

| # | Gravité | Fichier / fonction | Description | Correction recommandée | Preuve | Essai |
|---|---|---|---|---|---|---|
| M1 | MEDIUM | Pages de la Phase 2c (à écrire) ; `build.py` (`Referrer-Policy`) ; PR #46 | Jeton de confirmation ou de désinscription transmis à Meta par l'en-tête `Referer` de la page suivante, si le pixel de la PR #46 est en place (IR-12) | `no-referrer` sur ces pages ; jeton dans le fragment `#`, effacé aussitôt ; pages exclues de `mesure.js` | Revue n° 1 (raisonnement sur `build.py` et la PR #46) | À écrire en Phase 2c |
| M2 | MEDIUM | `journal_audit` (existant, gelé) ; pg_net ; Brevo et Meta | Après effacement restent : l'UUID du client et les motifs libres dans `journal_audit` ; le corps des requêtes et des réponses dans pg_net (environ 6 h, rapporté), dont le numéro `wa_id` ; les journaux des fournisseurs | Décision du juriste et du CEO : motifs à codes seulement ; durée de pg_net (partagée avec le transactionnel) ; contrats des sous-traitants | Revues n° 1 et 2 ; T-05B | T-05B |
| M3 | MEDIUM | 41 `arreter_communications` → 43 `communication_transmissions_en_cours` | Le constat d'arrêt se fait dans la transaction de l'arrêt. Sur une table très remplie, il pourrait dépasser le délai d'exécution (8 s rapporté) : l'arrêt échoue (erreur 57014) au lieu de répondre (IR3-02). Atténué par le filtrage et les index partiels. | Mesurer ; si besoin, écrire la demande dans une transaction à part, puis confirmer | Revue n° 3 | T-01F, T-05 |
| M4 | MEDIUM | Démonstration de l'arrêt (H1 à H5) | Faits de PostgreSQL et de pg_net 0.20.4 **rapportés, non éprouvés** : ordre retrait / appel / réponse, délai, visibilité avant libération des verrous, ordre de service des verrous, procédure avec COMMIT lancée par pg_cron | Les éprouver | Documentation (rapporté) | T-01-bis, T-01B à T-01H, T-02 |
| M5 | MEDIUM | Fonction Edge (Phase 3, à écrire) | Authentification non choisie (décision S-1 : rôle dédié recommandé). Le STOP repose sur la réponse 5xx de la fonction Edge et sur le réessai du fournisseur (non vérifié). | Décision S-1 ; vérifier les politiques de réessai de Meta et de Brevo | Revues n° 1 et 2 | T-07D, Phase 3 |
| L1 | LOW | En-têtes des brouillons | Un découpeur qui ignore les commentaires peut exécuter des morceaux (IR2-08) | Ne jamais passer un brouillon à un tel outil | Revue n° 2 (simulation) | T-14C |
| L2 | LOW | 41 `communication_suivre_client` | Une annulation par délai n'est pas attrapée (IR-16) | Accepté ; à mesurer | Revue n° 1 | T-18 |
| L3 | LOW | 40 `communication_brevo_disponible`, 43 STOP entrant, 42 aperçu | Coûts sous verrous globaux et parcours complets (IR-21) | Mesurer, puis cumuls et index | Revues n° 1 et 3 | T-05 |
| L4 | LOW | 41 `lever_arret_communications` | La levée ne compare pas l'état affiché à l'écran (IR3-07) | Version de la ligne passée par l'écran (Phase 2c) | Revue n° 3 | T-01H |
| L5 | LOW | Chaîne 40 à 43 | En chaîne partielle, la demande de purge à la suppression du compte n'est pas recréée (IR-05 résiduel) | Appliquer 40 à 43 **dans une seule transaction** | Revue n° 2 | T-14B |
| L6 | LOW | 40 `communication_demandes_purge` | Une demande en attente garde l'identifiant et les empreintes (nécessaire) ; motif libre dans `journal_audit` (IR2-15) | Délai de traitement des demandes ; motifs à codes | Revue n° 2 | T-05B |
| L7 | LOW | 40 `communication_fuseau` | Pour HT et DO, le pays du profil vaut résidence (hypothèse assumée, IR-23) | Déclaration du fuseau dans « Mon compte » (Phase 2c) | Revue n° 1 | T-09 |
| L8 | LOW | 43 webhook « pause du canal » | Écrite au mieux, sans N0. Ce n'est pas un arrêt confirmé (documenté). | Pour une garantie : l'arrêt d'urgence | Auteur, revues n° 1 et 2 | T-07B |
| L9 | LOW | 43 `relancer_envoi_communication` | La relance d'un envoi effacé est acceptée, puis écartée (IR2-18) | Refuser d'emblée en Phase 2 | Revue n° 2 | T-01E |

**Aucun risque CRITICAL ni HIGH connu n'est ouvert.** Les derniers HIGH (IR3-01, IR2-01, IR-01, IR-02, IR-03) sont corrigés dans les brouillons. Ceux de la revue n° 3 n'ont **pas** été revérifiés de façon indépendante.

---

## 7. PR #46, #48 et #65 (point 8 de la consigne, sans aucune action)

| PR | Constat | Ordre recommandé |
|---|---|---|
| #65 (ce projet) | Ne modifie **que** `docs/communication-center/`. Selon la revue n° 2, `git merge-tree` avec `main` ne montre aucun conflit. `docs/` est exclu de la publication. | Peut rester ouverte en brouillon. **Rien à fusionner** avant la décision du CEO sur la Phase 2. |
| #46 (pixel Meta) | Touche `build.py` et `confidentialite.html` (× 4), que la Phase 2c du Centre modifiera aussi. Le pixel lit le `Referer` (rapporté) : risque M1. | **Avant** la Phase 2c : la rebaser sur `main`, puis exclure explicitement les pages du Centre portant un jeton |
| #48 (Centre de Commandement IA) | Un seul document d'audit ; prévoit `ia.*` dans `permissions_du_role` (cinq copies), une migration, une fonction Edge. `deploy.yml` ignore les `*.ts` (IR-24). | Le premier projet qui **écrit** sa migration pose les permissions des deux. Une seule convention de fonction Edge (rôle de connexion dédié). Aucun agent IA ne reçoit `communications.approve`, `.manage` ni `.test`. |

**Aucune PR n'a été fusionnée, modifiée, fermée, ni changée de statut.**

---

## 8. Verdict

### CONDITIONAL — INDEPENDENT REVIEW PENDING

Raisons :
- les corrections faites **après** la revue indépendante n° 3 n'ont pas été revérifiées par une revue indépendante. La revue n° 3, interrompue deux fois par une limite d'usage, n'a pas été suivie d'une quatrième. Ces corrections portent sur IR3-01 à IR3-08, dont IR3-01, HIGH, qui touchait l'arrêt d'urgence ;
- **aucun essai n'a été exécuté** (0 sur 40) ;
- les décisions du CEO et du juriste restent ouvertes : C4, S-1, durées, D-G, D-H.

**Aucun risque CRITICAL connu n'est ouvert**, donc le verdict n'est pas NOT APPROVED. Il n'est pas non plus favorable, parce que la dernière série de corrections de l'arrêt n'a pas de vérification indépendante.
