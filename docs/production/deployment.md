# Déploiement

Quatre composants, quatre chemins. **Ordre de mise en ligne d'une version qui
touche plusieurs composants : base → site → bureau → mobile.** Toutes les
migrations ajoutent sans rien retirer : l'ancien site et les applications déjà
installées continuent de fonctionner sur une base plus récente — l'inverse n'est
pas vrai (un site récent sur une base ancienne appelle des fonctions absentes).

**Une exception : `supabase-notifications.sql`.** Il retire aux comptes
`envoyer_email_client` et `envoyer_whatsapp_client`, que le site d'avant la
Phase 11 appelle depuis le tableau de bord (la base envoie désormais elle-même).
Entre cette migration et la publication du site de la Phase 11, l'envoi manuel
d'un e-mail ou d'un WhatsApp depuis le tableau de bord échoue. Les deux se font
donc **l'un juste après l'autre** : migration, contrôles, puis fusion de la PR
des pages de la Phase 11 dans la foulée.

| Composant | Comment il part en ligne | Qui déclenche | Retour arrière |
|---|---|---|---|
| Base (Supabase) | chaîne `outils/migrations.txt`, SQL Editor | une personne, à la main | rollback.md § Base |
| Site (+ tableau de bord, + bureau) | `deploy.yml` à chaque push sur `main` | la fusion d'une PR | rollback.md § Site |
| Bureau (coquille) | `bureau.yml` construit les installateurs ; distribution à la main | une personne | réinstaller la version précédente |
| Mobile | EAS Build + EAS Submit (dépôt `goship-express-app`) | une personne | rollback.md § Mobile |

## 1. La base

**Jamais directement en production.** Toute migration passe par la préproduction
(environment.md) avant.

Avant :

1. **Préproduction verte** — Actions > **Préproduction** > Run workflow, sur la
   version à publier : chaîne, contrôles, essai métier, sonde.
2. **Sauvegarde vérifiée** — Actions > **Sauvegarde de la base** > Run workflow :
   les deux jobs verts (le second restaure la sauvegarde du jour et compare
   chaque table). Sans restauration réussie de la sauvegarde du jour, on ne
   migre pas.
3. **État de départ** — Actions > **Contrôles de la base de production** > Run
   workflow (lecture seule) ; et **Audit de la base de production** : quelles
   migrations sont déjà passées.
4. **Fenêtre** — en dehors des heures de scan de l'entrepôt ; prévenir l'équipe.

Pendant — deux façons, au choix :

- **Depuis un ordinateur de confiance** (psql 17), la chaîne à partir du premier
  fichier qui a changé, arrêt au premier échec, chaque fichier dans sa propre
  transaction :
  ```
  CIBLE_DB_URL='…production…' CONFIRMER_PRODUCTION=gpfdyslysqjmojgzggib \
    bash outils/production/appliquer-chaine.sh supabase-notifications.sql
  ```
  Sans `CONFIRMER_PRODUCTION`, le script refuse l'adresse de production.
- **Depuis le SQL Editor**, pour chaque fichier de `outils/migrations.txt`, dans
  l'ordre : GitHub > le fichier > **Copy raw file** (un aperçu copié à la main est
  tronqué : « unterminated dollar-quoted string ») ; New query > coller > Run ;
  lire la dernière ligne (chaque fichier finit par un contrôle). Une erreur :
  **s'arrêter**, ne pas lancer le fichier suivant (troubleshooting.md).

Aucun workflow ne migre la production : c'est volontaire.

Après :

