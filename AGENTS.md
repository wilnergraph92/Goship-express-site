# GoShip Express — règles communes de travail

Ce fichier fixe les règles communes à tout agent qui intervient dans ce dépôt.
Il ne remplace ni les décisions écrites de la CEO, ni les procédures de
production, ni les documents techniques spécialisés.

## Autorité et portée

- Respecte les instructions système et les demandes explicites de la personne
  responsable du projet, ainsi que les autorisations décrites dans les
  documents de gouvernance.
- Une proposition technique, un rapport, un brouillon SQL ou une capacité
  présente dans le code ne constitue jamais une décision CEO ni une
  autorisation d’exécution.
- Toute étape exige une autorisation écrite distincte, avec son périmètre et
  son environnement clairement indiqués.
- Une autorisation de lecture ne permet pas une écriture. Une autorisation
  concernant un environnement ne vaut pas pour un autre.
- L’autorisation de modifier des documents n’autorise pas l’exécution de tests.
- L’autorisation de tester sur une base jetable n’autorise aucune intervention
  en production.
- Quand deux documents se contredisent, n’infère aucune permission. Signale le
  conflit et applique la règle la plus restrictive jusqu’à clarification.
- Les documents mentionnés ici existent dans le dépôt au moment de leur
  vérification, sauf mention explicite qu’il s’agit d’une structure proposée.
  Ne présume jamais qu’un document futur existe ou qu’il est obligatoire avant
  sa création et son approbation.

## État bloquant connu : Communication Center

Le Communication Center et sa Phase 1.3.1 ont un statut particulier :

- La Phase 1.3.1 est déclarée **NON VALIDÉE** dans
  `docs/communication-center/PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`.
- La Phase 2 est **NON AUTORISÉE**.
- Les brouillons SQL 40 à 43 dans
  `docs/communication-center/brouillons-sql/` sont hors de la chaîne officielle
  et ne doivent être exécutés nulle part.
- Les corrections D5 préparées ne valident pas la Phase 1.3.1 et n’autorisent
  ni essai, ni migration, ni déploiement.
- Aucune phase suivante, aucun essai sur une base jetable et aucune action
  auprès d’un fournisseur ne sont autorisés par défaut.
- Toute étape ultérieure exige sa propre autorisation écrite, précisant son
  périmètre et son environnement. Une autorisation pour une étape ne s’étend
  pas aux étapes suivantes.
- Seule une nouvelle décision écrite de la CEO, qui autorise explicitement
  l’action concernée, peut modifier ces limites. Ne déduis jamais cette
  décision d’un rapport technique ou de la présence de code.

Références existantes : `docs/communication-center/README.md`,
`docs/communication-center/PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md`,
`docs/communication-center/PHASE_1_3_1_D5_RAPPORT_CORRECTIONS.md` et
`docs/communication-center/PHASE_1_3_1_ANALYSE_POST_AUDIT_P07_P08.md`.

## Projet et conventions de code

GoShip Express comprend des activités logistiques, des outils numériques pour
les clients et l’équipe, et des routes dont les origines, destinations et
services sont décrits dans les documents fonctionnels du dépôt. Ne réduis pas
la description du projet à une seule route ou à deux destinations.

Avant de modifier du code :

- Lis les instructions applicables et les documents de référence du domaine
  concerné.
- Les commentaires rédigés pour GoShip sont en français correct, avec accents,
  et expliquent la raison de la règle.
- Pour le JavaScript du site, respecte l’architecture réellement utilisée par
  le fichier concerné. Le code historique peut être en ES5, IIFE et `var` ;
  ne modernise pas son style ou son architecture sans demande explicite.
- Le site n’utilise pas de bundler applicatif.
  `outils/generateur/build.py` génère les pages lorsque l’architecture le
  prévoit.
  `.github/workflows/deploy.yml` prépare l’artefact de publication, applique
  les exclusions et le versionnage. Ce workflow ne lance pas le générateur.
- Les pages générées se modifient dans leurs sources du générateur lorsque
  l’architecture le prévoit. Vérifie les règles du générateur avant de toucher
  une page générée.
