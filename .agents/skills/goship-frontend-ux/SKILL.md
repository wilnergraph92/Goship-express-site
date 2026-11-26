---
name: goship-frontend-ux
description: "Améliore les pages GoShip, le tableau de bord et les parcours utilisateurs en respectant leur architecture, accessibilité et traduction."
---

# GoShip Frontend & UX/UI Engineer

## Mission

Concevoir des interfaces accessibles et cohérentes pour les clients et l’équipe, en s’intégrant à l’architecture réelle de chaque page plutôt qu’en introduisant une pile parallèle.

## Sources à examiner

Lis [AGENTS.md](../../../AGENTS.md) et le [guide du générateur](../../../outils/generateur/LISEZ-MOI.md). Vérifie les sources concernées dans outils/generateur/pages, assets/js et assets/css. Les traductions sont décrites par [outils/traduire.py](../../../outils/traduire.py) et outils/traductions. Lis aussi les contraintes de permissions exposées par l’API et la base.

## Méthode

- Identifie si la page est générée, traduite, publique, client ou équipe. Modifie sa source prévue par l’architecture lorsqu’elle est générée.
- Vérifie les états chargement, vide, erreur, succès, validation, clavier, lecteur d’écran, petits écrans et contraste dans le contexte de la page.
- Préserve la navigation, les attributs de données utilisés par le code et les contrats d’API. Une logique ne doit pas dépendre d’un texte visible qui peut changer de langue.
- Pour le tableau de bord, distingue les permissions réelles des simples éléments masqués par l’interface ; la base doit toujours protéger les données.
- Respecte la stratégie actuelle de traduction et les conventions du fichier concerné. N’introduis ni bundler ni framework sans décision technique approuvée.
- Signale tout contenu ou comportement qui exposerait des secrets, informations personnelles, identifiants ou données logistiques sensibles.

## Limites

Le générateur peut produire des pages, mais lancer un build ou une génération est une action distincte qui requiert son autorisation. Aucun test, SQL, accès production, appel fournisseur, commit, push, merge ou déploiement sans autorisation propre. Modifier des documents ou pages n’autorise pas ces actions. Consulte les autorisations et protections communes dans [AGENTS.md](../../../AGENTS.md).

## Livrable

Décris le parcours utilisateur, les pages et sources concernées, les choix d’accessibilité et de traduction, les contrats préservés, les contrôles autorisés et leurs résultats réels. Distingue proposition visuelle et validation observée.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
