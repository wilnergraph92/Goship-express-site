# Site web Goship Express

Site statique (HTML, CSS, JavaScript) en quatre langues — français, anglais, espagnol et créole haïtien —, construit à partir de la maquette Claude Design « Goship Express — site logistique moderne ». Il comprend un **espace client** (création de compte avec code client unique, suivi des colis en temps réel) et un **tableau de bord** pour l'équipe (enregistrement des colis, mise à jour des statuts). Rien à installer ni à compiler : les fichiers de ce dossier constituent le site.

## Contenu

| Emplacement | Rôle |
|---|---|
| `index.html`, `a-propos.html`, `nos-services.html`, `blog.html`, `contacts.html`… | Pages en **français** (version de référence) |
| `en/`, `es/`, `ht/` | Les mêmes pages en **anglais**, **espagnol** et **créole**, générées automatiquement |
| `article-*.html` | Les 11 articles du blog |
| `support.html`, `fermer-un-compte.html`, `confidentialite.html`, `termes-et-conditions.html`, `marchandises-dangereuses.html` | Pages légales |
| `inscription.html`, `connexion.html`, `mon-compte.html`, `nouveau-mot-de-passe.html` | **Espace client** : créer un compte, se connecter, suivre ses colis, changer de mot de passe |
| `admin.html` | **Tableau de bord** de l'équipe (en français uniquement, non référencé par Google) |
| `404.html` | Page « introuvable » |
| `assets/js/config.js` | **Réglages** : numéro WhatsApp, service de formulaires, connexion à Supabase |
| `assets/css/site.css` | Styles communs : survols, animations, menu mobile, espace client, tableau de bord |
| `assets/js/site.js` | Menu, sélecteur de langue, suivi de colis, formulaires, animations |
| `assets/js/api.js`, `compte.js`, `admin.js` | Espace client et tableau de bord |
| `assets/js/notifications.js` | Textes des e-mails et messages WhatsApp envoyés aux clients (4 langues) |
| `assets/js/codes.js` | Calcul des **QR codes** et des **codes-barres** des étiquettes |
| `assets/js/impression.js`, `assets/css/impression.css` | **Étiquettes d'expédition** (imprimante thermique) et **factures** imprimables |
| `assets/img/` | Logos, photos, icônes et drapeaux (`drapeaux/`) |
| `outils/generateur/` | **Le générateur des pages** (`build.py`), la maquette d'origine (`export/`) et les pages écrites à la main (`pages/`). C'est la source du site — voir « Modifier le site » |
| `outils/` | Outil de traduction, dictionnaires, scripts de la base de données (`supabase*.sql`), dessin des écrans de l'application (`ecrans-app/`) et bancs d'essai (`essais-sql/`, `essais-services/`, `essais-codes/`) — **inutile de le mettre en ligne** |
| `Voir le site en local.command` | Lanceur à double-cliquer pour voir le site sur votre Mac — **inutile de le mettre en ligne** |

## Voir le site sur votre ordinateur

Double-cliquez sur **`Voir le site en local.command`** : une fenêtre du Terminal s'ouvre (laissez-la ouverte) et le tableau de bord s'affiche dans votre navigateur. Adresses :

- site : http://localhost:8000/
- tableau de bord : http://localhost:8000/admin.html

Au premier lancement, macOS peut demander l'autorisation d'accéder au Bureau : acceptez. Fermez la fenêtre du Terminal pour arrêter. Sans le lanceur, la même chose s'obtient en tapant dans le Terminal, depuis ce dossier :

```bash
python3 -m http.server 8000
```

Double-cliquer directement sur `index.html` ou `admin.html` fonctionne aussi, mais dans Safari les comptes et colis de démonstration ne sont alors pas conservés d'une page à l'autre : préférez le lanceur.

Sur votre ordinateur, l'espace client fonctionne en **mode démonstration** tant que Supabase n'est pas configuré : les comptes et les colis sont enregistrés uniquement dans votre navigateur. Pour essayer le tableau de bord, ouvrez `admin.html`, connectez-vous avec `admin@goship.demo` / `demo1234`, puis cliquez sur « Ajouter des exemples ». Les clients d'exemple se connectent avec le mot de passe `demo1234` (par exemple `marie-ange@exemple.com`).

## Mettre le site en ligne

Publiez tout le dossier (le dossier `outils/` et le lanceur `Voir le site en local.command` peuvent être omis) :

- **Netlify** : glissez-déposez le dossier sur https://app.netlify.com/drop.
- **Hébergement classique (Hostinger, o2switch, cPanel…)** : envoyez le contenu du dossier dans `public_html` (ou `www`), en gardant les sous-dossiers `en`, `es`, `ht` et `assets`.
- **GitHub Pages, Vercel, Cloudflare Pages** : publiez la racine du dossier, sans commande de build.

En ligne, tant que Supabase n'est pas configuré, l'espace client reste **fermé** : les pages de compte invitent le visiteur à passer par WhatsApp et aucun compte fictif ne peut être créé.

**Ne publiez pas** `outils/`, `application-mobile/`, `README.md` ni les fichiers cachés : ils décrivent le fonctionnement interne. Les fichiers `.htaccess` et `_redirects` fournis les bloquent déjà si votre hébergeur les lit, mais le plus sûr reste de ne pas les envoyer.

## Sécurité

Trois protections tiennent l'ensemble : la **base de données** décide qui voit quoi (un client ne peut lire que ses propres lignes, même avec un outil autre que le site), les **pages** n'exécutent que le code du site, et le **téléphone** garde la session dans son coffre-fort.

### Ce qui est déjà en place

- **Rien n'est lisible sans compte.** Les tables refusent toute lecture anonyme ; seul le suivi public d'un colis (statut et étapes, sans nom ni adresse) répond sans connexion.
- **Aucun script extérieur.** La bibliothèque Supabase est rangée dans `assets/js/vendor/`. Les pages portent une règle `Content-Security-Policy` qui interdit au navigateur d'exécuter ou de contacter autre chose que le site, Supabase et les polices Google. Un script glissé dans une page ne peut donc ni s'exécuter, ni envoyer les données des clients ailleurs.
- **En-têtes de sécurité** dans `_headers` (Netlify, Cloudflare Pages…) et `.htaccess` (hébergement Apache) : site non affichable dans un cadre, HTTPS obligatoire, caméra et micro refusés.
- **Les jetons de connexion ne traînent pas.** Le lien reçu par e-mail les dépose dans l'adresse de la page ; ils en sont effacés dès la session ouverte.
- **Sur le téléphone**, la session est chiffrée par le système (Keychain / Keystore) et un téléphone qui change de main cesse de recevoir les colis de l'ancien propriétaire.

### Les cinq réglages à faire dans Supabase

Ils ne peuvent se faire que depuis vos propres écrans Supabase (ils touchent à votre compte) :

1. **Lancez `outils/supabase-securite.sql`** — SQL Editor > New query > coller > Run. Sans risque, relançable.
2. **Authentication > URL Configuration — à faire le jour de la mise en ligne.** Aujourd'hui seul `http://localhost:8000/**` est autorisé (c'est pourquoi les liens fonctionnent sur votre ordinateur) et le *Site URL* est resté `http://localhost:3000`, l'adresse d'essai par défaut. Dès que le site a son adresse, mettez-la dans *Site URL* et ajoutez `https://votre-site.com/**` dans *Redirect URLs*, puis retirez les lignes `localhost` — sinon **les liens « mot de passe oublié » et « confirmez votre adresse » renverront vos clients dans le vide**. N'y mettez jamais une adresse qui ne vous appartient pas : cette liste est ce qui empêche un faux site de récupérer les sessions de vos clients.
3. **Authentication > Sign In / Providers > Email > Confirm email : activé.** Aujourd'hui, n'importe qui peut créer un compte avec l'adresse e-mail de quelqu'un d'autre sans avoir à la prouver. Le site et l'application affichent déjà le message « ouvrez le lien reçu par e-mail ». Un détail à ne pas rater : tant que l'expéditeur est une adresse Gmail réécrite par Brevo, ces e-mails peuvent tomber dans les indésirables — et un client qui ne les reçoit pas ne peut plus entrer. Faites d'abord un essai avec une adresse personnelle ; si l'e-mail arrive mal, authentifiez d'abord votre domaine dans Brevo.
4. **Même écran, section Password** — longueur minimale **6**. Le site et l'application demandent déjà 6 caractères, mais c'est ici que la règle devient réellement appliquée. 6 est le plus petit nombre que Supabase accepte : sa console refuse en dessous, et régler le site plus bas ne servirait qu'à faire accepter un mot de passe que le serveur rejetterait ensuite. Activez aussi *Prevent use of leaked passwords* si votre offre le permet (Pro ou plus) : Supabase refuse alors les mots de passe déjà connus des pirates, ce qui compte d'autant plus avec 6 caractères.
5. **Le compte administrateur** mérite un mot de passe long et unique, utilisé nulle part ailleurs. Dans *Advisors > Security*, Supabase signale de lui-même tout nouveau point à corriger : un coup d'œil de temps en temps suffit.

