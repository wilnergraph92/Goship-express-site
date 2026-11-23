# Communication Center — référence de gouvernance et dossier de conception

Ce dossier n'est pas publié (`deploy.yml` exclut `docs/`). Il réunit les livrables du projet
« Centre de communication » (WhatsApp, e-mail, campagnes), phase par phase, chacune approuvée par écrit
par le CEO avant la suivante.

## Référence permanente — vision et gouvernance

Cette section conserve le cadrage du Master Prompt GoShip remis à Codex le 21 novembre 2026. Elle
résume la vision et l'état d'autorisation pour les agents techniques ; elle ne remplace ni les règles
communes de [`AGENTS.md`](../../AGENTS.md), ni les décisions écrites de la CEO, ni les documents
spécialisés ci-dessous. Un objectif futur n'est pas une autorisation d'implémentation. En cas d'écart,
signaler le conflit et ne pas choisir une règle métier à la place de la CEO.

### Vision et objectifs

Le Communication Center est destiné à centraliser les communications GoShip à partir des vraies
données et événements de la plateforme. Il ne crée pas une base métier parallèle pour les clients,
colis ou historiques. L'invariant reste : **UNE PLATEFORME — UNE SOURCE DE VÉRITÉ — UNE LOGIQUE MÉTIER
PARTAGÉE — DES MODULES INTERCONNECTÉS.**

Les objectifs couvrent les communications opérationnelles liées à des événements officiellement
autorisés et les campagnes marketing préparées, approuvées, planifiées et suivies par les rôles permis.
Un événement logistique ne déclenche pas à lui seul une campagne marketing. Les messages marketing et
transactionnels conservent des règles, identités, données, permissions et chemins distincts. Les
contrats transactionnels existants ne changent pas implicitement.

Le périmètre fonctionnel visé comprend WhatsApp et e-mail, ainsi que l'intégration cohérente avec les
notifications transactionnelles existantes, dont celles des plateformes GoShip. Les contrats et
l'accès au dépôt mobile restent soumis à leur autorisation et gouvernance propres. Un canal, modèle,
fournisseur ou envoi n'est jamais réputé autorisé par défaut. Chaque canal conserve ses propres règles,
consentements, quotas et suivi.

Les communications opérationnelles ne pourront partir qu'à partir d'événements réels et autorisés
(par exemple création/confirmation, expédition, disponibilité, livraison ou action requise), en
respectant les règles du module source. Elles ne modifient pas les contrats transactionnels existants
sans autorisation. Les fonctions marketing visées comprennent la création et modification des
campagnes et modèles, la planification, la segmentation, l'aperçu, les quotas et budgets, l'approbation
administrative, l'envoi autorisé, l'historique et le suivi des résultats.

Les rôles et permissions sont contrôlés côté serveur. L'interface peut guider l'utilisateur, mais
masquer un bouton n'est pas une autorisation. Les campagnes marketing exigent l'approbation
administrative prévue par les permissions ; les droits d'un employé ne sont pas élargis par cette
vision. Le modèle attendu est : l'ADMIN gère et approuve ; le GÉRANT prépare, modifie et planifie dans
ses permissions, sans approbation finale d'envoi ; l'EMPLOYÉ n'accède pas à la gestion des campagnes
sans décision CEO ultérieure.

Le consentement doit être explicite, vérifiable, traçable et propre à chaque canal, avec son historique,
sa date et son origine. Un compte GoShip ou une notification transactionnelle ne vaut pas consentement
marketing ; un consentement ne se transfère pas d'un compte à un autre. Les retraits et STOP doivent
être respectés et tracés. Les données, coûts, quotas, états de livraison et statistiques ne peuvent
être annoncés que s'ils sont réellement disponibles et mesurés ; aucune métrique ne doit être inventée.
La supervision visée couvre les messages préparés, envoyés, délivrés lorsque la source le permet,
échoués et en attente, les réponses et désinscriptions, les campagnes, coûts, quotas, alertes et
reprises. L'interface doit rendre visibles l'état, les approbations attendues, erreurs, alertes, coûts
et résultats ; les actions sensibles demandent confirmation et laissent une trace.

Le flux conceptuel est : événement GoShip → validation → règles de communication → consentement →
quotas et limites → autorisation → transmission → résultat, historique et supervision. Il ne crée pas
de dépendance circulaire entre modules.

La fiabilité attendue couvre notamment Kill Switch, idempotence, callbacks répétés, concurrence,
deadlocks, attentes bornées, reprise après interruption, limites de fréquence et de budget, audit,
permissions SQL/RLS/`SECURITY DEFINER`, et protection des secrets et données personnelles. Ces objectifs
restent des exigences de conception, pas des propriétés opérationnelles validées.

### Décisions D1–D5 et écart à résoudre

