---
name: goship-team-orchestrator
description: "Oriente une demande GoShip vers les Skills spécialisés, ordonne les étapes et consolide les revues sans lancer de processus en arrière-plan."
---

# GoShip Team Orchestrator

## Mission

Servir de point d’entrée pour choisir et ordonner les Skills GoShip adaptés, coordonner leurs apports et produire une synthèse unique. Ce Skill coordonne l’utilisation de compétences chargées à la demande ; il n’est ni un agent autonome, ni un processus en arrière-plan, ni un superviseur d’agents.

## Parcours d’orientation

1. Lire [AGENTS.md](../../../AGENTS.md), comprendre le résultat demandé, l’environnement, les autorisations et l’état du checkout avant toute écriture.
2. Découper la demande en livrables indépendants et relever les dépendances, risques, décisions CEO et étapes non autorisées.
3. Charger ou recommander uniquement les Skills utiles : [architecte système](../goship-system-architect/SKILL.md), [base Supabase](../goship-database-supabase/SKILL.md), [backend API](../goship-backend-api/SKILL.md), [frontend UX](../goship-frontend-ux/SKILL.md), [opérations logistiques](../goship-logistics-operations/SKILL.md), [communications](../goship-communication-notifications/SKILL.md), [sécurité et confidentialité](../goship-security-privacy/SKILL.md), [qualité et tests](../goship-qa-testing/SKILL.md), [analytics et finance](../goship-analytics-finance/SKILL.md), [DevOps et release](../goship-devops-release/SKILL.md).
4. Ordonner les activités selon leurs dépendances. Ne demande pas de travail simultané dans le checkout partagé : un seul agent écrivain à la fois. Aucun sous-agent ou processus parallèle n’est lancé implicitement.
5. Comparer les constats aux sources et décisions écrites ; résoudre les différences par preuve ou les signaler, sans transformer un avis technique en décision CEO.
6. Consolider les faits, propositions, actions autorisées, exclusions, résultats observés et questions qui restent ouvertes.

## Coordination et relais

Pour un relais séquentiel entre Codex et Claude Code, appliquer intégralement le protocole de [AGENTS.md](../../../AGENTS.md). L’agent sortant arrête toute intervention ; son compte rendu indique branche, commit, travail local absent de GitHub, commits non poussés, divergence avec la branche distante, fichiers laissés modifiés et actions inachevées. L’agent entrant inspecte tous les changements locaux avant d’écrire et ne les nettoie, écrase ou supprime jamais.

## Gouvernance obligatoire

Une autorisation vaut seulement pour l’étape, le périmètre et l’environnement qu’elle nomme. L’autorisation documentaire n’autorise pas de test ; une base jetable n’autorise pas la production. Aucun SQL, test, accès production, appel fournisseur, commit, push, merge ou déploiement sans autorisation écrite propre.

Communication Center Phase 1.3.1 : NON VALIDÉE. Phase 2 : NON AUTORISÉE. SQL drafts 40–43 : NON EXÉCUTABLES. L’ambiguïté de docs/production/deployment.md doit être clarifiée avant une opération de production.

## Livrable

Présente le besoin et son périmètre, les Skills recommandés et leur ordre, les dépendances, les conclusions consolidées, les écarts non résolus, les vérifications réellement faites et les autorisations encore nécessaires. Signale les tâches bloquées au lieu d’inventer une validation ou de dépasser le mandat.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
