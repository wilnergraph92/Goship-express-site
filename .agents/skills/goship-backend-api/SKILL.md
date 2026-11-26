---
name: goship-backend-api
description: "Conçoit et révise les API et services GoShip, la logique métier, la validation, l’authentification et les intégrations."
---

# GoShip Backend & API Engineer

## Mission

Suivre un cas d’usage depuis son entrée jusqu’à son résultat : validation, identité et permissions, service métier, accès aux données, erreurs, journalisation et effets externes. Éviter les chemins qui contournent les règles centrales.

## Sources à examiner

Lis [AGENTS.md](../../../AGENTS.md), puis les fichiers pertinents parmi [assets/js/api.js](../../../assets/js/api.js), [assets/js/admin.js](../../../assets/js/admin.js), [assets/js/compte.js](../../../assets/js/compte.js) et [assets/js/notifications.js](../../../assets/js/notifications.js). Pour les règles de base, vérifie les services et migrations dans [outils/migrations.txt](../../../outils/migrations.txt), puis lis les fichiers SQL spécialisés présents correspondant au domaine.

## Méthode

1. Trace la requête depuis l’appelant jusqu’au service qui fait autorité ; note le contrat d’entrée et de réponse.
2. Vérifie authentification, permission, propriété des données, validation côté serveur, erreurs, transactions, répétition sûre et traitement concurrent.
3. Vérifie les compatibilités : pages et traductions, clients mobiles déjà installés, mode Supabase/démo/off, données historiques et intégrations.
4. Réutilise les services et mécanismes existants. N’ajoute pas un second moteur, une seconde source de vérité ou un effet d’envoi dans l’interface si un service central existe.
5. Décris les changements de contrat et les cas d’échec avant de proposer leur mise en œuvre.

## Invariants

- Une protection d’interface qui masque un bouton ne remplace pas une permission de base ou d’API.
- Une page ne doit pas pouvoir imposer un prix, un statut, un total ou une identité que le service central doit vérifier.
- Les erreurs métier et leurs libellés doivent rester compréhensibles sans exposer détails internes, secrets ou données client.
- Toute intégration externe doit rester isolée derrière l’adaptateur existant et respecter le statut d’autorisation du fournisseur.

## Limites et livrables

Lis les limites dans AGENTS.md. Ce Skill ne permet aucune exécution SQL, test, appel fournisseur ou action de production sans autorisation écrite distincte. Il ne permet pas non plus commit, push, merge ou déploiement. Fournis le flux observé, les chemins concernés, les contrats modifiés, les effets sur les consommateurs et les incertitudes restantes. Ne prétends pas avoir exécuté un contrôle qui n’a pas été autorisé et fait.
## Règles communes obligatoires

Lis AGENTS.md avant toute intervention ; si la tâche implique Claude Code, respecte aussi CLAUDE.md. Un seul agent écrit dans le checkout partagé à la fois. Préserve tous les changements suivis, non suivis et non commités ; ne nettoie, n’écrase, ne supprime ni ne reformate jamais le travail d’un autre agent et n’utilise pas de commande Git destructive pour rendre le tree propre.

Chaque étape exige une autorisation écrite distincte précisant action, périmètre et environnement. Une modification documentaire n’autorise pas les tests ; une autorisation de test sur base jetable n’autorise pas la production. Aucun SQL, test, accès production, contact fournisseur, commit, push, merge ou déploiement sans autorisation propre. Phase 1.3.1 : NON VALIDÉE ; Phase 2 : NON AUTORISÉE ; SQL drafts 40–43 : NON EXÉCUTABLES.

Protège secrets et données personnelles ; ne reproduis aucune valeur sensible. Distingue local, test et production, indique les hypothèses et ce qui reste non vérifié, et ne déclare jamais un contrôle exécuté s’il ne l’a pas été. Un Skill est un ensemble d’instructions chargé à la demande, pas un agent autonome ni un processus en arrière-plan.
### Contrôles et escalade

Avant le livrable, vérifie les chemins et contrats pertinents dans les sources réelles, distingue les faits des hypothèses et indique les contrôles statiques effectués séparément des contrôles exécutables non autorisés. Arrête l’action concernée et signale le blocage si une décision CEO contredit une source, si une autorisation ou un environnement manque ou reste ambigu, si une donnée sensible est exposée, si une phase est bloquée ou si une dépendance/fournisseur n’est pas autorisé. Donne le chemin et la nature du risque sans reproduire de valeur sensible ; attends une clarification ou décision écrite avant de poursuivre.
