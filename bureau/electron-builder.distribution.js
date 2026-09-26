// Configuration de DISTRIBUTION de l'application de bureau : la même que « build » dans
// package.json, avec une vraie signature.
//
// bureau.yml ne s'en sert que si les certificats sont posés en secrets GitHub (et
// jamais sur une pull request) ; sinon l'installateur reste signé ad hoc (macOS) ou
// non signé (Windows), pour l'équipe seulement.
//
//   macOS    identité Developer ID Application, trouvée par electron-builder dans le
//            certificat CSC_LINK (+ CSC_KEY_PASSWORD) ; « hardened runtime » et
//            entitlements exigés par Apple ; notarisation automatique quand APPLE_ID,
//            APPLE_APP_SPECIFIC_PASSWORD et APPLE_TEAM_ID sont posés.
//   Windows  signature Authenticode par electron-builder avec WIN_CSC_LINK
//            (+ WIN_CSC_KEY_PASSWORD) : aucun réglage de plus ici.
//
// Voir docs/production/deployment.md, § 3, et go-no-go.md (B7).

const base = require('./package.json').build;

const mac = { ...base.mac };
delete mac.identity;                 // « - » (ad hoc) ; absent = le certificat Developer ID
mac.hardenedRuntime = true;
mac.gatekeeperAssess = false;        // l'évaluation se fait après, dans bureau.yml (spctl)
mac.entitlements = 'build/entitlements.mac.plist';
mac.entitlementsInherit = 'build/entitlements.mac.plist';

module.exports = { ...base, mac };
