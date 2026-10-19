# Programmes : anniversaires, offre de bienvenue, parrainage, GOPOINTS

Ce document dit ce que fait chaque programme, où vivent ses règles, ce qui est
prêt et ce qui reste à décider ou à brancher. **Aucune valeur commerciale n'est
écrite dans le code** : chaque programme naît éteint ou en brouillon, et ne
promet rien au client tant que l'équipe ne l'a pas réglé et publié.

## Ce qui est installé (quatre migrations, dans cet ordre)

| Fichier | Rôle |
|---|---|
| `outils/supabase-naissance.sql` | Date de naissance obligatoire à l'inscription par e-mail (facultative avec Google), table fermée `profils_naissance`, fuseau de l'entreprise. Redéfinit `creer_profil_client`. |
| `outils/supabase-fidelite.sql` | GOPOINTS : registre immuable, soldes jamais négatifs, règles, offres, expiration, avantages (`recompenses`). |
| `outils/supabase-anniversaires.sql` | Messages d'anniversaire (16 modèles : 4 types × fr/en/es/ht), planification toutes les 15 minutes (pg_cron), rappels internes. |
| `outils/supabase-campagnes.sql` | GOship APP Welcome, GOship Refer, le moteur d'opérations qualifiantes, les avantages. |

Banc : `outils/essais-services/essai-programmes.py` (374 vérifications sur une
base jetable), `essai-programmes.js` (copie démo, 106), `essai-programmes-tableau.mjs`
(tableau de bord, navigateur, 41) et `essai-programmes-navigateur.mjs` (espace
client, navigateur, 64).

## Règles communes

- **Tout se décide dans la base.** Les pages et l'application lisent et règlent
  par des fonctions ; elles ne calculent aucun solde, aucune éligibilité.
- **Rien n'est promis avant d'être acquis.** Un avantage « en attente » est dit
  en attente ; une opération annulée ou remboursée avant validation annule
  l'avantage.
- **Jamais une erreur de programme ne bloque une réception de colis ou un
  paiement** : elle est notée (`programmes_erreurs`, visible dans l'onglet
  Avantages) et l'opération continue.
- **Permissions** : `birthdays.view` / `birthdays.manage`, `programs.view` /
  `programs.manage`, `points.adjust`. Un employé ne lit ni les dates de naissance
  ni les programmes. Un client ne lit que ses propres soldes et avantages.
- **Les avantages hors points** (crédit d'expédition, réduction, bonus, avantage
  sur un prochain colis) sont **enregistrés**, pas appliqués : l'équipe les
  applique à la facture à la main. La facturation (5 $/lb + 10 $ de frais) n'est
  jamais modifiée automatiquement.

## Anniversaires

- Un message par client et par année, le jour même (jour civil de l'entreprise,
  fuseau initial `America/Santo_Domingo`, réglable), dans la langue du client.
- 29 février : le 28 février ou le 1er mars, au choix de l'équipe.
- Rattrapage réglable si un envoi est manqué ; clé unique client + année : jamais
  de doublon, même si la tâche tourne deux fois.
- Rappel interne 7 jours avant (réglable) ; rappel au client à venir **désactivé
  par défaut**.
- Aucun cadeau n'est promis par le modèle de base. Un avantage d'anniversaire
  n'est annoncé que s'il est configuré (type, valeur, texte) **et** allumé.
- Le client peut couper son message dans son compte (site et application).
- **Canaux** : l'application (notification du compte) et, si configurés, push et
  e-mail, par le moteur de notifications existant (`docs/notifications.md`).
  **WhatsApp n'est pas disponible pour les anniversaires** : il faudrait un
  modèle de message approuvé par Meta et une branche d'envoi. Un envoi n'est
  « envoyé » ou « livré » que sur réponse du fournisseur.

## GOship APP Welcome

Une campagne (nom, dates, type et valeur de la récompense, opération qualifiante,
budget, délai de validation, cumul avec le parrainage, conditions). Statuts :
brouillon, programmée, active, suspendue, terminée. **Une campagne incomplète
ne se publie pas** (la base dit ce qui manque). Un seul bonus par client, après
sa première opération qualifiante vue par la base (`colis_recu` ou
`facture_payee`) ; le téléchargement de l'application n'est pas vérifiable et
ne compte pas.

