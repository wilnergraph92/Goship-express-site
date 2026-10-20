/* ==========================================================================
   Goship Express — grille de points en arrière-plan (effet « dot grid »)
   Une grille de petits points, fixe derrière la lecture : près du curseur
   (ou du doigt) les points grossissent et virent à l'orange, puis reviennent.
   Aucune donnée, aucun appel réseau : du dessin, rien d'autre.
   ========================================================================== */
(function () {
  'use strict';

  var ECART = 28;              // distance entre deux points (px)
  var RAYON = 1.3;             // rayon d'un point au repos
  var RAYON_MAX = 3.4;         // rayon d'un point sous le curseur
  var PORTEE = 150;            // distance à laquelle le curseur agit (px)
  var REPOS = 'rgba(23,70,168,.16)';       // le bleu du site, très léger : il ne doit pas gêner la lecture
  var ACTIF = [244, 96, 13];               // l'orange du site
  var BASE = [23, 70, 168];
  var ALPHA_REPOS = 0.16;
  var ALPHA_ACTIF = 0.85;

  // Un visiteur qui demande moins d'animation garde la grille, mais immobile
  var mouvement = !(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  var toile = document.createElement('canvas');
  toile.className = 'gs-fond';
  toile.setAttribute('aria-hidden', 'true');
  var ctx = toile.getContext && toile.getContext('2d');
  if (!ctx) return;

  var largeur = 0, hauteur = 0, densite = 1;
  var curseur = { x: -9999, y: -9999, vu: 0 };   // vu : force de l'effet, 1 pendant le mouvement puis retombe à 0
  var dernier = 0, enBoucle = false;

  function dimensionner() {
    densite = Math.min(window.devicePixelRatio || 1, 2);   // 2 suffit : au-delà, on dessine pour rien
    largeur = window.innerWidth;
    hauteur = window.innerHeight;
    toile.width = Math.round(largeur * densite);
    toile.height = Math.round(hauteur * densite);
    ctx.setTransform(densite, 0, 0, densite, 0, 0);
    dessiner();
  }

  function dessiner() {
    ctx.clearRect(0, 0, largeur, hauteur);
    var colonnes = Math.ceil(largeur / ECART) + 1;
    var lignes = Math.ceil(hauteur / ECART) + 1;
    var decalageX = (largeur - (colonnes - 1) * ECART) / 2;
    var decalageY = (hauteur - (lignes - 1) * ECART) / 2;
    var agit = curseur.vu > 0.01;
    var portee2 = PORTEE * PORTEE;

    // Les points au repos, tous d'un coup : un seul tracé
    ctx.fillStyle = REPOS;
    ctx.beginPath();
    for (var j = 0; j < lignes; j++) {
      var y = decalageY + j * ECART;
      for (var i = 0; i < colonnes; i++) {
        var x = decalageX + i * ECART;
        if (agit) {
          var dx = x - curseur.x, dy = y - curseur.y;
          if (dx * dx + dy * dy < portee2) continue;   // ceux-là sont dessinés plus bas
        }
        ctx.moveTo(x + RAYON, y);
        ctx.arc(x, y, RAYON, 0, 6.2832);
      }
    }
    ctx.fill();
    if (!agit) return;

    // Les points près du curseur : plus gros et plus orange à mesure qu'on s'approche
    for (var b = 0; b < lignes; b++) {
      var yb = decalageY + b * ECART;
      for (var a = 0; a < colonnes; a++) {
        var xa = decalageX + a * ECART;
        var ex = xa - curseur.x, ey = yb - curseur.y;
        var d2 = ex * ex + ey * ey;
        if (d2 >= portee2) continue;
        var f = (1 - Math.sqrt(d2) / PORTEE) * curseur.vu;   // 1 sous le curseur, 0 à la limite
        f = f * f * (3 - 2 * f);                             // adouci : pas de bord net
        var r = RAYON + (RAYON_MAX - RAYON) * f;
        var c0 = Math.round(BASE[0] + (ACTIF[0] - BASE[0]) * f);
        var c1 = Math.round(BASE[1] + (ACTIF[1] - BASE[1]) * f);
        var c2 = Math.round(BASE[2] + (ACTIF[2] - BASE[2]) * f);
        ctx.fillStyle = 'rgba(' + c0 + ',' + c1 + ',' + c2 + ',' + (ALPHA_REPOS + (ALPHA_ACTIF - ALPHA_REPOS) * f).toFixed(3) + ')';
        ctx.beginPath();
        ctx.arc(xa, yb, r, 0, 6.2832);
        ctx.fill();
      }
    }
  }

  // La boucle ne tourne que tant que l'effet bouge : une page immobile ne coûte rien
  function image(maintenant) {
    var ecoule = dernier ? Math.min(maintenant - dernier, 64) : 16;
    dernier = maintenant;
    curseur.vu = Math.max(0, curseur.vu - ecoule / 700);   // retombe en 0,7 s
    dessiner();
    if (curseur.vu > 0) window.requestAnimationFrame(image);
    else { enBoucle = false; dernier = 0; }
  }
  function lancer() {
    if (enBoucle) return;
    enBoucle = true;
    window.requestAnimationFrame(image);
  }

  function bouge(e) {
    if (!mouvement) return;
    curseur.x = e.clientX;
    curseur.y = e.clientY;
    curseur.vu = 1;
    lancer();
  }

  function demarrer() {
    document.body.appendChild(toile);
    dimensionner();
    var attente = 0;
    window.addEventListener('resize', function () {
      window.clearTimeout(attente);
      attente = window.setTimeout(dimensionner, 120);
    });
    window.addEventListener('pointermove', bouge, { passive: true });
    // La souris quitte la fenêtre : l'effet s'éteint tout seul
    document.addEventListener('mouseleave', function () { curseur.vu = Math.min(curseur.vu, 0.6); });
  }

  if (document.body) demarrer();
  else document.addEventListener('DOMContentLoaded', demarrer);
})();
