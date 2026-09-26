/* « Connexion impossible » : dire ce qui se passe, et réessayer — à la main ou dès que le réseau revient. */
(function () {
  'use strict';
  var p = new URLSearchParams(location.search);
  var raison = p.get('raison');
  if (raison === 'serveur') {
    document.querySelector('[data-titre]').textContent = 'Service temporairement indisponible';
    document.querySelector('[data-texte]').textContent =
      'Le serveur de GoShip Express ne répond pas correctement. Vos données ne sont pas touchées : elles restent sur le serveur. Réessayez dans quelques instants.';
  } else {
    document.querySelector('[data-titre]').textContent = 'Connexion perdue';
    document.querySelector('[data-texte]').textContent =
      'Cet ordinateur n’est pas connecté à Internet, ou le réseau bloque GoShip Express. Certaines fonctionnalités sont indisponibles tant que la connexion n’est pas revenue.';
  }
  document.querySelector('[data-detail]').textContent = p.get('code') ? 'Détail technique : ' + p.get('code') : '';
  var bouton = document.querySelector('[data-reessayer]');
  function reessayer() {
    bouton.disabled = true;
    document.querySelector('[data-etat]').textContent = 'Connexion en cours…';
    if (window.GoshipHorsLigne) window.GoshipHorsLigne.reessayer();
  }
  bouton.addEventListener('click', reessayer);
  window.addEventListener('online', reessayer);
  bouton.focus();
})();