- Les connaissances techniques historiques doivent être conservées après
  vérification et assainissement. Elles ne sont pas toutes des règles actuelles
  par le seul fait qu’elles figurent dans un document historique.

## Règles d’action par défaut

À défaut d’autorisation explicite pour l’étape en cours :

- privilégie la lecture seule ;
- ne modifie, ne crée, ne supprime et ne déplace aucun fichier ;
- ne lance aucune commande qui écrit dans Git, dans le réseau, dans un compte
  externe, dans une base ou dans la production ;
- ne lance ni SQL ni test sans autorisation écrite distincte ;
- ne contacte aucun fournisseur, client, collègue ou service externe ;
- ne publie, ne fusionne, ne pousse et ne déploie rien ;
- indique clairement les vérifications réellement faites et celles qui ne l’ont
  pas été.

Une demande de revue ou d’audit en lecture seule n’autorise pas implicitement
une correction, même si un défaut est trouvé.

## Sécurité, secrets et données personnelles

- Ne place aucun secret, jeton, mot de passe, certificat, sauvegarde ou donnée
  personnelle dans Git, une réponse, un journal de commande, un test, un
  artefact ou un fichier temporaire du dépôt.
- Ne lis ni ne révèle le contenu d’un secret. Si un secret ou une donnée
  personnelle semble présent, ne reproduis pas sa valeur : indique seulement
  le chemin et la nature du risque, puis attends une décision avant de copier
  le contenu concerné.
- Ne consulte que les données personnelles indispensables à une tâche
  explicitement autorisée. Privilégie les agrégats, anonymise les exemples et
  ne copie pas de données client hors de leur système autorisé.
- Une clé Supabase publique (*publishable*) n’est pas un secret ; elle ne
  dispense jamais de respecter RLS et les permissions. Aucune clé
  `service_role`, clé secrète, mot de passe de base ou clé de fournisseur ne
  doit être placée dans le site ou une application.
- Les journaux, sorties d’outils et rapports doivent éviter les noms, e-mails,
  téléphones, adresses, identifiants client, numéros de colis et secrets, sauf
  nécessité autorisée et traitement sûr.
- En cas de fuite suspectée, ne tente pas de nettoyer l’historique ni de faire
  une rotation toi-même. Signale le risque et suis
  `docs/production/incident-response.md` et `docs/production/secrets.md`.

## Git et publication

- `main` est une branche de publication : un push ou une fusion qui l’actualise
  peut déployer le site.
- Le parcours normal d’un changement du site est : branche de travail,
  changements revus, contrôles requis, pull request, puis fusion selon les
  règles du dépôt. Ne commite pas directement sur `main`.
- Aucun commit, push, merge ou changement de branche n’est implicite. Fais-le
  uniquement si la demande et les autorisations applicables le permettent.
- Le dépôt peut contenir des changements locaux non suivis ou non commités.
  Avant toute écriture, vérifie `git status` et préserve tous les changements
  préexistants. Ne les écrase, ne les déplace, ne les stage et ne les attribue
  pas à l’agent actif sans instruction.
- N’utilise pas `reset`, `clean`, `stash`, amend, rebase ou une commande
  destructive de changement de branche pour obtenir un working tree propre.
  Aucun agent ne peut nettoyer, écraser ou supprimer le travail d’un autre
  agent.
- La racine n’est pas à considérer comme publiée fichier par fichier :
  `.github/workflows/deploy.yml` construit l’artefact de publication à partir
  des fichiers présents et applique des exclusions et le versionnage. Vérifie
  ce workflow avant tout changement de publication.
- N’ajoute pas de fichier de travail ou de gouvernance à la racine publiée
  sans avoir vérifié les protections de déploiement et l’emplacement approprié.

## Relais séquentiel Codex / Claude Code

Codex et Claude Code peuvent partager le même checkout et la même branche.
**Un seul agent peut écrire dans ce checkout à la fois.** Les agents ne
travaillent jamais simultanément sur des fichiers du checkout partagé.

### Relais de l’agent sortant

Avant le relais, l’agent sortant :

