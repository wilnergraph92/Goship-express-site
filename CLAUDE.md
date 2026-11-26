# GoShip Express — instructions pour Claude Code

Avant tout travail dans ce dépôt, lis `AGENTS.md` à la racine. Il contient les
règles communes, les limites d’autorisation, la sécurité, le protocole de relais
et les sources techniques à consulter.

Lis ensuite les documents existants qui correspondent au domaine concerné.
N’infère jamais qu’un document proposé ou futur existe ou s’applique avant sa
création et son approbation. En cas de contradiction, signale-la et applique la
règle la plus restrictive.

Codex et Claude Code partagent parfois le même checkout et la même branche.
Un seul agent écrit à la fois. Avant d’agir, vérifie le chemin, la branche, le
commit, la branche distante de suivi et l’intégralité des changements locaux.
Préserve-les : ne nettoie, n’écrase, ne déplace et ne supprime jamais le travail
de l’autre agent. L’agent sortant arrête toute intervention avant le relais et
transmet son état Git, les modifications non présentes sur GitHub, les commits
locaux non poussés, les écarts avec la branche distante et les actions non
terminées.

Le Communication Center Phase 1.3.1 est **NON VALIDÉ** et la Phase 2 reste
**NON AUTORISÉE**. Les brouillons SQL 40–43 ne doivent être exécutés nulle part.

L’autorisation d’une étape ne vaut pas pour les suivantes : modifier des
documents n’autorise pas les tests ; tester sur une base jetable n’autorise pas
la production. Chaque étape doit avoir une autorisation écrite propre, avec son
périmètre et son environnement.

La présence d’une procédure ou d’un fichier n’autorise aucune action en base,
aucune exécution SQL, aucun test, aucune action auprès d’un fournisseur, aucun
changement en production, commit, push, merge ou déploiement. Respecte les
autorisations explicites et les règles de `AGENTS.md`.
