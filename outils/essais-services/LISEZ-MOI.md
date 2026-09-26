# Les règles métier, éprouvées des deux côtés

`outils/supabase-services.sql` met les règles métier dans la base : prix,
statuts, permissions, doublons, journal. Le mode démonstration
(`assets/js/api.js`) en garde une copie, pour que le tableau de bord se
comporte sur votre ordinateur exactement comme en ligne. Ce banc d'essai
vérifie les deux, et vérifie qu'ils disent la même chose.

```bash
python3 outils/essais-services/essai-services.py     # les règles métier (Phase 2)
python3 outils/essais-services/essai-evenements.py   # le moteur d'événements (Phase 3)
python3 outils/essais-services/essai-scanner.py      # le poste de scan, côté base (Phase 4)
python3 outils/essais-services/essai-finances.py     # paiements, soldes, annulations (Phase 5)
python3 outils/essais-services/essai-permissions.py  # rôles, permissions, isolation des clients (Phase 6)
python3 outils/essais-services/essai-tableau.py      # le tableau de bord : chiffres, rôles, périodes (Phase 7)
python3 outils/essais-services/essai-analytics.py    # les Analytics : périodes, délais, créances, volume (Phase 8)
python3 outils/essais-services/essai-mobile.py       # l'application mobile par l'API réelle : isolation, pré-alertes (Phase 10)
node outils/essais-services/essai-demo.js            # le mode démonstration seul
node outils/essais-services/essai-scanner.js         # le lecteur de codes et le poste en démonstration
node outils/essais-services/essai-finances.js        # les finances en démonstration
node outils/essais-services/essai-permissions.js     # les rôles en démonstration
node outils/essais-services/essai-tableau.js         # le tableau de bord en démonstration
node outils/essais-services/essai-analytics.js       # les Analytics en démonstration
```

**À relancer après toute modification de `supabase.sql`,
`supabase-services.sql`, `supabase-evenements.sql`, `supabase-finances.sql`,
`supabase-tableau-de-bord.sql`, `supabase-analytics.sql`, `supabase-mobile.sql`, `supabase-notifications.sql` ou des règles dans
`api.js`.**

## Ce que prouve `essai-services.py`

Il installe la base **complète** — `supabase.sql`, `supabase-facturation.sql`,
`supabase-services.sql` —, la réinstalle deux fois dans le désordre pour
vérifier qu'elle se rejoue sans risque, puis joue les rôles du site : un membre
de l'équipe, deux clients, un visiteur. Chacun est connecté comme le fait
vraiment le site (rôle `authenticated` ou `anon`, compte dans le jeton) : les
règles de sécurité des tables s'appliquent donc pour de bon.

- **Création d'un colis** : numéro, statut « Reçu », tarif, prix calculé par la
  base (celui envoyé par la page est ignoré), événement initial, facture créée
  dans la même transaction.
- **Validation** : quatorze refus (poids nul, négatif, absent, illisible, absurde ;
  tarif ; description ; client inconnu ou compte d'équipe ; service ;
  destination ; date future), chacun avec son code.
- **L'ancien chemin** : écrire directement dans la table ne contourne rien.
- **Permissions** : un client ne crée, ne change ni ne facture rien ; un
  visiteur n'appelle même pas les fonctions.
- **Transitions** : le parcours normal, les étapes facultatives, l'incident et
  son retour, la correction d'une erreur, les refus.
- **Idempotence et concurrence** : double clic, requête répétée, deux membres
  de l'équipe sur le même colis au même instant, deux créations identiques
  simultanées, deux factures simultanées, scan répété.
- **Facturation** : doublons refusés, total calculé par la base, facture
  arrêtée, annulation puis refacturation.
- **Journal d'audit** : qui, quoi, avant, après — et jamais l'adresse d'un
  client.
- **Suivi** : public (ni nom, ni note, ni prix) et interne.
- **RLS** : chaque client ne voit que ses colis ; la sécurité reste active sur
  toutes les tables ; toute fonction « security definer » a son `search_path`.
- **Volume** : 5 000 colis, une page filtrée en moins d'une seconde.
- **Les deux côtés d'accord** : même matrice des transitions (tous les cas,
  un par un), mêmes tarifs, mêmes prix au cent près.