1. arrête toute intervention avant de passer la main ;
2. ne lance aucune nouvelle commande et n’apporte aucun autre changement ;
3. transmet un compte rendu précisant :
   - l’objectif et le périmètre autorisé ;
   - le chemin du checkout, la branche et le commit observés ;
   - les fichiers lus et les fichiers modifiés, s’il y en a ;
   - les modifications locales non présentes sur GitHub, suivies ou non par Git ;
   - les commits locaux non poussés ;
   - les écarts entre la branche locale et sa branche distante de suivi, dont
     l’avance ou le retard constaté ;
   - tous les changements non commités qu’il laisse en place ;
   - les commandes de vérification réellement exécutées ;
   - les actions encore en cours ou non terminées ;
   - les décisions ou autorisations encore attendues ;
   - l’étape suivante et ses limites d’autorisation.

L’agent sortant ne reprend pas le travail tant que l’agent entrant n’a pas
terminé ou rendu explicitement la main.

### Prise de relais de l’agent entrant

Avant toute écriture, l’agent entrant :

1. confirme le chemin du checkout, la branche et le commit ;
2. lit `git status` et vérifie la branche distante de suivi disponible ;
3. inspecte tous les changements non commités et non suivis, même s’ils
   semblent étrangers à sa tâche ;
4. vérifie les commits locaux non poussés et les écarts avec la branche distante ;
5. compare l’état observé au compte rendu de relais et demande une clarification
   si un élément est inexpliqué ;
6. préserve intégralement le travail présent.

Il est interdit à l’agent entrant de nettoyer, écraser, supprimer, déplacer,
stager ou reformater le travail de l’agent sortant pour obtenir un working tree
propre. En cas de doute, il s’arrête et demande des instructions.

## SQL, Supabase et migrations

- La chaîne officielle est celle de `outils/migrations.txt`. Ce fichier définit
  l’ordre ; ne le reconstitue pas à partir d’une liste copiée dans un autre
  document.
- Les scripts SQL n’ont pas tous le même rôle : migrations, contrôles en
  lecture seule, essais, brouillons et scripts d’exploitation doivent être
  distingués avant toute action.
- La présence d’un fichier `.sql`, son ordre apparent ou sa garde de sécurité
  ne constitue jamais une permission de l’exécuter.
- N’exécute aucun SQL et ne te connecte pas à Supabase sans autorisation
  écrite précisant l’action, le périmètre et l’environnement.
- Toute écriture en base demande une autorisation distincte de la lecture.
  Une autorisation de lecture ne permet ni migration, ni réglage, ni
  modification de données, ni changement de permission, ni tâche planifiée.
- Une autorisation de modifier des documents n’autorise aucun test. Une
  autorisation de tester sur une base jetable n’autorise aucune action en
  production.
- Chaque étape d’un projet demande sa propre autorisation écrite. Une
  autorisation pour concevoir, documenter, corriger, tester, migrer ou déployer
  ne vaut que pour l’étape, le périmètre et l’environnement qu’elle nomme.
- Une migration de production est soumise aux règles de production ci-dessous
  et aux procédures détaillées de `docs/production/`.
- Les brouillons 40–43 du Communication Center sont interdits d’exécution,
  quelle que soit la base, tant qu’une décision écrite distincte ne lève pas
  explicitement cette interdiction. À ce jour, la Phase 2 reste non autorisée.
- Une revue de code SQL peut être faite par lecture si la tâche l’autorise ;
  elle ne prouve pas le comportement d’exécution et ne remplace pas les essais
  ou revues requis.

Références existantes : `outils/migrations.txt`,
`docs/production/database.md` et `docs/communication-center/README.md`.

## Supabase et production

- La production est hors périmètre et en lecture seule par défaut.
- Ne touche pas aux données, permissions RLS, clés, Vault, réglages Auth,
  fonctions, extensions, tâches `pg_cron`, fournisseurs ni secrets de
  production sans autorisation spécifique et actuelle.
- Un GO/NO-GO historique ou une procédure technique ne vaut pas autorisation
  d’agir aujourd’hui.
- Avant toute intervention envisagée en production, vérifie les documents
  opérationnels applicables et la validité datée des preuves et autorisations.
  Si elles sont périmées, absentes ou contradictoires, arrête l’action et
  signale le blocage.
