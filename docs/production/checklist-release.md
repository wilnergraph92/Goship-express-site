# Liste de contrôle d'une mise en production

À copier dans la PR de mise en production (ou dans go-no-go.md) et à cocher.
Une case qu'on ne peut pas cocher = NO-GO, sauf si elle est marquée *(non
bloquant)* et qu'un risque accepté est écrit à côté.

## Avant

### Code
- [ ] `essais.yml` vert sur le commit à publier (tous les bancs d'essai)
- [ ] `bureau.yml` vert si `assets/`, `admin.html` ou `bureau/` changent
- [ ] `mobile.yml` vert (dépôt mobile) si une version mobile part
- [ ] Revue du diff : aucun secret, aucune adresse d'essai, aucun fichier de
      travail à la racine
- [ ] `CHANGELOG.md` à jour ; étiquette RC posée

### Base
- [ ] **Préproduction** verte sur la version à publier (chaîne, contrôles, essai
      métier, sonde)
- [ ] **Sauvegarde de la base** du jour : les deux jobs verts (sauvegarde +
      restauration d'épreuve) ; RPO/RTO notés
- [ ] Une restauration dans un vrai projet Supabase a réussi ce trimestre
- [ ] **Contrôles de la base de production** et **Audit de la base de production** lancés :
      résultats gardés (état de départ), aucune ALERTE inexpliquée
- [ ] Fenêtre choisie, équipe prévenue

### Réglages
- [ ] Supabase Auth : *Site URL* et *Redirect URLs* = l'adresse de production
      (aucun `localhost`) ; confirmation d'e-mail activée (la surveillance le
      vérifie : « confirmation des adresses e-mail active ») ; mot de passe ≥ 6
- [ ] Aucun compte de démonstration ou d'essai en production (contrôle de sécurité,
      « Comptes de démonstration »)
- [ ] Au moins un administrateur, mots de passe longs et uniques pour l'équipe
- [ ] Secrets des fournisseurs dans le Vault seulement *(non bloquant si le canal
      n'est pas mis en service : les envois sont « annulés »)*

## Pendant

- [ ] Migrations en production par `appliquer-chaine.sh` (ou SQL Editor), dans
      l'ordre, arrêt au premier échec
- [ ] **Audit de la base de production** : 11/11
- [ ] `select public.sante();` → `status ok`, `pret true`
- [ ] Contrôles relancés : pas de nouvelle ALERTE, mêmes nombres
- [ ] Fusion sur `main` → `deploy.yml` vert, **y compris** le contrôle après publication
- [ ] Étiquette `site-AAAA.MM.JJ`

## Tests de production (fumée, 15 minutes)

Avec un compte client **de l'équipe** (jamais le compte d'un vrai client) :

- [ ] Accueil, suivi public d'un numéro existant, dans les quatre langues
- [ ] Connexion, « Mon compte » : colis, factures, solde, notifications
- [ ] Mot de passe oublié : le lien de l'e-mail mène au site de production
- [ ] Tableau de bord (compte de l'équipe) : vue générale, recherche, un colis
- [ ] Scanner : l'étiquette d'un colis d'essai, une opération, puis correction
      (événement `CORRECTION`) — le colis d'essai reste identifié comme tel
- [ ] Facture d'essai : création, paiement, annulation du paiement (motif), annulation
      de la facture
- [ ] Notification de l'étape d'essai visible dans « Mon compte » ; un envoi par
      canal en service, reçu
- [ ] Bureau : ouverture, impression d'une étiquette
- [ ] Mobile, profil `staging` puis version de test interne (TestFlight, Play
      Internal) : connexion, colis, pré-alerte, notifications, déconnexion, réseau
      coupé ; paquet contrôlé (`controle-paquet.mjs`)

## Après

- [ ] `surveillance.yml` vert à l'exécution **planifiée** suivante (rien de
      critique) ; Healthchecks « up » si `HEARTBEAT_URL` est posé
- [ ] Supabase > Logs : pas d'erreur nouvelle après 1 h
- [ ] Décision et résultat notés dans go-no-go.md
