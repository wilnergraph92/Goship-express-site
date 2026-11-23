# Communication Center — C7.3 : clôture du banc local (23/11/2026)

**Nature du document.** Ce rapport consigne le compte rendu de clôture C7.3 transmis par Codex lors
du relais Codex → Claude Code du 23 novembre 2026. Avant ce relais, ce compte rendu n'existait que
dans la conversation ; il est rangé ici pour qu'il ne se perde pas. Claude Code n'a **pas** réexécuté
ces vérifications : les résultats ci-dessous sont **déclarés par Codex**, et seuls les constats de la
section 5 ont été observés par Claude Code.

Ce rapport ne valide pas la Phase 1.3.1, n'autorise pas la Phase 2 et ne rend pas exécutables les
brouillons SQL 40–43. Un résultat local réussi n'est pas une autorisation.

---

## 1. Place dans le plan officiel

C1 à C7.3 sont des incréments techniques, pas des phases. Le plan officiel reste le suivant ; les
états sont ceux du relais du 23/11/2026 et ne changent qu'avec une preuve.

| Phase | Objectif | État au 23/11/2026 |
|---|---|---|
| 0 | Technical audit | Audit terminé (approuvé le 18/11/2026) |
| 1 | Architecture & security | Phase 1.3.1 **NON VALIDÉE** ; validation finale en attente |
| 2 | Database & backend | Candidates 001–009 éprouvées localement ; phase **NON AUTORISÉE** |
| 3 | Email + WhatsApp | Adaptateurs et parcours locaux construits ; fournisseurs réels non validés |
| 4 | Dashboard UI | Interface construite ; connexion à un backend réel non validée |
| 5 | Automation | Logique construite ; envois réels non autorisés |
| 6 | QA & deployment | QA locale en cours ; aucun staging, aucun déploiement |

## 2. Résultats déclarés

| Vérification | Résultat déclaré | Source dans le dépôt |
|---|---|---|
| Banc C7.3 sur deux bases PostgreSQL jetables, neuves et indépendantes | **438/438** vérifications réussies | `outils/essais-services/essai-communication-center.py` (puis `essai-communication-edge.mjs` et `essai-communication-interface.mjs`, lancés par le même script) |
| Chaîne officielle (`outils/migrations.txt`) puis candidates 001–009, appliquées et rejouées | Réussi | Même banc |
| Versions de la stack Supabase locale | PostgreSQL 17.12, PostgREST 16.5 | Stack Docker `goship-communication-center-local` |
| JWT ES256 : RPC worker autorisées | Acceptées | Stack locale, procédure non versionnée (voir §4) |
| JWT altéré | Rejeté | Idem |
| Appel croisé (jeton worker vers RPC webhook) | Refusé, HTTP 403 | Idem |
| Parcours WhatsApp synthétique : Vault, outbox, faux transport local, confirmation client | Fonctionnel | Banc et stack locale |
| Appel réseau vers Meta ou un autre fournisseur | **Aucun** | — |
| Edge Function servie : jeton invalide | HTTP 401 | Stack locale |
| Edge Function servie : configuration worker absente | HTTP 503 | Stack locale |
| Tests de module : WebCrypto, faux transport, classification d'erreurs, idempotence, concurrence, aucune reprise automatique d'un résultat incertain | Réussis | `essai-communication-edge.mjs` |

## 3. Ce que ces résultats ne couvrent pas

- **Le parcours de succès de l'Edge Function réellement servie** n'a pas été validé avec un faux
  transport.
- **Les brouillons 40–43 ne sont pas couverts.** Le banc éprouve les candidates 001–009, dont la
  construction diffère : par exemple, P-08 traite en une seule transaction `SKIP LOCKED` dans la
  candidate 006. Les **78 essais** du plan final visent les brouillons 40–43 ; ils restent **tous
  non exécutés**.
- **La revue indépendante n'est pas remplacée.** Q1–Q7 exigent toujours un spécialiste humain
  PostgreSQL. Une session Claude ou Codex ne vaut pas revue indépendante.
- **Les propriétés cryptographiques ne sont pas validées par le banc scripté.** Le PostgreSQL embarqué
  ne fournit pas `pgcrypto` ; le banc utilise des doublures non cryptographiques.
- **Aucun fournisseur réel n'est validé** : ni Meta, ni Brevo, ni Resend, ni Expo.
- **La décision S-1 reste ouverte**, même si l'option qu'implémente la candidate 009 passe les
  essais locaux (voir le README du dossier).

## 4. Reproductibilité

- **Banc scripté** : `essai-communication-center.py` crée un cluster PostgreSQL temporaire, deux
  bases neuves, puis supprime le tout en fin d'exécution. Il est reproductible depuis le dépôt.
- **Vérifications sur la stack Supabase locale** (JWT via PostgREST réel, 403, Edge 401/503) :
  le 23/11/2026, Claude Code n'a retrouvé **aucune procédure versionnée** dans le dépôt pour ces
  vérifications. Elles reposent sur le compte rendu de Codex et ne sont pas reproductibles en l'état.

## 5. Limites locales ouvertes (état observé le 23/11/2026)

| # | Limite | État |
|---|---|---|
| 1 | Parcours de succès Edge servie, non validé | Ouvert |
| 2 | Runtime Edge local | Arrêté : aucun conteneur Edge présent le 23/11/2026 ; son volume est conservé |
| 3 | PostgreSQL et Kong démarrés | **Arrêtés le 23/11/2026 à 07:32 UTC** par Claude Code, sur autorisation de la CEO : arrêt propre des 4 conteneurs `db`, `rest`, `auth`, `kong` (code 0), sans suppression |
| 4 | Ports publiés sur `0.0.0.0` et `::` | Plus aucune écoute sur 54321/54322 après l'arrêt. La configuration reste inchangée : un nouveau démarrage republierait ces ports sur toutes les interfaces |
| 5 | Pare-feu macOS | Observé désactivé le 23/11/2026, puis **activé** le même jour par la personne responsable du poste ; vérifié (`socketfilterfw` : état 1, mode furtif désactivé). Le pare-feu applicatif ne remplace pas la limitation des ports à `127.0.0.1` lors d'un prochain démarrage |
| 6 | Fixtures synthétiques et secrets Vault de test | Conservés dans le volume `supabase_db_goship-communication-center-local` ; aucun nettoyage |
| 7 | Immutabilité empêchant la suppression forcée d'une tentative | Inchangée ; aucune désactivation |
| 8 | Nettoyage destructif | Aucun |
| 9 | Fichier de secrets de démarrage local sous `outils/communication-center-edge/supabase/.temp/` | Fichier présent, contenu non lu. **Ignoré par Git depuis le 23/11/2026** (règle `**/supabase/.temp/` du `.gitignore` racine, vérifiée avec `git check-ignore`). Il est aussi exclu de la publication, puisque `deploy.yml` exclut `outils` |

Les conteneurs utilisent la politique de redémarrage `unless-stopped` : un arrêt manuel tient
après un redémarrage de Docker, mais un `supabase start` les relance.