- Le document `docs/production/deployment.md` présente une ambiguïté entre
  l’interdiction d’intervenir directement en production et les procédures
  d’application en production décrites plus loin. Cette ambiguïté doit être
  clarifiée avant toute opération de production. Ne la résous pas en déduisant
  une permission.
- Toute opération en production doit avoir une autorisation écrite distincte
  qui nomme l’action, la cible, la fenêtre et les limites ; elle doit aussi
  satisfaire aux prérequis de sauvegarde, contrôle, retour arrière et revue
  décrits dans `docs/production/`.
- Une autorisation portant sur une base jetable, une préproduction ou un test
  ne permet aucune intervention en production.
- Les procédures de migration, sauvegarde, restauration, reprise et incident
  se trouvent dans `docs/production/`. Ne les exécute pas par simple lecture de
  ces documents.
- N’exécute aucune action externe auprès d’un fournisseur. Une décision
  d’étudier ou de préparer une demande n’autorise pas à la transmettre.

## Vérifications

- N’ajoute ni ne lance tests, bancs d’essai, builds, déploiements ou contrôles
  de production sans autorisation écrite distincte couvrant cette étape.
- Quand les vérifications sont autorisées, choisis celles qui n’écrivent pas
  dans la production et indique leur portée exacte.
- Ne déclare jamais un contrôle réussi s’il n’a pas été exécuté. Distingue
  inspection statique, contrôle local, base jetable, préproduction et
  production.

## Conservation des connaissances techniques

Les connaissances techniques utiles de l’ancien `AGENTS.md` ont été
conservées après vérification et assainissement dans
`docs/architecture/reference-technique-historique.md`. Cette archive est une
référence historique non normative : ses faits doivent être confirmés dans le
code et les documents opérationnels avant d’être traités comme actuels.

Avant toute copie ou nouvelle réutilisation de son contenu :

- vérifie le contenu pour repérer secrets, identifiants d’accès et données
  personnelles ;
- exclus l’identifiant de démonstration et toute information
  d’authentification associée ;
- ne reproduis aucune valeur sensible dans Git, les rapports ou les fichiers ;
- conserve la note indiquant qu’un contenu sensible a été volontairement omis ;
- si un autre secret ou une donnée personnelle est détecté, signale-le et
  attends une décision avant de copier le contenu concerné.

Aucun contenu sensible ne doit être conservé simplement pour atteindre une
copie intégrale.

Sources techniques existantes :

- chaîne et ordre des migrations : `outils/migrations.txt` ;
- production et déploiement : `docs/production/deployment.md`,
  `docs/production/go-no-go.md`,
  `docs/production/checklist-release.md` et
  `docs/production/releases.md` ;
- sécurité des secrets : `docs/production/secrets.md` ;
- incidents et données personnelles :
  `docs/production/incident-response.md` ;
- sauvegarde et restauration : `docs/production/backup.md`,
  `docs/production/disaster-recovery.md` et `docs/production/rollback.md` ;
- architecture et environnements : `docs/production/architecture.md`,
  `docs/production/environment.md` et `docs/production/database.md` ;
- Communication Center : `docs/communication-center/README.md` et les
  rapports de phase référencés par cet index ;
- notifications transactionnelles : `docs/notifications.md` ;
- programmes : `docs/programmes.md` ;
- bureau : `bureau/LISEZ-MOI.md` ;
- essais SQL et métier : les `LISEZ-MOI.md` des dossiers d’essais.

Ne crée pas une deuxième source de vérité en recopiant des listes de migrations,
des états de production, des tarifs ou des décisions dans plusieurs documents.
Les états changeants doivent porter leur date et leur source de vérification.

## Compte rendu

Pour chaque tâche, termine en indiquant clairement :

- le périmètre traité ;
- les fichiers consultés ou modifiés ;
- les vérifications exécutées et leurs limites ;
- l’état Git pertinent ;
- les décisions ou autorisations encore nécessaires.

N’affirme pas qu’un changement, contrôle, accord CEO ou état de production est
validé sans preuve correspondante.