| Sujet | État de référence |
|---|---|
| D1 — N-01, plafond de fréquence | **Décision CEO confirmée :** plafond par empreinte du numéro, et non sur le seul identifiant de compte. Le draft 43 ajoute un plafond par compte, agrégé entre canaux ; l’approbation de ce plafond supplémentaire n’est pas établie. Préserver ce comportement jusqu’à décision distincte, sans redemander la règle par numéro. |
| D1 — N-02, confirmation WhatsApp | **Exigences confirmées :** six chiffres, lien au numéro et à la demande, expiration, limite d’essais, protection contre les demandes répétées, consentement non transférable. **Choix D5 préparés, approbation numérique/modèle non retrouvée :** 60 min par défaut, cinq erreurs annulant toutes les demandes ouvertes de l’empreinte, limites répétées par compte et par empreinte. Plusieurs demandes de comptes partageant un numéro coexistent dans le draft ; ne pas décider qu’il doit y en avoir une seule sans décision écrite. |
| D2 — numéros partagés | Règle provisoire conservatrice : exclure le numéro si un compte actif qui le partage ne dispose pas du consentement confirmé requis. Validation juridique encore attendue. |
| D3 — production | La lecture `SELECT` limitée autorisée des paramètres de délai des rôles est documentée comme déjà réalisée. Ne pas refaire de consultation de production. |
| D4 — spécialiste PostgreSQL | La préparation d'une liste et d'une méthode est documentée ; aucun contact, engagement ou dépense n'est autorisé sans décision distincte de la CEO. |
| D5 — corrections | P-07, P-08, P-09, P-05, N-01, N-02, D2, P-03 et la supervision ont été préparés dans le périmètre D5. Les blocs du 22/11/2026 séparent l'accusé de réception des webhooks de leur traitement différé, limitent le STOP automatique à `STOP` seul normalisé et séparent une plainte d'un retrait de consentement. La supervision agrège les états disponibles ; l'état d'un événement en cours n'est pas mesuré par le modèle actuel. Les variantes STOP restent à valider. Ces éléments restent des brouillons locaux : aucune exécution, validation indépendante ni mise en service n'en découle. |

### Statut et décisions restantes

