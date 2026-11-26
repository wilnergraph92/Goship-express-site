# Centre de communication — Phase 1.3.1 : décisions CEO en attente

**Rédigé le 23/11/2026 par Claude Code, en lecture seule.** Cette fiche rassemble les décisions encore
ouvertes, chacune avec ses options. La colonne « Avis technique » est un **avis** : ce n'est ni une
décision ni une autorisation. Rien ici n'est tranché tant que la CEO ne l'a pas écrit.

Phase 1.3.1 : **NON VALIDÉE**. Phase 2 : **NON AUTORISÉE**. Brouillons 40–43 : **NON EXÉCUTABLES**.

---

## Ordre conseillé

**A** (objet de la revue) conditionne **E** (essais) et **F** (devis). **B**, **C**, **D**, **G** et
**H** peuvent être décidées en parallèle. **I** concerne seulement le poste local.

## A. Objet de la revue indépendante et des 78 essais

| | |
|---|---|
| Contexte | Les 78 essais et Q1–Q7 visent les **brouillons 40–43** (`PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md`). Les **candidates 001–009** ont été construites ensuite. Elles ont une autre construction (P-07 en deux appels, P-08 en une seule transaction `SKIP LOCKED`) et ont passé un banc local de 438 vérifications. Ces essais ne remplacent pas les 78. |
| Options | 1. Les brouillons seulement, comme le prévoit D5. 2. Les candidates seulement : les 78 essais et Q1–Q7 doivent alors être reformulés pour elles. 3. Les deux. |
| Avis technique | La revue doit porter sur le code destiné à la chaîne officielle ; examiner l'autre ne prouve rien pour lui. La table de correspondance (`PHASE_1_3_1_CORRESPONDANCE_BROUILLONS_CANDIDATES.md`, 23/11/2026) montre que les deux lignées **ne sont pas interchangeables** : 10 objets communs seulement. Les brouillons portent l'envoi marketing ; les candidates modifient le moteur transactionnel, n'envoient aucun marketing et n'ont pas de hiérarchie de verrous globale documentée. Il faut donc d'abord **fixer le périmètre de la Phase 2**, puis choisir l'objet de la revue. |
| Débloque | E, F, et la version figée du dossier de revue (§1) |

## B. S-1 : authentification de l'Edge vers PostgreSQL

| | |
|---|---|
| Contexte | La recommandation de `PHASE_1_3_FINAL_REPORT.md` §10 était un rôle de connexion dédié, avec mot de passe. Une autre option est construite et éprouvée localement : la candidate 009 et le client Edge. |
| Options | 1. **JWT ES256** signé par l'Edge ; rôles `communication_webhook` et `communication_worker` sans connexion, membres d'`authenticator` ; émetteur, audience et durée vérifiés (candidate 009). 2. **Rôle de connexion dédié** avec mot de passe dans les secrets Edge (recommandation 1.3). 3. Clé `service_role` : écartée par tous les documents de sécurité. |
| Avis technique | L'option 1 évite tout mot de passe de base de données dans l'Edge et passe par PostgREST, avec le moindre privilège. Il reste à **vérifier, sans rien activer**, que l'offre Supabase visée accepte une clé publique de signature supplémentaire pour PostgREST et des réglages `app.communication_jwt_*` sur `authenticator`. Il faut aussi définir qui garde la clé privée et comment la renouveler. |
| Débloque | L'intégration réelle de l'Edge (Phase 3), après la Phase 2 |

## C. Écran d'arrêt d'urgence

| | |
|---|---|
| Contexte | D5 (P-07) sépare l'arrêt en deux appels : `arreter_communications` répond `STOP_REQUESTED`, puis `confirmer_arret_communications` répond `STOP_CONFIRMED` ou `STOP_PENDING`. |
| À décider | Si l'écran relance la confirmation automatiquement, à quel intervalle et pendant combien de temps ? Que voit l'opérateur pendant `STOP_PENDING` ? Qui peut lever l'arrêt ? |
| Avis technique | Relance automatique bornée, `STOP_PENDING` affiché clairement, alerte si l'état dure (voir D). La demande reste écrite dans tous les cas. |