## Ce que prouve `essai-evenements.py`

- **La migration** : il installe d'abord la base telle qu'elle est publiée
  (les fichiers de la dernière version, lus dans Git — variable
  `GOSHIP_AVANT` pour en choisir une autre), y crée colis, factures et
  historique, puis installe la nouvelle version par-dessus. Les événements
  passés restent intacts au caractère près, aucun n'est inventé, factures et
  prix ne bougent pas, et un ancien colis continue sa route.
- **Les transitions** : valides, refusées, « Action requise » et son retour,
  la livraison, « Livré » final, la correction avec son motif.
- **Les événements sans changement de statut** : inspection, consolidation,
  chargement — invisibles pour le client et le suivi public.
- **Un événement est un fait** : ni modifiable ni effaçable, même au SQL
  Editor ; un client ne peut ni en écrire ni en fabriquer.
- **Double scan, idempotence, conflits** et **concurrence** : deux postes sur
  le même colis au même instant, la même requête HTTP en double, un retry
  réseau.
- **L'historique complet** d'un colis : exactement les événements attendus,
  avec statut d'avant, statut d'après, auteur et heure, dans le même ordre à
  chaque lecture.
- **Les deux côtés d'accord** : le catalogue des événements, la nature de
  chaque transition et chaque validation d'opération, cas par cas, entre la
  base et `api.js`.

## Ce que prouvent `essai-scanner.py` et `essai-scanner.js`

- **La lecture des codes** : le code-barres et le QR de nos étiquettes, les
  QR imprimés en local ou dans une autre langue, les numéros tirés au
  hasard, les cartons Amazon, UPS, SHEIN et USPS (avec son préfixe 420), un
  scanner QWERTY branché sur un poste AZERTY — et tout ce qui doit être
  refusé sans même interroger la base (code trop court, QR de facture…).
- **Le rythme des frappes** : un scanner sans touche Entrée est reconnu, une
  saisie à la main n'est jamais envoyée toute seule.
- **La fiche** : ce que le poste affiche, sans adresse ni téléphone du client,
  et les seules opérations que la base permet.
- **Scan → opération → événement → statut**, le double scan, le retry après
  coupure, les opérations refusées, le colis livré, l'action requise, deux
  postes en même temps, et une recherche parmi 20 000 colis par l'index.

## Ce que prouve `essai-finances.py`