- Phase 1.3.1 : **NON VALIDÉE** jusqu'à validation formelle.
- Phase 2 : **construction locale autorisée** par la délégation écrite de la CEO du 23/11/2026 (`COMMUNICATION_CENTER_DECISIONS_DELEGUEES.md`) : code, documentation et essais sur bases locales jetables seulement. **Aucune action distante** (production, fournisseur, envoi réel, déploiement, commit ou push) sans autorisation qui la nomme. `CLAUDE.md` et `AGENTS.md` indiquent encore « Phase 2 non autorisée » ; leur mise à jour attend l'accord de la CEO.
- SQL drafts 40–43 : **NON EXÉCUTABLES**, sur toute base. Depuis la décision A, ce sont des références de conception.
- **Décision A (23/11/2026)** : les candidates `outils/migrations-candidates/` sont la base de la Phase 2. La revue indépendante et le plan d'essais portent sur elles ; leur hiérarchie de verrous est documentée dans `COMMUNICATION_CENTER_VERROUS_CANDIDATES.md`. Les 78 essais (78 = 40 + 38 ; le chiffre de 65 dans l'audit final correspond à l'état antérieur à D5) visaient les brouillons : ils seront remplacés par un plan adapté aux candidates.
- La validation indépendante par un spécialiste humain PostgreSQL reste **requise avant la production**. Le document Q1–Q7 de D5 (`PHASE_1_3_1_CLARIFICATIONS_ET_RISQUES_RESIDUELS.md`) reste introuvable ; des questions proposées figurent dans `PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md` et doivent être adaptées aux candidates.
- **S-1 (décision B, 23/11/2026)** : option JWT ES256 de la candidate 009. Repli prévu : un rôle de connexion dédié, si l'offre Supabase n'accepte pas de clé de signature supplémentaire.
- **Permissions (décision G)** : l'ensemble `communications.*`, dont `communications.emergency_stop` réservée à l'Admin, figure dans la chaîne officielle et dans le miroir `api.js` (`essai-permissions.py` : 114/114). Ce changement n'est pas commité et n'est appliqué à aucune base distante par ce dépôt.
- Décisions C (écran d'arrêt), D (alertes), H (N-01, N-02, D2) et STOP : prises le 23/11/2026, voir le document des décisions déléguées. La validation juridique de D2, des conditions STOP et de la conservation reste nécessaire **avant le premier envoi marketing réel**. La demande de devis au spécialiste reste une action de la CEO.
- Le banc local C7.3 (candidates 001–009, 438/438 déclarées par Codex le 23/11/2026) est consigné dans `COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md`, avec ses limites. Il ne valide ni la Phase 1.3.1 ni les brouillons 40–43.

### Fiabilité, architecture et méthode

Les objectifs de conception incluent le Kill Switch, l'idempotence, la réception durable et la reprise des
webhooks, la prévention des doubles envois et deadlocks, les délais bornés, quotas et budgets, les
permissions serveur, RLS, `SECURITY DEFINER`, la protection des secrets et des données personnelles, la
traçabilité et la supervision. Une promesse de fiabilité reste non validée tant que les preuves et
vérifications autorisées ne sont pas obtenues.

Les indicateurs doivent provenir des opérations réelles ; une donnée non disponible ne doit pas être
simulée. Toute modification ultérieure doit cartographier les modules, sources de vérité, permissions,
contrats, événements et plateformes affectés, puis faire l'objet d'une analyse d'impact intermodules.

Les rapports existants et les décisions datées sont à consulter avant d'agir. Distinguer objectif,
proposition, correction préparée, validation et opération exécutée. Chaque étape exige une autorisation
écrite propre à son action, périmètre et environnement : modifier un document n'autorise pas les tests ;
tester sur une base jetable n'autorise pas la production. Aucun SQL, test, accès production, appel
fournisseur, envoi réel, commit, push, merge ou déploiement n'est implicite.

Le Communication Center reste la priorité A du plan directeur. Growth & App Analytics ne commence
qu'après l'achèvement opérationnel formel du Communication Center et une autorisation distincte.
Ce chantier futur pourra mesurer téléchargements, utilisateurs actifs/inactifs, inscriptions,
commandes, pré-alertes, recherches sur les stores, clics et désinstallations uniquement lorsque les
plateformes fournissent réellement ces données ; il reste hors du périmètre actuel.

Le terme « opérationnel » ne peut être employé qu'après cohérence de l'architecture, validation des
permissions et consentements, vérification du Kill Switch et des traitements concurrents, récupération
des événements, données de supervision fiables, revues indépendantes requises et autorisations
spécifiques de chaque étape de mise en service.

| Fichier | Phase | État |
|---|---|---|
| `COMMUNICATION_CENTER_PHASE_0_AUDIT.md` | 0 — audit en lecture seule | approuvé le 18/11/2026 |
| `COMMUNICATION_CENTER_PHASE_1_RAPPORT.md` | 1 — rapport de la phase (corrigé en 1.2 : mentions « [Corrigé 1.2] ») | remplacé par la conception 1.2 |
| `COMMUNICATION_CENTER_PHASE_1_1_RAPPORT.md` | 1.1 — revue indépendante, verdict ÉCHEC | référence des constats C, H, M, L |
| `COMMUNICATION_CENTER_PHASE_1_2_RAPPORT.md` | 1.2 — corrections, traçabilité, verdict (errata 1.3 en tête) | remplacé par la Phase 1.3 |
| `PHASE_1_3_FINAL_REPORT.md` | 1.3 — corrections techniques, verdict VALIDÉ SOUS CONDITIONS | remplacé par la Phase 1.3.1 |
| `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` | Clôture 1.3.1 — vérification finale, revue indépendante comparée, risques, chiffres clients (71, Phase 0 : 69) ; **verdict NON VALIDÉ** | **en attente de la décision du CEO** |
| `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` | Clôture 1.3.1 — verrous de l'arrêt fonction par fonction, preuve, hypothèses H1 à H6 et H4′ | en attente |
| `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md` | Clôture 1.3.1 — revue des migrations 40 à 43, séparation, constats S-01 à S-07 | en attente |
| `PHASE_1_3_1_FINAL_TEST_PLAN.md` | Clôture 1.3.1 — 78 essais au total : 40 du plan précédent + 38 dans ce plan ; aucun exécuté | en attente |
| `COMMUNICATION_CENTER_DECISIONS_DELEGUEES.md` | Décisions A à J prises le 23/11/2026 sur délégation écrite de la CEO, portée retenue (local et bases jetables seulement), suivi de mise en œuvre | **en vigueur** ; production, fournisseurs, envois réels et déploiement toujours soumis à une autorisation nommée |
| `COMMUNICATION_CENTER_VERROUS_CANDIDATES.md` | Hiérarchie unique des verrous des candidates 001–010 (V0 à V4), règles anti-cycle, points L-1 à L-5 pour la revue, correction du contournement de l'arrêt par l'Edge | relevé statique ; à examiner par la revue humaine |
| `PHASE_1_3_1_RAPPORT_REPRISE_CLAUDE_CODE.md` | Relais Codex → Claude Code du 23/11/2026 — rapport complet : état initial, actions autorisées (arrêt de la stack locale, harmonisation documentaire, dossier de revue, fiche CEO, correspondance, `.gitignore`), constats, vérifications exécutées, blocages et état Git | référence du relais ; aucune validation |
| `PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md` | Clôture 1.3.1 — dossier préparatoire pour le spécialiste PostgreSQL : version figée des brouillons (SHA-256), hiérarchie des verrous, Q1–Q7 proposées avec code, hypothèses et essais, points D5 à vérifier ; **pas une revue** | préparé le 23/11/2026 ; attend la décision A et l'envoi par la CEO |
| `PHASE_1_3_1_CORRESPONDANCE_BROUILLONS_CANDIDATES.md` | Clôture 1.3.1 — comparaison en lecture seule entre brouillons 40–43 et candidates 001–009 : périmètres, 10 objets communs, corrections, divergences (moteur transactionnel modifié, bouton STOP, levée absente, verrous), applicabilité des 78 essais | préparée le 23/11/2026 ; sert à la décision A |
| `PHASE_1_3_1_DECISIONS_CEO_EN_ATTENTE.md` | Clôture 1.3.1 — décisions CEO ouvertes (A à I) avec options et avis technique, validations juridiques à demander | **en attente de la décision du CEO** |
| `COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md` | Incrément C7.3 — banc local des candidates 001–009 (438/438 déclarées par Codex), stack Supabase locale, limites ouvertes ; aucun essai des 78 | consigné le 23/11/2026, non réexécuté par Claude Code |
| `PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md` | Corrections D5 des brouillons 40 à 43 (P-07, P-08, P-09, P-05, N-01, N-02, D2, P-03, surveillance), délais mesurés (D3), spécialiste (D4) ; **non exécutées** | **en attente d'une nouvelle revue indépendante et de la décision du CEO** |
| `PHASE_1_3_1_ANALYSE_POST_AUDIT_P07_P08.md` | Analyse historique en lecture seule, antérieure aux blocs correctifs P-07/P-08 ; ses constats décrivent l'état alors examiné, pas le draft courant | complétée par les addenda de construction préparatoire et `COMMUNICATION_CENTER_DATABASE.md` §9 ; aucune validation d'exécution |
| `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md` | Clôture 1.3.1 — rapport du relecteur indépendant (RF-01 à RF-19), tel quel | référence |
| `PHASE_1_3_1_FINAL_REPORT.md` | 1.3.1 — audit indépendant, arrêt d'urgence ; verdict CONDITIONAL — INDEPENDENT REVIEW PENDING (complété par la clôture) | remplacé par la clôture |
| `PHASE_1_3_1_INDEPENDENT_SECURITY_AUDIT.md` | 1.3.1 — trois revues indépendantes, constats, risques ouverts | en attente |
| `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` | 1.3.1 — arrêt d'urgence prouvé : verrous, scénarios, démonstration | en attente |
| `PHASE_1_3_1_SQL_DRAFT_CORRECTIONS.md` | 1.3.1 — corrections des brouillons, constat par constat | en attente |
| `PHASE_1_3_1_TEST_PLAN.md` | 1.3.1 — 40 essais (aucun exécuté) | en attente |
| `PHASE_1_3_TECHNICAL_CORRECTIONS.md` | 1.3 — diagnostic des huit problèmes, corrections, avant / après | en attente |
| `PHASE_1_3_SECURITY_REVIEW.md` | 1.3 — contre-revue, PostgreSQL, dépendances, PR #46 et #48 | en attente |
| `PHASE_1_3_TEST_PLAN.md` | 1.3 — essais T-01 à T-20 (aucun exécuté) | en attente |
| `COMMUNICATION_CENTER_ARCHITECTURE.md` | conception en vigueur (1.2, annotée « [Corrigé 1.3] ») | en attente |
| `COMMUNICATION_CENTER_SECURITY.md` | conception en vigueur (1.2, annotée « [Corrigé 1.3] ») | en attente |
| `COMMUNICATION_CENTER_DATABASE.md` | conception en vigueur (1.2, annotée « [Corrigé 1.3] ») | en attente |
| `COMMUNICATION_CENTER_TESTING.md` | plan d'essais (aucun exécuté) | en attente |
| `brouillons-sql/40…43-*.sql` | **brouillons jamais exécutés** (version 1.3.1, corrigée D5 le 20/11/2026) | garde à quatre couches : bloc DO, contenu dans une chaîne inerte, garde interne, fermeture de session pour un outil qui découpe le texte |

**Les brouillons SQL ne font pas partie de la chaîne** (`outils/migrations.txt`) et ne doivent être
exécutés nulle part. En Phase 2, après accord écrit du CEO, ils deviendront des fichiers de `outils/`,
éprouvés d'abord sur une base jetable.

**Règle de livraison (consigne du CEO, 18/11/2026)** : chaque phase se termine par un rapport complet,
en français, sur le modèle de celui de la Phase 0 (fichier rangé dans ce dossier).