## D. Alertes

| | |
|---|---|
| À décider | Les seuils : échec d'un retour prioritaire (STOP, plainte, désinscription), retour en attente au-delà de N minutes (F-W06 prend 11 min comme exemple), `STOP_PENDING` prolongé, interruption du travailleur. Les destinataires et le canal d'alerte. |
| Avis technique | Toute défaillance d'un retour prioritaire doit déclencher une alerte immédiate, car elle peut cacher un STOP non appliqué. |

## E. Autorisation d'exécuter les 78 essais

| | |
|---|---|
| Prérequis | A tranchée. |
| À préciser par écrit | Le périmètre (tous les essais, ou d'abord F-M01 et F-M02), l'environnement (base locale jetable, jamais la production), les données (synthétiques seulement) et la conservation des résultats. |
| Avis technique | Commencer par F-M01 et F-M02 (garde, puis création 40 → 43) : les brouillons n'ont jamais été créés dans une base (R-04). |

## F. Demande de devis au spécialiste PostgreSQL (D4)

| | |
|---|---|
| Contexte | D5 §6 contient déjà la liste des cabinets (Dalibo ou Data Bene, CYBERTEC), la méthode exigée et le texte de demande. |
| À décider | Envoyer ou non, à qui, quelles pièces transmettre (dossier de revue §2), et faire signer un accord de confidentialité. |
| Rappel | L'envoi est fait par la CEO. Aucun agent ne contacte un prestataire. |

## G. Permission `communications.view` dans la chaîne officielle

| | |
|---|---|
| Contexte | Une modification locale non commitée ajoute `communications.view` aux rôles admin et gérant dans `outils/supabase.sql`, `supabase-naissance.sql` et `supabase-suivi-externe.sql` (`permissions_du_role`). Les candidates en dépendent. La candidate 008 redéfinit en outre cette fonction avec les permissions de campagne. |
| Options | 1. La garder, et l'intégrer à la Phase 2. 2. La retirer de la chaîne officielle et la placer dans une candidate. 3. Reporter la décision. |
| Avis technique | Option 2 tant que la Phase 2 n'est pas autorisée : la chaîne officielle ne devrait pas porter une permission du Centre. Si elle est appliquée, elle donne seulement accès à la supervision, en lecture. |

## H. Paramètres N-01 et N-02

| | |
|---|---|
| Contexte | Le plafond par empreinte de numéro est décidé (D1). Le brouillon 43 ajoute un plafond **par compte, tous canaux confondus**, dont l'approbation n'est pas établie. Pour le code WhatsApp : 60 min de validité, 5 erreurs, limites répétées ; ces valeurs n'ont pas d'approbation retrouvée. |
| À décider | Approuver, modifier ou retirer ces valeurs. |

## I. Poste local (hors Phase 1.3.1)

| Point | État au 23/11/2026 | À décider |
|---|---|---|
| Stack Supabase locale | Arrêtée, volumes conservés | Ne la redémarrer qu'avec des ports limités à `127.0.0.1` (autorisation distincte) |
| Pare-feu macOS | **Activé** le 23/11/2026 par la personne responsable du poste ; vérifié (`socketfilterfw` : état 1) | Réglé. Le mode furtif reste désactivé ; c'est un choix facultatif |
| `outils/communication-center-edge/supabase/.temp/` | Contient des secrets locaux ; **ignoré par Git depuis le 23/11/2026** (règle `**/supabase/.temp/`) | Réglé |
| Fixtures et secrets Vault de test | Conservés | Les nettoyer ou non, plus tard ; aucune suppression sans autorisation |

## Validations juridiques à demander (hors CEO)

La règle D2 (numéros partagés) ; la liste des mots d'arrêt (États-Unis/Floride, République
dominicaine, Haïti) et le bouton de désinscription Meta ; la durée de conservation de la table de
traitement ; le STOP conservé après l'effacement d'une personne.
