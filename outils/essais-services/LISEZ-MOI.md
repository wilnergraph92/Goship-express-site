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
node outils/essais-services/essai-demo.js            # le mode démonstration seul
node outils/essais-services/essai-scanner.js         # le lecteur de codes et le poste en démonstration
node outils/essais-services/essai-finances.js        # les finances en démonstration
```

**À relancer après toute modification de `supabase.sql`,
`supabase-services.sql`, `supabase-evenements.sql`, `supabase-finances.sql`
ou des règles dans `api.js`.**

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
