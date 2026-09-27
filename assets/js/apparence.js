/* ==========================================================================
   Goship Express — l'apparence du tableau de bord, avant le premier affichage
   ==========================================================================
   Chargé sans « defer », dans le <head> de admin.html : il pose l'apparence
   choisie (réglage « Apparence », gardé dans gse-tableau-reglages) sur <html>
   avant que la page ne se dessine, pour qu'un tableau de bord sombre ne
   s'affiche pas d'abord en clair. admin.js prend ensuite le relais (changement
   de réglage, changement d'apparence du système). Aucune donnée, aucune
   requête.
   ========================================================================== */
(function () {
  'use strict';
  var choix = 'clair', animations = true;
  try {
    var r = JSON.parse(localStorage.getItem('gse-tableau-reglages') || '{}') || {};
    if (r.apparence === 'sombre' || r.apparence === 'systeme') choix = r.apparence;
    animations = r.animations !== false;
  } catch (e) { /* navigation privée : l'apparence claire */ }
  var sombre = choix === 'sombre' ||
    (choix === 'systeme' && !!window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  var html = document.documentElement;
  html.setAttribute('data-apparence', sombre ? 'sombre' : 'clair');
  if (!animations) html.setAttribute('data-animations', 'non');
})();