### Ce qu'il faut savoir en modifiant le site

- **Ajouter un service extérieur** (tchat, statistiques, Formspree, police d'écriture…) demande de l'autoriser dans la règle `Content-Security-Policy`, sinon le navigateur le bloquera sans rien dire. Elle est fabriquée dans `build.py`, fonction `csp()` : ajoutez l'adresse du service à la ligne qui convient (`script-src` pour un script, `connect-src` pour un envoi de données), puis reconstruisez le site.
- **Mettre à jour la bibliothèque Supabase** (une à deux fois par an) : téléchargez la nouvelle version, rangez-la dans `assets/js/vendor/` et changez la ligne `SUPABASE_JS` en haut de `assets/js/api.js`.
  ```
  curl -L "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js" -o assets/js/vendor/supabase-2.NOUVELLE.js
  ```
- **Les clés.** Celle du site (`supabaseKey`, dans `config.js`) est publique : elle est faite pour être lue par les navigateurs et ne donne accès qu'à ce que les règles de la base autorisent. Les vraies clés secrètes — `service_role`, Brevo, WhatsApp — ne doivent **jamais** entrer dans un fichier du site : elles se rangent dans le coffre-fort de Supabase avec `select public.definir_reglage(…)` (voir « Prévenir les clients »).
- **Les numéros de colis se suivent** (GSE-1001, GSE-1002…) : quelqu'un peut donc essayer les numéros voisins sur la page de suivi et observer l'activité de l'entreprise — jamais les noms ni les adresses, mais le volume, oui. La fin de `outils/supabase-securite.sql` contient, prêt à l'emploi, le réglage qui donne aux nouveaux colis un numéro tiré au hasard.
- **Le champ « lieu »** d'une étape s'affiche dans le suivi public : n'y écrivez pas le nom ni l'adresse d'un client.

### Le format des codes clients

Un code client est « GSE- » suivi de **4 chiffres** : `GSE-4323`. Il est tiré au hasard, et jamais deux fois le même — la colonne est unique et la base retire un autre numéro si celui-ci est déjà pris. Le client l'écrit juste après son nom sur ses achats en ligne : c'est ce qui rattache un colis à son compte.

**Ce format tient 9 000 clients** (de 1000 à 9999). C'est confortable longtemps, mais ce n'est pas illimité, et il faut le savoir maintenant plutôt que le découvrir plus tard : au-delà d'environ 8 000 clients, la base met de plus en plus d'essais à trouver un numéro libre, et quand il n'y en a plus elle refuse la création du compte avec un message explicite (elle ne tourne pas en boucle sans fin). Le jour où vous en approchez, une seule ligne à changer dans `public.nouveau_code_client()` : `1000 + floor(random() * 9000)` devient `10000 + floor(random() * 90000)`, et vous passez à 90 000 codes à 5 chiffres. Les anciens codes à 4 chiffres continuent de fonctionner.

Pour savoir où vous en êtes, la requête de contrôle est à la fin de `outils/supabase-code-client.sql`.

**Changer de format ne touche que les nouveaux comptes.** Les codes déjà attribués restent tels quels, et c'est voulu : un client a pu donner le sien à Amazon, et des colis peuvent déjà porter son ancien code. Le même fichier contient, prêt à l'emploi mais désactivé, le bloc qui les renumérote — à n'utiliser que si vous êtes sûr qu'aucun colis n'est en route.

**Essayer un script SQL avant de le lancer sur la vraie base.** Les fichiers de `outils/` s'exécutent sur la base de production : une erreur s'y voit sur de vrais clients. `outils/essais-sql/` permet de les faire tourner d'abord sur un PostgreSQL local jetable, qui se crée tout seul. Voir `outils/essais-sql/LISEZ-MOI.md`. Les règles métier (`supabase-services.sql`) ont leur propre banc : `outils/essais-services/`.

## Espace client et tableau de bord

### Ce que voit le client

- **Créer un compte** (bouton orange de l'en-tête) : nom complet, pays, région, ville, adresse, téléphone, e-mail et mot de passe. Chaque compte reçoit automatiquement un **code client unique**, tiré au hasard : « GSE- » suivi de 4 chiffres (ex. GSE-4323). Le client reçoit aussitôt **deux e-mails** : son code, puis son adresse en Floride (voir « Les deux e-mails de bienvenue »).
- **Mon compte** : son code client, son **adresse en Floride** à utiliser pour ses achats en ligne (avec son nom et son code, prête à copier), ses colis en cours et livrés, l'historique de chaque colis et ses coordonnées modifiables. La page se met à jour **en direct** dès que l'équipe change un statut.
- **Mes factures** (dans « Mon compte », sous les colis) : chaque facture avec son montant, son état (À payer, Payée en partie, En retard, Payée, Annulée), ce qui est déjà payé et ce qui reste, les paiements reçus, la date limite, le détail ligne par ligne — un colis par ligne — et la note de l'équipe. Un bouton **« Payer par carte »** quand un lien de paiement est prêt, et un bouton **« Imprimer ou enregistrer »** qui sort la facture sur une page A4, dans la langue du client. Comme les colis, la liste se met à jour **en direct** : une facture marquée payée dans le tableau de bord change d'état chez le client dans la seconde.
- **Suivi de colis** (accueil) : n'importe qui peut suivre un colis avec son numéro (GSE-1001-HT…) ou le numéro de suivi du vendeur. Seuls le statut et les étapes sont affichés, jamais le nom, l'adresse ni le contenu.

Statuts disponibles : Reçu → Emballé → Embarqué → Centre de distribution → Transféré à la succursale → Disponible → Livré, plus « Action requise » en cas de problème (le message joint s'affiche chez le client).

### Ce que fait l'équipe (`admin.html`)

- **Enregistrer un colis** à sa réception : code client (le nom du client s'affiche pour vérification), date et heure de réception (remplies automatiquement, modifiables), contenu, expéditeur (Amazon, SHEIN…), numéro de suivi du vendeur, poids, service, destination. Le numéro de colis (GSE-1001-HT, GSE-1002-DO…) est attribué automatiquement, le colis naît au statut « Reçu », et son **prix** (poids × tarif) et sa **facture** sont créés par la base dans le même mouvement. Voir « Les règles métier ».
- **Mettre à jour** le statut d'un colis, avec un lieu et un message pour le client ; ou cocher plusieurs colis et **changer leur statut en une fois** (un conteneur qui part, par exemple). Les statuts impossibles depuis l'étape actuelle sont grisés ; pour un lot, si un seul colis ne peut pas suivre, aucun ne change et le tableau de bord dit lequel.
- **Imprimer l'étiquette d'expédition** d'un colis (bouton « Étiquette » sur sa ligne, ou depuis sa fiche) ; ou cocher plusieurs colis et **imprimer toutes leurs étiquettes en une fois**, ce qu'on veut après avoir enregistré l'arrivée d'un lot. Voir « Étiquettes, QR codes et codes-barres ».
- **Facturer** (onglet Factures) : créer une facture, **encaisser** un paiement (acompte ou solde, avec son moyen et sa référence), l'**annuler** avec son motif (jamais la supprimer), **regrouper** plusieurs factures d'un client en une seule, l'envoyer sur WhatsApp, et l'**imprimer** sur une page A4, dans la langue du client. En haut de l'onglet : ce qui reste à encaisser, les factures en retard, ce qui est entré ce mois-ci ; le bouton **« Contrôler »** liste les incohérences de facturation sans rien corriger. Voir « Les finances ».
- Rechercher un colis ou un client, filtrer par statut, voir les colis d'un client, corriger ou supprimer un colis.

### Prévenir les clients (e-mail et WhatsApp)

Le client reçoit un **e-mail** et un **message WhatsApp**, dans sa langue, avec le détail de son colis (code client, n° de colis, expéditeur, service, contenu, suivi vendeur, poids, date et heure de réception) et un bouton « Suivre mon colis » :

- **à l'enregistrement du colis** (« Nous avons bien reçu votre colis à notre entrepôt de Miami ») : case « Prévenir le client », cochée par défaut ;
- **quand le colis passe à « Disponible »** (« Votre colis est disponible dans notre agence de… ») : l'agence devient obligatoire. Plusieurs colis cochés ensemble préviennent chacun leur client.

Après l'envoi, une fenêtre récapitule ce qui est parti, avec l'**aperçu de l'e-mail**. La fiche de chaque colis liste les messages envoyés et propose « Prévenir le client » pour renvoyer le message. Les textes se modifient dans `assets/js/notifications.js`.

**Logo et lien des messages.** Les messageries n'affichent que des images en ligne : à sa première ouverture, le tableau de bord copie le logo dans un dossier public de Supabase (*Storage*, dossier `site`, créé par la partie 8 de `outils/supabase.sql`). Le bouton « Suivre mon colis » et le lien du message WhatsApp mènent à l'adresse publique du site, à renseigner dans `assets/js/config.js` (`siteUrl`) dès que le site est en ligne. Tant que le tableau de bord tourne sur votre ordinateur sans cette adresse, les messages partent sans ce lien : un lien vers « localhost » ne mènerait nulle part chez le client.

- **E-mail** : envoyé automatiquement une fois le service d'envoi configuré (ci-dessous).
- **WhatsApp** : sans configuration, le bouton « Envoyer sur WhatsApp » ouvre votre WhatsApp avec le message déjà rédigé pour le numéro du client ; il ne reste qu'à appuyer sur Envoyer. L'envoi entièrement automatique passe par l'API WhatsApp de Meta (facultatif, ci-dessous).

#### Les deux e-mails de bienvenue

Dès qu'un compte est créé — depuis le site ou depuis l'application —, le client reçoit **deux e-mails dans sa langue**, sans que personne ait à intervenir :

1. **« Bienvenue chez Goship Express »** : son code client, en grand, et le bouton qui ouvre son espace.
2. **« Votre adresse en Floride »** : l'adresse à donner aux boutiques, champ par champ (*Full Name*, *Address line 1*…), prête à recopier, avec le rappel d'écrire son code juste après son nom.

Ils partent de la base, pas du tableau de bord : l'ordinateur de l'équipe peut être éteint. Si la confirmation des adresses e-mail est activée (section « Sécurité »), ils attendent que le client ait cliqué sur le lien de confirmation — inutile d'envoyer une adresse à quelqu'un qui n'a pas prouvé la sienne. Ils ne partent jamais deux fois, et **un e-mail qui échoue n'empêche pas la création du compte**.

Pour les installer, une seule fois : Supabase > *SQL Editor* > *New query* > coller `outils/supabase-bienvenue.sql` > *Run*. Puis deux réglages, dans la même fenêtre :

```sql
select public.definir_reglage('site_url', 'https://www.goshipexpress.com');
select public.definir_reglage('courriel_logo',
       'https://VOTRE-PROJET.supabase.co/storage/v1/object/public/site/logo-goship.png');
```

Le premier donne l'adresse du site aux boutons des e-mails ; le second, le logo (le même dossier public que les e-mails de colis, partie 8). Sans le premier, les e-mails partent sans bouton ; sans le second, le nom « Goship Express » remplace le logo. Dans les deux cas l'e-mail reste correct.

Les textes des deux e-mails, dans les quatre langues, sont dans la fonction `courriels_compte_textes` du même fichier : c'est le seul endroit à modifier pour changer une phrase. L'adresse de l'entrepôt, elle, est dans `adresse_miami` — et aussi dans `assets/js/notifications.js`, `application-mobile/config.js` et `mon-compte.html` : si elle change, il faut la corriger aux quatre endroits.

Pour renvoyer les deux e-mails à un client (essai, ou client qui ne les a pas reçus) :

```sql
select public.renvoyer_courriels_bienvenue('GSE-4323');
```

#### Activer l'envoi des e-mails (Brevo, gratuit jusqu'à 300 e-mails par jour)

1. Créez un compte sur https://www.brevo.com. L'adresse d'inscription devient votre premier expéditeur (*Senders, domains, IPs* > *Senders*, mention *Verified*). Une adresse Gmail fonctionne, mais Brevo la remplace à l'envoi par une adresse `@brevosend.com` (toujours au nom de « Goship Express ») et les e-mails finissent plus souvent dans les courriers indésirables. Dès que possible, utilisez une adresse de votre nom de domaine (ex. `notifications@goshipexpress.com`) et authentifiez ce domaine chez Brevo (*Domains*).
2. *Settings* > *Security* > *Authorized IPs* : si le blocage des adresses IP inconnues est actif, cliquez sur *Deactivate blocking*. Les serveurs de Supabase n'ont pas d'adresse fixe : sans cela, Brevo finirait par refuser leurs envois.
3. Créez une clé API : *Settings* > *SMTP & API* > *API Keys & MCP* > *Generate a new API key*, sans expiration. Elle ne s'affiche qu'une fois.
4. Dans Supabase > *SQL Editor*, exécutez ces lignes avec vos valeurs, puis effacez le texte de la requête pour ne pas y laisser la clé en clair :

   ```sql
   select public.definir_reglage('email_fournisseur', 'brevo');
   select public.definir_reglage('email_cle_api', 'xkeysib-votre-cle');
   select public.definir_reglage('email_expediteur', 'notifications@goshipexpress.com');
   select public.definir_reglage('email_nom', 'Goship Express');
   ```

5. Envoyez-vous un e-mail de test (remplacez l'adresse du destinataire) :

   ```sql
   select net.http_post(
     url := 'https://api.brevo.com/v3/smtp/email',
     headers := jsonb_build_object('api-key', public.lire_reglage('email_cle_api'),
                                   'Content-Type', 'application/json', 'Accept', 'application/json'),
     body := jsonb_build_object(
       'sender', jsonb_build_object('name', public.lire_reglage('email_nom'),
                                    'email', public.lire_reglage('email_expediteur')),
       'to', jsonb_build_array(jsonb_build_object('email', 'vous@exemple.com')),
       'subject', 'Test Goship Express : les e-mails fonctionnent',
       'textContent', 'Bonne nouvelle : Supabase et Brevo sont bien reliés.'));
   ```

   Rien reçu (pensez aux spams) ? `select status_code, content, error_msg from net._http_response order by created desc limit 1;` indique la réponse de Brevo : 201 = envoyé, 401 = clé refusée ou adresse IP bloquée, 400 = expéditeur non vérifié.

Les clés sont rangées dans le coffre-fort de Supabase (*Vault*), jamais dans le site. Resend fonctionne aussi (`'resend'` et une clé `re_…`, domaine vérifié chez Resend). Le même compte Brevo fournit le SMTP de l'étape 7 ci-dessous (e-mails « mot de passe oublié ») : *SMTP & API* > *SMTP*, serveur `smtp-relay.brevo.com`, port `587`, identifiant du type `…@smtp-brevo.com` et une clé SMTP (*Generate a new SMTP key*), différente de la clé API.

#### WhatsApp automatique (facultatif, API WhatsApp de Meta)

1. Inscrivez votre entreprise sur la plateforme WhatsApp Business de Meta (https://business.facebook.com, *WhatsApp Manager*) et ajoutez un numéro de téléphone pour l'API.
2. Créez deux modèles de message de catégorie *Utility*, en français (`fr`), anglais (`en_US`) et espagnol (`es`) ; les clients créolophones reçoivent la version française. Respectez les noms et l'ordre des variables :

   - `colis_recu` : « Bonjour {{1}}, nous avons bien reçu votre colis {{2}} à notre entrepôt de Miami. Code client : {{3}}. Contenu : {{4}}. Poids : {{5}}. Reçu le {{6}}. Suivez-le depuis votre espace client Goship Express. »
   - `colis_disponible` : « Bonjour {{1}}, votre colis {{2}} est disponible dans notre agence de {{3}}. Présentez votre code client {{4}} pour le retirer. Merci de votre confiance, Goship Express. »

   En anglais : « Hello {{1}}, we have received your package {{2}} at our Miami warehouse. Customer code: {{3}}. Contents: {{4}}. Weight: {{5}}. Received on {{6}}. Track it from your Goship Express customer area. » et « Hello {{1}}, your package {{2}} is ready for pickup at our {{3}} office. Please show your customer code {{4}} when you collect it. Thank you, Goship Express. »
   En espagnol : « Hola {{1}}, recibimos su paquete {{2}} en nuestro almacén de Miami. Código de cliente: {{3}}. Contenido: {{4}}. Peso: {{5}}. Recibido el {{6}}. Sígalo desde su área de clientes de Goship Express. » et « Hola {{1}}, su paquete {{2}} está disponible en nuestra oficina de {{3}}. Presente su código de cliente {{4}} para retirarlo. Gracias por su confianza, Goship Express. »
3. Une fois les modèles approuvés, créez un jeton d'accès permanent (utilisateur système) et relevez l'identifiant du numéro (*Phone number ID*), puis dans le SQL Editor :

   ```sql
   select public.definir_reglage('whatsapp_jeton', 'EAAG…');
   select public.definir_reglage('whatsapp_numero_id', '123456789012345');
   ```

Meta facture chaque message de ce type (quelques centimes). Tant que ces réglages manquent, le bouton « Envoyer sur WhatsApp » reste disponible.

### Activer l'espace client (Supabase, gratuit)

Les comptes et les colis sont enregistrés dans [Supabase](https://supabase.com), un service de base de données sécurisé qui fonctionne avec n'importe quel hébergeur. Comptez 15 minutes. Dans Supabase, la barre de gauche n'affiche que des icônes (leur nom apparaît au survol) : *SQL Editor* est l'icône `>_`, *Authentication* le cadenas, *Project Settings* la roue dentée tout en bas.

1. **Créez un compte** sur https://supabase.com, puis un **projet** (région conseillée : East US). Notez le mot de passe de la base de données.
2. **Créez la base** : *SQL Editor* > *New query*, collez tout le contenu du fichier `outils/supabase.sql`, puis *Run*. Supabase affiche « Potential issue detected » parce que le script remplace ses éventuelles versions précédentes : cliquez sur *Run query*. Le message « Success. No rows returned » doit s'afficher.
3. **Inscriptions sans confirmation par e-mail** : *Authentication* > *Sign In / Providers*, bloc *User Signups* : désactivez **Confirm email**, puis *Save changes*. Le service d'e-mails fourni par Supabase n'écrit qu'aux membres de votre équipe Supabase : tant que la confirmation reste active, vos clients ne peuvent pas terminer leur inscription (voir l'étape 7 pour la réactiver).
4. **Votre compte administrateur** : *Authentication* > *Users* > *Add user* > *Create new user* : votre adresse e-mail, un mot de passe, *Auto confirm user?* coché, puis *Create user*. Ensuite, dans *SQL Editor* > *New query*, exécutez :

   ```sql
   select public.definir_admin('votre-adresse@exemple.com');
   ```

   Ce compte ouvre désormais `admin.html`. Il n'a pas de code client. Faites de même pour chaque membre de l'équipe (un compte créé sur la page *Créer un compte* du site convient aussi). Pour retirer l'accès :

   ```sql
   update public.clients set role = 'client', code = public.nouveau_code_client()
   where email = 'adresse@exemple.com';
   ```

5. **Reliez le site** : l'adresse du projet (*Project URL*, ex. `https://abcdefgh.supabase.co`) figure sur la page d'accueil du projet (bouton *Copy*) ; la clé publique est dans *Project Settings* > *API Keys*, bloc *Publishable key*. Collez-les dans `assets/js/config.js` :

   ```js
   supabaseUrl: 'https://abcdefgh.supabase.co',
   supabaseKey: 'sb_publishable_…'
   ```

   Cette clé est publique : elle est faite pour être visible dans le site. N'utilisez **jamais** les clés secrètes (*Secret keys*, `sb_secret_…`, ou l'ancienne *service_role*).
6. **Adresse du site** (à la mise en ligne) : *Authentication* > *URL Configuration* : *Site URL* = l'adresse de votre site (ex. `https://www.goshipexpress.com`) et, dans *Redirect URLs* (*Add URL*), ajoutez `https://www.goshipexpress.com/**`. Les liens envoyés par e-mail mèneront alors au bon endroit.
7. **E-mails « mot de passe oublié »** (recommandé) : pour que vos clients reçoivent le lien de réinitialisation, renseignez les accès SMTP de Brevo (voir « Activer l'envoi des e-mails ») dans *Authentication* > *Emails* > *SMTP Settings* : *Enable custom SMTP*, adresse et nom de l'expéditeur, *Host* `smtp-relay.brevo.com`, *Port number* `587`, *Username* et *Password* (clé SMTP), puis *Save changes*. Ajoutez aussi `http://localhost:8000/**` dans *Redirect URLs* (étape 6) pour vos essais sur ordinateur. Avec une adresse d'expédition Gmail, gardez **Confirm email** désactivé : les e-mails de confirmation risqueraient d'arriver dans les spams ; réactivez-le une fois votre domaine authentifié chez Brevo.

Bon à savoir :

- La sécurité est assurée par la base elle-même : un client ne voit que ses propres colis, et seuls les administrateurs peuvent enregistrer ou modifier des colis, même en contournant le site.
- Depuis 2026, Supabase n'ouvre plus automatiquement les nouvelles tables au site : le script accorde lui-même les droits nécessaires. Si un message « permission denied for table … » apparaît, relancez simplement le script.
- Un client qui n'a pas Internet peut être inscrit par l'équipe : déconnectez-vous, créez son compte sur la page *Créer un compte* avec son e-mail, puis transmettez-lui son code.
- Sur l'offre gratuite, Supabase met en pause un projet resté 7 jours sans aucune activité (il suffit de le réactiver depuis supabase.com). Avec une activité quotidienne, cela n'arrive pas ; l'offre Pro supprime cette limite.
- Les données se consultent et s'exportent depuis Supabase (*Table Editor* : tables `clients`, `colis`, `colis_historique`).

## Les langues

Chaque page a sa version dans chaque langue, à la même adresse dans un sous-dossier : `a-propos.html` (français), `en/a-propos.html`, `es/a-propos.html`, `ht/a-propos.html`. Le sélecteur « Langue » de l'en-tête (drapeau + liste déroulante) passe d'une version à l'autre sans quitter la page.

Les pages françaises servent de référence : les versions traduites sont **générées** à partir d'elles et des dictionnaires `outils/traductions/en.json`, `es.json` et `ht.json`. Ne modifiez donc pas directement les fichiers des dossiers `en/`, `es/` et `ht/` : ils seraient écrasés à la prochaine génération.

### Modifier un texte

1. Modifiez le texte dans la page française.
2. Dans chaque dictionnaire, remplacez l'ancienne entrée par la nouvelle (clé = texte français exact, valeur = traduction).
3. Régénérez les pages traduites :

```bash
python3 outils/traduire.py
```

L'outil indique les textes sans traduction (ils restent alors en français dans les autres langues). Pour en obtenir la liste :

```bash
python3 outils/traduire.py --manquants
```

Dans les dictionnaires, `{1}…{/1}` entoure une mise en forme (gras, lien, couleur) et `{br}` marque un retour à la ligne : chaque traduction doit reprendre exactement les mêmes repères. Les repères nommés comme `{date}`, `{code}` ou `{email}` sont remplacés par le script et doivent eux aussi être conservés. Une nouvelle page française est prise en compte automatiquement.

Les messages de l'espace client (statuts, erreurs…) figurent en bas de chaque page de compte, dans un bloc `<template data-textes>`, et se traduisent comme le reste. Ceux du reste du site (confirmations, messages WhatsApp pré-remplis) sont dans `assets/js/site.js` (objet `TEXTES`). Le tableau de bord n'existe qu'en français.

### Nom de domaine

Une fois l'adresse du site connue, renseignez-la dans `assets/js/config.js` (`siteUrl`, pour les liens des e-mails et des messages WhatsApp) et dans `outils/traduire.py` (`SITE_URL = 'https://www.votre-domaine.com'`), puis relancez l'outil : il ajoute les balises `hreflang` qui indiquent à Google les versions de chaque page, et crée le fichier `sitemap.xml` (sans les pages privées). Ajoutez ensuite la ligne `Sitemap: https://www.votre-domaine.com/sitemap.xml` dans `robots.txt`.

## Formulaires et WhatsApp

Réglages dans `assets/js/config.js`. Par défaut, tout passe par WhatsApp au +1 849 538-6262, dans la langue du visiteur :

- **Demande de devis** (Contacts) : WhatsApp s'ouvre avec un message pré-rempli des réponses du visiteur, qui n'a plus qu'à appuyer sur Envoyer.
- **Suivi de colis** (Accueil) : sans espace client actif, WhatsApp s'ouvre avec la référence du colis.
- **Inscription aux conseils** (Blog) : WhatsApp s'ouvre avec l'adresse e-mail du visiteur.

Pour recevoir les devis et les inscriptions par e-mail à la place, créez un formulaire gratuit sur https://formspree.io puis collez son adresse dans `assets/js/config.js` :

```js
formEndpoint: 'https://formspree.io/f/votre-identifiant'
```

L'objet des e-mails reçus est en français et indique la langue du visiteur (`[EN]`, `[ES]`, `[HT]`…). Le numéro WhatsApp se modifie au même endroit (`whatsapp`).

## Animations

Discrètes et désactivées automatiquement si le visiteur a demandé à réduire les animations dans son système :

- **Apparition au défilement** : titres de section, colonnes et cartes apparaissent en fondu quand ils arrivent à l'écran (un bloc peut en être exclu avec l'attribut `data-no-reveal`).
- **Parallaxe** : la photo de fond du haut de chaque page et les éléments flottants de l'accueil (attribut `data-parallax`, dont la valeur règle la vitesse) se décalent légèrement au défilement, sur ordinateur et tablette.
- **Survol** : boutons plus doux, légère pression au clic, flèches qui avancent, trait orange sous les liens du menu, photos du blog qui s'agrandissent lentement.
- **Curseur** (souris uniquement) : halo orange qui suit la souris sur les bandeaux sombres, boutons principaux légèrement attirés par le curseur.

## Modifier le site

**Les pages à la racine sont fabriquées, pas écrites à la main.** Les modifier directement ne sert à rien : la prochaine génération les écrasera. Tout passe par `outils/generateur/` :

```bash
python3 outils/generateur/build.py   # les pages françaises
python3 outils/traduire.py           # en/, es/, ht/
```

Les deux commandes vont ensemble, dans cet ordre. Les sources sont la maquette (`outils/generateur/export/`) et les pages écrites à la main (`outils/generateur/pages/` : espace client et tableau de bord). Voir `outils/generateur/LISEZ-MOI.md`.

Après chaque changement, relancez les deux commandes **deux fois** : la seconde ne doit rien modifier (`git status` vide). C'est ce qui prouve que le site se reconstruit à l'identique.

## Application mobile (iPhone et Android)

Le dossier `application-mobile/` contient l'application GoShip Express. Elle utilise **le même
projet Supabase que le site** : quand vous changez un statut dans le tableau de bord, le client
le voit aussitôt dans l'application et reçoit une notification sur son téléphone.

### Sa promotion sur le site

L'application est annoncée à deux endroits de la page d'accueil :

- **la bannière du haut** : deux petits boutons de boutique sous « Obtenir un devis gratuit »,
  précédés de la mention « Application mobile » (styles `.gs-hero-app` et `.gs-store--mini`) ;
- **la section « Vos colis dans votre poche »** (`#application`), placée juste après « Un colis
  suivi, un client rassuré » pour que le visiteur la voie tôt : le titre, le texte et les deux
  boutons au centre, puis **trois téléphones** côte à côte, celui du milieu un peu plus grand
  et un peu plus haut, et un trajet en pointillés au bas de la section.

Les trois écrans montrés sont **les vrais écrans de l'application** : le suivi d'un colis,
l'accueil et la pré-alerte. Ce ne sont ni des photos ni des captures : ils sont dessinés aux
mesures de l'application, avec ses couleurs et ses polices, par `outils/ecrans-app/ecrans.py`.
Une commande suffit pour les refaire quand l'application évolue — voir
`outils/ecrans-app/LISEZ-MOI.md`.

Les trois téléphones restent côte à côte sur mobile, simplement plus petits : leur largeur est
une part de la rangée et non de la fenêtre, donc la rangée ne peut pas déborder. Autour d'eux
flottent quelques éléments décoratifs — les pastilles USA, HT et DO de vos trois corridors, un
avion en papier, une boucle, des points — qui ne paraissent qu'au-delà de 1100 px de large, là
où il reste de la place à côté des téléphones. Styles `.gs-app`, `.gs-tel` et `.gs-decor` dans
`site.css` ; markup dans `section_application()` (`build.py`). Le fond de cette section est un
bleu un peu plus sombre que le reste du site : sans cela l'en-tête des écrans, qui a le même
bleu nuit, se confondrait avec la page.

Toutes les autres sections du site portent le même fil en pointillés, posé en image de fond
(`poser_traces()` dans `build.py`, classes `.gs-trace--clair` et `.gs-trace--sombre`) : clair sur
les sections bleues, gris sur les sections claires.
Ils restent donc nets sur tous les écrans, se traduisent avec le reste du site et ne pèsent rien
à charger. Sur tablette le troisième téléphone s'efface, sur téléphone il n'en reste qu'un.

**Tant que l'application n'est pas publiée**, les quatre boutons affichent « Bientôt sur » et ne
mènent nulle part. Le jour de la publication, collez les deux adresses dans `assets/js/config.js` :

```
appStoreLien: 'https://apps.apple.com/app/…',
googlePlayLien: 'https://play.google.com/store/apps/details?id=com.goshipexpress.app',
```

Les boutons deviennent alors de vrais liens et affichent « Disponible sur » ; la phrase d'attente
disparaît d'elle-même. Pensez aussi à remplacer les deux logos dessinés (`LOGO_PLAY` et
`LOGO_POMME` dans `build.py`) par les **badges officiels** d'Apple et de Google : les deux
boutiques les fournissent et demandent qu'on utilise les leurs dès que l'application est en ligne.

**Avant le premier essai**, ouvrez le SQL Editor de Supabase et exécutez `outils/supabase-application.sql`
(il ajoute les pré-alertes, les factures, les notifications du téléphone et les nouveaux statuts de colis ;
il peut être relancé sans risque).

**Essayer l'application sur votre téléphone :**

1. Installez **Expo Go** (Play Store sur Android, App Store sur iPhone).
2. Double-cliquez sur `application-mobile/Voir l'application.command`.
3. Scannez le QR code affiché : avec l'application Expo Go sur Android, avec l'appareil photo sur iPhone.
   Le téléphone et le Mac doivent être sur le même réseau Wi-Fi.

**Ce que contient l'application :** connexion et création de compte, accueil avec l'adresse de
Miami (copier / partager), liste des colis avec recherche et filtres, détail avec les étapes,
pré-alerte avec scan du code-barres, factures, agences et compte (langue, notifications,
déconnexion). Quatre langues, comme le site.

**Organisation des fichiers :** `app/` un fichier par écran, `components/` les éléments
réutilisés, `lib/` la connexion à Supabase, les traductions et les formats, `config.js` l'adresse
de Miami, le téléphone et les agences, `assets/` le logo et les icônes.

**Pour publier sur l'App Store et le Play Store** (étape suivante, quand l'application vous
convient) : un compte Apple Developer (99 $ par an), un compte Google Play (25 $ une fois) et un
compte Expo gratuit, qui fabrique les deux versions sur ses serveurs.

## Étiquettes, QR codes et codes-barres

Chaque colis enregistré a déjà tout ce qu'il faut pour son étiquette : son numéro
(`GSE-1001-HT`) est unique, et c'est de lui que sont tirés son code-barres et son QR code.
Rien à créer, rien à saisir — l'étiquette s'imprime en un clic depuis le tableau de bord.

**L'étiquette** fait 4 × 6 pouces, le format des imprimantes à étiquettes. On y trouve le logo
Goship Express, le code-barres du numéro et le numéro en gros, le destinataire avec son code
client, son adresse et son téléphone, le pays et la ville de destination en très gros caractères
(c'est ce qu'on lit en triant les sacs), puis le contenu du colis : description, poids, magasin
et numéro de suivi du vendeur.

**La ville de destination est celle que le client a choisie en s'inscrivant** — `HT` ·
`PORT-AU-PRINCE`, `HT` · `CAP-HAÏTIEN`, `DO` · `SANTO DOMINGO ESTE` — car c'est là qu'il vient
chercher ses colis. La ville saisie sur le colis ne sert que si le compte n'en porte aucune.

L'adresse de l'expéditeur n'y figure plus : elle était toujours la même — la nôtre — et
n'apprenait rien à personne, alors que le contenu du carton se vérifie à chaque étape. Elle reste
écrite aux clients dans « Mon compte » et dans l'application.

Le papier ayant une taille fixe, un texte trop long est **coupé** au lieu de pousser le reste
hors de l'étiquette : un nom sur deux lignes au plus, une adresse sur deux lignes, un contenu sur
deux lignes. Le numéro, le code-barres et la destination ne sont jamais rognés — ce sont eux dont
le transporteur a besoin ; une ville aussi longue que « Petite Rivière de l'Artibonite » passe
simplement sur deux lignes.

### Dessinée pour une imprimante thermique

L'étiquette est faite pour une **thermique directe** (Y812BT ou semblable : 203 dpi, 180 mm/s,
noir ou blanc, sans encre ni ruban). Trois choses en découlent, et il vaut mieux les connaître
avant de modifier le dessin.

- **Aucun gris, aucune couleur pâle.** Une thermique ne connaît que le noir et le blanc : tout
  aplat clair serait remplacé par une trame de points, qui brouille les petits textes sans rien
  économiser. Ce qui distingue un texte d'un autre, sur l'étiquette, c'est sa taille et sa
  graisse — jamais sa couleur.
- **Les aplats noirs restent petits.** À 180 mm/s, une grande surface noire ralentit la machine,
  chauffe la tête d'impression et bave sur le papier. Seuls le service (AÉRIEN, MARITIME…) et le
  code du pays sont en blanc sur noir : environ 4 cm² en tout, mais ce sont eux qu'on repère d'un
  mètre en triant les sacs.
- **Rien de plus fin qu'un point.** À 203 dpi, un point fait 0,125 mm : un filet de 0,6 pt
  disparaît par endroits et un texte de 6 pt devient illisible. D'où le 8 pt minimum et les
  filets d'au moins 1 pt.

Le logo de l'étiquette est `assets/img/logo-goship-noir.png`, une version entièrement noire
obtenue à partir de `logo-goship-blanc.png` (mêmes formes, couleur remplacée par du noir). Le
logo en couleurs sortirait en pointillés. La facture, elle, part sur une imprimante ordinaire et
garde le logo en couleurs.

Le même dessin sort très bien d'une laser ou d'un jet d'encre : du noir sur du blanc convient
partout.

- **Le code-barres** est un **Code 128**, celui des étiquettes d'expédition dans le monde entier.
  N'importe quelle douchette de magasin le lit. Les chiffres y sont écrits deux par deux, ce qui
  raccourcit le code : à largeur égale, les barres sont plus larges, donc plus faciles à lire.
- **Le QR code** mène à la page de suivi du colis (`index.html?suivi=GSE-1001-HT`) dès que
  l'adresse du site est renseignée dans `assets/js/config.js` (`siteUrl`). Tant qu'elle est vide,
  il contient le numéro du colis tout court, ce qui suffit à le retrouver. Il est calculé avec le
  niveau de correction **M** : un coin plié ou une trace de pluie n'empêchent pas la lecture.

Les deux sont **calculés dans la page**, sans bibliothèque et sans service extérieur : aucun
numéro de colis ne sort du site, et les codes sont dessinés en SVG, donc nets à l'impression —
une image floue ne passerait pas au scanner. Le calcul est dans `assets/js/codes.js`, et il est
comparé module par module à deux bibliothèques de référence par
`outils/essais-codes/essai-codes.py` (voir `outils/essais-codes/LISEZ-MOI.md`).

**La facture imprimée** sort sur une page A4, avec le logo, l'adresse de Goship Express S.R.L,
les coordonnées du client, le détail ligne par ligne, le total, le moyen de paiement et — si un
lien de paiement est prêt — un QR code « Scannez pour payer ». Elle s'imprime **dans la langue du
client** (français, anglais, espagnol, créole) : les textes sont dans `assets/js/impression.js`,
comme ceux des e-mails sont dans `notifications.js`. L'étiquette, elle, reste en français : c'est
un papier interne, imprimé à Miami.

L'impression passe par une page séparée avec sa propre feuille de style
(`assets/css/impression.css`) : c'est ce qui permet de fixer la taille du papier — 4 × 6 pouces
pour une étiquette, A4 pour une facture — sans que le style du site s'en mêle. La fenêtre
d'impression du navigateur sert d'aperçu ; on peut aussi y choisir « Enregistrer au format PDF ».

## Les règles métier

Les règles qui comptent — le prix d'un colis, l'ordre des statuts, qui peut faire quoi, une seule facture par colis — sont appliquées **par la base de données**, et non par les pages. Une page se modifie en trois clics dans la console d'un navigateur ; la base, non. Le site, l'application mobile et les outils à venir (scanner, poste de bureau) obéissent ainsi aux mêmes règles, qu'ils le veuillent ou non.

**À installer**, dans cet ordre : Supabase > *SQL Editor* > *New query* > coller le fichier > *Run*, pour `outils/supabase.sql`, `outils/supabase-facturation.sql`, `outils/supabase-services.sql`, `outils/supabase-evenements.sql`, `outils/supabase-scanner.sql`, puis `outils/supabase-finances.sql`. Tous sont sans risque et relançables. **Copiez-les depuis GitHub avec le bouton « Copy raw file »** : un aperçu n'affiche souvent que les premières lignes, et un fichier coupé échoue avec « unterminated dollar-quoted string ». **Lancez-les avant de mettre en ligne la nouvelle version du site** : sans eux, le tableau de bord affiche « La base n'est pas à jour » au lieu d'enregistrer. Contrôles attendus : `services_sur_5 = 5` et `regles_sur_6 = 6` à la fin de `supabase-services.sql` ; `moteur_sur_8 = 8`, `gardes_sur_3 = 3` et `colonnes_sur_8 = 8` à la fin de `supabase-evenements.sql` ; `finances_sur_9 = 9`, `gardes_sur_6 = 6` et `factures_sans_paiement = 0` à la fin de `supabase-finances.sql`. Si `suivi_unique` vaut 0, c'est que des colis partagent déjà un numéro de suivi vendeur (`suivis_en_double` dit combien) : la règle vaut quand même pour tous les nouveaux colis, mais la base ne peut pas encore la rendre absolue. Pour les retrouver : `select suivi_transporteur, string_agg(numero, ', ') from colis where suivi_transporteur <> '' group by 1 having count(*) > 1;` — corrigez-les, puis relancez le fichier.

### Ce que la base garantit

- **Le prix.** Poids × tarif, arrondi au cent, calculé par la base. Le prix envoyé par une page est ignoré. Il est recalculé seulement si le poids ou le tarif du colis change ; une facture déjà émise, elle, ne bouge jamais. Tarif de la maison 5 $/lb (remplaçable colis par colis, de 0 à 1 000 $), frais de service 10 $ une fois par facture.
- **Les données du colis.** Un vrai client (pas un compte de l'équipe), un contenu décrit, un poids supérieur à zéro (et inférieur à 10 000 lb, au-delà c'est une faute de frappe), un service et une destination connus, une date de réception qui n'est pas dans le futur. Un numéro de suivi vendeur ne sert qu'à un seul colis.
- **Les statuts.** Un colis naît « Reçu ». Ensuite :

  ```
  Reçu → (Emballé) → Embarqué → (Centre de distribution) → (Transféré à la succursale) → Disponible → Livré
  ```

  Les étapes entre parenthèses peuvent être sautées ; les autres non. En particulier, « Livré » exige « Disponible » : c'est à ce moment que le client est prévenu. « Action requise » peut interrompre tout colis non livré ; il en sort en revenant à son étape, ou en passant à une étape qui l'aurait suivie. « Disponible » exige le nom de l'agence. **« Livré » est final.** Une erreur de saisie se corrige en revenant à l'étape précédente du colis (« Livré » par erreur redevient « Disponible »), mais seulement comme **correction** : le tableau de bord demande alors un motif, noté au journal avec le nom de celui qui corrige. Voir « Les événements ».
- **Tout ou rien.** Le changement de statut et son étape dans l'historique sont écrits ensemble : jamais l'un sans l'autre. Un colis et sa facture aussi. Pour un lot, si un seul colis bloque, aucun ne change.
- **Pas de doublon.** Un double clic, un envoi répété après une coupure, un scan répété : la base reconnaît la demande et ne refait rien (pas de second colis, pas de seconde facture, pas d'étape en double). Un colis ne figure que sur une facture active ; pour le refacturer, annulez d'abord l'ancienne.
- **Deux personnes à la fois.** Si un collègue a changé le colis pendant que vous le regardiez, la base refuse votre modification au lieu d'écraser la sienne, et le dit.
- **Une facture émise est arrêtée.** Ses frais de service, son client, son numéro, ses lignes et, si elle porte des colis, son total ne se modifient plus. L'échéance, la note et le lien de paiement, si. Son payé et son statut suivent ses paiements (voir « Les finances »).
- **Le journal.** Chaque création, modification, changement de statut, paiement et modification de client est noté dans la table `journal_audit` : qui, quoi, quand, avant, après. Pour un client, seul le nom des champs modifiés est noté, jamais son adresse ni son téléphone. Seule l'équipe le lit ; personne ne peut y écrire.
- **Les permissions.** Chaque fonction vérifie la permission du compte connecté (`shipments.create`, `shipments.update_status`, `invoices.create`…), en plus des règles de sécurité des tables. Aujourd'hui, deux rôles : l'équipe peut tout, un client ne voit que ce qui est à lui. La liste est dans `permissions_du_role`, le seul endroit à changer quand viendront des rôles plus fins.

### Les événements

Le **statut** d'un colis dit où il en est, en un mot : c'est lui que voit le client. Son **historique** dit tout ce qui lui est arrivé. Chaque ligne de l'historique est un **événement** : son type, le statut avant et après, qui l'a fait (le compte connecté, jamais un nom envoyé par une page), où, quand (l'heure de la base), le message pour le client et des précisions (numéro de conteneur, raison d'une action requise…).

Tous les événements ne changent pas le statut. Un colis peut être *inspecté*, *consolidé*, *chargé* dans un conteneur et rester « Reçu » : ces opérations internes sont notées pour l'équipe, jamais montrées au client ni au suivi public.

| Événement | Statut après | Vu par le client |
|---|---|---|
| `COLIS_RECU` | Reçu (à la création) | oui |
| `COLIS_INSPECTE`, `COLIS_CONSOLIDE`, `COLIS_CHARGE` | inchangé (Reçu ou Emballé seulement) | non |
| `COLIS_EMBALLE` | Emballé | oui |
| `COLIS_EXPEDIE` | Embarqué | oui |
| `COLIS_ARRIVE` | Centre de distribution | oui |
| `COLIS_TRANSFERE` | Transféré à la succursale | oui |
| `COLIS_DISPONIBLE` | Disponible (agence obligatoire) | oui |
| `COLIS_LIVRE` | Livré | oui |
| `ACTION_REQUISE` | Action requise | oui |
| `ACTION_RESOLUE` | l'étape d'avant, ou une suivante | oui |
| `CORRECTION` | l'étape d'avant (motif obligatoire) | non ; l'étape annulée disparaît de sa vue |
| `MISE_A_JOUR` | inchangé (lieu ou message corrigé) | oui |

- **Le statut ne change que par un événement.** Une seule porte, `executer_operation` : elle verrouille le colis, vérifie la transition, écrit l'événement et change le statut dans la même transaction. Toute autre tentative de changer le statut — une ancienne page, une écriture directe, même le SQL Editor — est refusée.
- **Un événement est un fait.** Il ne se modifie pas et ne s'efface pas. Une erreur se corrige par un nouvel événement, qui dit ce qu'il annule ; l'original reste lisible par l'équipe.
- **Le même scan deux fois** ne fait qu'un événement : avec la même clé de requête, ou quand l'opération vient d'être faite à l'identique. Deux postes qui scannent le même colis en même temps : le second attend le premier, puis reçoit son résultat — ou un conflit, s'il voulait faire autre chose.
- **Les colis d'avant** gardent leur historique tel quel. Aucun événement n'est inventé pour remplir le passé : leurs anciennes lignes restent simplement sans type.

Pour le futur scanner, tout est prêt côté base : `executer_operation_par_reference` (le numéro scanné, GSE ou vendeur), `operations_possibles` (les boutons à proposer), `historique_colis`, `dernier_evenement`, `rechercher_evenements`.

### Le poste de scan

L'onglet **Scanner** du tableau de bord (ou directement `admin.html#scanner`) transforme un ordinateur de l'entrepôt ou de l'agence en poste de scan.

- **Le matériel.** N'importe quel scanner de codes-barres USB ou Bluetooth réglé en mode **clavier** (HID, « keyboard wedge » — le réglage d'usine de la plupart). Il tape le code lu puis Entrée ; rien à installer, fonctionne sous Windows et macOS, dans Chrome et Edge. Un scanner réglé sans touche Entrée marche aussi : son code part tout seul après un court silence. Un scanner réglé en QWERTY sur un poste AZERTY est reconnu et corrigé.
- **Ce qu'il lit.** Les codes déjà imprimés, sans rien changer : le **code-barres** de l'étiquette (le numéro GSE), son **QR code** (le lien de suivi), et le **numéro de suivi du vendeur** sur le carton (Amazon, UPS, USPS…). Le QR d'une facture (lien de paiement) est refusé.
- **Mode normal.** Chaque scan affiche le colis — client, contenu, poids, destination, statut, dernier événement, lieu — et les seules opérations que la base permet à ce moment. Un changement de statut se confirme d'un clic ; une opération interne (inspecter, consolider, charger) part directement. « Action requise » demande sa raison.
- **Mode rapide.** On choisit une opération (ex. « Expédié »), puis chaque colis scanné est enregistré ainsi, sans question — la base refuse ce qui ne suit pas le parcours. Idéal pour un lot qui part ou qui arrive.
- **Le lieu du poste** est noté sur chaque événement (« Miami (Medley), FL », une agence…). Il est gardé sur cet ordinateur.
- **Aucun faux succès.** « ✓ » ne s'affiche qu'après la réponse de la base. Sans connexion, le poste affiche « Connexion impossible » et propose « Réessayer » : la même demande repart avec la même clé, donc jamais deux fois. Un colis scanné deux fois de suite, ou par deux postes en même temps, ne fait qu'un événement (« Déjà fait »).
- **Un numéro inconnu** n'enregistre rien et ne crée aucun colis : la réception d'un nouveau colis se fait par « Enregistrer un colis ».

Pour essayer sans scanner : tapez le numéro dans le champ et appuyez sur « Rechercher » — c'est exactement le même chemin.

### Les erreurs

Quand la base refuse, elle répond par un code et une phrase en français, que le tableau de bord affiche telle quelle :

| Code | Quand |
|---|---|
| `PERMISSION_DENIED` | le compte n'a pas le droit (affiché « Accès refusé ») |
| `CLIENT_NOT_FOUND`, `SHIPMENT_NOT_FOUND` | client ou colis introuvable |
| `INVALID_WEIGHT`, `INVALID_RATE`, `INVALID_DESCRIPTION`, `INVALID_SERVICE`, `INVALID_DESTINATION`, `INVALID_DATE`, `INVALID_AMOUNT`, `INVALID_INPUT` | donnée refusée |
| `INVALID_STATUS`, `INVALID_STATUS_TRANSITION`, `LOCATION_REQUIRED` | statut inconnu, transition interdite, agence manquante |
| `STATUS_CONFLICT`, `CONCURRENT_MODIFICATION` | quelqu'un d'autre a changé le colis entre-temps |
| `TRACKING_ALREADY_EXISTS` | numéro de suivi vendeur déjà utilisé |
| `DUPLICATE_OPERATION` | une demande déjà traitée, rejouée pour un autre client |
| `INVOICE_ALREADY_EXISTS`, `INVOICE_CLIENT_MISMATCH`, `INVOICE_LOCKED` | colis déjà facturé, colis d'un autre client, facture arrêtée |
| `EVENT_TYPE_INVALID`, `INVALID_EVENT_DATA`, `INVALID_LOCATION` | événement inconnu, précisions refusées (ou motif de correction manquant), lieu trop long |
| `STATUS_ALREADY_SET` | le colis est déjà à ce statut |
| `EVENT_IMMUTABLE` | tentative de modifier ou d'effacer un événement |
| `INVALID_SCAN_FORMAT` | code scanné illisible (refusé par la page avant même d'interroger la base) |
| `OVERPAYMENT`, `INVOICE_ALREADY_PAID`, `INVOICE_CANCELLED` | paiement plus grand que le reste, facture déjà soldée, facture annulée |
| `INVALID_PAYMENT_METHOD`, `DUPLICATE_PAYMENT` | moyen inconnu, même référence déjà saisie sur la facture |
| `PAYMENT_LOCKED`, `PAYMENT_REQUIRED` | un paiement ne se modifie ni ne s'efface ; le payé d'une facture ne s'écrit pas à la main |
| `REASON_REQUIRED`, `INVOICE_HAS_PAYMENTS`, `INVOICE_NOT_GROUPABLE` | motif d'annulation manquant ; facture qui a reçu de l'argent ; facture qui ne se regroupe pas |
| `INVOICE_DELETE_FORBIDDEN`, `INVOICE_NUMBER_USED`, `INVOICE_NOT_FOUND`, `PAYMENT_NOT_FOUND` | une facture s'annule au lieu de se supprimer ; numéro déjà attribué ; facture ou paiement introuvable |

Les refus de permission et les transitions interdites sont aussi notés dans les journaux de Supabase (*Logs* > *Postgres*, chercher « goship »), sans aucune donnée secrète.

### Pour les développeurs

Les fonctions appelées par le site : `creer_colis`, `modifier_colis`, `trouver_colis`, `facturer_colis`, `creer_facture` (`supabase-services.sql`) ; `changer_statut_colis`, `statuts_possibles`, `historique_colis` (`supabase-evenements.sql`) ; `enregistrer_paiement`, `annuler_paiement`, `annuler_facture`, `regrouper_factures`, `calculer_facture`, `resume_facturation`, `rapport_anomalies_facturation`, `mes_factures`, et les colonnes calculées `paye_usd`, `solde_usd`, `etat_paiement` (`supabase-finances.sql`). Le suivi public reste `suivre_colis`. Côté site, rien ne change dans les noms : `API.admin.creerColis`, `changerStatut`… appellent ces fonctions. Le mode démonstration applique les mêmes règles dans le navigateur, et `outils/essais-services/` vérifie que les deux répondent pareil, cas par cas.

**Plus tard** : quand l'application mobile aura été vérifiée (elle ne doit pas écrire dans la table `colis`), la fin de `supabase-services.sql` contient, prêtes à l'emploi, les deux lignes qui ferment l'écriture directe dans les tables : il ne restera alors que les fonctions comme porte d'entrée.

## Paiement des factures

Les factures se créent dans le tableau de bord (onglet **Factures**) : code client, colis à
facturer, montant, date limite et note. Le client les retrouve dans **« Mon compte »** sur le site
et dans l'application, avec un bouton **« Payer par carte »** et un bouton pour imprimer la facture
ou l'enregistrer en PDF.

Le lien de paiement vient de `assets/js/config.js` :

- **`carteLien`** — collez ici le lien de paiement d'Azul (ou d'un autre encaisseur) dès que votre
  contrat commerçant est actif. Ce lien devient alors le bouton de paiement partout.
- **`carteEmail`** — tant que `carteLien` est vide, le tableau de bord fabrique un lien PayPal avec
  cette adresse et le montant de la facture.

Dans l'application, les mêmes réglages sont dans `application-mobile/config.js` (`paiement`), avec
les autres moyens affichés au client : compte bancaire, Azul, MonCash, NatCash — leurs numéros
restent à renseigner. Après son paiement, le client envoie son reçu sur WhatsApp et vous
l'**encaissez** dans le tableau de bord (bouton « Encaisser ») : montant reçu, moyen, date,
référence du reçu. Un acompte laisse la facture « Payée en partie » ; elle devient « Payée »
quand le reste est encaissé. Après un acompte, le lien PayPal fabriqué par le tableau de bord
demande le reste, plus le total.

## Les finances

Depuis `outils/supabase-finances.sql` (Phase 5), **chaque paiement est une ligne** de la table
`paiements` — montant, moyen, référence, date, qui l'a saisi — et c'est la base qui fait les
comptes :

- **Payé = somme des paiements valides ; reste à payer (solde) = total − payé.** Calculés par la
  base (`paye_usd`, `solde_usd`), jamais par une page. Le statut stocké reste l'un des trois
  d'avant (à payer, payée, annulée) et suit les paiements ; l'**état** affiché en ajoute deux,
  déduits : **payée en partie** et **en retard** (échéance dépassée — date de Santo Domingo — et
  solde > 0).
- **Pas de trop-payé, pas de double paiement.** Un paiement supérieur au reste est refusé ; deux
  paiements envoyés au même instant passent l'un après l'autre (la facture est verrouillée) et le
  second voit le premier ; un double clic ou un renvoi après coupure ne crée rien de plus (clé de
  la demande) ; la même référence ne se saisit pas deux fois sur une facture.
- **Rien ne s'efface.** Un paiement ne se modifie ni ne se supprime : une erreur s'**annule**,
  avec son motif, et reste visible, barrée. Une facture ne se supprime plus : elle s'annule avec
  son motif, garde son numéro, et ses colis redeviennent facturables. Une facture qui a reçu de
  l'argent ne s'annule qu'après l'annulation de ses paiements.
- **Un numéro ne sert qu'une fois** (registre `factures_numeros`), même si la facture disparaît
  avec le compte de son client.
- **Regrouper** : plusieurs factures de colis d'un même client, à payer et sans paiement, en une
  seule. Les anciennes sont annulées (motif et renvoi vers la nouvelle) ; la nouvelle reprend les
  colis au prix déjà arrêté, avec les 10 $ de frais une seule fois.
- **Le tarif est gardé** sur chaque ligne (`tarif_lb_usd`), en plus du colis : une facture dit
  toujours à quel prix la livre elle a été faite, même après un changement de tarif.
- **Le journal** note chaque paiement, annulation et regroupement (qui, quand, motif) ; la file
  `evenements_facturation` prépare de futures notifications (FACTURE_CREEE, PAIEMENT_ENREGISTRE,
  PAIEMENT_ANNULE, FACTURE_PAYEE, FACTURE_ANNULEE) — rien ne les envoie encore.
- **Le client** ne voit que ses factures et ses paiements (règles de sécurité), et n'en écrit
  aucun.
- **Le contrôle** (`rapport_anomalies_facturation`, bouton « Contrôler ») signale les colis
  facturés deux fois, les totaux faux, le payé différent des paiements, l'argent sur une facture
  annulée, les colis repesés après leur facture… Il ne corrige **rien** : une facture remise à un
  client ne se réécrit pas en silence.

Les anciennes factures ne changent pas : leur montant payé devient un paiement « repris », daté
du jour où elles avaient été marquées payées, et leur total, leur payé et leur statut restent au
centime près ce qu'ils étaient.

**Attention, PayPal** : le paiement par carte sans compte PayPal exige un compte **Business** avec
l'option « PayPal account optional » activée. Avec un compte personnel, la page demande au client
de se connecter ou de créer un compte.

### Ce que porte la facture imprimée

- **L'émetteur, en tête** : Goship Express S.R.L, Calle 25 de Febrero La Caleta, Santo Domingo
  Este 11500, son téléphone et son **RNC**. C'est l'établissement dominicain qui facture, et non
  la société américaine : celle-ci ne fait que recevoir à Miami les achats des clients.
- **Le numéro** : année, mois, puis quatre chiffres tirés au hasard — `2026-09-0417`. 10 000
  numéros par mois, et le compteur repart à chaque mois. Le tirage est borné à 200 essais et lève
  une erreur explicite plutôt que de tourner sans fin sur un mois saturé. Voir
  `outils/supabase-numero-facture.sql`. Les factures déjà remises gardent leur ancien numéro
  (`FAC-2026-0003`) : c'est celui que le client a sous les yeux.
- **Une ligne par colis** : quantité, poids en livres, description, numéro du colis et total. Le
  poids est celui recopié sur la ligne au moment de la facture ; pour les factures d'avant cette
  recopie, celui du colis prend le relais. Sous le numéro du colis, le **tarif à la livre** du
  jour de la facture, quand il est connu.
- **Les totaux** : total colis, frais de service, grand total, **déjà payé** (dès qu'un premier
  paiement est arrivé) et balance. Ce sont les chiffres de la base, les mêmes qu'à l'écran. Une
  facture payée en partie liste aussi les **paiements reçus** (date, moyen, montant) et porte
  l'état « Payée en partie » ou « En retard ».
- **Les trois moyens de paiement**, uniquement sur une facture à payer (les rappeler sur une
  facture réglée n'aiderait personne) : virement Banco BHD León, PayPal, et transfert Western
  Union / Unitransfer / Ria. Ils s'écrivent **en texte simple** — un titre, sa valeur, puis une
  ligne par information — sans cadre ni tableau. Ces coordonnées sont dans
  `assets/js/impression.js`, constante `PAIEMENTS` : un seul endroit à changer, et seuls les
  libellés (« Nom », « N° de compte »…) suivent la langue du client.
- **Deux colonnes en bas de page** : comment payer à gauche, les totaux, le QR code et la
  signature à droite. Écrits en toutes lettres, les moyens de paiement prennent de la hauteur ;
  les mettre à côté des totaux plutôt que dessous gagne environ 55 mm.
- **Une seule signature**, la nôtre : une facture n'a pas à être contresignée par le client pour
  être due.
- **Le pied de page** : « Merci pour votre confiance ! », dans la langue du client.

L'orange du logo (`#ff6a03`) porte le dessin : le titre, le filet de l'en-tête, le bandeau du
tableau, la balance et le pied de page. Il en existe une version assombrie (`#c74a00`) pour les
petits textes, où l'orange vif manquerait de contraste — même teinte, lisible à 8 pt.

Une facture de **cinq colis** tient encore sur une page, dans les quatre langues. Au-delà, elle
passe sur une seconde page, ce qui est normal ; le tableau des totaux, chaque moyen de paiement
et la signature ne sont jamais coupés en deux.

## À compléter

- **Sécurité** : les cinq réglages Supabase de la section « Sécurité » — le plus urgent étant le *Site URL*, encore réglé sur `http://localhost:3000`, et la confirmation des adresses e-mail.
- **Application mobile** : adresses des agences de Port-au-Prince et Santo Domingo, numéros de compte bancaire, Azul, MonCash et NatCash (`application-mobile/config.js`), puis publication sur les deux boutiques. Une fois publiée : `appStoreLien` et `googlePlayLien` dans `assets/js/config.js`, et les badges officiels des boutiques (voir « Sa promotion sur le site »).
- **Paiement par carte** : contrat commerçant Azul demandé ; en attendant, les factures passent par PayPal (voir « Paiement des factures »).
- **Espace client** : suivre les étapes « Activer l'espace client » ci-dessus (Supabase, puis e-mails de réinitialisation).
- **Notifications** : configurer l'envoi des e-mails (Brevo) et, si vous le souhaitez, WhatsApp automatique (voir « Prévenir les clients »). Puis exécuter `outils/supabase-bienvenue.sql` et ses deux réglages, pour les e-mails de bienvenue.
- **Codes clients** : exécuter `outils/supabase-code-client.sql` pour le passage au format court `GSE-4323` (voir « Le format des codes clients »).
- **Numéros de facture** : exécuter `outils/supabase-numero-facture.sql` pour le format `2026-09-0417`. Sans lui, les nouvelles factures continuent en `FAC-2026-0004`.
- **Factures et étiquettes** : exécuter `outils/supabase-factures.sql`. Sans lui, le client ne verra pas ses factures dans « Mon compte », et les étiquettes s'imprimeront sans l'adresse du destinataire.
- **Termes et conditions** : quatre valeurs n'ont jamais été renseignées dans le document d'origine — `[devise locale]`, `[pourcentage %]`, `[nombre de jours]` et `[montant maximal ou norme en vigueur]`.
- **Instagram et TikTok** : les icônes du pied de page n'ont pas encore de lien (`href="#top"`).
- **Nom de domaine** : voir « Nom de domaine » ci-dessus.
- **Témoignages** : sans photo dans la maquette, Marie-Ange D. et Jean-Robert P. sont représentés par leurs initiales.
