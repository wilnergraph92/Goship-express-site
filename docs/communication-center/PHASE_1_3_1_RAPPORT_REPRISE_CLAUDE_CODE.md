# Centre de communication — rapport de reprise Claude Code (23/11/2026)

**Objet.** Ce rapport rend compte de la reprise du Communication Center par Claude Code, après la
session Codex qui s'est terminée par l'incrément C7.3. Il couvre l'état initial, les actions
autorisées et réalisées, les constats, les vérifications réellement exécutées, les décisions encore
attendues et l'état laissé pour un prochain relais.

**Statut de gouvernance, inchangé.** Phase 1.3.1 : **NON VALIDÉE**. Phase 2 : **NON AUTORISÉE**.
Brouillons SQL 40–43 : **NON EXÉCUTABLES**, sur toute base. Aucun des 78 essais n'est exécuté. Ce
rapport ne vaut ni revue indépendante, ni validation, ni autorisation.

---

## 1. Résumé

- **Reprise** sans perte : branche, commit et branche distante confirmés ; les 36 changements locaux
  laissés par Codex sont intacts.
- **Risque local fermé** : PostgreSQL et Kong étaient joignables sur toutes les interfaces, alors que
  le pare-feu macOS était désactivé. La stack est arrêtée proprement, sans perte de données, et le
  pare-feu a été activé par la personne responsable du poste.
- **Documents mis en cohérence** :
  - le décompte des essais (65 → 78) est expliqué ;
  - S-1 est décrite comme implémentée en candidate, mais non décidée ;
  - le rapport C7.3 est consigné ;
  - les README des candidates (008, 009) et de l'Edge sont à jour.
- **Clôture 1.3.1 préparée** : un dossier pour la revue indépendante (Q1–Q7, version figée des
  brouillons), une fiche des décisions CEO (A à I), et une table de correspondance entre brouillons et
  candidates.
- **Constat majeur** : les brouillons 40–43 et les candidates 001–009 ne sont **pas
  interchangeables** (10 objets communs seulement). La prochaine décision utile revient à la CEO :
  fixer le **périmètre de la Phase 2**, puis l'objet de la revue.
- **Rien n'est commité ni poussé.** Je n'ai exécuté ni SQL ni essai, et je n'ai contacté aucun
  fournisseur.

## 2. Autorisations reçues et périmètre

| Ordre | Décision écrite de la responsable | Périmètre réalisé |
|---|---|---|
| 1 | Reprise : « Ne modifie rien avant d'avoir établi cet état initial » | Lecture seule ; état initial remis |
| 2 | « Arrêter la stack locale » | `docker stop` des 4 conteneurs, sans suppression ; aucun redémarrage |
| 3 | « Oui, corriger la doc » | Harmonisation des documents dans `docs/communication-center/` et dans deux README de `outils/` |
| 4 | « Oui, action 3 » | Dossier de revue indépendante et fiche des décisions CEO |
| 5 | « Table brouillons↔candidates » | Comparaison en lecture seule, rédigée dans un document |
| 6 | « Oui, ignorer .temp » | Règle ajoutée au `.gitignore` racine et documents mis à jour |
| 7 | « le pare-feu macOS est activé » (fait par la responsable) | État vérifié en lecture et documents mis à jour |

**Hors périmètre, non fait** : SQL, migrations, essais, accès à Supabase en production, appels
fournisseurs, envois, commit, push, merge, fetch, déploiement, suppression de données ou de volumes,
levée d'une immutabilité, redémarrage de la stack.

## 3. Environnement

| Élément | Valeur constatée |
|---|---|
| Checkout | `/Users/wilnergraph/Projects/GoShip/Goship-express-site` |
| Branche | `ccr-056ddc8c-m7u4p1` |
| Commit | `77cf8e6c626a3bc2271740844e17774fcbb0eeb0` (inchangé de bout en bout) |
| Branche distante de suivi | `origin/ccr-056ddc8c-m7u4p1` |
| Écart avec la branche distante | 0 en avance, 0 en retard, selon la référence locale (aucun `fetch` lancé) |
| Stash | Aucun |

## 4. Plan officiel (inchangé)

C1 à C7.3 sont des incréments techniques, pas des phases. Je n'ai changé aucun statut, faute de
preuve nouvelle.

| Phase | Objectif | État |
|---|---|---|
| 0 | Technical audit | Audit terminé (approuvé le 18/11/2026) |
| 1 | Architecture & security | Phase 1.3.1 **NON VALIDÉE** |
| 2 | Database & backend | Candidates 001–009 éprouvées localement ; **NON AUTORISÉE** |
| 3 | Email + WhatsApp | Adaptateurs et parcours locaux ; fournisseurs réels non validés |
| 4 | Dashboard UI | Interface construite ; backend réel non validé |
| 5 | Automation | Logique construite ; envois réels non autorisés |
| 6 | QA & deployment | QA locale ; aucun staging, aucun déploiement |

