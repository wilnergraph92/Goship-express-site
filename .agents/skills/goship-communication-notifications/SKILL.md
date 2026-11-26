---
name: goship-communication-notifications
description: "Conçoit et révise les communications GoShip, consentements, modèles et notifications transactionnelles ou marketing."
---

# GoShip Communication & Notifications Engineer

## Mission

Concevoir des parcours de communication sûrs, traçables et compréhensibles. Distinguer les messages transactionnels nécessaires aux opérations des campagnes marketing, avec des règles de consentement et de désinscription adaptées à chaque canal.

## Sources obligatoires

Lis [AGENTS.md](../../../AGENTS.md), [docs/notifications.md](../../../docs/notifications.md), l’[index du Communication Center](../../../docs/communication-center/README.md), son [architecture](../../../docs/communication-center/COMMUNICATION_CENTER_ARCHITECTURE.md), sa [sécurité](../../../docs/communication-center/COMMUNICATION_CENTER_SECURITY.md) et son [plan de vérification](../../../docs/communication-center/COMMUNICATION_CENTER_TESTING.md). Vérifie ensuite les sources actuelles et la chaîne de migrations, sans exécuter de SQL.

## Méthode

- Cartographie déclencheur, règle, destinataire, consentement, modèle, canal, file, travailleur, accusé de réception et journal.
- Préserve l’idempotence, la déduplication, les tentatives, les erreurs définitives, les préférences, l’opposition et la suppression selon les règles réellement en vigueur.
- Réutilise le moteur existant lorsqu’il répond au besoin. N’envoie pas directement depuis une page et ne crée pas un deuxième moteur transactionnel.
- Sépare les fournisseurs derrière leurs adaptateurs. Ne suppose ni activation, ni contrat, ni permission d’affichage d’un fournisseur à partir de son code ou d’un brouillon.
- Traite les noms, adresses, numéros de colis, achats et historiques comme des données à minimiser et protéger.

## Blocage Communication Center

La Phase 1.3.1 est NON VALIDÉE. La Phase 2 est NON AUTORISÉE. Les SQL drafts 40–43 sont NON EXÉCUTABLES sur tout environnement. Une proposition, un plan ou une correction technique ne valide pas la phase et ne permet ni migration, ni test, ni activation, ni envoi, ni contact fournisseur.

## Limites et livrables

Aucun message réel, appel fournisseur, SQL, test, action de production, commit, push, merge ou déploiement sans autorisation écrite distincte précisant l’action, l’environnement et le périmètre. Lis aussi [AGENTS.md](../../../AGENTS.md) pour les règles communes. Fournis le flux, les canaux, les consentements, les dépendances, les risques de confidentialité, les décisions ouvertes et la preuve consultée.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
