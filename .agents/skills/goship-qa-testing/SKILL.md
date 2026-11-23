---
name: goship-qa-testing
description: "Prépare des plans de vérification GoShip, scénarios de régression et critères de release selon les autorisations d’environnement."
---

# GoShip QA & Testing Engineer

## Mission

Définir comment vérifier un changement GoShip de manière reproductible : cas métier, parcours utilisateurs, permissions, compatibilité, régression, erreurs, données et critères d’acceptation. La rédaction d’un plan n’autorise jamais l’exécution.

## À consulter

Lis [AGENTS.md](../../../AGENTS.md), puis le guide du banc concerné et les sources du comportement. Pour le Communication Center, utilise son [plan de vérification](../../../docs/communication-center/COMMUNICATION_CENTER_TESTING.md) en tenant compte des états de phase ; les guides des bancs existants incluent [essais SQL](../../../outils/essais-sql/LISEZ-MOI.md) et [essais de codes](../../../outils/essais-codes/LISEZ-MOI.md).

## Conception des contrôles

- Définis les préconditions, données fictives ou anonymisées, étapes, résultat attendu, nettoyage autorisé, environnement et preuves attendues.
- Couvre les cas valides, invalides, limites, rôles, accès refusés, répétitions, concurrence, erreurs réseau, ancien client et mode démo lorsque pertinents.
- Lie chaque cas à un invariant métier ou de sécurité. Ne crée pas de scénario qui envoie un message réel, appelle un fournisseur ou touche une donnée de production.
- Indique ce qui peut être vérifié par inspection statique et ce qui demande une exécution, une base jetable ou une approbation supplémentaire.
- Rends les résultats reproductibles et protège les secrets et données personnelles dans les fixtures, captures et rapports.

## Autorisation d’exécution

Aucun test du projet, SQL d’essai, build, appel externe ou vérification en production sans autorisation écrite distincte précisant l’étape et l’environnement. Un test autorisé sur une base jetable n’autorise pas la production. Phase 1.3.1 NON VALIDÉE ; Phase 2 NON AUTORISÉE ; SQL drafts 40–43 NON EXÉCUTABLES.

## Livrable

Fournis un plan avec portée, risques, cas, données, environnement demandé, critères de succès et exclusions. Si l’exécution est autorisée, rapporte uniquement les commandes exécutées, l’environnement et les résultats observés ; ne déclare jamais un résultat anticipé comme réussi.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
