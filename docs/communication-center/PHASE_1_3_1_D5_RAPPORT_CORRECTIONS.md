# GoShip Express — Centre de communication
# Rapport des corrections D5 (préparation autorisée sous conditions)

| | |
|---|---|
| Date | 20 novembre 2026 |
| Décision appliquée | Décision écrite de la CEO du 20/11/2026 : D1 approuvé, D2 provisoire prudente, D3 autorisé sous conditions strictes, D4 approuvé, D5 approuvé sous conditions |
| Branche | `ccr-056ddc8c-m7u4p1` (PR #65, brouillon, **non fusionnée**) |
| Point de départ | commit `86e8c57` (brouillons identiques à `2e9cc9f`, le commit de clôture) |
| Périmètre modifié | Brouillons SQL 40 à 43 et documents techniques du dossier `docs/communication-center/` **uniquement** |
| Verdict de la Phase 1.3.1 | Toujours **NON VALIDÉ**, jusqu'à la nouvelle revue indépendante |
| Phase 2 | **Non autorisée** |

> **Rien n'a été exécuté**, sauf la seule lecture autorisée par D3 (§2) :
> - aucune migration ;
> - aucun essai, même sur une base jetable ;
> - aucun SQL sur une base de test ;
> - aucun appel à Meta, Brevo ou un autre fournisseur ;
> - aucun secret lu ou modifié ;
> - aucune configuration changée ;
> - aucune fusion, aucun déploiement, aucun canal activé.
>
> Les corrections ne sont vérifiées que **par lecture** et par **analyse statique** (`pglast`, l'analyseur de PostgreSQL, sans serveur). Une analyse statique ne prouve ni l'existence des colonnes, ni les types, ni le comportement à l'exécution.

**Légende** :
- **[V]** vérifié dans le code ;
- **[D]** hypothèse sur le fonctionnement de PostgreSQL ;
- **[NE]** non testé ;
- **[EXT]** dépend d'un service ou d'une documentation externe.

---

## 1. Résumé

| Décision | Fait | Où |
|---|---|---|
| **D1** N-01, fréquence par numéro | Plafond par compte **et** par contact | 43 `communication_frequence_atteinte(uuid, text, text)` |
| **D1** N-02, code WhatsApp | 6 chiffres ; unique par numéro parmi les demandes ouvertes (garanti par un index) ; expiration en 60 min ; 5 essais au plus ; demandes répétées limitées (1 par minute et par compte, plafond par 24 h par compte **et** par numéro) | 40, 41, 43 |
| **D1** Contradiction C6 / R-06 | Levée : C6 est appliquée en entier, et R-06 devient « code à 6 chiffres, 5 essais, 60 min » (§7) | Ce rapport, `COMMUNICATION_CENTER_SECURITY.md` §10.2 |
| **D2** Numéro partagé | Exclu dès qu'un compte qui l'utilise n'a pas de consentement confirmé (`CONTACT_PARTAGE_NON_CONSENTI`). Documenté comme **mesure conservatrice** en attente du juriste. | 42 `communication_raison_exclusion` |
| **D3** Délais des rôles | Une seule requête `SELECT`, résultats au §2 | Production, lecture seule |
| **D4** Spécialiste PostgreSQL | Courte liste, méthode et demande de devis au §3. **Aucun contact pris, aucun engagement.** | — |
| **D5** P-07, version, P-03, P-08, P-09, P-05, surveillance | Fait dans les brouillons ; documents mis à jour | §4 à §6 |

---

## 2. D3 — Délais d'exécution des rôles, mesurés en production

**Requête exécutée, une seule fois, en lecture seule** :

```sql
select rolname, rolconfig from pg_catalog.pg_roles
 where rolname in ('anon', 'authenticated', 'service_role') order by rolname
```

**Résultat exact** :

| Rôle | `rolconfig` |
|---|---|
| `anon` | `{statement_timeout=3s}` |
| `authenticated` | `{statement_timeout=8s}` |
| `service_role` | `null` (aucun réglage propre au rôle) |

**Limites de cette mesure** :
- Seuls les réglages **propres au rôle** sont lus. Ne sont pas inspectés, conformément à D3 :
  - les réglages par base (`pg_db_role_setting`) ;
  - ceux du serveur ;
  - ceux de PostgREST ;
  - ceux de la fonction Edge.
- Un réglage de base ou de serveur peut s'appliquer à `service_role`.
- Ce sont des **plafonds**, pas des durées. La durée réelle des fonctions n'est **pas** mesurée [NE] (essai F-K07).
- Le futur rôle `communication_webhook` n'existe pas encore : il n'a pas de délai connu.
- La valeur peut changer si Supabase modifie ses réglages par défaut [EXT].

**Effet sur les brouillons** : chaque appel de l'écran borne ses attentes sous ces valeurs.
- Arrêt : 5 s.
- Confirmation : 3 + 2 s.
- Levée : 3 + 3 s.
- Désinscription, ouverte aux visiteurs : 2 s, sous les 3 s d'`anon`.

---

## 3. D4 — Spécialiste PostgreSQL indépendant (aucun contact, aucun engagement)

**Source** :
- l'annuaire officiel des sociétés de services PostgreSQL (postgresql.org, « Professional Services ») : **seuls les noms et les liens** de ses plus de 80 entrées ont été lus, pas leurs descriptions complètes ;
- les pages publiques des sociétés retenues.

**Les informations ci-dessous viennent de leurs sites et n'ont pas été vérifiées** [EXT]. **Aucun devis n'est public** : il faut le demander.

| Société | Pays, langue | Expérience (d'après leur site) | Pourquoi elle convient | Tarif connu |
|---|---|---|---|---|
| **Dalibo** | France, français | Société PostgreSQL de référence en France, depuis 2005 ; coopérative (SCOP) ; audits d'applications construites sur PostgreSQL (sécurité, stabilité, performance) | Francophone ; audit d'applications | Non public, devis |
| **Data Bene** | France, français | Ex-2ndQuadrant France (2010-2020), fondée par Cédric Villemain ; support, audits, conseil d'architecture | Francophone ; équipe historique de PostgreSQL en France | Non public, devis |
| **CYBERTEC PostgreSQL** | Autriche, anglais et allemand | Services PostgreSQL depuis 2000 ; facturation à l'heure (conditions générales) ; « Start-Up Assessment Package » d'une journée (8 h au plus) | Formule courte d'une journée, adaptée à une revue ciblée | Taux horaire, sur devis |
| **Data Egret** | Allemagne, anglais | 100 % PostgreSQL depuis 2012 ; audits, ateliers, architecture | Audits sans toucher à la production | Non public, devis |
| **PGX, Inc.** | États-Unis, anglais | « PostgreSQL hacking », conseil de performance | Spécialistes du fonctionnement interne | Non public, devis |

**Recommandation** : demander deux devis, à **Dalibo** ou **Data Bene** (francophones) et à **CYBERTEC** (formule courte). Il faut les comparer sur la méthode et sur la déclaration d'indépendance, pas seulement sur le prix.

**Méthode à exiger** :
1. **Déclaration d'indépendance** : aucun lien avec GoShip ni avec ses prestataires.
2. Lecture des brouillons 40 à 43 et des documents de conception, sous accord de confidentialité, **sans** accès à la production.
3. Réponses écrites aux 7 questions Q1 à Q7 (`PHASE_1_3_1_CLARIFICATIONS_ET_RISQUES_RESIDUELS.md`, §7) :
   - sous-transactions et rattrapage des erreurs ;
   - verrous consultatifs ;
   - verrous des clés étrangères ;
   - interblocages ;
   - verrou N3b ;
   - traitement une seule fois ;
   - durabilité.
4. Avis sur les specs d'essais de concurrence (`isolationtester`). S'il le juge utile, ses propres essais sur une base jetable **fournie par GoShip**, jamais sur la production.
5. Livrable : un rapport signé, point par point (confirmé, réfuté, à corriger), avec un niveau de gravité.

**Texte de demande de devis (à envoyer par la CEO, si elle le décide)** :

> Objet : Demande de devis — revue indépendante de code PL/pgSQL (concurrence et verrous)
>
> Bonjour,
> Nous recherchons une revue indépendante, en lecture seule, de quatre scripts de migration PostgreSQL (environ 6 000 lignes de PL/pgSQL, PostgreSQL 17 sur Supabase, extensions pg_net et pg_cron), avant leur première exécution. Les points à valider : sous-transactions et rattrapage d'erreurs (40P01, 55P03, 57014), verrous consultatifs (partagés et exclusifs), verrous posés par les clés étrangères, absence d'interblocage entre une dizaine de chemins concurrents, traitement exactement une fois d'événements, durabilité d'un arrêt d'urgence. Livrable : un rapport écrit point par point, et un avis sur nos plans d'essais de concurrence. Aucun accès à la production. Pouvez-vous nous indiquer votre méthode, vos délais, votre tarif et confirmer votre indépendance ?
> Cordialement,

**Avant d'envoyer** : décider ce qui sera partagé (les brouillons et les documents de la PR #65, sous accord de confidentialité). **Aucun secret** : les brouillons n'en contiennent pas, mais `assets/js/config.js` en contient et ne doit jamais être partagé.

---

## 4. Fichiers modifiés

| Fichier | Lignes ajoutées / retirées | Contenu |
|---|---|---|
| `brouillons-sql/40-supabase-communications-fondation.sql` | +56 / −3 | Ordre des verrous (N3b) ; `communication_arret.version` ; réglage `confirmation_code_validite_min` ; confirmations à 6 chiffres, `tentatives`, index unique par numéro ; purge bornée |
| `brouillons-sql/41-supabase-communications-consentement.sql` | +197 / −79 | Arrêt d'urgence (P-07, version) ; délais bornés (P-03) ; déclencheur non bloquant ; demande de consentement (code, limites) |
| `brouillons-sql/42-supabase-communications-campagnes.sql` | +33 / −6 | Règle D2 ; aperçu et volume dédoublonnés ; index unique des destinataires ; délais |
| `brouillons-sql/43-supabase-communications-envoi.sql` | +488 / −132 | Retours fournisseurs en deux temps (P-08) ; table de traitement ; classification (P-09) ; dédoublonnage et N3b (P-05) ; fréquence par contact (N-01) ; relance ; désinscription ; purges ; surveillance ; droits |
| **Total des 4 brouillons** | **+774 / −220** | |
| `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` | section « D5 » | Arrêt en deux appels, version |
| `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` | §7 | Effet sur la preuve |
| `PHASE_1_3_1_SQL_DRAFT_CORRECTIONS.md` | §6 | Liste des corrections D5 |
| `PHASE_1_3_1_FINAL_TEST_PLAN.md` | §4 bis, récapitulatif | 13 essais ajoutés, 7 révisés : **78 au total** |
| `PHASE_1_3_1_TEST_PLAN.md` | note en tête du §1 | Arrêt en deux appels |
| `COMMUNICATION_CENTER_DATABASE.md` | §8 | Objets nouveaux et modifiés |
| `COMMUNICATION_CENTER_SECURITY.md` | §10 | D2, code WhatsApp, procédure de reprise, délais mesurés |
| `README.md` | index | Ce rapport |
| **Ce rapport** | nouveau | — |

**Aucun fichier hors de `docs/communication-center/`** n'est modifié : aucun fichier de `outils/`, aucun contrat transactionnel, aucune page.

Différences complètes : `git diff 86e8c57 -- docs/communication-center/` sur la branche (ou l'onglet « Files changed » de la PR #65).

---

## 5. Différences avant / après, correction par correction

### 5.1 P-07 — l'arrêt d'urgence (41 §4.8)

**Avant** (une seule transaction, `arreter_communications`) :
```sql
perform set_config('lock_timeout', '3s', true);
begin perform public.communication_verrou_interrupteurs(true); v_n0 := true;
exception when lock_not_available then v_n0 := false; end;
... select * into a from public.communication_arret for update; ...
perform set_config('lock_timeout', '0', true);
update ... set etat = 'arret_demande', ...;                 -- la demande
v_resultat := public.communication_conclure_arret(v_n0);   -- le constat : une erreur ici annule la demande
```

**Après** :
```sql
-- arreter_communications : la demande SEULE, sans N0, ligne d'arrêt 5 s au plus
perform set_config('lock_timeout', '5s', true);
begin select * into a from public.communication_arret for update; v_trouve := found;
exception when lock_not_available then return ... 'STOP_NOT_CONFIRMED' ...; end;
update ... set derniere_demande_le = clock_timestamp(), version = version + 1, ...;
if a.etat = 'actif' then update ... set etat = 'arret_demande', ...; end if;
return jsonb_build_object('etat', 'STOP_REQUESTED', 'version', ..., 'suite', 'confirmer_arret_communications');

-- confirmer_arret_communications : le constat, protégé
begin v_resultat := public.communication_conclure_arret(v_n0);
exception when query_canceled then v_etat := '57014';
          when others then get stacked diagnostics v_etat = returned_sqlstate; end;
if v_etat is not null then ... 'STOP_PENDING', 'CONSTAT_IMPOSSIBLE' ...; end if;
```

Dans `communication_conclure_arret` :
- `autorisations_closes_le = greatest(clock_timestamp(), a.demande_le)` ;
- `confirme_le = greatest(clock_timestamp(), v_closes)` ;
- `version + 1` à la fermeture des autorisations et à la confirmation.

**Concurrence** : la demande ne prend que la ligne ; le constat et la levée prennent N0, puis la ligne. Une porte qui lit l'état après le COMMIT de la demande refuse **[V] + [D]**.

### 5.2 Version attendue (40, 41)

- **Avant** : `lever_arret_communications(p_motif)` ne contrôlait que `derniere_demande_le > v_debut`, et attendait 5 s + 5 s, soit **10 s, plus que les 8 s du rôle**.
- **Après** :
  - `drop function if exists public.lever_arret_communications(text)` ;
  - nouvelle fonction `lever_arret_communications(p_motif, p_version_attendue bigint)` ;
  - refus `STOP_STATE_CHANGED` si `version` ≠ celle de l'écran ;
  - l'ancien contrôle est gardé en plus ;
  - attentes de 3 s + 3 s, puis `BUSY` ;
  - la liste des droits porte la nouvelle signature.

### 5.3 P-03 — délais bornés

| Fonction | Avant | Après |
|---|---|---|
| `regler_communications` | N0 10 s, puis `'0'` | 3 s, puis 2 s |
| `verifier_quota_brevo`, `regler_whatsapp_commercial`, `verifier_issue_http` | N0 exclusif sans limite | 3 s, puis `BUSY`, puis 2 s |
| Consentement (`demander_`, `confirmer_`, `retirer_mon_`, `retirer_consentement_client`), `approuver_purge_`, `executer_purge_`, `changer_statut_campagne`, `ecrire_campagne_communication`, `relancer_envoi_communication` | sans limite | `set lock_timeout = '3s'` |
| `desinscrire_communication` (visiteurs) | sans limite | `2s`. Au-delà, une erreur, jamais « ok » sans écriture. |
| Déclencheur `communication_suivre_client` (chemin **existant** des clients) | attendait N3 sans limite | `pg_try_advisory_xact_lock`. S'il est pris, l'invalidation s'écrit quand même, et le cas est noté (`N3_OCCUPE`). C'est sûr, puisqu'un consentement ne vaut que pour le contact **actuel** **[V]**. |
| Retours des fournisseurs | 5 s | temps A : 2 s ; temps B : 3 s |

### 5.4 P-08 — retours des fournisseurs (43)

**Avant** : `communication_recevoir_evenement` faisait tout dans une seule transaction. L'insertion du retour, avec sa clé étrangère vers l'envoi, posait un `FOR KEY SHARE` caché **avant** N1 et N3 (RF-02) ; un STOP insérait la suppression **avant** N3 (RF-05). Une annulation défaisait tout, y compris l'anti-rejeu.

**Après** :
- **Clé étrangère retirée** : `envoi_id bigint`, sans `references`. Un bloc rejouable la retire d'une base qui l'aurait déjà.
- **Nouvelle table `communication_evenements_traitement`** : `a_traiter`, `traite` ou `echec` ; priorité 1 pour un STOP, une plainte, une désinscription ou une opposition (131050) ; l'empreinte et le code sont effacés une fois le retour traité (contrainte).
- **Temps A** (`communication_recevoir_evenement`) : contrôles inchangés. Ensuite :
  - classe et empreinte calculées à la réception ;
  - **le retour et sa ligne de traitement dans la même transaction** ;
  - traitement **immédiat** des retours de priorité 1 et des messages entrants, **dans un sous-bloc** ; un échec laisse le retour `a_traiter` ;
  - les autres statuts attendent le travailleur.
- **Temps B** (`communication_traiter_evenement`) :
  - `FOR UPDATE SKIP LOCKED` sur sa ligne, état **relu** ;
  - ordre des verrous : N1 seulement pour une pause ou un report → N3 → l'envoi → **puis** les écritures ;
  - passage à `traite` dans le même bloc que les effets.
- **Reprise** (`communication_evenement_a_reprendre`) : nouvel essai après 1, 2, 5 puis 15 min ; au 5ᵉ échec, `echec`, avec une trace dans `communication_erreurs`.
- **Reprise manuelle** : `reprendre_evenement_communication` (administrateur, motif, journalisée).
- **Travailleur** : une nouvelle étape, priorité 1 d'abord, un retour par transaction.
- **Purge par date** : n'efface jamais un retour `a_traiter` ou en `echec`.
- **Purge d'une personne** : ses confirmations en attente sont closes ; un STOP en attente est **gardé**, parce qu'il protège le numéro.
- **Relance** : la campagne (N1) **avant** l'envoi.
- **Retraits idempotents** : un retrait n'est écrit que si le consentement est encore en attente ou confirmé.

### 5.5 P-09 — reconnaître le STOP (43)

- **Avant** : `communication_est_stop` = le message **entier** est l'un des 13 mots.
- **Après** : `communication_classer_entrant(texte, bouton)` répond `stop`, `confirmation`, `ambigu` ou `autre`, selon ces règles :
  - un bouton de désinscription ;
  - une liste fermée de mots et de phrases entiers (ajouts : STOP PLEASE, PLEASE STOP, ARRETEZ, QUIT, END, FIN, REVOKE, OPT OUT, CANCELAR, NO MAS…) ;
  - un **premier mot** d'arrêt sans ambiguïté, dans un message de 5 mots au plus ;
  - « ambigu » quand un mot d'arrêt apparaît ailleurs : rien n'est retiré, mais c'est compté pour une revue humaine.

  Des mots comme ARRET, END, FIN, CANCEL ou QUIT ne comptent que **seuls** : « Arrêt de bus » n'est pas un STOP. `communication_est_stop` appelle désormais cette fonction.

### 5.6 P-05, N-01, D2 — contact partagé (42, 43)

- **Aperçu** : `row_number()` par contact, et les doublons sont comptés `CONTACT_EN_DOUBLE`.
- **Volume** : `count(distinct communication_cible(...))`.
- **Coût WhatsApp** : calculé par contact distinct.
- **Préparation** : CTE `audience` dédoublonnée ; un seul retenu par contact, celui du plus petit identifiant de compte.
- **Base** : index unique `communication_destinataires_contact_idx`.
- **Envoi** : verrou N3b `contact:<canal>:<empreinte>` après N3 ; contrôle « déjà envoyé à ce contact dans cette campagne » qui donne `CONTACT_EN_DOUBLE` ; fréquence par compte **et** par contact.
- **D2** : si un compte actif partageant le contact n'a pas de consentement confirmé, la raison est `CONTACT_PARTAGE_NON_CONSENTI`. Ce contrôle est aussi fait à l'envoi, puisque `communication_raison_exclusion` y est rappelée **[V]**.

### 5.7 N-02 — code de confirmation (40, 41, 43)

- **Avant** : 4 chiffres (`gen_random_bytes(2) % 10000`), 168 h de validité, pas unique par numéro.
- **Après** :
  - 6 chiffres par tirage de 3 octets, rejeté au-delà de 16 000 000 pour éviter tout biais ;
  - insertion protégée par l'index unique `(canal, cible_empreinte, code)` des demandes ouvertes ; en cas de conflit, un autre tirage (20 au plus) ;
  - expiration en `confirmation_code_validite_min` (60 min) ;
  - côté retour : un code inconnu ajoute 1 aux `tentatives` des demandes ouvertes de ce numéro, et à 5 elles sont annulées ;
  - au plus 1 demande par minute et par compte ;
  - plafond par 24 h et par numéro.

### 5.8 Surveillance (43)

`sante_communications` gagne une section `evenements` : `a_traiter`, `en_retard` (plus de 10 min), `echec`, `echec_prioritaires`, `ambigus_7j`, `plus_ancien_en_attente`, `alerte`. La procédure de reprise est dans `COMMUNICATION_CENTER_SECURITY.md`, §10.3.

---

## 6. Contrôles faits (sans exécution)

| Contrôle | Résultat |
|---|---|
| Chaque fichier, lu en entier, n'est que la garde (`DoStmt` + `SelectStmt`) | **OK**, les 4 fichiers |
| Lignes de la garde (en-tête jusqu'à la couche 4) et fin de fichier | **Identiques** à avant D5, les 4 fichiers |
| Découpeur naïf (simulation du relecteur) | Inchangé : la fermeture de session est la 3ᵉ instruction exécutée |
| Instructions du contenu | 126 + 43 + 50 + 79, toutes lisibles par `pglast` |
| Corps PL/pgSQL relus avec leur vraie signature | **90 / 90** |
| Fonctions : `search_path` vide | **109 / 109** (la procédure vide le sien elle-même) |
| Fonctions : `REVOKE` présent | **108 / 109** ; l'exception est `permissions_du_role`, qui garde ses droits d'origine (voulu) |
| Tables : RLS activée et `revoke all` | **29 / 29** |
| Appels `net.http_*` contrôlés par la porte | 3 / 3 (inchangé) |
| Textes faux retirés | « Aucune autre table n'est verrouillée », « ordre unique » de 43, `lock_timeout '0'`, code `{4}`, `gen_random_bytes(2)` : **0** occurrence |

**Ce que ces contrôles ne prouvent pas [NE]** :
- que chaque colonne ou fonction citée existe avec le bon type (la base n'a pas été créée) ;
- l'absence d'interblocage ;
- le traitement une seule fois ;
- les délais ;
- le comportement de pg_net.

**Seuls les 78 essais et le spécialiste peuvent le prouver.**

---

## 7. Risques résiduels

| # | Gravité | Risque | Niveau |
|---|---|---|---|
| R-01 | MOYENNE | Un retour est perdu si la **transaction du temps A** elle-même échoue (coupure, délai, base indisponible) : il dépend alors du réessai du fournisseur | [EXT] ; essai F-W08 |
| R-02 | MOYENNE | Hypothèses de PostgreSQL : rattrapage de `query_canceled` et de 40P01 en sous-bloc ; `FOR KEY SHARE` des clés étrangères ; file d'attente des verrous consultatifs ; unicité sous concurrence (index partiel) | [D] ; spécialiste, essais F-K10, F-W01, F-W04, F-C11 |
| R-03 | MOYENNE | pg_net (H4, H4′) | [EXT] ; F-K05, F-K09 |
| R-04 | MOYENNE | **Erreurs que l'analyse statique ne voit pas** : nom de colonne, type, fonction mal référencée. Les brouillons n'ont jamais été créés dans une base. | [NE] ; F-M02 en premier |
| R-05 | MOYENNE | **Coût de la règle D2** : `communication_raison_exclusion` parcourt tous les comptes pour chaque client (et RF-04 n'est pas corrigé). Sans effet à 71 clients ; à mesurer avant 10 000. | [NE] ; mesure |
| R-06 | FAIBLE | Code à 6 chiffres : 5 essais sur 1 000 000, soit 1 chance sur 200 000 de deviner depuis le numéro lui-même, en 60 min. *(Remplace l'ancien R-06 à 4 chiffres : la contradiction C6 / R-06 est levée.)* | Conception |
| R-07 | FAIBLE | Retours de priorité 1 traités dans le temps A : la ligne d'éclat du débit est tenue jusqu'à 3 s. Un autre retour du même éclat peut dépasser ses 2 s et échouer, puis être renvoyé par le fournisseur. | [D] + [EXT] |
| R-08 | FAIBLE | Liste des mots d'arrêt : faux positifs ou faux négatifs possibles. Le bouton de Meta reste à confirmer sur des exemples réels. | Juriste ; [EXT] |
| R-09 | FAIBLE | D2 exclut **aussi** les comptes consentants d'un numéro partagé : moins de destinataires, voulu par prudence. En production, 2 numéros sont partagés. | Décision CEO |
| R-10 | FAIBLE | Déclencheur sans N3 quand il est occupé : l'invalidation s'écrit sans verrou. C'est sûr par la règle « contact actuel », mais l'ordre des lignes du registre peut s'inverser. | [D] |
| R-11 | FAIBLE | Placement des `REVOKE` en fin de fichier (RF-08, RF-16, P-12) : **non corrigé**, hors du périmètre D5 | Phase 2 |

**Non corrigés, hors du périmètre autorisé** :
- **P-10 / RF-04** : coût du HMAC par ligne ;
- **P-11 / RF-11** : motifs codés dans `journal_audit` ;
- **P-12** : `REVOKE` juste après chaque création ;
- **P-13 / RF-09** : `add column if not exists` pour toutes les colonnes, verrous de rejeu ;
- **RF-06** : refus de valeurs identiques entre clés commerciales et transactionnelles ;
- **RF-12 à RF-15, RF-18, RF-19.**

---

## 8. Ce qui demande encore une validation humaine

| Qui | Quoi |
|---|---|
| **Spécialiste PostgreSQL** (D4) | Q1 à Q7 ; en particulier : le rattrapage `query_canceled` / 40P01 dans `confirmer_arret_communications` et dans le temps A ; le traitement une seule fois (temps A et B) ; N3b ; l'index unique des codes sous concurrence ; le retrait de la clé étrangère |
| **Juriste** | Règle D2 (mesure conservatrice) ; liste des mots d'arrêt (US / Floride, DO, HT) ; conservation de la table de traitement ; STOP gardé après l'effacement d'une personne |
| **CEO** | Comportement de l'écran d'arrêt (deux appels, réessai automatique) ; seuil et destinataire des alertes ; décision S-1 (authentification de la fonction Edge) ; envoi des demandes de devis (D4) ; autorisation, distincte, d'exécuter les 78 essais |
| **Nouvelle revue indépendante** | Exigée après correction. À faire par le spécialiste humain ; une revue par une session Claude distincte peut la précéder, mais ne la remplace pas. |

> **Note du 23/11/2026 sur S-1.** Après ce rapport, une option S-1 a été construite **en candidate
> locale**, hors des brouillons 40–43 : `outils/migrations-candidates/009-communication-identite-edge.sql`
> et le client Edge. Elle crée des rôles `communication_webhook` et `communication_worker` sans
> connexion, membres d'`authenticator` ; leurs RPC passent par le schéma `communication_edge` et
> vérifient l'émetteur, l'audience et la durée d'un JWT ES256 signé par l'Edge. Cette option diffère
> de la recommandation de `PHASE_1_3_FINAL_REPORT.md` §10, qui prévoyait un rôle de connexion dédié
> avec mot de passe. Elle a passé les essais locaux (`COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md`).
> **La décision S-1 de la CEO reste ouverte** : une implémentation testée localement n'est pas une
> décision.

---

## 9. Contrôle des interdictions

| Interdiction | Respectée |
|---|---|
| Aucune exécution SQL (sauf la lecture D3) | **Oui** : une seule requête `SELECT` sur `pg_roles`, rien d'autre |
| Aucune migration, aucun essai, même sur une base jetable | **Oui** |
| Aucune modification de la production | **Oui** |
| Aucun appel à un fournisseur | **Oui** |
| Aucun secret, aucune configuration | **Oui** |
| Aucune fusion, aucun déploiement, aucun canal activé | **Oui** (commit sur la branche de la PR #65 seulement) |
| Aucun contrat transactionnel touché | **Oui** : aucun fichier hors de `docs/communication-center/` |
| Recherche D4 | Pages publiques seulement ; **personne n'a été contacté** ; aucune donnée de GoShip transmise |

**CORRECTIONS D5 PRÉPARÉES — EN ATTENTE D'UNE NOUVELLE REVUE INDÉPENDANTE ET DE LA DÉCISION ÉCRITE DE LA CEO. PHASE 2 NON AUTORISÉE.**
