/* ==========================================================================
   Goship Express — déconnexion après un moment sans activité
   ==========================================================================
   Un ordinateur laissé allumé au comptoir ou chez un client ne doit pas
   laisser le tableau de bord ni l'espace client ouverts à qui passe. Ce
   module compte le temps depuis le dernier geste (souris, clavier, toucher,
   défilement) et appelle la page quand il faut avertir, puis déconnecter.
   Il ne connaît ni Supabase ni l'interface : admin.js et compte.js gardent
   leurs textes (traduits chacun à sa façon) et leur façon de se déconnecter.

   L'heure du dernier geste est rangée dans le navigateur (localStorage),
   partagée par tous les onglets du site : travailler dans un onglet garde
   les autres ouverts, et un onglet oublié se ferme en même temps que les
   autres. On compare des heures, jamais une minuterie : un navigateur
   ralentit les onglets cachés et un ordinateur en veille ne compte rien.
   Revenir après une heure d'absence déconnecte donc tout de suite.

   C'est une protection de l'appareil, pas du serveur : la session reste
   valable chez Supabase jusqu'à sa propre expiration (voir CLAUDE.md).

     var veille = GoshipInactivite.surveiller({
       minutes: 10,            // délai sans activité, 1 à 240
       connecteLe: 1700000000, // heure de la connexion (ms) : une connexion
                               // plus récente que le dernier geste noté repart à zéro
       avertir: function () {},   // une minute avant (la moitié du délai s'il est court)
       reprendre: function () {}, // un geste, ici ou dans un autre onglet
       expirer: function () {}    // le délai est passé : la page se déconnecte
     });
     veille.prolonger();  // « Rester connecté »
     veille.arreter();    // déconnexion voulue : plus rien ne se passe
   ========================================================================== */
(function () {
  'use strict';

  var CLE = 'gse-derniere-activite';
  // Écrire à chaque mouvement de souris ne sert à rien : une heure notée toutes
  // les 5 secondes au plus suffit, l'erreur reste négligeable devant des minutes.
  var ECART_ECRITURE = 5000;
  var GESTES = ['pointerdown', 'mousedown', 'mousemove', 'keydown', 'wheel', 'touchstart', 'scroll'];

  function lire() {
    try {
      var v = Number(window.localStorage.getItem(CLE));
      return isFinite(v) && v > 0 ? v : null;
    } catch (e) { return null; }
  }
  function ecrire(t) {
    try { window.localStorage.setItem(CLE, String(t)); } catch (e) { /* stockage plein ou interdit */ }
  }
  function effacer() {
    try { window.localStorage.removeItem(CLE); } catch (e) { /* rien à faire */ }
  }

  // Le délai lu dans config.js : un nombre de minutes entre 1 et 240. Une valeur
  // absente, vide ou farfelue garde le délai prévu par la page.
  function minutes(valeur, defaut) {
    var n = Number(valeur);
    if (!isFinite(n) || n <= 0) return defaut;
    return Math.min(240, Math.max(1, n));
  }

  function surveiller(o) {
    var delai = minutes(o.minutes, 10) * 60000;
    var preavis = Math.min(60000, delai / 2);
    var avertit = false, finie = false, ecrite = 0, minuterie = null;
    var rien = function () {};
    var avertir = o.avertir || rien, reprendre = o.reprendre || rien, expirer = o.expirer || rien;

    function noter(maintenant) {
      if (finie) return;
      if (maintenant - ecrite >= ECART_ECRITURE) { ecrite = maintenant; ecrire(maintenant); }
    }

    function verifier() {
      if (finie) return;
      var dernier = lire();
      var maintenant = Date.now();
      // Plus d'heure notée (un autre onglet s'est déconnecté, ou le stockage a été
      // vidé) : on repart de maintenant plutôt que de fermer sans raison.
      if (dernier === null) { ecrite = 0; noter(maintenant); if (avertit) { avertit = false; reprendre(); } return; }
      var reste = dernier + delai - maintenant;
      if (reste <= 0) {
        // L'heure rangée reste en place : les autres onglets la lisent et se ferment
        // aussi. La prochaine connexion, plus récente qu'elle, repart à zéro.
        finie = true;
        arreterEcoute();
        expirer();
      } else if (reste <= preavis) {
        if (!avertit) { avertit = true; avertir(); }
      } else if (avertit) {
        avertit = false;
        reprendre();
      }
    }

    function geste() {
      if (finie) return;
      var maintenant = Date.now();
      // Un geste pendant l'avertissement compte tout de suite : il doit le faire disparaître
      if (avertit) ecrite = 0;
      noter(maintenant);
      if (avertit) verifier();
    }

    function surStockage(e) {
      if (!e || e.key === CLE || e.key === null) verifier();
    }
    function surRetour() {
      if (document.visibilityState !== 'hidden') verifier();
    }

    function arreterEcoute() {
      clearInterval(minuterie);
      GESTES.forEach(function (g) { document.removeEventListener(g, geste, true); });
      window.removeEventListener('storage', surStockage);
      window.removeEventListener('focus', verifier);
      document.removeEventListener('visibilitychange', surRetour);
    }

    // Au départ : une connexion faite après le dernier geste noté (ou aucun geste
    // noté) repart à zéro ; sinon l'heure rangée fait foi, et une page rouverte
    // après une longue absence se ferme aussitôt.
    var dernier = lire();
    var connecteLe = Number(o.connecteLe) || 0;
    if (dernier === null || connecteLe > dernier) { ecrite = 0; noter(Date.now()); }

    GESTES.forEach(function (g) { document.addEventListener(g, geste, { capture: true, passive: true }); });
    window.addEventListener('storage', surStockage);
    window.addEventListener('focus', verifier);
    document.addEventListener('visibilitychange', surRetour);
    minuterie = setInterval(verifier, 1000);
    // Après le retour : la vérification immédiate attend que la page ait fini de
    // se mettre en place (expirer peut afficher un écran)
    setTimeout(verifier, 0);

    return {
      prolonger: function () { ecrite = 0; noter(Date.now()); verifier(); },
      arreter: function () {
        if (finie) return;
        finie = true;
        arreterEcoute();
        effacer();
      }
    };
  }

  window.GoshipInactivite = { surveiller: surveiller, minutes: minutes, effacer: effacer, CLE: CLE };
})();
