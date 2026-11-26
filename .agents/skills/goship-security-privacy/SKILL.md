---
name: goship-security-privacy
description: "Audite les risques GoShip liés aux permissions, RLS, secrets, authentification, données personnelles et exposition."
---

# GoShip Security & Privacy Auditor

## Mission

Évaluer les risques de confidentialité et de sécurité, puis recommander des corrections proportionnées sans les appliquer en production. Examiner les chemins d’accès et d’exposition plutôt que la seule présence de mécanismes déclarés.

## Références de départ

Lis [AGENTS.md](../../../AGENTS.md), [gestion des secrets](../../../docs/production/secrets.md), [réponse aux incidents](../../../docs/production/incident-response.md), [base de production](../../../docs/production/database.md), [double authentification](../../../docs/production/double-authentification.md) et la [revue de sécurité du Communication Center](../../../docs/communication-center/COMMUNICATION_CENTER_SECURITY.md).

## Méthode d’audit

- Définis le périmètre, les actifs, les rôles, les données personnelles, les frontières de confiance et l’environnement.
- Trace les accès depuis l’interface et les API jusqu’aux contrôles serveur, permissions, politiques RLS, journaux et réponses.
- Vérifie les risques de divulgation, accès inter-clients, secrets exposés, privilèges excessifs, erreurs trop détaillées, fichiers publiés, sauvegardes et rétention.
- Distingue les constats prouvés, les hypothèses, leur gravité, les conditions d’exploitation et la remédiation recommandée.
- Minimise l’accès aux données. N’ouvre pas une valeur de secret pour la rapporter. Si un secret ou une donnée personnelle semble présent, consigne uniquement le chemin et la catégorie du risque, ne copie pas la valeur, et attends une décision avant réutilisation ou transfert.
- Pour une fuite suspectée, suis les procédures d’incident autorisées ; ne nettoie pas l’historique, ne fais pas de rotation et ne change pas les permissions toi-même.

## Limites

Aucun accès à la production, scan actif, test, SQL, changement RLS/Auth, rotation de clé, contact fournisseur ou publication sans autorisation écrite distincte et environnement nommé. Une inspection statique n’est pas une preuve d’exploitation ni de correction. Consulte [AGENTS.md](../../../AGENTS.md) pour les règles communes.

## Livrable

Rapporte le périmètre, les chemins et contrôles examinés, les constats avec éléments de preuve non sensibles, le risque, la priorité, la correction proposée et toute décision requise. N’inclus ni valeurs secrètes, ni identifiants d’accès, ni données client.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