## GOship Refer (« ENVITE YON ZANMI »)

Code unique par client (8 signes sans ambiguïté), lien `inscription.html?parrain=CODE`,
copie, partage natif. Les deux avantages (parrain et filleul, réglés séparément)
sont accordés après la première transaction qualifiante du filleul, avec un
délai de validation optionnel. Plafonds par parrain et au total. Le parrain
voit des chiffres et ses propres avantages, **jamais** l'identité ni les
opérations d'un filleul.

Contrôles d'abus : auto-parrainage et cycles refusés ; même téléphone, même
adresse, même identifiant e-mail, rafale de 5 inscriptions en 24 h rendent le
parrainage **« à examiner »** : rien n'est bloqué ni accordé automatiquement, un
administrateur valide ou refuse avec un motif (journalisé).

## GOPOINTS

Événements configurables : création du compte, première opération, opérations
répétées, parrainage validé, campagne, anniversaire. Chaque règle a ses points,
son opération qualifiante, ses limites par jour, par mois et par client, sa
durée de vie. Le registre ne se modifie jamais (corrections et annulations =
lignes de plus, avec motif) ; le solde est verrouillé, donc deux échanges
simultanés ne dépassent jamais le solde. Le catalogue d'offres est **vide** tant
que l'équipe n'y ajoute rien. L'expiration des points tourne chaque jour (pg_cron).

## À décider par GoShip (valeurs commerciales)

Rien n'est inventé. Avant d'allumer un programme, décidez :

1. **Bienvenue** : quel avantage (type et valeur), pour quelle opération, pendant
   quelles dates, pour combien de clients au plus ? Un délai de validation
   (par exemple le temps d'un remboursement possible) ?
2. **Parrainage** : avantage du parrain, avantage du filleul, transaction
   qualifiante, plafond par parrain, durée de vie des avantages, cumul avec la
   bienvenue ? Conditions générales et conditions d'annulation (visibles par le
   client).
3. **GOPOINTS** : combien de points pour chaque événement, quelles limites,
   quelle durée de vie, quelles offres échangeables, à quel coût ? Qui les
   applique à la facture ?
4. **Anniversaire** : un avantage ou seulement le message ? Quel texte exact ?
   Quels canaux ?

## Mise en service (rien n'est actif tant que ces étapes ne sont pas faites)

1. Lancer, dans Supabase > SQL Editor, `supabase-naissance.sql`, `supabase-fidelite.sql`,
   `supabase-anniversaires.sql`, `supabase-campagnes.sql` (« Copy raw file »), puis
   contrôler les valeurs attendues (README § migrations). **Tester ensuite une
   inscription par e-mail et une avec Google** : `creer_profil_client` a changé.
2. Vérifier que l'extension **pg_cron** est active (sinon rien ne part).
3. Régler le réglage `site_url` si l'on veut un lien de parrainage complet
   (`definir_reglage`, comme pour les notifications).
4. Configurer au moins un canal d'envoi réel (e-mail, push) avant d'allumer les
   anniversaires ; l'onglet Programmes dit ce qui est configuré.
5. Dans le tableau de bord > Programmes : régler, puis publier ou allumer
   programme par programme, en commençant par un essai sur peu de clients.
6. Publier le site, puis la mise à jour de l'application (canal EAS Update).

## Limites connues

- **Mode démonstration** : copie fidèle des règles, mais aucun message ne part
  (les anniversaires restent « en attente ») et l'expiration des points ne tourne pas.
- Corriger ou ajouter une date de naissance : onglet Programmes > Anniversaires, bloc
  « Date de naissance d'un client » (administrateur, code du client, motif obligatoire,
  journalisé sans la date). Un client ne déclare la sienne qu'une fois.
- Les avantages hors points ne sont pas déduits automatiquement des factures.
- L'application doit être mise à jour pour afficher l'écran « Mes avantages » ;
  les versions déjà installées continuent de fonctionner sans.
