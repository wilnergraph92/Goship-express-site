# GoShip Express — l'application de bureau (Windows, macOS)

Le poste de travail de l'équipe : le tableau de bord (`admin.html`) dans une
fenêtre à lui, avec l'impression des étiquettes et des factures sur
l'imprimante choisie, le scanner, des raccourcis, un menu, des notifications
et une session chiffrée par le système.

**Ce n'est pas un second logiciel.** L'application ouvre le tableau de bord du
site, celui que l'équipe utilise déjà dans son navigateur. Même code, mêmes
comptes, mêmes permissions, même base de données :

```
            Supabase (base, règles, permissions, historique)
                              │
                   site (admin.html, assets/js)
          ┌───────────────────┼───────────────────┐
     navigateur         application de bureau    application mobile
                        (cette coquille)
```

Elle ne garde **aucune donnée métier** : ni colis, ni client, ni facture, ni
paiement. Les prix, les statuts, les soldes et les droits sont décidés par la
base, comme dans le navigateur. Une mise en ligne du site met aussi à jour ce
que montre l'application, sans la réinstaller.

Réservée à l'équipe (administrateur, gérant, employé). Un compte client qui s'y
connecte reçoit le même refus que dans le navigateur.

---

## Installer

Les installateurs sont construits par GitHub (onglet **Actions** du dépôt,
workflow « Application de bureau », rubrique *Artifacts* d'une exécution
réussie) :

| Système | Fichier | Pour |
|---|---|---|
| Windows 10 / 11 | `GoShip-Express-Setup-1.0.0-windows-x64.exe` | PC (Intel ou AMD, 64 bits) |
| macOS 12 ou plus | `GoShip-Express-1.0.0-macos-arm64.dmg` | Mac Apple Silicon (M1, M2, M3, M4…) |
| macOS 12 ou plus | `GoShip-Express-1.0.0-macos-x64.dmg` | Mac Intel |

### Windows

1. Lancez `GoShip-Express-Setup-…-windows-x64.exe`.
2. **SmartScreen** affiche « Windows a protégé votre ordinateur » : l'application
   n'est pas encore signée (voir « Signature »). Cliquez sur *Informations
   complémentaires*, vérifiez que le fichier vient bien de votre dépôt GitHub,
   puis *Exécuter quand même*. Ne désactivez pas SmartScreen.
3. L'installation se fait pour votre compte Windows, sans droits
   d'administrateur (dossier `%LOCALAPPDATA%\Programs\GoShip Express`), avec un
   raccourci sur le Bureau et dans le menu Démarrer.

Désinstaller : *Paramètres > Applications > GoShip Express > Désinstaller*. Le
journal et les préférences du poste restent dans `%APPDATA%\GoShip Express`
(effacez ce dossier pour repartir de zéro). Aucune donnée de GoShip Express
n'est touchée : elles sont sur le serveur.

### macOS

1. Ouvrez le `.dmg` qui correspond à votre Mac (menu Pomme > *À propos de ce
   Mac* : « Puce Apple » → arm64, « Processeur Intel » → x64).
2. Glissez **GoShip Express** dans *Applications*.
3. Premier lancement : **Gatekeeper** refuse une application non notarisée
   (voir « Signature »). Ouvrez *Réglages Système > Confidentialité et
   sécurité*, section *Sécurité* : « GoShip Express a été bloquée » → *Ouvrir
   quand même*. À faire une seule fois. Ne désactivez pas Gatekeeper.

Désinstaller : mettez l'application à la Corbeille. Journal et préférences :
`~/Library/Application Support/GoShip Express`.

---

## Ce que l'application ajoute au navigateur