- **La migration** : la base publiée (version `97f53f0`, variable
  `GOSHIP_AVANT`) reçoit des factures à l'ancienne — payée par « Marquer
  payée », à moitié payée, annulée avec de l'argent dessus, sans frais
  (d'avant le 22/09), montant libre —, puis la nouvelle version s'installe
  par-dessus, trois fois dans le désordre. Aucune facture ni ligne ne bouge ;
  chaque montant payé devient un paiement « repris », une seule fois.
- **La facture de 31 $** reste 31 $ partout : base, espace client, tableau de
  bord, et `totauxFacture` d'`api.js` nourri des réponses de la base.
- **Les tarifs** : 10 lb × 2,50 $ = 25 $ reste 25 $ quand le tarif par défaut
  passe à 3 $ ; un nouveau colis prend le nouveau tarif.
- **Le regroupement** : 20 + 15 + 30 + 10 = 75 $, aperçu compris ; refus
  (paiement, deux clients, une seule facture, sans colis, annulée).
- **Les paiements** : partiel (25 → payé 25, solde 50), multiples
  (25 + 20 + 30), trop-payé (80 $ refusé), montant, moyen et date refusés,
  double clic, même référence, **deux paiements de 50 $ simultanés sur 75 $**
  (un seul passe), annulation motivée puis correction.
- **La garde** : plus de « Marquer payée », de payé écrit à la main, de
  suppression, de ligne ajoutée ou retirée ; un paiement ne se modifie ni ne
  s'efface, même depuis le SQL Editor.
- **Annuler une facture**, **numéros jamais réutilisés**, **RLS** (un client
  ne voit que ses paiements, n'en écrit aucun), **en retard**, **résumé**,
  **scanner et statuts sans effet sur la facture**, **journal et file
  d'événements**, **rapport d'anomalies** qui signale sans rien modifier,
  **volume** (3 000 factures), mêmes moyens de paiement que `api.js`.

`essai-finances.js` rejoue les mêmes cas sur le mode démonstration.

## Ce que prouve `essai-permissions.py`

- **La migration** : la base publiée (`e2d2106`, variable `GOSHIP_AVANT`)
  reçoit des comptes et des données, puis la nouvelle version s'installe par
  dessus, trois fois dans le désordre : personne ne change de rôle, rien ne
  bouge, et plus aucune règle de sécurité ne teste « administrateur ».
- **Les rôles** : l'administrateur nomme un gérant et une employée ; le
  journal garde qui, sur quel compte, ancien et nouveau rôle. Refus : rôle
  inconnu, compte inconnu, son propre rôle, tout rôle donné par un gérant,
  une employée ou un client ; deux administrateurs qui se rétrogradent au
  même instant laissent toujours un administrateur.
- **L'élévation de privilèges** : écrire « role », son identifiant ou son code
  dans la table (refusé, même si le droit sur la colonne était rouvert),
  modifier le profil d'un autre, s'inscrire avec « role: admin ».
- **La matrice** : chaque action (colis, tarif, statut, scanner, correction,
  historique, factures, paiements, annulations, regroupement, résumé,
  rapport, e-mails, équipe, réglages) pour l'administrateur, le gérant,
  l'employée et le client — par les fonctions et directement dans les tables.
- **L'isolation des clients**, table par table, en lecture comme en
  écriture ; le visiteur non connecté ; toute fonction « security definer »
  ouverte au site vérifie une permission ; la matrice d'`api.js` est celle de
  la base.

`essai-permissions.js` rejoue les mêmes cas sur le mode démonstration.

## Ce que prouve `essai-tableau.py`

Le tableau de bord (`supabase-tableau-de-bord.sql`), installé par-dessus la
version publiée sans qu'une donnée bouge :

- **Base vide** : des zéros partout, aucune alerte, aucune valeur vide.
- **Rôles** : administrateur et gérant voient tout, l'employée tout sauf la
  facturation ; un client et un visiteur sont refusés ; les parties internes
  ne s'appellent jamais seules ; « Mon résumé » ne montre que son compte.
- **Périodes** : aujourd'hui, 7 et 30 jours, mois, mois précédent, année,
  personnalisée ; un paiement à 23 h 30 à Santo Domingo compte pour son jour.
- **Finances** : 75 $ → payé 25 → payé 50 : solde 75, 50, 0 et facturé =
  payé + solde à chaque étape, dans la vue générale, l'onglet Clients,
  l'espace client et la recherche.
- **Scan → tableau de bord** : un scan se voit aussitôt (compteurs, statuts,
  activité, dernier scan) ; deux scans simultanés n'en comptent qu'un ; une
  livraison corrigée ne compte plus.
- **Recherche** : numéro, début, QR, suivi, code, nom, téléphone, e-mail,
  facture — et « % » ne liste jamais tout.
- **Volume** : 1, 100, 1 000 puis 6 000 colis, chaque chiffre égal au
  `count(*)` de la table, la vue générale en moins d'une demi-seconde, et
  chaque recherche servie par un index.
- **Les deux côtés d'accord** : même forme de réponse et mêmes jours de
  période en démonstration (`essai-tableau.js --formes`, `--periodes`).

## Ce que prouve `essai-analytics.py`

Les Analytics (`supabase-analytics.sql`), installées par-dessus la version
publiée sans qu'une donnée bouge :

- **Rôles** : administrateur et gérant lisent les huit rubriques ; employée,
  client et visiteur sont refusés ; les aides internes ne s'appellent pas.
- **Périodes** : les dix, avec leur période précédente, et les mêmes jours
  que le tableau de bord pour les codes communs ; une période à l'envers,
  trop longue ou inconnue est refusée ; à Santo Domingo, 23 h 59 le 31 mars et
  0 h 00 le 1er avril, 23 h 59 le 31 décembre et 0 h 00 le 1er janvier tombent
  chacun dans leur jour ; une variation contre zéro ne donne jamais Infinity.
- **Un mois contrôlé** (mars 2026) : chaque chiffre attendu à la main — reçus,
  poids, livrés, délais (moyenne, médiane, extrêmes), transitions, retours en
  arrière et corrections.
- **Finances** : 75 $ payé 25 puis 50 → 0 ; 75 $ payé 25 → 50 ; facturé ≠
  encaissé ; créances reconstituées à une date passée égales au solde du
  moment ; âge des créances.
- **Tarif historique** : un colis à 3 $/lb reste à 3 $/lb quand le tarif passe
  à 4 $.
- **Les mêmes chiffres que la vue générale** (reçus, livrés, facturé,
  encaissé, statuts, créances).
- **Volume** : 10 000 colis, 100 000 événements, 5 000 factures — chaque
  fonction en moins de 3 secondes (1,5 en pratique).
- **Les deux côtés d'accord** : même forme de réponse et mêmes jours de
  période en démonstration (`essai-analytics.js --formes`, `--periodes`).

## Ce que prouve `essai-demo.js`

Les mêmes cas, rejoués sur le mode démonstration de `api.js`, chargé hors
navigateur. Les codes d'erreur doivent être identiques à ceux de la base.

## À installer une fois

```bash
pip3 install pgserver pglast
```

Et Node.js pour `essai-demo.js` (déjà présent si vous avez installé
l'application mobile).

## Ce que l'essai ne prouve pas

Comme `outils/essais-sql/`, il remplace par des doublures ce qui n'existe que
chez Supabase : les comptes (`auth`), le coffre-fort (`vault`), les appels
sortants (`pg_net`) et le stockage. La base d'essai est écrite dans un dossier
temporaire du système, jamais dans le site.

## Ce que prouve `essai-mobile.py`

Il installe les neuf migrations (la mobile, deux fois de plus), crée deux clients
(Marie, 25 colis ; Jean, 2 colis), une employée et un administrateur, des événements
(parcours complet, inspection interne, action requise, correction), des factures et
des paiements. Puis il envoie **les requêtes HTTP exactes** de l'application mobile
(`lib/api.js` du dépôt `goship-express-app`) à un **vrai PostgREST 12**, avec le
jeton d'un client — comme quelqu'un qui contournerait l'application :

- **Isolation** : Marie n'obtient rien de Jean (colis, étapes, factures, lignes,
  paiements, pré-alertes, profil, téléphones, notifications), ne modifie ni ne
  supprime rien à lui, ne fait pas sonner son téléphone ; le visiteur n'a rien.
- **Liste** : pages de 20, filtres et recherche faits par la base, index utilisé ;
  10 000 colis chez un client : une page en quelques millisecondes.
- **Étapes** : une opération interne ou une étape corrigée n'est pas montrée.
- **Pré-alertes** (`creer_prealerte`) : sept refus avec leur code, doublon, colis
  déjà arrivé, même envoi répété, cinq requêtes simultanées → une pré-alerte,
  ancien chemin toujours ouvert, limite de 60.
- **Argent** : `mon_resume` et `mes_factures` disent les mêmes soldes ; un client
  n'écrit ni paiement ni montant payé.
- **Compte de l'équipe** : filtré sur son compte, « Mes colis » ne montre pas ceux
  des clients.

Il faut PostgREST 12 (`postgrest` dans le PATH, ou `POSTGREST=chemin`).
`--serveur` garde la base allumée sur `http://localhost:54321` (PostgREST, doublure
de l'authentification, commandes `/essai/panne`, `/essai/revoquer`, `/essai/sql`) :
c'est la base des essais de l'application (`npm run essai:web`, parcours Maestro).

## essai-notifications.py et essai-notifications.js (Phase 11)

Les notifications : événement → règle → notification → envois → statut. Base
jetable avec toutes les migrations ; les fournisseurs (Expo, Brevo, Meta) ne
sont jamais appelés — la doublure de pg_net garde chaque requête et l'essai
écrit lui-même la réponse du fournisseur (réussite, refus, panne, silence).
Règles et étapes, idempotence (même clé, six traitements simultanés),
factures et paiements, travailleur (nouveaux essais 30 s / 2 min, abandon au
troisième, échecs définitifs), panne de pg_net et moteur cassé sans effet sur
l'opération métier, préférences, sécurité compte par compte, rappels de
retard, échappement et liens, forme des réponses démo = base, volume (10 000
envois, quatre travailleurs en parallèle).

    python3 outils/essais-services/essai-notifications.py
    node outils/essais-services/essai-notifications.js
