# Essayer le SQL sans toucher à la vraie base

Les scripts de `outils/` s'exécutent dans Supabase, sur la base de production :
une erreur s'y voit tout de suite, et sur de vrais clients. Ce dossier permet de
les faire tourner **avant**, sur un PostgreSQL local jetable.

```bash
python3 outils/essais-sql/essai-base.py
```

Le script installe `outils/supabase-bienvenue.sql` sur cette base d'essai, crée
des comptes, et vérifie ce qui doit arriver : les deux e-mails partent, ils
attendent la confirmation de l'adresse quand elle est demandée, ils ne partent
pas deux fois, un client connecté ne peut pas les déclencher, et un envoi qui
échoue n'empêche pas la création du compte. Il écrit aussi les deux e-mails en
HTML pour qu'on puisse les ouvrir dans un navigateur.

Il installe ensuite `outils/supabase-factures.sql` et contrôle les deux points
qui comptent : la vue `colis_details` porte bien l'adresse du client (sans elle,
l'étiquette d'expédition n'aurait qu'un nom de ville), et `mes_factures()` ne
montre à chacun que ses propres factures. Ce dernier point est vérifié deux
fois, une fois par barrière : le filtre écrit dans la fonction, puis les règles
de sécurité de la table, chacun devant tenir seul.

Pour essayer un autre script :

```bash
python3 outils/essais-sql/essai-base.py outils/supabase-securite.sql
```

## À installer une fois

```bash
pip3 install pgserver pglast
```

`pgserver` apporte un PostgreSQL complet (rien à installer à côté, rien à
démarrer) ; `pglast` est l'analyseur de PostgreSQL, utile pour relire un fichier
sans même le lancer :

```bash
python3 -c "import pglast; print(len(pglast.parse_sql(open('outils/supabase.sql').read())), 'instructions')"
```

## Ce que l'essai ne prouve pas

Supabase apporte trois choses qui n'existent pas sur un PostgreSQL ordinaire :
`auth.users` (les comptes), le coffre-fort `vault` (les clés) et `pg_net`
(les appels vers Brevo). Le script les remplace par des doublures — assez
fidèles pour le comportement, mais ce sont des doublures. En particulier
**aucun e-mail ne part réellement** : la doublure de `pg_net` range la requête
dans une table au lieu de l'envoyer, ce qui permet justement de la relire.

La base d'essai et les aperçus sont écrits dans un dossier temporaire du
système, jamais dans le site.