| | |
|---|---|
| **Fenêtre dédiée** | taille et position retenues ; une seule fenêtre (relancer l'application la ramène au premier plan) |
| **Menu** | Fichier, Édition, Affichage, Fenêtre, Aide (et le menu GoShip Express sur Mac) — seulement des commandes qui existent |
| **Raccourcis** | voir ci-dessous |
| **Impression** | fenêtre « Imprimer » : aperçu exact, choix de l'imprimante retenu par format, exemplaires, PDF, message clair et « Réessayer » si l'imprimante refuse |
| **Session** | chiffrée par le système (Windows : DPAPI ; macOS : Trousseau), jamais le mot de passe |
| **Notifications** | du système, quand une alerte du tableau de bord apparaît pendant que la fenêtre est en arrière-plan (réglable) |
| **Réseau** | « Connexion perdue » ou « Service temporairement indisponible », avec « Réessayer » ; rien n'est affiché comme enregistré sans la réponse du serveur |
| **Journal** | un fichier local pour diagnostiquer une panne (menu *Aide > Ouvrir le dossier des journaux*) |

### Raccourcis

| Windows | Mac | Action |
|---|---|---|
| Ctrl + K | ⌘ K | Recherche rapide (colis, suivi, code-barres, client, téléphone, facture) |
| Ctrl + Maj + S | ⌘ ⇧ S | Poste de scan, prêt à lire |
| Ctrl + R | ⌘ R | Actualiser |
| Ctrl + , | ⌘ , | Préférences (réglages du tableau de bord) |
| Échap | Échap | Fermer une fenêtre ou un panneau |
| Entrée | Entrée | Valider un formulaire ; un scanner envoie son code avec Entrée |
| Ctrl + + / − / 0 | ⌘ + / − / 0 | Agrandir, réduire, taille réelle |
| F11 | ⌃ ⌘ F | Plein écran |

Ctrl/⌘ + K et Ctrl/⌘ + Maj + S marchent aussi dans le navigateur. Ils suivent la
lettre de la touche : même geste en AZERTY et en QWERTY.

---

## Scanner

Un scanner **USB** ou **Bluetooth** réglé en **mode clavier** (HID, le réglage
d'usine de la plupart des modèles) n'a rien à installer : il tape le code puis
Entrée. L'application ouvre le poste de scan de la Phase 4, sans rien changer :
même lecture (`scan-parser.js`), mêmes règles, même historique. Le mode rapide
enchaîne les colis sans question ; un double scan ne réécrit rien.

- **Disposition du clavier** : réglez le scanner sur la même disposition que le
  système (AZERTY France si Windows est en AZERTY). Un scanner en QWERTY sur un
  poste AZERTY tape `&é"'` au lieu de `1234`. Les notices ont un code-barres de
  réglage pour cela.
- **État du scanner** : un scanner en mode clavier se présente au système comme
  un clavier ; ni le navigateur ni l'application ne peuvent savoir s'il est
  branché. Le poste de scan affiche donc la **dernière lecture reçue** au
  rythme d'un scanner. Débrancher et rebrancher ne demande pas de relancer
  l'application.
- **Non pris en charge** : les scanners en mode port série (COM, « USB CDC »).
- Chaque opération scannée depuis l'application est notée dans l'historique du
  colis avec `poste: "bureau"`, le système et la version de l'application.

---

## Impression

Les documents sont ceux du site (`assets/js/impression.js`) : étiquette 4 × 6
pouces avec Code128 et QR, facture A4, rapport Analytics. L'application ne les
redessine pas ; elle les imprime.

1. *Étiquette* ou *Imprimer* dans le tableau de bord ouvre la fenêtre
   « Imprimer » : l'aperçu est le PDF exact qui partira.
2. Choisissez l'imprimante. Le choix est retenu **par format** : l'étiquette
   ira ensuite d'elle-même vers l'imprimante thermique, la facture vers
   l'imprimante de bureau.
3. *Imprimer* : l'application attend la réponse de l'imprimante. Si elle
   refuse (éteinte, débranchée, sans papier, pilote), le message le dit et
   le bouton devient *Réessayer*.
4. *Enregistrer en PDF* : même document, sans imprimante.

Rien ne part à l'imprimante sans cette fenêtre.

**Imprimante thermique (étiquettes 4 × 6)** : installez le pilote du fabricant
(Zebra, Rollo, MUNBYN, Brother…), réglez le papier sur 4 × 6 pouces (101,6 ×
152,4 mm) dans le pilote, imprimez une page de test. L'étiquette est envoyée au
format 4 × 6 exact (vérifié par les essais : PDF de 288 × 432 points) ; la
facture en A4 (595 × 842 points).

---

## Sécurité

- **Une seule page** : le tableau de bord du site configuré. Toute autre page
  du site (accueil, espace client) et tout lien extérieur (WhatsApp, e-mail)
  s'ouvrent dans le navigateur ; `javascript:`, `file:` et les autres schémas
  ne s'ouvrent nulle part. Pas de nouvelle fenêtre, pas de `<webview>`.
- **Page isolée** : `contextIsolation`, `sandbox`, pas de Node.js dans la page.
  Le site ne voit qu'un objet, `window.GoshipBureau` (`src/pont.js`) : lire et
  écrire la session Supabase, ouvrir « Imprimer », écrire une ligne de journal,
  recevoir les commandes du menu. Aucune commande système, aucun accès aux
  fichiers. L'application revérifie l'expéditeur de chaque message.
- **Content-Security-Policy** : celle de `_headers`, posée par l'application
  sur la page (GitHub Pages ne l'envoie pas) : pas de script injecté, pas de
  script d'un autre domaine.
- **Permissions** : notifications, presse-papiers et plein écran pour le site ;
  caméra, micro, position, USB, HID, port série refusés.
- **Pages locales** servies par `goship-app://` (pas `file://`) ; le document à
  imprimer reste en mémoire, jamais écrit sur le disque.
- **Exécutable verrouillé** (Electron *fuses*) : pas de mode Node.js, pas
  d'inspecteur, code chargé uniquement depuis l'archive signée par empreinte,
  cookies chiffrés.
- **Aucun secret** : ni clé `service_role`, ni mot de passe, ni clé d'API
  (e-mail, WhatsApp, paiement). La seule clé utilisée est la clé **publique**
  Supabase du site (`assets/js/config.js`), protégée par les règles de la
  base. L'application construite ne contient que `src/`, `ui/`, `config/`.
- **Aucune télémétrie** : rien n'est envoyé nulle part. Le journal reste sur le
  poste ; il ne contient ni mot de passe, ni jeton, ni clé, ni paramètre
  d'adresse, ni montant.

## Données sur le poste

| Fichier | Contenu | Sensible ? |
|---|---|---|
| `session.bin` | la session Supabase (jetons), chiffrée par le système | chiffré ; illisible sur un autre compte ou un autre ordinateur |
| `preferences.json` | taille de la fenêtre, imprimante par format | non |
| `journaux/bureau.log` | démarrages, pages chargées, erreurs (1 Mo, puis `bureau.1.log`) | non (nettoyé avant écriture) |

Dossier : `%APPDATA%\GoShip Express` (Windows), `~/Library/Application
Support/GoShip Express` (macOS). Le supprimer déconnecte le poste et oublie
ses préférences ; rien d'autre.

Sous Linux sans trousseau (développement seulement), la session reste en
mémoire : reconnexion à chaque lancement plutôt qu'un jeton en clair.

---

## Configuration

`config/environnements.json` : l'adresse du site, par environnement.

```json
{
  "production": { "site": "https://wilnergraph92.github.io/Goship-express-site/" },
  "local": { "site": "http://localhost:8765/" }
}
```

- Une installation ouvre `production`. `--env=local` (ou `GOSHIP_ENV=local`)
  ouvre le site de développement ; seuls les noms du fichier sont acceptés.
- **Le jour où le site passe sur son nom de domaine** (ex.
  `https://www.goshipexpress.com/`) : changez `production`, puis reconstruisez
  les installateurs. C'est le seul endroit où l'adresse est écrite.
- Pas d'environnement « staging » : il n'en existe pas aujourd'hui. Pour en
  ajouter un, une ligne de plus dans ce fichier, avec l'adresse d'un site qui a
  sa propre base Supabase.

---

## Développer

```bash
cd bureau
npm ci                          # Electron et les outils, versions figées
node essais/serveur-essai.js    # le site en mode démonstration, sur :8765
npm run demarrer:local          # l'application sur ce site (autre terminal)
```

`serveur-essai.js` sert le dépôt avec un `config.js` **vide** : mode
démonstration, jamais la base de production. Ne lancez pas l'application
`--env=local` sur un serveur qui servirait le vrai `config.js`.

| Commande | |
|---|---|
| `npm run demarrer` | l'application sur le site de production |
| `npm run demarrer:local` | l'application sur `http://localhost:8765/` |
| `npm run essai` | l'essai complet de l'application (voir « Essais ») |
| `npm run essai:paquet -- <exécutable>` | l'essai de l'application construite |
| `npm run construire:windows` | l'installateur Windows x64 (`dist/`) |
| `npm run construire:macos` | les images disque macOS arm64 et x64 (sur un Mac) |
| `npm run construire:linux` | un dossier Linux, pour essayer sur une machine Linux |

Linux : `xvfb-run -a npm run essai` sans écran ; et jamais en `root` (le bac à
sable de Chromium le refuse).

### Fichiers

```
bureau/
  package.json              version, scripts, configuration de construction
  config/environnements.json
  src/principal.js          démarrage, fenêtre, menu, messages du site
  src/pont.js               window.GoshipBureau (le seul lien avec le site)
  src/securite.js           navigation, fenêtres, permissions, CSP, expéditeurs
  src/stockage-session.js   session chiffrée par le système
  src/impression.js         fenêtre « Imprimer », PDF, imprimantes
  src/protocole.js          goship-app:// (pages locales, document en mémoire)
  src/menu.js, preferences.js, journal.js, config.js, pont-impression.js
  ui/                       « Connexion impossible », « Imprimer »
  build/icone.png           icône (1024 × 1024)
  essais/                   essai-bureau.js, essai-paquet.js, serveur-essai.js
```

Côté site, l'application ne change rien pour le navigateur : `api.js` confie la
session à `GoshipBureau.stockageSession` et note le poste d'un scan ;
`impression.js` envoie le même document à `GoshipBureau.imprimer` ;
`admin.js` gère raccourcis, commandes du menu, notifications, réseau coupé et
session expirée (ces trois derniers servent aussi dans le navigateur).

### Le contrat entre le site et l'application

`window.GoshipBureau.contrat` (aujourd'hui **1**) est la version du pont. Le
tableau de bord exige `BUREAU_CONTRAT_MIN` (`assets/js/admin.js`). Si un jour
le site a besoin d'une fonction que les postes installés n'ont pas : ajoutez-la
au pont, montez `contrat`, publiez les nouveaux installateurs, **puis** montez
`BUREAU_CONTRAT_MIN`. Un poste trop ancien affiche alors « Mettez à jour
l'application » au lieu de casser. Le site vérifie aussi chaque fonction avant
de s'en servir.

---

## Versions et mises à jour

- Version : `package.json` (`1.0.0`, *Majeur.Mineur.Correctif*). Elle
  s'affiche dans *À propos* et dans *Réglages > Système*, et c'est celle de
  l'installateur (même fichier).
- **Le tableau de bord se met à jour avec le site** : une mise en ligne suffit,
  sans réinstaller. Une nouvelle version de l'application n'est nécessaire que
  pour un changement de la coquille (menu, impression, pont…).
- **Mise à jour automatique** : pas encore. Il faut d'abord signer les
  applications (une mise à jour non signée est refusée par macOS et doit
  l'être). Le jour venu : `electron-updater` et les *Releases* GitHub, avec
  les mêmes installateurs. La session est gardée (elle est dans le dossier de
  données, que l'installateur ne touche pas) et aucune donnée métier ne peut
  être perdue : il n'y en a pas sur le poste.

## Signature et distribution

Aujourd'hui les installateurs **ne sont pas signés** : SmartScreen (Windows) et
Gatekeeper (macOS) avertissent au premier lancement (voir « Installer »). Pour
distribuer sans avertissement :

- **Windows** : un certificat de signature de code (OV, ou EV pour une
  réputation SmartScreen immédiate) ; secrets `CSC_LINK` / `CSC_KEY_PASSWORD`
  dans GitHub (*Settings > Secrets*), jamais dans le dépôt.
- **macOS** : un compte Apple Developer (99 $/an), un certificat *Developer ID
  Application*, la notarisation. Dans `package.json` : `mac.identity` (au lieu
  de `"-"`, signature ad hoc), `hardenedRuntime: true`, `notarize`. Secrets :
  `CSC_LINK`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.

## Architectures

- **Windows x64** : construit et essayé (GitHub Actions, `windows-latest`).
  Windows sur ARM exécute la version x64 en émulation ; pas de version arm64
  tant qu'elle n'est pas demandée.
- **macOS arm64 et x64**, deux images séparées (moitié moins lourdes qu'une
  image *universelle*), chacune construite et lancée sur une machine de son
  architecture (`macos-latest`, `macos-15-intel`).
- **Linux** : pour le développement et les essais seulement ; pas distribué.

---

## Essais

`npm run essai` lance la vraie application sur le site d'essai et vérifie :
démarrage et pont ; session (clés refusées, rien en clair sur le disque) ;
connexion et rôles (administrateur, gérant, employé, et le refus de la base) ;
raccourcis (lettre et position de touche) et menu ; scanner (lecture au rythme
d'un scanner, mode rapide sur trois colis, double scan, code illisible, colis
inconnu, poste noté dans l'historique) ; impression (fenêtre « Imprimer »,
aperçu, PDF 4 × 6 et A4, imprimante qui refuse puis « Réessayer ») ;
sécurité (navigation, `window.open`, schémas, CSP, permissions) ; réseau
(coupure, retour, serveur injoignable, « Réessayer »).

`essai-paquet.js` lance l'application **construite** (celle qu'on installe) et
lit son journal : démarrage, tableau de bord chargé, page « Connexion
impossible » depuis l'archive, rien de sensible écrit.

Le workflow `.github/workflows/bureau.yml` fait les deux sur Windows et macOS,
puis installe et désinstalle (Windows), ouvre l'image disque (macOS), et dépose
les installateurs.

**Pas essayé automatiquement** : une vraie imprimante (thermique ou de bureau),
un vrai scanner (les essais tapent au rythme d'un scanner), les notifications
affichées par le système, les avertissements SmartScreen/Gatekeeper au premier
lancement par un utilisateur. À vérifier sur un poste réel.

---

## Dépannage

| Symptôme | Cause probable | Que faire |
|---|---|---|
| « Connexion perdue » | pas d'Internet, ou le réseau bloque le site | vérifier la connexion ; *Réessayer* (automatique au retour du réseau) |
| « Service temporairement indisponible » | le site ou Supabase ne répond pas | réessayer dans quelques minutes ; vérifier le site dans un navigateur |
| « Votre session a expiré » | jeton expiré ou révoqué | se reconnecter ; rien n'est perdu |
| Reconnexion à chaque lancement | pas de coffre du système (Linux sans trousseau) | normal hors Windows/macOS |
| « Aucune imprimante installée » | pas d'imprimante sur le poste | installer l'imprimante ; en attendant, *Enregistrer en PDF* |
| « Impression échouée : imprimante introuvable » | imprimante renommée ou retirée | la choisir de nouveau dans la liste |
| Étiquette coupée ou réduite | papier du pilote différent de 4 × 6 | régler le pilote sur 4 × 6 pouces |
| Le scanner tape `&é"'` au lieu de chiffres | scanner en QWERTY sur un poste AZERTY | régler le scanner sur la disposition du système |
| Un scan ne part pas | le curseur n'est pas dans le poste de scan | Ctrl/⌘ + Maj + S, puis scanner |
| « Mettez à jour l'application » | poste plus ancien que le site | installer la dernière version |
| Autre | — | *Aide > Ouvrir le dossier des journaux*, envoyer `bureau.log` (il ne contient rien de secret) |