## 5. Sources et Skills consultés

- **Règles** : `CLAUDE.md`, `AGENTS.md`.
- **Communication Center** :
  - le README ;
  - D5 (§6 à §10) ;
  - l'audit indépendant final (§10 et §11) ;
  - le plan d'essais final (§4 bis et §5) ;
  - la preuve des verrous de l'arrêt (hypothèses H1–H6 et H4′) ;
  - les sections de `COMMUNICATION_CENTER_DATABASE.md`.
- **Code** : les brouillons 40–43 (lectures ciblées) ; les candidates 001–009 (inventaire et lectures
  ciblées) ; `outils/supabase.sql` et ses deux copies (diff) ; les README des candidates et de l'Edge ;
  le banc `essai-communication-center.py` (structure) ; `.github/workflows/deploy.yml` (exclusions).
- **Skills** : `goship-team-orchestrator`, `goship-database-supabase`, `goship-qa-testing`,
  `goship-security-privacy`, `goship-communication-notifications`. Claude Code les découvre grâce à
  des liens symboliques `.claude/skills/*` vers `.agents/skills/*`, déjà en place. Je n'ai modifié ni
  déplacé aucune Skill.

## 6. Travail Codex retrouvé

- Candidates `outils/migrations-candidates/001` à `009`, hors de `outils/migrations.txt`.
- Edge Functions locales `outils/communication-center-edge/` : webhooks, worker, reçus Expo, JWT
  ES256.
- Bancs `outils/essais-services/essai-communication-{center.py,edge.mjs,interface.mjs,campagnes.mjs}`.
- Interface du tableau de bord : `admin.html`, `api.js`, `communications*.js`, traductions.
- Brouillons 40, 41 et 43 modifiés **après** `77cf8e6`, sans commit (blocs du 22/11 : N3c, temps A
  et B, STOP exact, garde `READ COMMITTED`, reprise des erreurs transitoires).
- Ajout non commité de `communications.view` (admin, gérant) dans la chaîne officielle.
- `CLAUDE.md` réduit, et son contenu historique déplacé vers
  `docs/architecture/reference-technique-historique.md`.
- **Le rapport C7.3 (438/438) n'existait pas dans le dépôt** ; je l'ai consigné (§7.2).

## 7. Actions réalisées

### 7.1 Arrêt de la stack locale

- **Constat initial** : 4 conteneurs `goship-communication-center-local` actifs (PostgreSQL 17.12,
  PostgREST 16.5, Kong 2.8.1, GoTrue 2.198.0) ; ports 54321 et 54322 publiés sur `0.0.0.0` et `::` ;
  pare-feu macOS désactivé.
- **Action** : arrêt de `rest`, `auth` et `kong`, puis de `db` en dernier (délai de 60 s). PostgreSQL
  s'est arrêté proprement (point de contrôle d'arrêt, « database system is shut down ») ; les 4
  conteneurs sont sortis avec le code 0.
- **Vérification** : plus aucune écoute sur 54321 ou 54322. Les volumes `supabase_db_…` et
  `supabase_edge_runtime_…` sont conservés, avec les fixtures et les secrets Vault de test.
- **À savoir** : la politique de redémarrage est `unless-stopped`. Un nouveau `supabase start`
  republierait les ports sur toutes les interfaces ; il faut d'abord les limiter à `127.0.0.1`, ce qui
  demande une autorisation distincte.

### 7.2 Harmonisation documentaire

- `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` : note datée. 65 essais (40 + 25) avant D5 ; D5 en ajoute
  13, d'où 78 (40 + 38). Le texte d'origine est conservé.
- `PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md` : note datée sur S-1. Une option est construite en
  candidate 009 ; elle diffère de la recommandation de la Phase 1.3 ; la décision reste ouverte.
- `README.md` (Communication Center) :
  - le décompte des essais ;
  - l'absence du document Q1–Q7 ;
  - l'objet de la revue, encore à décider ;
  - l'état de S-1 ;
  - `communications.view` ;
  - les nouvelles lignes de l'index.
- `COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md` (nouveau) : le compte rendu C7.3, déclaré par Codex et
  non réexécuté ; ce qu'il ne couvre pas ; l'absence de procédure versionnée pour les vérifications
  sur la stack ; les limites locales à jour.
- `outils/migrations-candidates/README.md` : ajout des candidates 008 et 009 ; S-1 mise à jour ;
  retrait d'une affirmation devenue fausse (« l'Edge ne signe aucun jeton ») ; dépendance à
  `communications.view`.