1. `select public.sante();` → `status = ok`, `pret = true`. `notifications` vaut
   `ok` (ou `inactives` si `supabase-notifications.sql` n'a pas encore été passé).
2. Relancer **Contrôles de la base de production** : aucune nouvelle ALERTE.
3. **Audit de la base de production** : la chaîne complète (11/11).
4. **Surveillance de la production** > Run workflow : rien de critique.

### Premier passage de `supabase-notifications.sql` en production

Le moteur envoie dès que pg_cron tourne **et** que les clés d'un fournisseur sont
dans le Vault. Sans clé, les envois sont marqués « annulé — non configuré » : rien
ne part. Aucun rappel ne remonte avant la date de mise en service
(`notification_moteur.actives_depuis`). Pour une mise en service prudente :

1. passer la migration **sans** clé de fournisseur ;
2. créer un colis d'essai sur un compte de l'équipe, vérifier la notification dans
   l'onglet Notifications ;
3. poser une clé (`definir_reglage`), refaire l'essai, vérifier la réception ;
4. seulement alors, les autres canaux.

Arrêt d'urgence des envois : `select cron.unschedule('goship-notifications');`
(rien ne se perd : les envois restent « en attente » ; relancer
`supabase-notifications.sql` remet le planificateur).

## 2. Le site

`main` **est** la production : `deploy.yml` publie sur GitHub Pages à chaque push
sur `main`.

1. Travailler sur une branche, ouvrir une PR. `essais.yml` fait tourner tous les
   bancs d'essai ; `bureau.yml` ceux du bureau si `assets/` ou `admin.html`
   changent.
2. Vérifier que la base a déjà reçu les migrations dont la PR dépend (§ 1).
3. Fusionner. `deploy.yml` :
   - copie le site en excluant ce qui n'est pas public (`outils/`, `docs/`,
     `bureau/`, `.github/`, `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `*.py`,
     `*.sql`, fichiers de configuration du serveur) ;
   - **refuse de publier** si un fichier de travail (`.sql`, `.py`, `.env`, clé,
     sauvegarde) ou une clé secrète (`sb_secret_`, JWT `service_role`, clé
     privée) se trouve dans ce qui part ;
   - publie, puis lance `surveiller.sh` sur l'adresse publiée (pages, scripts,
     aucune clé secrète, fichiers de travail introuvables, Auth, `sante()`,
     suivi public).
4. Le job `verifier` (« Contrôle après publication ») rouge = le site est en
   ligne mais quelque chose ne va pas : incident-response.md.

Le cache de GitHub Pages peut servir l'ancienne version une dizaine de minutes.

## 3. Le bureau

Le bureau affiche `admin.html` **du site** : une mise en ligne du site met à jour
le bureau sans rien faire. Une nouvelle coquille (fenêtre, pont, impression) :

1. `bureau/package.json` : version + 1 (releases.md) ; si le pont change,
   `contrat` + 1 (CLAUDE.md, « L'application de bureau »).
2. PR → `bureau.yml` construit et essaie les installateurs Windows et macOS sur
   de vraies machines.
3. Télécharger les artefacts de la PR fusionnée, les distribuer aux postes de
   l'équipe.
4. **Seulement ensuite**, si le contrat a changé : `BUREAU_CONTRAT_MIN` dans
   `admin.js`, dans une PR à part.

Aujourd'hui : Windows non signé (SmartScreen avertit à l'installation), macOS
signé *ad hoc* sans notarisation (Gatekeeper demande une ouverture manuelle) —
**pour l'équipe seulement**. Ne jamais faire désactiver SmartScreen ou
Gatekeeper sur un poste.

**Distribution signée** (prête, certificats à fournir — go-no-go.md, A10) : dès
que ces secrets de dépôt sont posés, `bureau.yml` construit hors pull request
avec `bureau/electron-builder.distribution.js` :

| Secret | Pour |
|---|---|
| `MAC_CSC_LINK`, `MAC_CSC_KEY_PASSWORD` | certificat *Developer ID Application* (.p12 en base64) et son mot de passe |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | notarisation automatique par electron-builder |
| `WIN_CSC_LINK`, `WIN_CSC_KEY_PASSWORD` | certificat de signature de code Windows (.pfx en base64) |

Le job échoue si l'application signée n'est pas acceptée : macOS `spctl
--assess` et `xcrun stapler validate` ; Windows `Get-AuthenticodeSignature`
= `Valid`. À essayer ensuite à la main sur un Mac Intel, un Mac Apple Silicon et
un PC Windows (SmartScreen : la réputation d'un nouveau certificat s'acquiert ;
un certificat EV l'a d'emblée).

## 4. Le mobile

Dans le dépôt `goship-express-app` :

0. Préproduction : `eas build --profile staging` (goship-staging), installé sur
   un téléphone de test ; parcours de fumée (checklist-release.md) ; le paquet
   passe `node essais/controle-paquet.mjs <paquet> staging`.
1. PR → `mobile.yml` : essais, APK/AAB de production, application iOS de
   production (non signée), parcours Maestro sur émulateur Android et simulateur
   iOS, contrôle des paquets (adresse de production, aucune adresse d'essai,
   aucun secret).
2. Vérifier que la base a les fonctions dont la version dépend (§ 1).
3. Fusionner, puis :
   ```
   eas build --profile production --platform all
   eas submit --profile production --platform all
   ```
   Numéros de build tenus par EAS (`appVersionSource: remote`) ; la version
   affichée (`app.json` > `version`) se change à la main.
4. Publier d'abord en test interne (Play Console, TestFlight), puis en
   déploiement progressif (Android : 10 %, 50 %, 100 % ; iOS : *phased release*).

Une version installée **ne se met pas à jour toute seule** : une fonction dont
elle dépend ne se renomme pas et ne change pas de forme de réponse, jamais.
