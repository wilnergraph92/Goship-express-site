/* ==========================================================================
   Goship Express — lire ce que tape un scanner
   --------------------------------------------------------------------------
   Un scanner USB ou Bluetooth en mode « clavier » (HID, keyboard wedge) ne
   parle pas au navigateur : il TAPE le code lu, très vite, puis Entrée. Ce
   fichier transforme ces frappes en une référence de colis, sans rien
   demander au serveur :

     GoshipScan.analyser(texte)   la chaîne lue → { ok, type, reference }
                                  ou { ok: false, code: 'INVALID_SCAN_FORMAT' }
     GoshipScan.Lecteur           reconnaît, à leur rythme, les frappes d'un
                                  scanner de celles d'une personne

   Il ne fait AUCUNE recherche : un code refusé ici ne coûte aucune requête.
   Rien ici ne décide de quoi que ce soit sur le colis — c'est le moteur de la
   base (outils/supabase-evenements.sql) qui le fait.

   Ce que portent nos étiquettes (assets/js/impression.js), inchangé :
     code-barres Code128   le numéro du colis           GSE-1001-HT
     QR code               le lien de suivi             https://…/index.html?suivi=GSE-1001-HT
                           (ou le numéro seul, si le site n'avait pas encore
                           d'adresse publique au moment de l'impression)
   Et ce qu'on trouve sur le carton du vendeur : son numéro de suivi (Amazon
   TBA…, UPS 1Z…, USPS 9400…), que la base connaît aussi.
   ========================================================================== */