- `outils/communication-center-edge/README.md` : le constat périmé « CLI Supabase et Deno
  indisponibles » est remplacé par l'état observé ; avertissement sur `.temp/`.

### 7.3 Dossier de revue indépendante et fiche des décisions

- `PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md` :
  - version figée des brouillons, par empreinte SHA-256 ;
  - changements postérieurs à `77cf8e6` ;
  - pièces à transmettre et à exclure ;
  - hiérarchie des verrous ;
  - **Q1–Q7 proposées**, puisque le document source est introuvable, chacune avec code et lignes,
    hypothèses et essais ;
  - points D5 à vérifier ;
  - livrable attendu du relecteur.
- `PHASE_1_3_1_DECISIONS_CEO_EN_ATTENTE.md` : décisions A à I avec leurs options et un avis
  technique présenté comme un avis ; validations juridiques à demander.

### 7.4 Table de correspondance

- `PHASE_1_3_1_CORRESPONDANCE_BROUILLONS_CANDIDATES.md` : périmètres comparés, 10 objets communs,
  correspondance correction par correction, divergences, applicabilité des 78 essais par famille,
  conséquences pour la décision A.

### 7.5 `.gitignore`

- Règle `**/supabase/.temp/` ajoutée au `.gitignore` racine, avec un commentaire. `git check-ignore`
  confirme que le fichier de secrets de démarrage local est ignoré, sans que je l'aie lu, et que les
  sources Edge ne le sont pas.

### 7.6 Pare-feu macOS

- Activé par la responsable du poste. J'ai vérifié en lecture (`socketfilterfw` : état 1 ; mode
  furtif désactivé, réglage facultatif) et mis à jour les documents.

## 8. Constats principaux

