---
name: goship-logistics-operations
description: "Analyse et améliore les parcours opérationnels GoShip des colis, préalertes, scans, acheminements et livraison."
---

# GoShip Logistics & Parcel Operations

## Mission

Modéliser les activités de prise en charge et de déplacement des colis sur l’ensemble des routes, origines, destinations, services et modes opérés par GoShip. Ne réduis pas le réseau à une route unique.

## Références

Lis [AGENTS.md](../../../AGENTS.md), les sources opérationnelles pertinentes de l’interface, notamment assets/js/api.js, assets/js/admin.js, assets/js/scanner.js et assets/js/prealertes.js, puis vérifie les règles applicables dans la chaîne SQL officielle [outils/migrations.txt](../../../outils/migrations.txt). Consulte aussi la documentation logistique et l’archive historique en les traitant comme contexte à confirmer, pas comme preuve d’état courant.

## Principes de parcours

- Décris précisément les acteurs, lieux, étapes, délais, transferts de responsabilité et exceptions du flux visé.
- Vérifie l’ordre réel entre annonce ou préalerte, réception, identification, événement, transition de statut, information client, tableau de bord, historique et indicateurs. Cet enchaînement est un modèle à vérifier, pas une permission d’agir.
- Une préalerte décrit un achat annoncé ; elle ne constitue pas à elle seule un colis reçu.
- Distingue les événements du transporteur externe des événements GoShip. Un statut externe ne change pas le statut interne d’un colis sans règle et autorisation explicites.
- Préserve traçabilité, motif de correction, identité de l’auteur, historique et visibilité des événements selon les règles existantes.
- Vérifie les effets sur le poste de scan, les étiquettes, les regroupements, les notifications, les clients et les opérations d’entrepôt.

## Limites

Ne déclenche pas de scan réel, création de colis, changement de statut, envoi de notification, appel transporteur ou autre opération métier réelle sans autorisation écrite distincte. N’exécute pas de SQL ni de tests sans autorisation couvrant l’environnement. N’accède pas à la production et n’effectue aucun commit, push, merge ou déploiement sans autorisation propre. Les restrictions Communication Center sont obligatoires : Phase 1.3.1 NON VALIDÉE, Phase 2 NON AUTORISÉE et SQL drafts 40–43 NON EXÉCUTABLES.

## Livrable

Fournis une carte du processus, des événements et responsabilités, les règles confirmées et hypothèses, les exceptions, les dépendances, les risques de traçabilité et les décisions opérationnelles nécessaires.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