(function () {
  'use strict';

  // Le numéro Goship : GSE-, des chiffres (1001, ou 8 tirés au hasard), le
  // pays de destination.
  var NUMERO = /^GSE-\d{3,12}-(HT|DO|US)$/;
  // Un suivi de vendeur : lettres et chiffres, de 8 à 40
  var SUIVI_VENDEUR = /^[A-Z0-9]{8,40}$/;
  // USPS imprime devant son numéro « 420 » et le code postal (5 ou 9
  // chiffres) : c'est ce que lit le scanner, pas ce que le vendeur donne.
  var USPS_PREFIXE = /^420(\d{5}|\d{9})(9\d{19,33})$/;
  // Les paramètres qu'un lien de suivi peut porter
  var PARAMETRES = ['suivi', 'numero', 'tracking', 'colis', 'ref'];

  /* ---- Le clavier du poste ---------------------------------------------------
     Un scanner réglé en QWERTY branché sur un poste AZERTY (Haïti, France) tape
     les chiffres de la rangée du haut sans Maj : « &é"'(-è_çà » au lieu de
     « 1234567890 », et « ) » au lieu du tiret. GSE, HT, DO, US ne changent pas
     (ni A/Q, ni Z/W, ni M). On remet donc ces caractères à leur place, mais
     seulement quand la chaîne en porte les traces : un vrai tiret reste un
     tiret.
     -------------------------------------------------------------------------- */
  var AZERTY = { '&': '1', 'é': '2', '"': '3', "'": '4', '(': '5', '-': '6', 'è': '7', '_': '8', 'ç': '9', 'à': '0',
                 ')': '-' };
  function corrigerClavier(t) {
    if (!/[&é"'(è_çà)]/.test(t)) return t;
    return t.replace(/[&é"'(\-è_çà)]/g, function (c) { return AZERTY[c]; });
  }

  function nettoyer(texte) {
    return String(texte == null ? '' : texte)
      .replace(/[\r\n\t\u0000-\u001f\u007f]/g, '')   // Entrée, tabulation, caractères de contrôle
      .replace(/^\s+|\s+$/g, '');
  }

  // Un lien : on en tire le numéro, où qu'il soit (paramètre ou fin du chemin)
  function depuisLien(t) {
    var u;
    try { u = new URL(t); } catch (e) { return null; }
    if (!/^https?:$/.test(u.protocol)) return null;
    for (var i = 0; i < PARAMETRES.length; i++) {
      var v = u.searchParams.get(PARAMETRES[i]);
      if (v) return v;
    }
    var m = /[?&#](?:suivi|numero|tracking)=([^&#]+)/i.exec(u.hash);
    if (m) return decodeURIComponent(m[1]);
    var dernier = u.pathname.split('/').filter(Boolean).pop() || '';
    return /^GSE-/i.test(dernier) ? decodeURIComponent(dernier) : null;
  }

  function reconnaitre(t) {
    var r = t.toUpperCase().replace(/\s+/g, '');
    if (NUMERO.test(r)) return { type: 'numero', reference: r };
    var usps = USPS_PREFIXE.exec(r);
    if (usps) return { type: 'suivi_vendeur', reference: usps[2] };
    // Un numéro Goship ne passe jamais pour un suivi de vendeur : GSE mal lu
    // (« GSE-10 », « GSE-1001 ») est une erreur de lecture, pas un code.
    if (/^GSE/.test(r)) return null;
    if (SUIVI_VENDEUR.test(r) && /\d/.test(r)) return { type: 'suivi_vendeur', reference: r };
    return null;
  }

  // La chaîne lue → { ok: true, type, reference, brut }
  //              ou { ok: false, code: 'INVALID_SCAN_FORMAT', brut, detail }
  // type : « numero » (Code128 ou QR sans lien), « lien » (QR de suivi),
  //        « suivi_vendeur » (carton du vendeur).
  function analyser(texte) {
    var brut = nettoyer(texte);
    function refus(detail) { return { ok: false, code: 'INVALID_SCAN_FORMAT', brut: brut, detail: detail }; }
    if (brut.length < 4) return refus('Code trop court.');
    if (brut.length > 500) return refus('Code trop long.');

    if (/^https?:\/\//i.test(brut)) {
      var dedans = depuisLien(brut);
      if (!dedans) return refus('Ce lien ne porte aucun numéro de colis (QR d’une facture ?).');
      var viaLien = reconnaitre(nettoyer(dedans));
      if (!viaLien) return refus('Le lien porte un numéro illisible.');
      return { ok: true, type: 'lien', reference: viaLien.reference, brut: brut };
    }

    var r = reconnaitre(brut) || reconnaitre(corrigerClavier(brut));
    if (!r) return refus('Ni un numéro Goship (GSE-1001-HT), ni un suivi de vendeur.');
    return { ok: true, type: r.type, reference: r.reference, brut: brut };
  }

  /* ---- Scanner ou personne ? --------------------------------------------------
     Un scanner tape tout son code en quelques dizaines de millisecondes ; une
     personne met plusieurs secondes. Le Lecteur note l'heure de chaque frappe
     et dit, quand la saisie s'arrête, si c'était un scanner. Cela sert aux
     scanners réglés SANS touche Entrée à la fin : leur code part tout seul
     après un court silence, alors qu'une saisie à la main attend Entrée ou le
     bouton « Rechercher ». Jamais une recherche par lettre tapée.
     -------------------------------------------------------------------------- */
  var ECART_SCANNER_MS = 45;   // au-delà, en moyenne, ce n'est plus un scanner
  var SILENCE_MS = 220;         // fin d'un code sans Entrée
  var LONGUEUR_MIN = 6;

  function Lecteur() { this.frappes = []; }
  Lecteur.prototype.noter = function (instant) { this.frappes.push(instant); };
  Lecteur.prototype.oublier = function () { this.frappes = []; };
  Lecteur.prototype.estScanner = function () {
    var f = this.frappes;
    if (f.length < LONGUEUR_MIN) return false;
    return (f[f.length - 1] - f[0]) / (f.length - 1) <= ECART_SCANNER_MS;
  };

  window.GoshipScan = {
    analyser: analyser,
    corrigerClavier: corrigerClavier,
    Lecteur: Lecteur,
    SILENCE_MS: SILENCE_MS
  };
})();