| # | Constat | Conséquence |
|---|---|---|
| C-1 | 65 et 78 essais : deux états successifs, pas une contradiction | Documenté ; 0 essai sur 78 exécuté |
| C-2 | `PHASE_1_3_1_CLARIFICATIONS_ET_RISQUES_RESIDUELS.md` (Q1–Q7) est introuvable | Q1–Q7 reformulées comme propositions, sans valeur de décision |
| C-3 | Le rapport C7.3 n'était pas dans le dépôt ; les vérifications sur la stack Supabase (JWT via PostgREST, 403, Edge 401/503) n'ont **aucune procédure versionnée** | Résultats déclarés, non reproductibles en l'état |
| C-4 | Brouillons 40, 41 et 43 modifiés après `77cf8e6` | La revue doit porter sur une version figée par empreinte |
| C-5 | `communications.view` ajoutée sans commit à la chaîne officielle (trois fichiers) ; `permissions_du_role` redéfinie aussi par les candidates 007 et 008 | Décision G |
| C-6 | **Brouillons et candidates : deux lignées distinctes** (10 objets communs ; brouillons = envoi marketing ; candidates = transactionnel, consentement, Edge, campagnes sans envoi) | Il faut fixer le périmètre de la Phase 2 avant la décision A |
| C-7 | Les candidates **modifient le moteur transactionnel** (`expedier_envoi`, `lire_reponse_envoi`, `texte_notification`, `traiter_notifications` ; colonnes de `notification_envois`) | Contraire à « aucun changement implicite des contrats transactionnels » ; décision requise ; F-T01, F-T02 et F-S03 sont inversés |
| C-8 | La candidate 006 traite un **bouton** « STOP » comme un retrait ; le brouillon le classe ambigu | Divergence à trancher, avec l'avis du juriste |
| C-9 | Les candidates n'ont **pas de fonction de levée** de l'arrêt d'urgence | Lacune à combler si les candidates sont retenues |
| C-10 | Les candidates utilisent d'autres clés de verrou, **sans hiérarchie globale documentée** | Q1–Q7 ne s'appliquent pas telles quelles aux candidates |
| C-11 | S-1 est implémentée en candidate (JWT ES256, rôles membres d'`authenticator`) ; elle diffère de la recommandation 1.3 | Décision B ; compatibilité Supabase à vérifier |
| C-12 | Exposition réseau locale et secrets `.temp/` non ignorés | **Corrigés** (§7.1, §7.5, §7.6) |

## 9. Vérifications réellement exécutées

| Type | Commandes ou contrôles | Effet |
|---|---|---|
| Git, lecture | `git status`, `rev-parse`, `rev-list`, `diff`, `show 77cf8e6:…`, `check-ignore` | Aucun |
| Fichiers, lecture | Lectures, `grep`, `shasum -a 256` des brouillons, inventaire des `create` | Aucun ; fichiers de travail dans le répertoire temporaire de session uniquement |
| Docker, lecture | `docker ps`, `inspect`, `volume ls`, `logs --tail 3` (lignes d'arrêt) | Aucun |
| Docker, écriture autorisée | `docker stop` des 4 conteneurs | Arrêt ; aucune suppression |
| Système, lecture | `socketfilterfw --getglobalstate/--getstealthmode/--getblockall`, `lsof` sur 54321 et 54322 | Aucun |

**Non exécuté** : aucun SQL, aucun essai (ni les 78, ni le banc C7.3, ni les essais Node), aucun
build, aucune connexion à Supabase, aucun appel réseau sortant. Je n'ai pas réexécuté les résultats
C7.3 : ils restent déclarés par Codex.

## 10. Blocages de la Phase 1.3.1

1. **Périmètre de la Phase 2, puis objet de la revue** (décision A), à fixer par la CEO.
2. **Revue indépendante humaine PostgreSQL** (Q1–Q7), non réalisée ; devis non demandé (décision F).
3. **Les 78 essais** : non exécutés ; autorisation distincte requise (décision E), après A.
4. **Décisions CEO** : B (S-1), C (écran d'arrêt), D (alertes), G (`communications.view`), H (N-01
   et N-02).
5. **Validations juridiques** : D2, mots d'arrêt et bouton Meta, conservation, STOP conservé après
   effacement.

## 11. Risques locaux résiduels

| Risque | État |
|---|---|
| Ports de la stack sur toutes les interfaces | Stack arrêtée ; limiter à `127.0.0.1` avant tout redémarrage |
| Pare-feu macOS | Activé |
| Secrets `.temp/` | Ignorés par Git ; à ne jamais ajouter avec `git add -f` ; exclus du déploiement |
| Fixtures synthétiques et secrets Vault de test | Conservés dans le volume ; nettoyage seulement sur décision |
| Immutabilité empêchant la suppression forcée d'une tentative | Inchangée |
| Parcours de succès de l'Edge servie | Non validé |

## 12. Prochaines étapes proposées

1. **CEO** : fixer le périmètre de la Phase 2, en s'appuyant sur la table de correspondance, puis
   trancher la décision A.
2. Selon A : figer la version à examiner (empreintes). Si les candidates sont retenues, documenter
   leur hiérarchie de verrous et réécrire Q1–Q7 et les essais pour elles.
3. **CEO** : décider de l'envoi des demandes de devis (F) et des pièces à partager, sous accord de
   confidentialité.
4. Sur autorisation distincte seulement : versionner une procédure reproductible pour les
   vérifications sur la stack Supabase locale, puis redémarrer la stack limitée à `127.0.0.1`.
5. Sur autorisation distincte : commit des changements sur la branche de travail. Rien n'a été
   commité à ce jour.

## 13. Fichiers créés ou modifiés par Claude Code

| Fichier | Nature |
|---|---|
| `docs/communication-center/PHASE_1_3_1_RAPPORT_REPRISE_CLAUDE_CODE.md` | Nouveau (ce rapport) |
| `docs/communication-center/COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md` | Nouveau |
| `docs/communication-center/PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md` | Nouveau |
| `docs/communication-center/PHASE_1_3_1_DECISIONS_CEO_EN_ATTENTE.md` | Nouveau |
| `docs/communication-center/PHASE_1_3_1_CORRESPONDANCE_BROUILLONS_CANDIDATES.md` | Nouveau |
| `docs/communication-center/PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` | Note datée ajoutée |
| `docs/communication-center/PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md` | Note datée ajoutée |
| `docs/communication-center/README.md` | Statut et index complétés (le fichier portait déjà des changements de Codex, conservés) |
| `outils/migrations-candidates/README.md` | Complété (dossier non suivi de Codex, conservé) |
| `outils/communication-center-edge/README.md` | Mis à jour (dossier non suivi de Codex, conservé) |
| `.gitignore` | Règle `**/supabase/.temp/` ajoutée |

Je n'ai modifié **aucun** SQL (brouillons, candidates ou chaîne officielle), aucun code applicatif,
aucun essai et aucune Skill. Les empreintes des brouillons sont inchangées depuis leur relevé.

## 14. État laissé pour un prochain relais

- Commit `77cf8e6`, branche `ccr-056ddc8c-m7u4p1` ; aucun commit local non poussé ; aucun stash.
- **44 entrées locales non commitées** :
  - les 36 laissées par Codex, intactes ;
  - les 5 nouveaux documents de Claude Code ;
  - 3 fichiers jusque-là intacts, modifiés par Claude Code : `.gitignore`, l'audit final et D5.

  Le README du Communication Center et les deux README de `outils/` portent à la fois des changements
  de Codex et des miens.
- Stack Docker locale arrêtée, volumes conservés ; pare-feu actif.
- Aucune action en cours. Toutes les étapes suivantes attendent une décision ou une autorisation
  écrite (§10 et §12).
