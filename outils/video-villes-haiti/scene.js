/* ==========================================================================
   Goship Express — vidéo « Nos villes de livraison en Haïti »
   ==========================================================================
   Tout est dessiné ici, au canvas, image par image : aucune photo, aucune
   banque d'images, aucune génération par IA. `rendre(t)` dessine l'image
   de l'instant t (en secondes) et ne dépend de rien d'autre — c'est ce qui
   permet à `rendre.js` de fabriquer la vidéo image par image, toujours
   identique d'un rendu à l'autre (aléas tirés d'une graine fixe).

   Grammaire reprise de la vidéo de référence : vue « heure dorée » par
   ville, lente poussée de caméra en parallaxe, titre chromé 3D entouré d'un
   anneau lumineux, pastille inclinée sous le titre, drapeau qui flotte,
   passage d'une ville à l'autre par une plongée à travers les nuages, puis
   un final logo + appel à l'action.

   Format : vertical 1080 × 1920 (reels, statuts WhatsApp, TikTok).
   ========================================================================== */
(function () {
  'use strict';

  var W = 1080, H = 1920;

  // --- Le minutage, en secondes : 120 BPM, une mesure = 2 s ---------------
  //  Chaque changement de scène tombe sur une mesure : musique.py s'aligne
  //  sur les mêmes chiffres (TEMPS dans ce fichier-là).
  var INTRO = 6, VILLE = 6, FINALE = 8;
  // La miniature ouvre la vidéo : c'est sa première image, celle que
  // WhatsApp, Instagram ou TikTok montrent avant la lecture. Hors mesure :
  // musique.py la compte à part (DEBUT).
  var MINIATURE = 1.5;

  // --- Les villes, dans l'ordre demandé ------------------------------------
  //  Coordonnées réelles : elles placent les points sur la carte d'Haïti.
  var VILLES = [
    { nom: 'PORT-AU-PRINCE', dep: "Département de l'Ouest",      lon: -72.34, lat: 18.54, dessin: dessinerPortAuPrince,
      photo: { fichier: 'port-au-prince', cy: 900, pan: 1, drapeau: 0 } },
    { nom: 'CAP-HAÏTIEN',    dep: 'Département du Nord',          lon: -72.20, lat: 19.76, dessin: dessinerCapHaitien,
      photo: { fichier: 'cap-haitien', cy: 880, pan: -1, drapeau: -1 } },
    { nom: 'GONAÏVES',       dep: "Département de l'Artibonite",  lon: -72.69, lat: 19.45, dessin: dessinerGonaives,
      photo: { fichier: 'gonaives', cy: 800, pan: 1, drapeau: 0 } },
    { nom: 'LES CAYES',      dep: 'Département du Sud',           lon: -73.75, lat: 18.19, dessin: dessinerLesCayes,
      photo: { fichier: 'les-cayes', cy: 820, pan: -1, drapeau: -1 } },
    { nom: 'HINCHE',         dep: 'Département du Centre',        lon: -72.01, lat: 19.15, dessin: dessinerHinche,
      photo: { fichier: 'hinche', cy: 830, pan: 1, drapeau: 1 } },
    { nom: 'JACMEL',         dep: 'Département du Sud-Est',       lon: -72.53, lat: 18.23, dessin: dessinerJacmel,
      photo: { fichier: 'jacmel', cy: 760, pan: -1, drapeau: 1 } }
  ];
  // `photo` : si photos/<fichier>.jpg existe (preparer-photos.sh), la ville
  // s'affiche en photo ; sinon elle garde son décor dessiné. cy : hauteur où
  // centrer la photo ; pan : sens du lent panoramique ; drapeau : grand
  // drapeau dans le coin (1 gauche, -1 droite, 0 aucun — la photo en a un).
  // Libellés de la carte, en casse normale
  var NOMS_CARTE = ['Port-au-Prince', 'Cap-Haïtien', 'Gonaïves', 'Les Cayes', 'Hinche', 'Jacmel'];
  // Où poser l'étiquette autour du point, pour qu'aucune ne se chevauche
  var COTE_ETIQUETTE = [[1, 1], [1, -1], [-1, -1], [-1, 1], [1, 0], [1, 1.2]];

  var SCENES = [];
  (function () {
    var t = 0;
    SCENES.push({ type: 'miniature', debut: t, fin: t + MINIATURE }); t += MINIATURE;
    SCENES.push({ type: 'intro', debut: t, fin: t + INTRO }); t += INTRO;
    VILLES.forEach(function (v, i) { SCENES.push({ type: 'ville', ville: i, debut: t, fin: t + VILLE }); t += VILLE; });
    SCENES.push({ type: 'finale', debut: t, fin: t + FINALE });
  })();
  var DUREE = SCENES[SCENES.length - 1].fin;

  // Contour d'Haïti (longitude, latitude), sens horaire depuis le Môle
  // Saint-Nicolas. Simplifié, mais fidèle à la silhouette du pays.
  var HAITI = [
    [-73.40, 19.83], [-73.15, 19.92], [-72.95, 19.95], [-72.83, 19.94], [-72.60, 19.92], [-72.40, 19.83],
    [-72.20, 19.78], [-72.05, 19.73], [-71.84, 19.71], [-71.75, 19.71], [-71.73, 19.55], [-71.66, 19.32],
    [-71.78, 19.10], [-71.72, 18.92], [-71.95, 18.65], [-71.88, 18.45], [-71.76, 18.30], [-71.74, 18.04],
    [-72.05, 18.15], [-72.32, 18.22], [-72.53, 18.21], [-72.75, 18.16], [-73.00, 18.17], [-73.25, 18.22],
    [-73.40, 18.27], [-73.58, 18.24], [-73.75, 18.17], [-73.92, 18.04], [-74.10, 18.11], [-74.30, 18.23],
    [-74.47, 18.38], [-74.47, 18.55], [-74.30, 18.65], [-74.12, 18.66], [-73.90, 18.59], [-73.65, 18.51],
    [-73.40, 18.51], [-73.10, 18.46], [-72.87, 18.44], [-72.63, 18.52], [-72.42, 18.55], [-72.34, 18.58],
    [-72.40, 18.71], [-72.50, 18.79], [-72.68, 18.96], [-72.72, 19.11], [-72.80, 19.30], [-72.70, 19.46],
    [-72.85, 19.59], [-73.05, 19.64], [-73.25, 19.68]
  ];
  var GONAVE = [[-73.30, 18.96], [-73.05, 18.95], [-72.80, 18.85], [-72.73, 18.78], [-72.95, 18.75], [-73.20, 18.80]];
  var TORTUE = [[-72.95, 20.05], [-72.75, 20.09], [-72.60, 20.05], [-72.80, 20.01]];

  // ========================================================================
  //  Outils
  // ========================================================================

  // Aléa à graine fixe (mulberry32) : deux rendus donnent la même vidéo
  function alea(graine) {
    var s = graine >>> 0;
    return function () {
      s = (s + 0x6D2B79F5) >>> 0;
      var t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function borner(x, a, b) { return x < a ? a : (x > b ? b : x); }
  function mix(a, b, t) { return a + (b - a) * t; }
  function prog(t, a, b) { return borner((t - a) / (b - a), 0, 1); }
  function douce(t) { t = borner(t, 0, 1); return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
  function sortie(t) { t = borner(t, 0, 1); return 1 - Math.pow(1 - t, 3); }
  function rebond(t) { t = borner(t, 0, 1); var c = 1.9; return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2); }
  function toile(w, h) { var c = document.createElement('canvas'); c.width = w; c.height = h; return c; }

  function arrondi(c, x, y, w, h, r) {
    c.beginPath();
    c.moveTo(x + r, y);
    c.arcTo(x + w, y, x + w, y + h, r);
    c.arcTo(x + w, y + h, x, y + h, r);
    c.arcTo(x, y + h, x, y, r);
    c.arcTo(x, y, x + w, y, r);
    c.closePath();
  }
  function degradeV(c, y0, y1, arrets) {
    var g = c.createLinearGradient(0, y0, 0, y1);
    arrets.forEach(function (a) { g.addColorStop(a[0], a[1]); });
    return g;
  }
  function degradeH(c, x0, x1, arrets) {
    var g = c.createLinearGradient(x0, 0, x1, 0);
    arrets.forEach(function (a) { g.addColorStop(a[0], a[1]); });
    return g;
  }
  function halo(c, x, y, r, couleur, alpha) {
    var g = c.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, couleur);
    g.addColorStop(1, 'rgba(0,0,0,0)');
    c.save();
    c.globalAlpha = alpha === undefined ? 1 : alpha;
    c.globalCompositeOperation = 'lighter';
    c.fillStyle = g;
    c.fillRect(x - r, y - r, 2 * r, 2 * r);
    c.restore();
  }

  // Les décors immobiles sont dessinés une seule fois, puis recopiés :
  // c'est ce qui rend le rendu de 1 500 images supportable.
  var cache = {};
  function couche(cle, dessin, w, h) {
    if (!cache[cle]) {
      var c = toile(w || W, h || H);
      dessin(c.getContext('2d'), c);
      cache[cle] = c;
    }
    return cache[cle];
  }

  // Caméra : poussée lente vers l'avant ; un plan proche (prof élevée)
  // grossit plus vite qu'un plan lointain — c'est la parallaxe.
  var CAM_X = 540, CAM_Y = 1000;
  function camera(c, prof, z) {
    var s = 1 + z * 0.16 * prof;
    c.setTransform(s, 0, 0, s, CAM_X * (1 - s), CAM_Y * (1 - s));
  }

  // ========================================================================
  //  Éléments de décor réutilisés par toutes les villes
  // ========================================================================

  // Ciel de fin de journée, soleil compris
  function ciel(c, horizon, pal, sx, sy, sr) {
    c.fillStyle = degradeV(c, 0, horizon, [[0, pal[0]], [0.33, pal[1]], [0.62, pal[2]], [0.86, pal[3]], [1, pal[4]]]);
    c.fillRect(0, 0, W, H);
    if (sr) {
      halo(c, sx, sy, sr * 9, 'rgba(255,190,110,0.55)');
      halo(c, sx, sy, sr * 3.2, 'rgba(255,230,170,0.9)');
      c.fillStyle = '#fff6dc';
      c.beginPath(); c.arc(sx, sy, sr, 0, Math.PI * 2); c.fill();
    }
  }
  var PAL_COUCHANT = ['#0a1f5e', '#2457b8', '#7c86cf', '#f2935a', '#ffd38c'];
  var PAL_OR = ['#13307a', '#3d64c0', '#c9879b', '#ff9a4a', '#ffcf7a'];
  var PAL_ROSE = ['#14205e', '#4a4fae', '#e07a8f', '#ff8f4f', '#ffc46e'];
  var PAL_JOUR = ['#1d56b8', '#3d86d8', '#8fb8e6', '#ffc98f', '#ffe3b0'];

  // Nuages : six formes peintes une fois, éclairées par-dessous (soleil bas)
  var NUAGES = [], NUAGES_BLANCS = [];
  function creerNuage(graine, blanc) {
    var w = 560, h = 240, c = toile(w, h), x = c.getContext('2d'), r = alea(graine);
    x.filter = blanc ? 'blur(6px)' : 'blur(2.5px)';
    var bouffees = [];
    for (var i = 0; i < 18; i++) {
      var px = w * (0.14 + 0.72 * r());
      var d = Math.abs(px / w - 0.5) * 2;
      var pr = h * (0.13 + 0.15 * r()) * (1.2 - d * 0.7);
      var py = h * 0.66 - pr * (0.25 + 0.9 * r()) * (1 - d * 0.5);
      bouffees.push([px, py, pr]);
    }
    bouffees.forEach(function (b) {
      x.fillStyle = blanc
        ? degradeV(x, b[1] - b[2], b[1] + b[2], [[0, '#ffffff'], [1, '#d9e4f5']])
        : degradeV(x, b[1] - b[2], b[1] + b[2], [[0, '#4b4f95'], [0.55, '#a07fb2'], [1, '#ffb878']]);
      x.beginPath(); x.arc(b[0], b[1], b[2], 0, Math.PI * 2); x.fill();
    });
    if (!blanc) {
      // Liseré doré sur le bas des bouffées
      x.globalCompositeOperation = 'source-atop';
      x.fillStyle = degradeV(x, h * 0.45, h * 0.78, [[0, 'rgba(255,205,140,0)'], [1, 'rgba(255,222,160,0.95)']]);
      x.fillRect(0, 0, w, h);
    }
    return c;
  }
  function champNuages(graine, haut, bas, nombre) {
    var r = alea(graine), liste = [];
    for (var i = 0; i < nombre; i++) {
      var y = mix(haut, bas, Math.pow(r(), 1.3));
      liste.push({
        x: r() * (W + 500) - 250, y: y,
        s: mix(1.25, 0.45, (y - haut) / (bas - haut + 1)) * (0.75 + r() * 0.5),
        v: 8 + r() * 18, f: Math.floor(r() * 6), a: 0.75 + r() * 0.25
      });
    }
    return liste;
  }
  function dessinerNuages(c, champ, u, teinte) {
    champ.forEach(function (n) {
      var spr = NUAGES[n.f];
      var w = spr.width * n.s, h = spr.height * n.s;
      var x = ((n.x + n.v * u) % (W + 600)) - 300;
      c.globalAlpha = n.a * (teinte === undefined ? 1 : teinte);
      c.drawImage(spr, x - w / 2, n.y - h / 2, w, h);
    });
    c.globalAlpha = 1;
  }

  // Crête de montagne ou de colline, d'après un profil y = f(x)
  function crete(c, profil, yBas, haut, bas) {
    c.beginPath();
    c.moveTo(-60, yBas);
    for (var x = -60; x <= W + 60; x += 6) c.lineTo(x, profil(x));
    c.lineTo(W + 60, yBas);
    c.closePath();
    var ymin = H;
    for (var k = 0; k <= W; k += 30) ymin = Math.min(ymin, profil(k));
    c.fillStyle = degradeV(c, ymin, yBas, [[0, haut], [1, bas]]);
    c.fill();
  }
  function bruit(graine) {
    var r = alea(graine), p = [r() * 9, r() * 9, r() * 9, r() * 9];
    return function (x, f) {
      return 0.5 * Math.sin(x * f + p[0]) + 0.27 * Math.sin(x * f * 2.17 + p[1]) +
             0.15 * Math.sin(x * f * 4.9 + p[2]) + 0.08 * Math.sin(x * f * 11.3 + p[3]);
    };
  }

  // Petites lumières de ville sur un relief
  function lumieres(c, graine, n, x0, x1, profil, yBas, taille) {
    var r = alea(graine);
    for (var i = 0; i < n; i++) {
      var x = mix(x0, x1, r());
      var y = mix(profil(x) + 8, yBas, Math.pow(r(), 0.8));
      var t = (taille || 2.2) * (0.6 + r() * 0.8);
      c.fillStyle = r() < 0.8 ? 'rgba(255,214,130,0.95)' : 'rgba(255,250,230,0.95)';
      c.fillRect(x, y, t, t);
      if (r() < 0.25) halo(c, x, y, t * 5, 'rgba(255,190,100,0.5)');
    }
  }

  // Reflet sur l'eau ou un sol mouillé : copie retournée, ondulée à chaque image
  function preparerReflet(cle, source, axe, hauteur, alpha, teinte) {
    return couche(cle, function (x) {
      x.setTransform(1, 0, 0, -1, 0, axe);
      x.drawImage(source, 0, 0);
      x.setTransform(1, 0, 0, 1, 0, 0);
      x.globalCompositeOperation = 'destination-in';
      x.fillStyle = degradeV(x, 0, hauteur, [[0, 'rgba(0,0,0,' + alpha + ')'], [1, 'rgba(0,0,0,0)']]);
      x.fillRect(0, 0, W, hauteur);
      x.globalCompositeOperation = 'source-atop';
      x.fillStyle = teinte || 'rgba(20,30,80,0.25)';
      x.fillRect(0, 0, W, hauteur);
    }, W, hauteur);
  }
  function dessinerReflet(c, reflet, axe, u, amplitude) {
    var h = reflet.height;
    for (var y = 0; y < h; y += 4) {
      var dx = Math.sin(y * 0.08 + u * 2.4) * (amplitude || 1) * (1 + y * 0.02);
      c.drawImage(reflet, 0, y, W, 4, dx, axe + y, W, 4);
    }
  }

  // Scintillement du soleil sur l'eau
  function scintillements(c, graine, n, cx, y0, y1, largeur, u, couleur) {
    var r = alea(graine);
    c.save();
    c.globalCompositeOperation = 'lighter';
    for (var i = 0; i < n; i++) {
      var p = Math.pow(r(), 0.7);
      var y = mix(y0, y1, p);
      var spread = largeur * (0.25 + p * 0.9);
      var x = cx + (r() - 0.5) * 2 * spread * Math.pow(r(), 0.6);
      var w = (8 + r() * 46) * (0.5 + p);
      var ph = r() * 6.28, vit = 2 + r() * 4;
      var a = Math.max(0, Math.sin(u * vit + ph)) * (0.9 - p * 0.4);
      c.fillStyle = couleur || 'rgba(255,214,150,1)';
      c.globalAlpha = a;
      c.fillRect(x - w / 2, y, w, 2 + p * 3);
    }
    c.restore();
  }

  // Palmier, balancé par la brise
  function palmier(c, x, y, h, penche, u, graine, couleur) {
    var r = alea(graine);
    var brise = Math.sin(u * 1.2 + graine) * 0.035 + Math.sin(u * 2.7 + graine * 2) * 0.01;
    var hx = x + (penche + brise) * h, hy = y - h;
    var cx = x + penche * h * 0.2, cy = y - h * 0.55;
    var fonce = couleur || '#16301c';
    c.save();
    c.lineCap = 'round';
    for (var i = 0; i < 18; i++) {
      var a = i / 18, b = (i + 1) / 18;
      var p0 = bez(x, y, cx, cy, hx, hy, a), p1 = bez(x, y, cx, cy, hx, hy, b);
      c.strokeStyle = i % 2 ? '#3a2a1f' : '#2d2018';
      c.lineWidth = mix(h * 0.05, h * 0.028, a);
      c.beginPath(); c.moveTo(p0[0], p0[1]); c.lineTo(p1[0], p1[1]); c.stroke();
    }
    var n = 11;
    for (var k = 0; k < n; k++) {
      var ang = -Math.PI / 2 + (k - (n - 1) / 2) * 0.42 + brise * 3 + (r() - 0.5) * 0.15;
      var L = h * (0.36 + r() * 0.12);
      feuillePalme(c, hx, hy, ang, L, fonce, Math.sin(u * 2 + k + graine) * 0.04);
    }
    c.fillStyle = '#3d2a1a';
    c.beginPath(); c.arc(hx, hy + 6, h * 0.025, 0, Math.PI * 2); c.fill();
    c.restore();
  }
  function bez(x0, y0, x1, y1, x2, y2, t) {
    var a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, d = t * t;
    return [a * x0 + b * x1 + d * x2, a * y0 + b * y1 + d * y2];
  }
  function feuillePalme(c, x, y, ang, L, couleur, frisson) {
    var ex = x + Math.cos(ang) * L, ey = y + Math.sin(ang) * L * 0.55 + L * 0.42;
    var mx = x + Math.cos(ang) * L * 0.55, my = y + Math.sin(ang) * L * 0.6 - L * 0.12 + frisson * L;
    var N = 26, pts = [];
    for (var i = 0; i <= N; i++) pts.push(bez(x, y, mx, my, ex, ey, i / N));
    var clair = 'rgba(120,170,80,0.55)';
    [-1, 1].forEach(function (cote) {
      for (var i = 2; i <= N; i++) {
        var dx = pts[i][0] - pts[i - 1][0], dy = pts[i][1] - pts[i - 1][1];
        var l = Math.sqrt(dx * dx + dy * dy) || 1;
        var tx = dx / l, ty = dy / l, nx = -ty * cote, ny = tx * cote;
        var s = i / N;
        var lf = L * 0.27 * Math.pow(Math.sin(Math.PI * Math.min(1, s * 1.08)), 0.7);
        var w0 = L * 0.02 * (1.2 - s * 0.6);
        var px = pts[i][0], py = pts[i][1];
        var bx = px + nx * lf * 0.75 + tx * lf * 0.5, by2 = py + ny * lf * 0.75 + ty * lf * 0.5 + lf * 0.5;
        c.fillStyle = (i + (cote > 0 ? 1 : 0)) % 3 ? couleur : '#1f4424';
        c.beginPath();
        c.moveTo(px - tx * w0, py - ty * w0);
        c.quadraticCurveTo(px + nx * lf * 0.5, py + ny * lf * 0.5 - lf * 0.05, bx, by2);
        c.quadraticCurveTo(px + nx * lf * 0.35 + tx * w0 * 2, py + ny * lf * 0.35 + w0 * 2, px + tx * w0, py + ty * w0);
        c.closePath(); c.fill();
        if (cote < 0 && i % 2) {
          c.strokeStyle = clair; c.lineWidth = 1.5;
          c.beginPath(); c.moveTo(px, py); c.quadraticCurveTo(px + nx * lf * 0.45, py + ny * lf * 0.45, bx, by2); c.stroke();
        }
      }
    });
    c.strokeStyle = '#2a4a22'; c.lineWidth = Math.max(3, L * 0.012); c.lineCap = 'round';
    c.beginPath(); c.moveTo(x, y); c.quadraticCurveTo(mx, my, ex, ey); c.stroke();
  }

  // Drapeau haïtien qui flotte. dir = 1 : il part vers la droite du mât.
  function drapeauHaiti(c, x, y, w, h, u, dir, mat) {
    if (mat) {
      c.fillStyle = degradeH(c, x - 6, x + 6, [[0, '#8b8f99'], [0.5, '#f2f2f2'], [1, '#6b6f78']]);
      c.fillRect(x - 5, y - 18, 10, mat);
      c.fillStyle = '#ffd36b';
      c.beginPath(); c.arc(x, y - 22, 10, 0, Math.PI * 2); c.fill();
    }
    var N = 48, larg = w / N;
    for (var i = 0; i < N; i++) {
      var s = (i + 0.5) / N;
      var ph = s * 4.4 - u * 4.6;
      var dy = Math.sin(ph) * h * 0.09 * s + s * h * 0.04;
      var sh = Math.cos(ph) * Math.min(1, s * 1.6);
      var px = dir > 0 ? x + i * larg : x - (i + 1) * larg;
      var py = y + dy;
      c.fillStyle = '#00209F'; c.fillRect(px, py, larg + 1, h / 2 + 1);
      c.fillStyle = '#D21034'; c.fillRect(px, py + h / 2, larg + 1, h / 2);
      if (s > 0.37 && s < 0.63) {
        c.fillStyle = '#ffffff'; c.fillRect(px, py + h * 0.31, larg + 1, h * 0.38);
        // Les armes, très simplifiées : palmier, trophée, pelouse
        c.fillStyle = '#2f7d32';
        if (Math.abs(s - 0.5) < 0.012) c.fillRect(px, py + h * 0.39, larg + 1, h * 0.2);
        if (Math.abs(s - 0.5) < 0.06) c.fillRect(px, py + h * 0.59, larg + 1, h * 0.04);
        if (Math.abs(s - 0.5) < 0.04) c.fillRect(px, py + h * 0.37 + Math.abs(s - 0.5) * h * 1.2, larg + 1, h * 0.025);
        if (Math.abs(s - 0.5) < 0.05 && Math.abs(s - 0.5) > 0.02) { c.fillStyle = '#7a5230'; c.fillRect(px, py + h * 0.55, larg + 1, h * 0.03); }
      }
      c.fillStyle = sh > 0 ? 'rgba(255,255,255,' + (sh * 0.22) + ')' : 'rgba(0,0,30,' + (-sh * 0.38) + ')';
      c.fillRect(px, py, larg + 1, h);
    }
  }

  // Bougainvillée en grappes (cadre les vues, comme dans la référence)
  function bougainvillee(c, cx, cy, rx, ry, graine) {
    var r = alea(graine), i;
    for (i = 0; i < 160; i++) {
      var a = r() * 6.28, d = Math.sqrt(r());
      var x = cx + Math.cos(a) * rx * d, y = cy + Math.sin(a) * ry * d;
      c.fillStyle = ['#0f3317', '#1a4a20', '#25602a'][Math.floor(r() * 3)];
      c.beginPath(); c.ellipse(x, y, 9 + r() * 10, 5 + r() * 5, r() * 3, 0, 6.28); c.fill();
    }
    for (i = 0; i < 300; i++) {
      var a2 = r() * 6.28, d2 = Math.sqrt(r());
      var x2 = cx + Math.cos(a2) * rx * d2 * 0.95, y2 = cy + Math.sin(a2) * ry * d2 * 0.95;
      c.fillStyle = ['#ff2f86', '#ff5fa8', '#e0186a', '#ff8cc3', '#c2125a'][Math.floor(r() * 5)];
      c.beginPath(); c.arc(x2, y2, 4 + r() * 6, 0, 6.28); c.fill();
    }
  }

  // Bouquet d'arbres tropicaux (Hinche)
  function canopee(c, cx, cy, rayon, graine, tons) {
    var r = alea(graine);
    for (var i = 0; i < 46; i++) {
      var a = r() * 6.28, d = Math.sqrt(r()) * rayon;
      var x = cx + Math.cos(a) * d, y = cy + Math.sin(a) * d * 0.7;
      var rr = rayon * (0.18 + r() * 0.2);
      var lum = (cy - y) / rayon * 0.5 + 0.5 + (cx - x) / rayon * 0.2;
      c.fillStyle = tons[Math.floor(borner(lum, 0, 0.999) * tons.length)];
      c.beginPath(); c.arc(x, y, rr, 0, 6.28); c.fill();
    }
  }

  // Petite maison caribéenne : façade colorée, toit, fenêtres allumées
  function maison(c, x, y, w, h, couleur, toit, r) {
    c.fillStyle = couleur; c.fillRect(x, y - h, w, h);
    c.fillStyle = 'rgba(255,190,120,0.18)'; c.fillRect(x + w * 0.55, y - h, w * 0.45, h);
    c.fillStyle = toit;
    c.beginPath(); c.moveTo(x - 4, y - h); c.lineTo(x + w / 2, y - h - w * 0.32); c.lineTo(x + w + 4, y - h); c.closePath(); c.fill();
    var nf = Math.max(1, Math.round(w / 22));
    for (var i = 0; i < nf; i++) {
      var fx = x + (i + 0.5) * w / nf - 4;
      c.fillStyle = r() < 0.7 ? '#ffd27a' : '#3a2f4a';
      c.fillRect(fx, y - h * 0.7, 8, h * 0.32);
    }
  }

  // Voilier de pêcheur, qui tangue
  function voilier(c, x, y, s, u, graine, voile) {
    var bob = Math.sin(u * 1.8 + graine) * 5 * s;
    var tilt = Math.sin(u * 1.4 + graine * 1.7) * 0.05;
    c.save();
    c.translate(x, y + bob); c.rotate(tilt); c.scale(s, s);
    c.fillStyle = 'rgba(255,200,140,0.25)';
    c.fillRect(-55, 22, 110, 4); c.fillRect(-40, 32, 80, 3);
    c.fillStyle = '#2b1a12';
    c.beginPath(); c.moveTo(-70, 0); c.lineTo(70, 0); c.lineTo(52, 20); c.lineTo(-55, 20); c.closePath(); c.fill();
    c.fillStyle = '#2f6fd1'; c.fillRect(-62, 2, 124, 5);
    c.strokeStyle = '#2b1a12'; c.lineWidth = 4;
    c.beginPath(); c.moveTo(0, 0); c.lineTo(0, -150); c.stroke();
    c.fillStyle = degradeH(c, 0, 90, [[0, voile], [1, '#fff3e0']]);
    c.beginPath(); c.moveTo(4, -146); c.quadraticCurveTo(60, -80, 92, -10); c.lineTo(4, -10); c.closePath(); c.fill();
    c.strokeStyle = 'rgba(80,50,30,0.35)'; c.lineWidth = 2;
    c.beginPath(); c.moveTo(4, -100); c.lineTo(58, -100); c.moveTo(4, -55); c.lineTo(78, -55); c.stroke();
    c.restore();
  }

  // Réverbère allumé
  function reverbere(c, x, y, h) {
    c.fillStyle = '#1b1d2b';
    c.fillRect(x - 4, y - h, 8, h);
    c.fillRect(x - 10, y - 12, 20, 12);
    c.fillStyle = '#ffe2a0';
    c.beginPath(); c.moveTo(x - 16, y - h); c.lineTo(x + 16, y - h); c.lineTo(x + 12, y - h - 34); c.lineTo(x - 12, y - h - 34); c.closePath(); c.fill();
    c.fillStyle = '#1b1d2b'; c.fillRect(x - 18, y - h - 40, 36, 7);
    halo(c, x, y - h - 17, 110, 'rgba(255,200,110,0.65)');
  }

  // Colis aux couleurs du logo (icône du trajet)
  function colis(c, x, y, s, ang) {
    c.save();
    c.translate(x, y); c.rotate(ang || 0); c.scale(s, s);
    halo(c, 0, 0, 70, 'rgba(255,140,40,0.6)');
    c.fillStyle = '#ff7a1a'; arrondi(c, -26, -20, 52, 40, 6); c.fill();
    c.fillStyle = '#d9590a'; c.fillRect(-26, 8, 52, 12);
    c.fillStyle = '#1f6bff'; c.fillRect(-6, -20, 12, 40);
    c.fillStyle = 'rgba(255,255,255,0.35)'; c.fillRect(-22, -16, 14, 4);
    c.restore();
  }

  // Épingle de localisation
  function epingle(c, x, y, s, couleur) {
    c.save();
    c.translate(x, y); c.scale(s, s);
    c.fillStyle = couleur || '#ff7a1a';
    c.beginPath(); c.arc(0, -8, 14, Math.PI * 0.85, Math.PI * 2.15); c.lineTo(0, 18); c.closePath(); c.fill();
    c.fillStyle = '#ffffff'; c.beginPath(); c.arc(0, -8, 5.5, 0, 6.28); c.fill();
    c.restore();
  }

  // ========================================================================
  //  Titres : chrome 3D, anneau lumineux, pastille
  // ========================================================================

  var PALETTE_CHROME = {
    arrets: [[0, '#ffffff'], [0.38, '#e4ebf3'], [0.5, '#8794a6'], [0.56, '#cfd8e3'], [0.8, '#ffffff'], [1, '#bfe3ff']],
    lueur: 'rgba(60,170,255,0.95)', relief: [8, 24, 62]
  };
  var PALETTE_ORANGE = {
    arrets: [[0, '#fff6e6'], [0.36, '#ffc271'], [0.5, '#c2440c'], [0.57, '#ff8a2a'], [0.82, '#ffd9a6'], [1, '#fff1d6']],
    lueur: 'rgba(255,130,30,0.95)', relief: [60, 18, 4]
  };

  function preparerTitre(texte, largeurMax, taille, pal) {
    var mesure = toile(10, 10).getContext('2d');
    var police = function (t) { return 'italic 900 ' + t + 'px Montserrat'; };
    mesure.font = police(taille);
    var tw = mesure.measureText(texte).width;
    if (tw > largeurMax) { taille = taille * largeurMax / tw; tw = largeurMax; }
    var cw = Math.ceil(tw + taille * 0.9), ch = Math.ceil(taille * 1.55);
    var bx = cw / 2, by = Math.round(ch * 0.74);
    var c = toile(cw, ch), x = c.getContext('2d');
    x.font = police(taille); x.textAlign = 'center';
    // Relief : la même lettre empilée vers le bas, de plus en plus sombre
    var prof = Math.round(taille * 0.075);
    for (var k = prof; k >= 1; k--) {
      var f = k / prof;
      x.fillStyle = k === prof ? 'rgba(0,8,24,0.75)'
        : 'rgb(' + Math.round(pal.relief[0] + 40 * (1 - f)) + ',' + Math.round(pal.relief[1] + 50 * (1 - f)) + ',' + Math.round(pal.relief[2] + 70 * (1 - f)) + ')';
      x.fillText(texte, bx + k * 0.45, by + k);
    }
    x.save();
    x.shadowColor = pal.lueur; x.shadowBlur = taille * 0.22;
    x.fillStyle = pal.lueur; x.fillText(texte, bx, by);
    x.restore();
    // Liseré sombre : le texte décalé tout autour, plutôt qu'un strokeText
    // qui dessinerait aussi les contours internes de la police
    var o = Math.max(1.5, taille * 0.013);
    x.fillStyle = 'rgba(10,18,42,0.95)';
    for (var a = 0; a < 12; a++) x.fillText(texte, bx + Math.cos(a / 12 * 6.283) * o, by + Math.sin(a / 12 * 6.283) * o);
    x.fillStyle = degradeV(x, by - taille * 0.74, by + 2, pal.arrets);
    x.fillText(texte, bx, by);
    var m = toile(cw, ch), mx = m.getContext('2d');
    mx.font = police(taille); mx.textAlign = 'center'; mx.fillStyle = '#fff';
    mx.fillText(texte, bx, by);
    return { c: c, masque: m, w: cw, h: ch, taille: taille, reflet: toile(cw, ch) };
  }

  // p : apparition (0 → 1) ; brillance : position du reflet qui balaie (0 → 1)
  function dessinerTitre(c, T, cx, cy, p, brillance) {
    if (p <= 0) return;
    var s = mix(1.45, 1, rebond(p));
    c.save();
    c.globalAlpha = borner(p * 2.2, 0, 1);
    c.translate(cx, cy); c.scale(s, s);
    c.drawImage(T.c, -T.w / 2, -T.h * 0.74);
    if (brillance > 0 && brillance < 1) {
      var r = T.reflet.getContext('2d');
      r.globalCompositeOperation = 'source-over';
      r.clearRect(0, 0, T.w, T.h);
      var bx = mix(-T.w * 0.3, T.w * 1.3, brillance);
      var g = r.createLinearGradient(bx - 140, 0, bx + 140, T.h * 0.4);
      g.addColorStop(0, 'rgba(255,255,255,0)');
      g.addColorStop(0.5, 'rgba(255,255,255,0.95)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      r.fillStyle = g; r.fillRect(0, 0, T.w, T.h);
      r.globalCompositeOperation = 'destination-in';
      r.drawImage(T.masque, 0, 0);
      c.globalCompositeOperation = 'lighter';
      c.drawImage(T.reflet, -T.w / 2, -T.h * 0.74);
    }
    c.restore();
  }

  // Anneau de lumière autour du titre : partie arrière dessinée avant le
  // texte, partie avant après, pour qu'il passe derrière puis devant.
  function anneau(c, cx, cy, rx, ry, rot, a0, a1, teinte, epais, partie) {
    var n = Math.max(2, Math.ceil(Math.abs(a1 - a0) / 0.025));
    var cr = Math.cos(rot), sr = Math.sin(rot);
    function pt(a) {
      var ex = rx * Math.cos(a), ey = ry * Math.sin(a);
      return [cx + ex * cr - ey * sr, cy + ex * sr + ey * cr];
    }
    c.save();
    c.globalCompositeOperation = 'lighter';
    c.lineCap = 'round';
    var passes = [[3.6, 0.10], [1.7, 0.35], [0.55, 0.95]];
    passes.forEach(function (pp, ip) {
      for (var i = 0; i < n; i++) {
        var a = mix(a0, a1, i / n), b = mix(a0, a1, (i + 1) / n);
        var devant = Math.sin((a + b) / 2) > 0;
        if (partie === 'arriere' && devant) continue;
        if (partie === 'avant' && !devant) continue;
        var k = (i + 1) / n;
        var p0 = pt(a), p1 = pt(b);
        c.strokeStyle = ip === 2 ? 'rgba(235,248,255,' + (pp[1] * k) + ')' : 'rgba(' + teinte + ',' + (pp[1] * k) + ')';
        c.lineWidth = epais * pp[0] * (0.25 + 0.75 * k);
        c.beginPath(); c.moveTo(p0[0], p0[1]); c.lineTo(p1[0], p1[1]); c.stroke();
      }
    });
    if (partie !== 'arriere' || Math.sin(a1) <= 0) {
      var tete = pt(a1);
      halo(c, tete[0], tete[1], epais * 9, 'rgba(' + teinte + ',0.9)');
      halo(c, tete[0], tete[1], epais * 3, 'rgba(255,255,255,0.9)');
    }
    c.restore();
  }

  // Les deux anneaux d'un titre (bleu, puis orange aux couleurs de Goship)
  function anneaux(c, cx, cy, rx, ry, u, partie) {
    var p = sortie(prog(u, 0, 0.9));
    if (p <= 0) return;
    var tourne = u * 0.35;
    var a1 = -2.2 + p * 5.2 + tourne;
    anneau(c, cx, cy, rx, ry, -0.12, a1 - Math.min(p * 5.2, 3.6), a1, '40,160,255', 7, partie);
    var p2 = sortie(prog(u, 0.25, 1.15));
    if (p2 > 0) {
      var b1 = 1.2 - p2 * 4.4 - tourne * 0.8;
      anneau(c, cx, cy + 14, rx * 0.86, ry * 0.8, -0.08, b1 + Math.min(p2 * 4.4, 2.2), b1, '255,130,30', 4.5, partie);
    }
  }

  function pastille(c, cx, cy, texte, p, frappe) {
    if (p <= 0) return;
    c.save();
    c.font = 'italic 800 42px Montserrat';
    var tw = c.measureText(texte).width;
    var w = tw + 130, h = 76;
    var e = sortie(p);
    c.globalAlpha = borner(p * 2, 0, 1);
    c.translate(cx, cy);
    c.save();
    c.transform(e, 0, -0.22 * e, 1, 0, 0);
    arrondi(c, -w / 2, -h / 2, w, h, 14);
    c.fillStyle = 'rgba(5,18,48,0.86)'; c.fill();
    c.shadowColor = 'rgba(60,170,255,0.9)'; c.shadowBlur = 18;
    c.lineWidth = 3; c.strokeStyle = degradeH(c, -w / 2, w / 2, [[0, '#2aa3ff'], [0.5, '#bfe8ff'], [1, '#2aa3ff']]);
    c.stroke();
    c.restore();
    epingle(c, -w / 2 + 52, -2, 1.15, '#ff7a1a');
    var n = Math.floor(texte.length * borner(frappe, 0, 1));
    c.fillStyle = '#ffffff'; c.textBaseline = 'middle';
    c.fillText(texte.slice(0, n), -w / 2 + 88, 2);
    c.restore();
  }

  // Le bloc complet d'une ville : anneaux + titre + pastille
  function blocTitre(c, i, u, y) {
    var T = cache['titre' + i];
    anneaux(c, 540, y - T.taille * 0.3, 545, 150, u - 0.6, 'arriere');
    dessinerTitre(c, T, 540, y, prog(u, 0.85, 1.45), prog(u, 1.5, 2.3) || -1);
    anneaux(c, 540, y - T.taille * 0.3, 545, 150, u - 0.6, 'avant');
    if (u > 3.3 && u < 4.1) dessinerTitre(c, T, 540, y, 1, prog(u, 3.3, 4.1));
    pastille(c, 540, y + 105, VILLES[i].dep, prog(u, 1.35, 1.8), prog(u, 1.55, 2.5));
  }

  // ========================================================================
  //  Les six villes
  // ========================================================================

  // --- Port-au-Prince : le Palais national, son dôme, son drapeau ---------
  function dessinerPortAuPrince(c, u, z) {
    var B = 1330;
    var fond = couche('pap-ciel', function (x) { ciel(x, 1150, PAL_COUCHANT, 860, 1005, 58); });
    var champ = cache['pap-nuages'] || (cache['pap-nuages'] = champNuages(11, 60, 940, 30));
    var monts = couche('pap-monts', function (x) {
      var n1 = bruit(3), n2 = bruit(4);
      var loin = function (X) { return 990 - 70 * n1(X, 0.004) - 40; };
      var pres = function (X) { return 1085 - 55 * n2(X, 0.006); };
      crete(x, loin, 1200, '#6f6cb2', '#9b86be');
      crete(x, pres, 1250, '#3b3f80', '#262a5e');
      lumieres(x, 5, 260, 0, W, pres, 1240, 2.4);
    });
    var palais = couche('pap-palais', function (x) { dessinerPalais(x, B); });
    var reflet = preparerReflet('pap-reflet', palais, B, 420, 0.55, 'rgba(25,30,80,0.35)');
    var sol = couche('pap-sol', function (x) {
      x.fillStyle = degradeV(x, B - 40, H, [[0, '#3a3f6e'], [0.25, '#20264d'], [1, '#0c1029']]);
      x.fillRect(0, B - 40, W, H);
      x.strokeStyle = 'rgba(255,220,170,0.08)'; x.lineWidth = 2;
      for (var k = -12; k <= 12; k++) { x.beginPath(); x.moveTo(540 + k * 20, B); x.lineTo(540 + k * 170, H); x.stroke(); }
      for (var j = 0; j < 9; j++) { var yy = B + Math.pow(j / 9, 1.8) * (H - B); x.beginPath(); x.moveTo(0, yy); x.lineTo(W, yy); x.stroke(); }
      x.fillStyle = '#173d24';
      x.beginPath(); x.moveTo(0, B + 10); x.lineTo(300, B + 10); x.lineTo(80, H); x.lineTo(0, H); x.fill();
      x.beginPath(); x.moveTo(W, B + 10); x.lineTo(780, B + 10); x.lineTo(1000, H); x.lineTo(W, H); x.fill();
    });

    camera(c, 0.2, z); c.drawImage(fond, 0, 0); dessinerNuages(c, champ, u);
    camera(c, 0.45, z); c.drawImage(monts, 0, 0);
    camera(c, 0.75, z); c.drawImage(sol, 0, 0);
    dessinerReflet(c, reflet, B, u, 1.2);
    c.drawImage(palais, 0, 0);
    drapeauHaiti(c, 540, 470, 250, 160, u, 1, 360);
    camera(c, 1.25, z);
    reverbere(c, 215, 1680, 330); reverbere(c, 865, 1680, 330);
    palmier(c, -40, 1760, 1180, 0.06, u, 7);
    palmier(c, 1120, 1780, 1140, -0.06, u, 9);
    c.setTransform(1, 0, 0, 1, 0, 0);
  }

  function dessinerPalais(x, B) {
    var facade = function () { return degradeH(x, 90, 990, [[0, '#d3cbe0'], [0.5, '#f6eee6'], [1, '#ffe2c2']]); };
    // Ailes
    x.fillStyle = facade(); x.fillRect(90, 1150, 900, B - 1150);
    x.fillStyle = '#fff8ef'; x.fillRect(80, 1140, 920, 14);
    x.fillStyle = 'rgba(90,70,100,0.35)'; x.fillRect(90, 1154, 900, 6);
    x.fillStyle = '#efe6dc';
    for (var bx = 92; bx < 988; bx += 14) x.fillRect(bx, 1122, 6, 18);
    x.fillRect(84, 1116, 912, 6);
    // Fenêtres cintrées, allumées
    [1180, 1258].forEach(function (fy) {
      for (var fx = 120; fx < 970; fx += 44) {
        if (fx > 380 && fx < 700) continue;
        if ((fx > 105 && fx < 295) || (fx > 785 && fx < 975)) continue;
        x.fillStyle = '#ffcf73';
        x.beginPath(); x.moveTo(fx, fy + 52); x.lineTo(fx, fy + 12); x.arc(fx + 12, fy + 12, 12, Math.PI, 0); x.lineTo(fx + 24, fy + 52); x.fill();
        x.fillStyle = 'rgba(120,70,40,0.35)'; x.fillRect(fx + 11, fy, 2, 52);
      }
    });
    // Pavillons d'angle et leurs dômes
    [[110, 290], [790, 970]].forEach(function (p) {
      x.fillStyle = facade(); x.fillRect(p[0], 1100, p[1] - p[0], B - 1100);
      x.fillStyle = '#fff8ef'; x.fillRect(p[0] - 8, 1090, p[1] - p[0] + 16, 14);
      var cx = (p[0] + p[1]) / 2;
      x.fillStyle = facade(); x.fillRect(cx - 56, 1040, 112, 52);
      dome(x, cx, 1042, 64, 80);
      for (var k = 0; k < 3; k++) {
        var wx = p[0] + 30 + k * 50;
        x.fillStyle = '#ffcf73'; x.fillRect(wx, 1180, 22, 54); x.fillRect(wx, 1262, 22, 50);
      }
      x.fillStyle = 'rgba(255,255,255,0.6)';
      x.fillRect(p[0] + 6, 1110, 8, B - 1110); x.fillRect(p[1] - 14, 1110, 8, B - 1110);
    });
    // Pavillon central, tambour, grand dôme
    x.fillStyle = facade(); x.fillRect(395, 1075, 290, B - 1075);
    x.fillRect(452, 962, 176, 116);
    for (var cc = 0; cc < 6; cc++) { x.fillStyle = 'rgba(140,120,150,0.45)'; x.fillRect(462 + cc * 31, 975, 4, 96); x.fillStyle = '#ffd27a'; x.fillRect(470 + cc * 31, 1000, 10, 36); }
    dome(x, 540, 964, 108, 132);
    x.fillStyle = facade(); x.fillRect(526, 812, 28, 24);
    dome(x, 540, 814, 18, 22);
    // Fronton
    x.fillStyle = '#fbf3ea';
    x.beginPath(); x.moveTo(382, 1082); x.lineTo(540, 1012); x.lineTo(698, 1082); x.closePath(); x.fill();
    x.strokeStyle = 'rgba(120,95,110,0.5)'; x.lineWidth = 3; x.stroke();
    // Portique
    x.fillStyle = 'rgba(55,40,70,0.6)'; x.fillRect(410, 1092, 260, 214);
    x.fillStyle = '#ffcf7a'; x.fillRect(518, 1205, 44, 101);
    halo(x, 540, 1250, 120, 'rgba(255,190,100,0.35)');
    for (var i = 0; i < 4; i++) {
      var cx2 = 434 + i * 71;
      x.fillStyle = degradeH(x, cx2 - 12, cx2 + 12, [[0, '#c9bfd2'], [0.5, '#fffaf2'], [1, '#e8d5c0']]);
      x.fillRect(cx2 - 12, 1092, 24, 214);
      x.fillStyle = '#fff8ef'; x.fillRect(cx2 - 17, 1086, 34, 10); x.fillRect(cx2 - 16, 1300, 32, 8);
    }
    x.fillStyle = '#fff8ef'; x.fillRect(388, 1080, 304, 12);
    // Marches
    for (var s = 0; s < 4; s++) { x.fillStyle = s % 2 ? '#d9cfc6' : '#f3ebe3'; x.fillRect(370 - s * 12, B - 26 + s * 7, 340 + s * 24, 7); }
    x.fillStyle = '#efe5da'; x.fillRect(84, B - 10, 912, 10);
  }
  function dome(x, cx, by, rx, ry) {
    x.fillStyle = degradeH(x, cx - rx, cx + rx, [[0, '#b3aecb'], [0.55, '#f8f2ec'], [1, '#ffd7ae']]);
    x.beginPath(); x.ellipse(cx, by, rx, ry, 0, Math.PI, 0); x.closePath(); x.fill();
    x.strokeStyle = 'rgba(120,100,135,0.35)'; x.lineWidth = 2;
    for (var k = -3; k <= 3; k++) {
      if (!k) { x.beginPath(); x.moveTo(cx, by); x.lineTo(cx, by - ry); x.stroke(); continue; }
      var rk = rx * Math.abs(k) / 3.6;
      x.beginPath();
      if (k < 0) x.ellipse(cx, by, rk, ry, 0, Math.PI, 1.5 * Math.PI);
      else x.ellipse(cx, by, rk, ry, 0, 1.5 * Math.PI, 2 * Math.PI);
      x.stroke();
    }
    x.fillStyle = '#fff6ec'; x.fillRect(cx - rx - 6, by - 6, 2 * rx + 12, 11);
  }

  // --- Cap-Haïtien : la Citadelle sur son pic, la baie, la ville ---------
  function dessinerCapHaitien(c, u, z) {
    var MER = 1270;
    var fond = couche('cap-ciel', function (x) { ciel(x, MER, PAL_ROSE, 170, 1130, 54); });
    var champ = cache['cap-nuages'] || (cache['cap-nuages'] = champNuages(23, 50, 700, 26));
    var montagne = couche('cap-montagne', function (x) {
      var n0 = bruit(31), n = bruit(17);
      crete(x, function (X) { return 1090 - 60 * n0(X, 0.005); }, MER, '#6a5a9a', '#8a6f9f');
      var profil = function (X) { return MER - 760 * Math.exp(-Math.pow((X - 600) / 300, 2)) - 120 * Math.exp(-Math.pow((X - 950) / 260, 2)) - 26 * n(X, 0.02); };
      crete(x, profil, MER + 10, '#3f7a3e', '#183823');
      // Lumière rasante venue de la gauche (le soleil)
      x.save();
      x.globalCompositeOperation = 'source-atop';
      x.fillStyle = degradeH(x, 250, 800, [[0, 'rgba(255,170,80,0.5)'], [0.5, 'rgba(255,170,80,0.08)'], [1, 'rgba(10,20,40,0.45)']]);
      x.fillRect(0, 0, W, MER);
      x.restore();
      var r = alea(5);
      for (var i = 0; i < 900; i++) {
        var X = r() * W, Y = mix(profil(X) + 10, MER, r());
        if (Y < profil(X) + 6) continue;
        x.fillStyle = ['rgba(15,45,20,0.6)', 'rgba(40,85,35,0.6)', 'rgba(90,120,50,0.45)'][Math.floor(r() * 3)];
        x.beginPath(); x.arc(X, Y, 4 + r() * 8, 0, 6.28); x.fill();
      }
      dessinerCitadelle(x);
    });
    var ville = couche('cap-ville', function (x) {
      var r = alea(8);
      var couleurs = ['#f2b33d', '#e5566f', '#3fb6b0', '#6a8fe8', '#f08a4b', '#f5e1b8', '#b9e06a'];
      for (var X = -10; X < W; ) {
        var w = 46 + r() * 50, h = 50 + r() * 60;
        maison(x, X, MER + 4, w, h, couleurs[Math.floor(r() * couleurs.length)], r() < 0.5 ? '#8b2f1f' : '#5a3b2a', r);
        X += w + 4;
      }
      // La cathédrale, blanche, dôme rouge
      x.fillStyle = '#f6efe6'; x.fillRect(150, MER - 150, 160, 154);
      x.fillStyle = '#d4483a'; x.beginPath(); x.ellipse(230, MER - 150, 50, 62, 0, Math.PI, 0); x.fill();
      x.fillStyle = '#f6efe6'; x.fillRect(222, MER - 236, 16, 28);
      x.fillStyle = '#ffd27a'; x.fillRect(214, MER - 90, 32, 92);
      x.fillRect(170, MER - 120, 16, 40); x.fillRect(274, MER - 120, 16, 40);
    });
    var reflet = preparerReflet('cap-reflet', ville, MER + 4, 300, 0.6, 'rgba(30,40,100,0.3)');
    var mer = couche('cap-mer', function (x) {
      x.fillStyle = degradeV(x, MER, H, [[0, '#e58f7a'], [0.12, '#8b6fa8'], [0.45, '#2a3f8a'], [1, '#0c1840']]);
      x.fillRect(0, MER, W, H - MER);
    });
    var fleurs = couche('cap-fleurs', function (x) {
      bougainvillee(x, 1000, 120, 260, 230, 4);
      bougainvillee(x, 1060, 420, 150, 170, 6);
      x.fillStyle = degradeV(x, 1700, H, [[0, '#8a6a4a'], [1, '#3b2a1e']]);
      x.beginPath(); x.moveTo(0, 1780); x.lineTo(380, 1760); x.lineTo(420, H); x.lineTo(0, H); x.fill();
      x.fillStyle = 'rgba(255,190,120,0.35)'; x.fillRect(0, 1760, 400, 10);
    });

    camera(c, 0.2, z); c.drawImage(fond, 0, 0); dessinerNuages(c, champ, u);
    camera(c, 0.5, z); c.drawImage(montagne, 0, 0);
    drapeauHaiti(c, 640, 505, 70, 45, u, 1, 60);
    // Brume qui s'accroche à la montagne
    dessinerNuages(c, cache['cap-brume'] || (cache['cap-brume'] = champNuages(77, 860, 1080, 7)), u * 1.6, 0.55);
    camera(c, 0.7, z);
    c.drawImage(mer, 0, 0);
    dessinerReflet(c, reflet, MER + 4, u, 1.6);
    scintillements(c, 12, 140, 260, MER + 8, 1900, 300, u, 'rgba(255,190,140,1)');
    c.drawImage(ville, 0, 0);
    voilier(c, 820, 1420, 0.9, u, 1, '#f3e4c8');
    voilier(c, 120, 1560, 1.15, u, 2, '#e85a3a');
    camera(c, 1.2, z); c.drawImage(fleurs, 0, 0);
    c.setTransform(1, 0, 0, 1, 0, 0);
  }

  function dessinerCitadelle(x) {
    // Silhouette en proue de navire, posée sur le pic (Bonnet à l'Évêque)
    var pts = [[430, 600], [492, 528], [700, 500], [790, 545], [785, 640], [560, 668], [470, 655]];
    x.beginPath(); pts.forEach(function (p, i) { if (i) x.lineTo(p[0], p[1]); else x.moveTo(p[0], p[1]); }); x.closePath();
    x.fillStyle = degradeH(x, 430, 790, [[0, '#f0be82'], [0.35, '#c99a66'], [0.7, '#8a6a4c'], [1, '#5e4836']]);
    x.fill();
    // Face avant, plus sombre
    x.beginPath(); x.moveTo(430, 600); x.lineTo(470, 655); x.lineTo(560, 668); x.lineTo(560, 610); x.lineTo(492, 528); x.closePath();
    x.fillStyle = 'rgba(255,190,120,0.35)'; x.fill();
    // Assises de pierre
    x.strokeStyle = 'rgba(70,45,30,0.35)'; x.lineWidth = 2;
    for (var y = 540; y < 665; y += 12) { x.beginPath(); x.moveTo(440, y + 20); x.lineTo(785, y); x.stroke(); }
    // Embrasures des canons, sur deux rangs
    x.fillStyle = 'rgba(40,25,20,0.85)';
    for (var k = 0; k < 9; k++) { x.fillRect(575 + k * 22, 585 - k * 1.8, 9, 7); x.fillRect(585 + k * 21, 620 - k * 1.5, 9, 7); }
    for (k = 0; k < 4; k++) x.fillRect(478 + k * 18, 600 + k * 9, 7, 6);
    // Couronnement
    x.fillStyle = '#d8ac76';
    for (k = 0; k < 14; k++) x.fillRect(505 + k * 20, 510 - k * 0.6, 12, 14);
    x.fillStyle = degradeH(x, 610, 690, [[0, '#e3b37e'], [1, '#8a6a4c']]);
    x.fillRect(612, 470, 78, 40);
    halo(x, 470, 600, 90, 'rgba(255,170,80,0.35)');
  }

  // --- Gonaïves : la Cité de l'Indépendance, son monument « 1804 » ------
  function dessinerGonaives(c, u, z) {
    var B = 1300;
    var fond = couche('gon-ciel', function (x) { ciel(x, 1230, PAL_OR, 330, 1120, 70); });
    var champ = cache['gon-nuages'] || (cache['gon-nuages'] = champNuages(37, 60, 900, 32));
    var monts = couche('gon-monts', function (x) {
      var n1 = bruit(41), n2 = bruit(42);
      crete(x, function (X) { return 1080 - 90 * n1(X, 0.005); }, 1250, '#9c6c86', '#b98a8c');
      crete(x, function (X) { return 1170 - 60 * n2(X, 0.008); }, 1260, '#6d4a6a', '#4e3554');
    });
    var place = couche('gon-place', function (x) {
      // Bâtiments à arcades, de part et d'autre de la place
      [[-20, 330, '#f4d6a6'], [750, 1100, '#f1c48e']].forEach(function (b, ib) {
        x.fillStyle = b[2]; x.fillRect(b[0], 1050, b[1] - b[0], B - 1050);
        x.fillStyle = '#8b3a26'; x.fillRect(b[0] - 10, 1035, b[1] - b[0] + 20, 18);
        x.fillStyle = ib ? 'rgba(80,40,60,0.25)' : 'rgba(255,200,140,0.25)';
        x.fillRect(b[0], 1050, b[1] - b[0], B - 1050);
        for (var a = b[0] + 20; a < b[1] - 40; a += 70) {
          x.fillStyle = '#ffcf7a';
          x.beginPath(); x.moveTo(a, B); x.lineTo(a, 1210); x.arc(a + 25, 1210, 25, Math.PI, 0); x.lineTo(a + 50, B); x.fill();
          x.fillRect(a + 10, 1085, 30, 60);
          x.fillStyle = 'rgba(255,255,255,0.7)'; x.fillRect(a + 4, 1148, 42, 5);
        }
      });
      // Le monument : soubassement, piédestal « 1804 », obélisque, flamme
      for (var s = 0; s < 4; s++) { x.fillStyle = s % 2 ? '#d7c3a8' : '#efe1cb'; x.fillRect(360 + s * 18, B - 24 - s * 22, 360 - s * 36, 24); }
      x.fillStyle = degradeH(x, 448, 632, [[0, '#fff1d8'], [0.5, '#e9d5b8'], [1, '#a88f78']]);
      x.fillRect(448, 1090, 184, 130);
      x.fillStyle = '#fff6e6'; x.fillRect(438, 1080, 204, 14); x.fillRect(438, 1212, 204, 10);
      x.font = 'italic 900 64px Montserrat'; x.textAlign = 'center';
      x.fillStyle = '#b8862b'; x.fillText('1804', 542, 1178);
      x.fillStyle = '#ffd772'; x.fillText('1804', 540, 1175);
      x.beginPath(); x.moveTo(495, 1080); x.lineTo(518, 580); x.lineTo(562, 580); x.lineTo(585, 1080); x.closePath();
      x.fillStyle = degradeH(x, 495, 585, [[0, '#fff3dd'], [0.45, '#efdcc0'], [1, '#9e8670']]); x.fill();
      x.beginPath(); x.moveTo(516, 582); x.lineTo(540, 530); x.lineTo(564, 582); x.closePath(); x.fillStyle = '#e2c9a6'; x.fill();
      x.fillStyle = '#ffcc4d';
      x.beginPath(); x.moveTo(540, 440); x.quadraticCurveTo(575, 490, 552, 528); x.lineTo(528, 528); x.quadraticCurveTo(505, 490, 540, 440); x.fill();
      halo(x, 540, 495, 140, 'rgba(255,190,80,0.7)');
    });
    var reflet = preparerReflet('gon-reflet', place, B, 460, 0.5, 'rgba(60,30,60,0.3)');
    var sol = couche('gon-sol', function (x) {
      x.fillStyle = degradeV(x, B - 10, H, [[0, '#7c5a63'], [0.3, '#3a2a45'], [1, '#140f22']]);
      x.fillRect(0, B - 10, W, H);
      x.strokeStyle = 'rgba(255,210,160,0.07)'; x.lineWidth = 2;
      for (var k = -14; k <= 14; k++) { x.beginPath(); x.moveTo(540 + k * 25, B); x.lineTo(540 + k * 190, H); x.stroke(); }
    });

    camera(c, 0.2, z); c.drawImage(fond, 0, 0); dessinerNuages(c, champ, u);
    camera(c, 0.45, z); c.drawImage(monts, 0, 0);
    camera(c, 0.8, z); c.drawImage(sol, 0, 0);
    dessinerReflet(c, reflet, B, u, 1);
    c.drawImage(place, 0, 0);
    camera(c, 1.25, z);
    palmier(c, 60, 1700, 1080, 0.02, u, 3);
    palmier(c, 1030, 1720, 1040, -0.02, u, 5);
    c.setTransform(1, 0, 0, 1, 0, 0);
    // Grand drapeau qui entre par le coin, comme dans la référence
    camera(c, 1.4, z);
    drapeauHaiti(c, 1062, 110, 440, 285, u, -1, 900);
    c.setTransform(1, 0, 0, 1, 0, 0);
  }

  // --- Les Cayes : la mer du Sud, l'Île-à-Vache, les voiliers -------------
  function dessinerLesCayes(c, u, z) {
    var HZ = 1060;
    var fond = couche('cay-ciel', function (x) { ciel(x, HZ, PAL_ROSE, 540, HZ - 30, 95); });
    var champ = cache['cay-nuages'] || (cache['cay-nuages'] = champNuages(53, 60, 820, 30));
    var cote = couche('cay-cote', function (x) {
      x.fillStyle = degradeV(x, HZ, 1680, [[0, '#ffb070'], [0.08, '#f0866a'], [0.4, '#4b4f9e'], [1, '#14275e']]);
      x.fillRect(0, HZ, W, 1700 - HZ);
      x.fillStyle = '#ffe6a8'; x.beginPath(); x.ellipse(540, HZ, 120, 14, 0, 0, Math.PI); x.fill();
      // Île-à-Vache, à l'horizon
      x.fillStyle = '#3f3468';
      x.beginPath(); x.moveTo(690, HZ); x.quadraticCurveTo(780, HZ - 46, 880, HZ - 30); x.quadraticCurveTo(990, HZ - 50, 1090, HZ - 20); x.lineTo(1090, HZ); x.fill();
      // La côte et la ville, à gauche
      x.fillStyle = '#2e2a5a';
      x.beginPath(); x.moveTo(-10, HZ - 120); x.quadraticCurveTo(170, HZ - 150, 300, HZ - 40); x.lineTo(380, HZ + 12); x.lineTo(-10, HZ + 30); x.fill();
      var r = alea(19);
      var couleurs = ['#f2b33d', '#e5566f', '#3fb6b0', '#6a8fe8', '#f08a4b'];
      for (var X = -6; X < 340; ) { var w = 26 + r() * 26; maison(x, X, HZ + 26 - X * 0.03, w, 26 + r() * 30, couleurs[Math.floor(r() * 5)], '#6b2a1f', r); X += w + 3; }
      x.fillStyle = '#efe6dc'; x.fillRect(120, HZ - 110, 34, 120);
      x.beginPath(); x.moveTo(114, HZ - 110); x.lineTo(137, HZ - 175); x.lineTo(160, HZ - 110); x.fill();
      x.fillStyle = '#ffd27a'; x.fillRect(130, HZ - 80, 14, 26);
    });
    var plage = couche('cay-plage', function (x) {
      x.fillStyle = degradeV(x, 1660, H, [[0, '#f4c27f'], [0.4, '#d99a5b'], [1, '#7a4a2c']]);
      x.beginPath(); x.moveTo(0, 1690); x.quadraticCurveTo(540, 1640, W, 1700); x.lineTo(W, H); x.lineTo(0, H); x.fill();
      var r = alea(23);
      for (var i = 0; i < 500; i++) { x.fillStyle = 'rgba(120,70,40,' + (0.1 + r() * 0.2) + ')'; x.fillRect(r() * W, 1700 + r() * 220, 2, 2); }
    });

    camera(c, 0.2, z); c.drawImage(fond, 0, 0); dessinerNuages(c, champ, u);
    camera(c, 0.6, z); c.drawImage(cote, 0, 0);
    scintillements(c, 31, 260, 540, HZ + 4, 1660, 260, u, 'rgba(255,215,150,1)');
    voilier(c, 760, 1220, 0.65, u, 3, '#f6e7cf');
    voilier(c, 310, 1330, 0.85, u, 4, '#d9452e');
    voilier(c, 900, 1480, 1.05, u, 5, '#f0c24a');
    camera(c, 0.95, z);
    c.drawImage(plage, 0, 0);
    // L'écume qui monte et redescend sur le sable
    var ec = Math.sin(u * 1.3) * 14;
    c.fillStyle = 'rgba(255,255,255,0.7)';
    c.beginPath(); c.moveTo(0, 1690 + ec);
    for (var X = 0; X <= W; X += 20) c.lineTo(X, 1688 + ec + Math.sin(X * 0.03 + u * 2) * 6 - Math.sin(X / W * Math.PI) * 30);
    c.lineTo(W, 1712 + ec); c.lineTo(0, 1712 + ec); c.fill();
    camera(c, 1.35, z);
    palmier(c, -90, 1940, 1120, 0.13, u, 11);
    palmier(c, 1170, 1960, 1060, -0.14, u, 13);
    c.setTransform(1, 0, 0, 1, 0, 0);
  }

  // --- Hinche : le Bassin Zim, sa cascade et ses vasques turquoise -------
  function dessinerHinche(c, u, z) {
    var fond = couche('hin-ciel', function (x) { ciel(x, 980, PAL_JOUR, 860, 760, 50); });
    var champ = cache['hin-nuages'] || (cache['hin-nuages'] = champNuages(61, 60, 650, 22));
    var relief = couche('hin-relief', function (x) {
      var n1 = bruit(71), n2 = bruit(72);
      crete(x, function (X) { return 800 - 90 * n1(X, 0.005); }, 1100, '#5f8f7a', '#4a7a5c');
      crete(x, function (X) { return 900 - 60 * n2(X, 0.008); }, 1150, '#3f7344', '#2b5a32');
      // La falaise calcaire
      x.beginPath(); x.moveTo(200, 1300); x.quadraticCurveTo(240, 860, 330, 830); x.lineTo(760, 820); x.quadraticCurveTo(860, 860, 880, 1300); x.closePath();
      x.fillStyle = degradeH(x, 200, 880, [[0, '#8b7a5c'], [0.4, '#c8b48a'], [1, '#6e6048']]); x.fill();
      var r = alea(3);
      for (var i = 0; i < 220; i++) {
        var X = 230 + r() * 620, Y = 840 + r() * 440;
        x.fillStyle = ['rgba(60,100,40,0.55)', 'rgba(110,140,60,0.5)', 'rgba(70,60,40,0.4)'][Math.floor(r() * 3)];
        x.beginPath(); x.arc(X, Y, 3 + r() * 9, 0, 6.28); x.fill();
      }
      // Le rideau d'eau, de fond
      x.fillStyle = degradeV(x, 830, 1300, [[0, 'rgba(225,250,255,0.95)'], [1, 'rgba(160,235,235,0.9)']]);
      x.beginPath(); x.moveTo(330, 832); x.lineTo(750, 822); x.quadraticCurveTo(800, 1050, 830, 1300); x.lineTo(250, 1300); x.quadraticCurveTo(290, 1050, 330, 832); x.fill();
      // Vasques en gradins
      [[1290, 1360, 120], [1400, 1490, 60], [1540, H, 0]].forEach(function (v) {
        x.fillStyle = degradeV(x, v[0], v[1], [[0, '#7ff0e6'], [0.5, '#2cc6c9'], [1, '#0e7c93']]);
        x.beginPath(); x.moveTo(v[2] - 40, v[0]); x.quadraticCurveTo(540, v[0] - 30, W - v[2] + 40, v[0]); x.lineTo(W - v[2] + 60, v[1]); x.lineTo(v[2] - 60, v[1]); x.fill();
        x.fillStyle = 'rgba(240,230,200,0.9)';
        x.beginPath(); x.moveTo(v[2] - 40, v[0]); x.quadraticCurveTo(540, v[0] - 30, W - v[2] + 40, v[0]); x.lineTo(W - v[2] + 40, v[0] + 8); x.quadraticCurveTo(540, v[0] - 22, v[2] - 40, v[0] + 8); x.fill();
      });
    });
    var jungle = couche('hin-jungle', function (x) {
      var tons = ['#0e2a16', '#163d1f', '#22552a', '#357035', '#5c8f3c', '#93b552'];
      canopee(x, 20, 880, 230, 1, tons); canopee(x, 40, 1230, 250, 2, tons); canopee(x, -10, 1600, 260, 3, tons);
      canopee(x, 1060, 860, 230, 4, tons); canopee(x, 1050, 1210, 250, 5, tons); canopee(x, 1090, 1600, 260, 6, tons);
    });

    camera(c, 0.2, z); c.drawImage(fond, 0, 0); dessinerNuages(c, champ, u, 0.85);
    camera(c, 0.6, z); c.drawImage(relief, 0, 0);
    // L'eau qui tombe : des filets en pointillés qui défilent vers le bas
    var r = alea(91);
    c.save();
    c.globalCompositeOperation = 'lighter';
    for (var X = 300; X < 800; X += 9) {
      var a = r(), b = r();
      var bas = 1300;
      var haut = 828 + (X - 330) * -0.02;
      var ecart = (X - 540) * 0.25;
      c.setLineDash([30 + a * 60, 12 + b * 30]);
      c.lineDashOffset = -u * (420 + a * 200);
      c.strokeStyle = 'rgba(255,255,255,' + (0.25 + b * 0.35) + ')';
      c.lineWidth = 3 + a * 4;
      c.beginPath(); c.moveTo(X, haut); c.quadraticCurveTo(X + ecart * 0.2, 1050, X + ecart, bas); c.stroke();
    }
    c.setLineDash([]);
    c.restore();
    // Écume et embruns au pied de la chute
    for (var k = 0; k < 14; k++) {
      var fx = 270 + k * 40, pul = 0.6 + 0.4 * Math.sin(u * 3 + k * 1.7);
      halo(c, fx, 1300, 70 * pul + 30, 'rgba(255,255,255,0.45)');
    }
    scintillements(c, 47, 160, 540, 1550, 1900, 420, u, 'rgba(220,255,255,1)');
    camera(c, 1.25, z); c.drawImage(jungle, 0, 0);
    c.setTransform(1, 0, 0, 1, 0, 0);
  }

  // --- Jacmel : maisons « gingerbread », balcons de fer forgé, masques ----
  function dessinerJacmel(c, u, z) {
    var B = 1370;
    var fond = couche('jac-ciel', function (x) { ciel(x, 1050, PAL_OR, 780, 560, 48); });
    var champ = cache['jac-nuages'] || (cache['jac-nuages'] = champNuages(83, 60, 600, 24));
    var rue = couche('jac-maisons', function (x) {
      var couleurs = [['#e94f7a', '#b8325a'], ['#f6c343', '#c9921f'], ['#2bb3b1', '#1a807f'], ['#4f7fe0', '#3459ad']];
      for (var i = 0; i < 4; i++) {
        var x0 = i * 270, haut = 640 + (i % 2) * 50;
        x.fillStyle = degradeH(x, x0, x0 + 270, [[0, couleurs[i][1]], [0.4, couleurs[i][0]], [1, couleurs[i][0]]]);
        x.fillRect(x0, haut, 270, B - haut);
        x.fillStyle = 'rgba(255,190,120,0.18)'; x.fillRect(x0 + 140, haut, 130, B - haut);
        // Toit à pignon et dentelle de bois
        x.fillStyle = '#8b2f1f';
        x.beginPath(); x.moveTo(x0 - 6, haut); x.lineTo(x0 + 135, haut - 110); x.lineTo(x0 + 276, haut); x.closePath(); x.fill();
        x.fillStyle = '#fff8ee';
        for (var d = 0; d < 13; d++) { x.beginPath(); x.arc(x0 + 10 + d * 20, haut + 4, 9, 0, Math.PI); x.fill(); }
        // Deux étages de portes-fenêtres à persiennes
        [haut + 80, haut + 400].forEach(function (fy, et) {
          for (var p = 0; p < 3; p++) {
            var px = x0 + 30 + p * 78;
            x.fillStyle = '#ffd27a'; x.fillRect(px, fy, 56, 190);
            x.fillStyle = et ? '#2b5d3a' : '#ffffff';
            x.fillRect(px - 16, fy, 14, 190); x.fillRect(px + 58, fy, 14, 190);
            x.fillStyle = 'rgba(0,0,0,0.18)';
            for (var l = 0; l < 12; l++) { x.fillRect(px - 16, fy + 8 + l * 15, 14, 3); x.fillRect(px + 58, fy + 8 + l * 15, 14, 3); }
            x.fillStyle = 'rgba(120,70,30,0.35)'; x.fillRect(px + 27, fy, 2, 190);
          }
        });
        // Balcon de fer forgé
        var by = haut + 310;
        x.fillStyle = 'rgba(30,20,30,0.35)'; x.fillRect(x0, by + 4, 270, 16);
        x.fillStyle = '#fff8ee'; x.fillRect(x0, by - 6, 270, 12); x.fillRect(x0, by - 86, 270, 6);
        x.strokeStyle = '#fff8ee'; x.lineWidth = 3;
        for (var b = 0; b < 27; b++) {
          var bx = x0 + 5 + b * 10;
          x.beginPath(); x.moveTo(bx, by - 80); x.lineTo(bx, by - 6); x.stroke();
          if (b % 3 === 0) { x.beginPath(); x.arc(bx + 5, by - 44, 6, 0, 6.28); x.stroke(); }
        }
        x.fillStyle = '#fff8ee';
        for (var po = 0; po < 4; po++) x.fillRect(x0 + 4 + po * 87, haut + 50, 8, by - haut - 50);
      }
      // Masques du carnaval accrochés aux façades
      [[175, 1150, '#ff3d7f', '#ffd23f'], [705, 1170, '#3fd0ff', '#ff7a1a'], [975, 1120, '#ffd23f', '#7a3fff']].forEach(function (m) {
        x.fillStyle = m[2]; x.beginPath(); x.ellipse(m[0], m[1], 34, 44, 0, 0, 6.28); x.fill();
        x.fillStyle = m[3];
        x.beginPath(); x.moveTo(m[0] - 34, m[1] - 30); x.lineTo(m[0] - 50, m[1] - 70); x.lineTo(m[0] - 14, m[1] - 40); x.fill();
        x.beginPath(); x.moveTo(m[0] + 34, m[1] - 30); x.lineTo(m[0] + 50, m[1] - 70); x.lineTo(m[0] + 14, m[1] - 40); x.fill();
        x.fillStyle = '#1b1030';
        x.beginPath(); x.ellipse(m[0] - 13, m[1] - 6, 9, 6, 0, 0, 6.28); x.ellipse(m[0] + 13, m[1] - 6, 9, 6, 0, 0, 6.28); x.fill();
        x.fillStyle = '#c2125a'; x.beginPath(); x.ellipse(m[0], m[1] + 22, 12, 5, 0, 0, 6.28); x.fill();
      });
    });
    var reflet = preparerReflet('jac-reflet', rue, B, 520, 0.5, 'rgba(30,20,60,0.3)');
    var pave = couche('jac-pave', function (x) {
      x.fillStyle = degradeV(x, B, H, [[0, '#5a4660'], [0.3, '#2e2440'], [1, '#110c1e']]);
      x.fillRect(0, B, W, H - B);
      var r = alea(29);
      for (var y = B + 6; y < H; y += 26 + (y - B) * 0.04) {
        for (var X = -20 + r() * 30; X < W; X += 40 + (y - B) * 0.06) {
          x.strokeStyle = 'rgba(255,220,180,0.08)'; x.lineWidth = 2;
          arrondi(x, X, y, 34 + (y - B) * 0.05, 18 + (y - B) * 0.02, 6); x.stroke();
        }
      }
    });

    camera(c, 0.2, z); c.drawImage(fond, 0, 0); dessinerNuages(c, champ, u);
    camera(c, 0.7, z);
    c.drawImage(pave, 0, 0);
    dessinerReflet(c, reflet, B, u, 0.8);
    c.drawImage(rue, 0, 0);
    // Guirlande de fanions au-dessus de la rue
    var couleursF = ['#00209F', '#D21034', '#ffd23f', '#2bb3b1', '#ff7a1a', '#ffffff'];
    for (var g = 0; g < 2; g++) {
      var y0 = 470 + g * 120, sag = 70 + g * 20;
      c.strokeStyle = 'rgba(40,30,30,0.8)'; c.lineWidth = 2;
      c.beginPath();
      for (var X = -10; X <= W + 10; X += 20) { var yy = y0 + Math.sin(X / W * Math.PI) * sag + Math.sin(u * 1.5 + g) * 6; if (X < 0) c.moveTo(X, yy); else c.lineTo(X, yy); }
      c.stroke();
      for (var f = 0; f < 22; f++) {
        var fxp = 20 + f * 48 + g * 24;
        var fy = y0 + Math.sin(fxp / W * Math.PI) * sag + Math.sin(u * 1.5 + g) * 6;
        var ang = Math.sin(u * 2.4 + f * 0.9 + g) * 0.25;
        c.save(); c.translate(fxp, fy); c.rotate(ang);
        c.fillStyle = couleursF[(f + g * 3) % couleursF.length];
        c.beginPath(); c.moveTo(-15, 0); c.lineTo(15, 0); c.lineTo(0, 38); c.closePath(); c.fill();
        c.restore();
      }
    }
    camera(c, 1.3, z);
    palmier(c, 1110, 1960, 980, -0.1, u, 19);
    c.setTransform(1, 0, 0, 1, 0, 0);
    camera(c, 1.4, z);
    drapeauHaiti(c, 18, 120, 420, 270, u, 1, 900);
    c.setTransform(1, 0, 0, 1, 0, 0);
  }

  // ========================================================================
  //  Villes en photo
  // ========================================================================
  //  La photo nette occupe toute la largeur (un peu plus, pour la poussée) ;
  //  si elle n'est pas assez haute pour l'écran vertical, elle se fond en
  //  haut et en bas dans un agrandissement flou d'elle-même — plutôt que de
  //  la recadrer jusqu'à n'en garder qu'une bande.
  function preparerPhoto(img, cy) {
    var iw = img.width, ih = img.height, rap = iw / ih;
    var fw = Math.max(W * 1.08, Math.min(H * 1.04 * rap, W * 1.25)), fh = fw / rap;
    var fond = toile(W, H), f = fond.getContext('2d');
    var cw = Math.max(W, H * rap) * 1.15, ch = cw / rap;
    f.filter = 'blur(38px) saturate(1.3) brightness(0.8)';
    f.drawImage(img, (W - cw) / 2, cy - ch / 2 < H - ch ? H - ch : Math.min(0, cy - ch / 2), cw, ch);
    f.filter = 'none';
    var avant = toile(W, H), a = avant.getContext('2d');
    a.imageSmoothingQuality = 'high';
    var y = fh >= H ? borner(cy - fh / 2, H - fh, 0) : cy - fh / 2;
    a.drawImage(img, (W - fw) / 2, y, fw, fh);
    if (fh < H) {
      // Fondu des bords haut et bas dans le fond flou
      a.globalCompositeOperation = 'destination-in';
      var h0 = Math.max(0, y), h1 = Math.min(H, y + fh), bord = 150;
      a.fillStyle = degradeV(a, h0, h1, [[0, 'rgba(0,0,0,' + (y > 0 ? 0 : 1) + ')'], [bord / (h1 - h0), 'rgba(0,0,0,1)'],
        [1 - bord / (h1 - h0), 'rgba(0,0,0,1)'], [1, 'rgba(0,0,0,' + (y + fh < H ? 0 : 1) + ')']]);
      a.fillRect(0, 0, W, H);
    }
    return { fond: fond, avant: avant };
  }

  function dessinerPhoto(c, u, z, i) {
    var v = VILLES[i], P = v.photo;
    var L = cache['photo' + i] || (cache['photo' + i] = preparerPhoto(images['photo' + i], P.cy));
    camera(c, 0.4, z); c.drawImage(L.fond, 0, 0);
    var s = 1 + 0.13 * z, dx = P.pan * (z - 0.5) * 50;
    c.setTransform(s, 0, 0, s, CAM_X * (1 - s) + dx, CAM_Y * (1 - s));
    c.drawImage(L.avant, 0, 0);
    c.setTransform(1, 0, 0, 1, 0, 0);
    // Voile chaud qui traverse l'image (fuite de lumière)
    var e = prog(u, 0.2, 4.5);
    if (e > 0 && e < 1) {
      var lx = mix(-400, W + 400, e), ly = mix(300, 900, e);
      halo(c, lx, ly, 900, 'rgba(255,150,60,' + (0.28 * Math.sin(e * Math.PI)) + ')');
    }
    if (!enMiniature) poussieres(c, u, 500 + i);
    // Assombrit le bas, pour que le titre se lise sur n'importe quelle photo
    c.fillStyle = degradeV(c, 1100, H, [[0, 'rgba(3,10,35,0)'], [0.45, 'rgba(3,10,35,0.55)'], [1, 'rgba(3,10,35,0.8)']]);
    c.fillRect(0, 1100, W, H - 1100);
    c.fillStyle = degradeV(c, 0, 260, [[0, 'rgba(3,10,35,0.35)'], [1, 'rgba(3,10,35,0)']]);
    c.fillRect(0, 0, W, 260);
    if (P.drapeau && !enMiniature) {
      camera(c, 1.4, z);
      if (P.drapeau > 0) drapeauHaiti(c, 18, 120, 380, 245, u, 1, 900);
      else drapeauHaiti(c, 1062, 110, 380, 245, u, -1, 900);
      c.setTransform(1, 0, 0, 1, 0, 0);
    }
  }

  // Poussière dorée qui monte lentement dans la lumière
  function poussieres(c, u, graine) {
    var r = alea(graine);
    c.save();
    c.globalCompositeOperation = 'lighter';
    for (var i = 0; i < 45; i++) {
      var x0 = r() * W, y0 = r() * H, v = 25 + r() * 60, t = 1.5 + r() * 3.5, ph = r() * 6.28;
      var y = ((y0 - u * v) % H + H) % H, x = x0 + Math.sin(u * 0.8 + ph) * 20;
      c.globalAlpha = 0.35 + 0.35 * Math.sin(u * 2 + ph);
      c.fillStyle = 'rgba(255,220,150,1)';
      c.beginPath(); c.arc(x, y, t, 0, 6.28); c.fill();
    }
    c.restore();
  }

  // ========================================================================
  //  Carte d'Haïti (introduction et final)
  // ========================================================================

  function projeter(lon, lat, m) { return [m.x + (lon + 74.5) * m.k, m.y + (20.15 - lat) * m.k * 1.058]; }
  function tracerContour(c, pts, m) {
    var p = pts.map(function (q) { return projeter(q[0], q[1], m); });
    c.beginPath();
    var n = p.length;
    var mid = function (a, b) { return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]; };
    var s = mid(p[n - 1], p[0]);
    c.moveTo(s[0], s[1]);
    for (var i = 0; i < n; i++) { var q = mid(p[i], p[(i + 1) % n]); c.quadraticCurveTo(p[i][0], p[i][1], q[0], q[1]); }
    c.closePath();
    return p;
  }
  function longueur(p) {
    var L = 0;
    for (var i = 0; i < p.length; i++) { var a = p[i], b = p[(i + 1) % p.length]; L += Math.hypot(b[0] - a[0], b[1] - a[1]); }
    return L * 1.02;
  }
  // Remplissage de la carte : terre sombre piquée de lumières de villes
  function carteRemplie(m, cle) {
    return couche(cle, function (x) {
      [HAITI, GONAVE, TORTUE].forEach(function (pts) {
        tracerContour(x, pts, m);
        x.fillStyle = degradeV(x, m.y, m.y + 2.3 * m.k, [[0, '#145a73'], [1, '#0a2c48']]);
        x.fill();
      });
      x.save();
      tracerContour(x, HAITI, m); x.clip();
      var r = alea(101);
      for (var i = 0; i < 700; i++) {
        var X = m.x + r() * 3 * m.k, Y = m.y + r() * 2.4 * m.k;
        x.fillStyle = 'rgba(255,' + Math.floor(190 + r() * 60) + ',120,' + (0.25 + r() * 0.6) + ')';
        var t = 1 + r() * 2.2; x.fillRect(X, Y, t, t);
      }
      VILLES.forEach(function (v) {
        var p = projeter(v.lon, v.lat, m);
        for (var j = 0; j < 90; j++) {
          var a = r() * 6.28, d = Math.pow(r(), 2) * m.k * 0.16;
          x.fillStyle = 'rgba(255,220,140,' + (0.4 + r() * 0.6) + ')';
          x.fillRect(p[0] + Math.cos(a) * d, p[1] + Math.sin(a) * d, 2.2, 2.2);
        }
      });
      x.restore();
    });
  }
  function dessinerCarte(c, m, cle, pTrace, pRemplir) {
    if (pRemplir > 0) { c.globalAlpha = pRemplir; c.drawImage(carteRemplie(m, cle), 0, 0); c.globalAlpha = 1; }
    if (pTrace <= 0) return;
    c.save();
    c.globalCompositeOperation = 'lighter';
    c.lineJoin = 'round';
    [[16, 'rgba(40,150,255,0.18)'], [6, 'rgba(110,200,255,0.55)'], [2.2, 'rgba(230,248,255,1)']].forEach(function (pp) {
      [HAITI, GONAVE, TORTUE].forEach(function (pts, ip) {
        var p = tracerContour(c, pts, m);
        var L = longueur(p);
        var pr = ip ? borner((pTrace - 0.5) * 2, 0, 1) : pTrace;
        c.setLineDash([L * pr, L]);
        c.lineWidth = pp[0]; c.strokeStyle = pp[1]; c.stroke();
      });
    });
    c.setLineDash([]);
    c.restore();
  }
  function pointVille(c, x, y, p, u, nom, cote, taille) {
    if (p <= 0) return;
    var s = rebond(p);
    var pul = (u * 1.2) % 1;
    c.save();
    c.globalCompositeOperation = 'lighter';
    c.strokeStyle = 'rgba(255,190,90,' + (1 - pul) * 0.9 + ')';
    c.lineWidth = 3;
    c.beginPath(); c.arc(x, y, 10 + pul * 34, 0, 6.28); c.stroke();
    halo(c, x, y, 46 * s, 'rgba(255,170,60,0.9)');
    c.restore();
    c.fillStyle = '#fff4d6'; c.beginPath(); c.arc(x, y, 8 * s, 0, 6.28); c.fill();
    c.fillStyle = '#ff7a1a'; c.beginPath(); c.arc(x, y, 4.5 * s, 0, 6.28); c.fill();
    if (nom) {
      c.save();
      c.globalAlpha = borner(p * 1.8 - 0.4, 0, 1);
      c.font = 'italic 800 ' + (taille || 30) + 'px Montserrat';
      c.textAlign = cote[0] > 0 ? 'left' : 'right';
      c.textBaseline = 'middle';
      c.lineWidth = 6; c.strokeStyle = 'rgba(2,10,30,0.85)';
      var tx = x + cote[0] * 18, ty = y + cote[1] * 24;
      c.strokeText(nom, tx, ty);
      c.fillStyle = '#ffffff'; c.fillText(nom, tx, ty);
      c.restore();
    }
  }
  // Arc de trajet, en pointillés lumineux, avec le colis qui voyage dessus
  function trajet(c, x0, y0, x1, y1, hauteur, p, avecColis) {
    if (p <= 0) return;
    var cx = (x0 + x1) / 2, cy = Math.min(y0, y1) - hauteur;
    c.save();
    c.globalCompositeOperation = 'lighter';
    var n = 60, fin = Math.floor(n * p);
    for (var i = 0; i < fin; i++) {
      if (i % 2) continue;
      var a = bez(x0, y0, cx, cy, x1, y1, i / n), b = bez(x0, y0, cx, cy, x1, y1, (i + 1) / n);
      c.strokeStyle = 'rgba(255,150,50,0.9)'; c.lineWidth = 4; c.lineCap = 'round';
      c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke();
    }
    c.restore();
    if (avecColis && p < 1) {
      var q = bez(x0, y0, cx, cy, x1, y1, p), q2 = bez(x0, y0, cx, cy, x1, y1, Math.min(1, p + 0.01));
      colis(c, q[0], q[1], 1, Math.atan2(q2[1] - q[1], q2[0] - q[0]) * 0.3);
    }
  }

  // Fond nocturne commun : dégradé, étoiles, Terre et son atmosphère
  function fondNuit(c, u, terreY) {
    var f = couche('nuit-' + terreY, function (x) {
      var g = x.createRadialGradient(540, 760, 50, 540, 900, 1500);
      g.addColorStop(0, '#123f96'); g.addColorStop(0.45, '#071a4a'); g.addColorStop(1, '#020818');
      x.fillStyle = g; x.fillRect(0, 0, W, H);
      var r = alea(7);
      for (var i = 0; i < 260; i++) { x.fillStyle = 'rgba(255,255,255,' + (0.2 + r() * 0.7) + ')'; var s = r() * 2.2 + 0.4; x.fillRect(r() * W, r() * H, s, s); }
      var R = 2400;
      x.save();
      x.beginPath(); x.arc(540, terreY + R, R, 0, 6.28);
      x.fillStyle = degradeV(x, terreY, H, [[0, '#0b2d66'], [0.25, '#061a3e'], [1, '#020a1c']]); x.fill();
      x.clip();
      var rr = alea(9);
      for (var j = 0; j < 500; j++) { x.fillStyle = 'rgba(255,210,130,' + rr() * 0.5 + ')'; x.fillRect(rr() * W, terreY + 30 + rr() * (H - terreY), 2, 2); }
      x.restore();
      x.save();
      x.globalCompositeOperation = 'lighter';
      [[60, 'rgba(40,140,255,0.10)'], [26, 'rgba(70,170,255,0.30)'], [8, 'rgba(160,220,255,0.75)'], [2.5, 'rgba(240,250,255,1)']].forEach(function (pp) {
        x.beginPath(); x.arc(540, terreY + R, R, Math.PI * 1.25, Math.PI * 1.75);
        x.lineWidth = pp[0]; x.strokeStyle = pp[1]; x.stroke();
      });
      x.restore();
      halo(x, 540, terreY, 520, 'rgba(70,160,255,0.35)');
    });
    c.drawImage(f, 0, 0);
    // Traits de lumière qui tournent (comme les anneaux de la référence)
    c.save();
    c.globalCompositeOperation = 'lighter';
    for (var k = 0; k < 3; k++) {
      var a0 = u * (0.25 + k * 0.1) + k * 2.1;
      anneau(c, 540, terreY - 40, 700 + k * 120, 210 + k * 50, -0.15 + k * 0.08, a0, a0 + 1.6, '40,140,255', 2.2, 'tout');
    }
    c.restore();
  }

  // ========================================================================
  //  Introduction
  // ========================================================================
  function dessinerIntro(c, u) {
    var m = { x: 70, y: 1020, k: 326 };
    // À la fin, la caméra plonge vers Port-au-Prince
    var pap = projeter(VILLES[0].lon, VILLES[0].lat, m);
    var plonge = douce(prog(u, 4.7, 6.0));
    var s = 1 + plonge * 1.8;
    c.setTransform(s, 0, 0, s, pap[0] * (1 - s), pap[1] * (1 - s));
    fondNuit(c, u, 960);
    // Éclat de lumière qui traverse l'écran au début
    var e = prog(u, 0.1, 1.6);
    if (e > 0 && e < 1) {
      c.save(); c.globalCompositeOperation = 'lighter';
      var lx = mix(-300, 1400, sortie(e));
      c.fillStyle = degradeH(c, lx - 400, lx + 400, [[0, 'rgba(60,160,255,0)'], [0.5, 'rgba(160,220,255,' + (0.5 * Math.sin(e * Math.PI)) + ')'], [1, 'rgba(60,160,255,0)']]);
      c.fillRect(0, 935, W, 50);
      halo(c, lx, 960, 260, 'rgba(120,200,255,' + 0.8 * Math.sin(e * Math.PI) + ')');
      c.restore();
    }
    dessinerCarte(c, m, 'carte-intro', douce(prog(u, 1.4, 3.4)), douce(prog(u, 2.4, 3.6)));
    // Miami → Port-au-Prince
    var miami = [30, 880];
    trajet(c, miami[0], miami[1], pap[0], pap[1], 260, sortie(prog(u, 2.6, 4.3)), true);
    if (u > 2.6) {
      c.save(); c.globalAlpha = prog(u, 2.6, 3.0);
      c.font = 'italic 800 30px Montserrat'; c.fillStyle = '#ffb066'; c.textAlign = 'left';
      c.fillText('MIAMI', 40, 850);
      c.restore();
    }
    VILLES.forEach(function (v, i) {
      var p = projeter(v.lon, v.lat, m);
      pointVille(c, p[0], p[1], prog(u, 3.0 + i * 0.18, 3.5 + i * 0.18), u, NOMS_CARTE[i], COTE_ETIQUETTE[i], 30);
    });
    // Logo, sur-titre, titre « HAÏTI », pastille
    var pl = rebond(prog(u, 0.3, 1.0));
    if (pl > 0) {
      var L = images.logo, lw = 640 * pl, lh = lw * L.height / L.width;
      c.save(); c.globalAlpha = borner(pl, 0, 1);
      halo(c, 540, 230, 360, 'rgba(255,255,255,0.18)');
      c.drawImage(L, 540 - lw / 2, 230 - lh / 2, lw, lh);
      c.restore();
    }
    var ps = prog(u, 0.8, 1.3);
    if (ps > 0) {
      c.save(); c.globalAlpha = ps;
      c.font = 'italic 800 40px Montserrat'; c.fillStyle = '#ffffff'; c.textAlign = 'center';
      if ('letterSpacing' in c) c.letterSpacing = mix(30, 12, sortie(ps)) + 'px';
      c.fillText('LIVRAISON PARTOUT EN', 540, 440);
      c.restore();
      c.strokeStyle = 'rgba(255,255,255,' + ps * 0.7 + ')'; c.lineWidth = 2;
      c.beginPath(); c.moveTo(120, 428); c.lineTo(170, 428); c.moveTo(910, 428); c.lineTo(960, 428); c.stroke();
    }
    var T = cache.titreHaiti;
    anneaux(c, 540, 580, 470, 120, u - 0.9, 'arriere');
    dessinerTitre(c, T, 540, 650, prog(u, 1.0, 1.6), prog(u, 1.8, 2.7) || -1);
    anneaux(c, 540, 580, 470, 120, u - 0.9, 'avant');
    pastilleSimple(c, 540, 760, 'MIAMI  ➜  HAÏTI', prog(u, 1.6, 2.1));
    c.setTransform(1, 0, 0, 1, 0, 0);
  }
  function pastilleSimple(c, cx, cy, texte, p) {
    if (p <= 0) return;
    c.save();
    c.font = 'italic 800 40px Montserrat';
    var w = c.measureText(texte).width + 90, h = 70, e = sortie(p);
    c.globalAlpha = borner(p * 2, 0, 1);
    c.translate(cx, cy);
    c.save();
    c.transform(e, 0, -0.22 * e, 1, 0, 0);
    arrondi(c, -w / 2, -h / 2, w, h, 14);
    c.fillStyle = degradeH(c, -w / 2, w / 2, [[0, '#ff6a00'], [1, '#ff9a2e']]); c.fill();
    c.shadowColor = 'rgba(255,140,40,0.9)'; c.shadowBlur = 22;
    c.lineWidth = 2.5; c.strokeStyle = '#ffd7a6'; c.stroke();
    c.restore();
    c.fillStyle = '#ffffff'; c.textAlign = 'center'; c.textBaseline = 'middle';
    c.fillText(texte, 0, 3);
    c.restore();
  }

  // ========================================================================
  //  Final : slogan, carte complète, appel à l'action
  // ========================================================================
  function dessinerFinale(c, u) {
    c.setTransform(1, 0, 0, 1, 0, 0);
    fondNuit(c, u, 1690);
    // Logo
    var pl = rebond(prog(u, 0.25, 0.9));
    if (pl > 0) {
      var L = images.logo, lw = 720 * pl, lh = lw * L.height / L.width;
      c.save(); c.globalAlpha = borner(pl, 0, 1);
      halo(c, 540, 225, 380, 'rgba(255,255,255,0.16)');
      c.drawImage(L, 540 - lw / 2, 225 - lh / 2, lw, lh);
      c.restore();
    }
    // « PLOP PLOP! » : chaque mot arrive avec son « plop » (musique.py)
    var P1 = cache.plop1, P2 = cache.plop2;
    var l1 = P1.w - P1.taille * 0.9, l2 = P2.w - P2.taille * 0.9, ecart = P1.taille * 0.32;
    var g0 = 540 - (l1 + l2 + ecart) / 2;
    dessinerTitre(c, P1, g0 + l1 / 2, 520, prog(u, 0.8, 1.2), prog(u, 2.0, 2.8) || -1);
    dessinerTitre(c, P2, g0 + l1 + ecart + l2 / 2, 520, prog(u, 1.15, 1.55), prog(u, 2.2, 3.0) || -1);
    anneaux(c, 540, 600, 500, 95, u - 1.5, 'arriere');
    dessinerTitre(c, cache.slogan, 540, 650, prog(u, 1.6, 2.1), prog(u, 4.2, 5.0) || -1);
    anneaux(c, 540, 600, 500, 95, u - 1.5, 'avant');
    // Carte : toutes les villes desservies, reliées à Miami
    var m = { x: 175, y: 790, k: 245 };
    dessinerCarte(c, m, 'carte-finale', douce(prog(u, 1.7, 3.0)), douce(prog(u, 2.3, 3.2)));
    var miami = [20, 760];
    VILLES.forEach(function (v, i) {
      var p = projeter(v.lon, v.lat, m);
      trajet(c, miami[0], miami[1], p[0], p[1], 120 + i * 18, sortie(prog(u, 2.2 + i * 0.12, 3.2 + i * 0.12)), false);
    });
    VILLES.forEach(function (v, i) {
      var p = projeter(v.lon, v.lat, m);
      pointVille(c, p[0], p[1], prog(u, 2.9 + i * 0.1, 3.3 + i * 0.1), u, NOMS_CARTE[i], COTE_ETIQUETTE[i], 25);
    });
    // Bouton d'appel à l'action, qui respire
    var pb = prog(u, 3.4, 3.9);
    if (pb > 0) {
      var s = rebond(pb) * (1 + 0.03 * Math.sin(u * 5.5));
      c.save();
      c.translate(540, 1440); c.scale(s, s);
      c.globalAlpha = borner(pb * 2, 0, 1);
      halo(c, 0, 0, 420, 'rgba(255,120,20,' + (0.35 + 0.2 * Math.sin(u * 5.5)) + ')');
      arrondi(c, -400, -66, 800, 132, 66);
      c.fillStyle = degradeV(c, -66, 66, [[0, '#ffa24a'], [0.5, '#ff6a00'], [1, '#e04e00']]); c.fill();
      c.lineWidth = 4; c.strokeStyle = '#ffd9b0'; c.stroke();
      c.fillStyle = 'rgba(255,255,255,0.25)'; arrondi(c, -380, -58, 760, 50, 25); c.fill();
      c.font = 'italic 900 52px Montserrat'; c.fillStyle = '#ffffff'; c.textAlign = 'center'; c.textBaseline = 'middle';
      c.fillText('EXPÉDIEZ MAINTENANT', -26, 4);
      c.beginPath(); c.moveTo(318, -22); c.lineTo(350, 0); c.lineTo(318, 22); c.lineWidth = 9; c.lineCap = 'round'; c.lineJoin = 'round'; c.strokeStyle = '#ffffff'; c.stroke();
      // Reflet qui balaie le bouton
      var rb = (u - 4.0) % 2.4;
      if (rb > 0 && rb < 0.8) {
        c.save(); arrondi(c, -400, -66, 800, 132, 66); c.clip();
        var bx = mix(-520, 520, rb / 0.8);
        c.fillStyle = degradeH(c, bx - 80, bx + 80, [[0, 'rgba(255,255,255,0)'], [0.5, 'rgba(255,255,255,0.55)'], [1, 'rgba(255,255,255,0)']]);
        c.fillRect(-400, -66, 800, 132);
        c.restore();
      }
      c.restore();
    }
    // Coordonnées : WhatsApp et site
    ligneContact(c, 1590, 'whatsapp', '+1 849 538-6262', prog(u, 3.8, 4.2));
    ligneContact(c, 1680, 'site', 'goshipexpress.net', prog(u, 4.1, 4.5));
    var pf = prog(u, 4.4, 4.9);
    if (pf > 0) {
      c.save(); c.globalAlpha = pf;
      c.font = 'italic 800 32px Montserrat'; c.textAlign = 'center'; c.fillStyle = '#9fd4ff';
      c.fillText('Miami  ➜  Haïti  ·  Livraison à domicile', 540, 1790);
      c.restore();
    }
  }
  function ligneContact(c, y, icone, texte, p) {
    if (p <= 0) return;
    c.save();
    c.globalAlpha = borner(p * 1.5, 0, 1);
    c.translate(mix(-60, 0, sortie(p)), 0);
    c.font = '800 50px Montserrat';
    var tw = c.measureText(texte).width, total = tw + 90, x0 = 540 - total / 2;
    var ix = x0 + 30;
    if (icone === 'whatsapp') {
      c.fillStyle = '#25D366'; c.beginPath(); c.arc(ix, y, 30, 0, 6.28); c.fill();
      c.beginPath(); c.moveTo(ix - 22, y + 28); c.lineTo(ix - 14, y + 10); c.lineTo(ix - 4, y + 22); c.fill();
      c.strokeStyle = '#ffffff'; c.lineWidth = 4;
      c.beginPath(); c.arc(ix, y, 18, 0, 6.28); c.stroke();
      c.fillStyle = '#ffffff';
      c.beginPath(); c.ellipse(ix + 1, y + 1, 5, 9, -0.7, 0, 6.28); c.fill();
    } else {
      c.strokeStyle = '#4fb3ff'; c.lineWidth = 4;
      c.beginPath(); c.arc(ix, y, 27, 0, 6.28); c.stroke();
      c.beginPath(); c.ellipse(ix, y, 11, 27, 0, 0, 6.28); c.stroke();
      c.beginPath(); c.moveTo(ix - 27, y); c.lineTo(ix + 27, y); c.moveTo(ix - 23, y - 13); c.lineTo(ix + 23, y - 13); c.moveTo(ix - 23, y + 13); c.lineTo(ix + 23, y + 13); c.stroke();
    }
    c.fillStyle = '#ffffff'; c.textBaseline = 'middle'; c.textAlign = 'left';
    c.shadowColor = 'rgba(0,0,0,0.6)'; c.shadowBlur = 10;
    c.fillText(texte, x0 + 90, y + 3);
    c.restore();
  }

  // ========================================================================
  //  Miniature : trois villes en haut, trois en bas, le titre au centre
  // ========================================================================
  // Centre vertical de chaque vue, là où se trouve son monument
  var CENTRES_VUES = [1080, 830, 900, 1120, 1040, 960];

  // Vrai pendant que la miniature peint ses vignettes : sans drapeau ni
  // poussière, une vignette de 360 px resterait illisible
  var enMiniature = false;

  function dessinerMiniature(c) {
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.drawImage(couche('miniature', peindreMiniature), 0, 0);
  }

  function peindreMiniature(x) {
    var vue = toile(W, H), vx = vue.getContext('2d');
    var HAUT = 620, BAS = 1300, LT = 360, ech = 0.4;
    enMiniature = true;
    // Les six vues, telles qu'elles apparaissent dans la vidéo
    VILLES.forEach(function (v, i) {
      vx.setTransform(1, 0, 0, 1, 0, 0);
      vx.globalAlpha = 1;
      v.dessin(vx, 2.5, 0.4);
      vx.setTransform(1, 0, 0, 1, 0, 0);
      var col = i % 3, ligne = i < 3 ? 0 : 1;
      var tx = col * LT, ty = ligne ? BAS : 0, th = ligne ? H - BAS : HAUT;
      var sw = LT / ech, sh = th / ech;
      var centre = v.enPhoto ? v.photo.cy : CENTRES_VUES[i];
      var sy = borner(centre - sh / 2, 0, H - sh);
      x.drawImage(vue, (W - sw) / 2, sy, sw, sh, tx, ty, LT, th);
      // Nom de la ville, au pied de la vignette
      var by = ty + th;
      x.fillStyle = degradeV(x, by - 130, by, [[0, 'rgba(2,10,32,0)'], [1, 'rgba(2,10,32,0.85)']]);
      x.fillRect(tx, by - 130, LT, 130);
      x.font = 'italic 800 27px Montserrat';
      var nom = NOMS_CARTE[i].toUpperCase();
      var tw = x.measureText(nom).width;
      var gx = tx + (LT - tw - 30) / 2;
      epingle(x, gx + 8, by - 42, 0.85, '#ff7a1a');
      x.fillStyle = '#ffffff'; x.textBaseline = 'middle'; x.textAlign = 'left';
      x.fillText(nom, gx + 30, by - 38);
    });
    enMiniature = false;
    // Séparations lumineuses entre les vignettes
    x.save();
    x.globalCompositeOperation = 'lighter';
    [LT, 2 * LT].forEach(function (sx) {
      [[0, HAUT], [BAS, H]].forEach(function (z) {
        x.fillStyle = degradeV(x, z[0], z[1], [[0, 'rgba(80,180,255,0.9)'], [1, 'rgba(80,180,255,0.2)']]);
        x.fillRect(sx - 2, z[0], 4, z[1] - z[0]);
      });
    });
    x.restore();
    // Bandeau central : nuit étoilée, comme l'intro
    x.save();
    x.beginPath(); x.rect(0, HAUT, W, BAS - HAUT); x.clip();
    var g = x.createRadialGradient(540, 960, 40, 540, 960, 760);
    g.addColorStop(0, '#16489f'); g.addColorStop(0.55, '#071c50'); g.addColorStop(1, '#020a22');
    x.fillStyle = g; x.fillRect(0, HAUT, W, BAS - HAUT);
    var r = alea(321);
    for (var i = 0; i < 120; i++) { x.fillStyle = 'rgba(255,255,255,' + (0.2 + r() * 0.6) + ')'; var st = 0.5 + r() * 2; x.fillRect(r() * W, HAUT + r() * (BAS - HAUT), st, st); }
    for (var k = 0; k < 3; k++) anneau(x, 540, 1010 + k * 30, 640 + k * 90, 150 + k * 30, -0.1 + k * 0.07, 0.3 + k * 2.2, 2.2 + k * 2.2, '40,140,255', 2.4, 'tout');
    // Logo
    var L = images.logo, lw = 540, lh = lw * L.height / L.width;
    halo(x, 540, 722, 320, 'rgba(255,255,255,0.16)');
    x.drawImage(L, 540 - lw / 2, 722 - lh / 2, lw, lh);
    // Sur-titre, titre chromé et ses anneaux
    x.font = 'italic 800 40px Montserrat'; x.fillStyle = '#ffffff'; x.textAlign = 'center'; x.textBaseline = 'alphabetic';
    if ('letterSpacing' in x) x.letterSpacing = '12px';
    x.fillText('LIVRAISON PARTOUT EN', 546, 862);
    if ('letterSpacing' in x) x.letterSpacing = '0px';
    x.strokeStyle = 'rgba(255,255,255,0.7)'; x.lineWidth = 2;
    x.beginPath(); x.moveTo(90, 849); x.lineTo(140, 849); x.moveTo(940, 849); x.lineTo(990, 849); x.stroke();
    var T = cache.titreMiniature;
    anneaux(x, 540, 1025, 470, 112, 3, 'arriere');
    dessinerTitre(x, T, 540, 1094, 1, -1);
    anneaux(x, 540, 1025, 470, 112, 3, 'avant');
    pastilleSimple(x, 540, 1192, "PLOP PLOP KOLI'W NAN MEN'W", 1);
    x.font = 'italic 800 30px Montserrat'; x.fillStyle = '#9fd4ff'; x.textAlign = 'center';
    x.fillText('Miami  ➜  Haïti  ·  6 villes desservies', 540, 1272);
    x.restore();
    // Liserés du bandeau (orange en haut, bleu en bas)
    x.save();
    x.globalCompositeOperation = 'lighter';
    [[HAUT, '255,130,30'], [BAS, '60,170,255']].forEach(function (b) {
      [[14, 0.18], [5, 0.55], [2, 1]].forEach(function (pp) {
        x.fillStyle = 'rgba(' + b[1] + ',' + pp[1] + ')'; x.fillRect(0, b[0] - pp[0] / 2, W, pp[0]);
      });
      halo(x, 540, b[0], 300, 'rgba(' + b[1] + ',0.45)');
    });
    x.restore();
    x.drawImage(cache.vignette, 0, 0);
  }

  // ========================================================================
  //  Assemblage : scène courante, transitions « plongée », finitions
  // ========================================================================
  var ecran, ctx, plan, px, images = {};

  function dessinerScene(i, u) {
    var S = SCENES[i];
    px.setTransform(1, 0, 0, 1, 0, 0);
    px.globalAlpha = 1;
    px.globalCompositeOperation = 'source-over';
    if (S.type === 'miniature') { dessinerMiniature(px); return; }
    if (S.type === 'intro') { dessinerIntro(px, u); return; }
    if (S.type === 'finale') { dessinerFinale(px, u); return; }
    var v = VILLES[S.ville];
    v.dessin(px, u, u / VILLE);
    px.setTransform(1, 0, 0, 1, 0, 0);
    // Le titre suit la poussée de la caméra, en plan rapproché
    camera(px, 0.5, u / VILLE);
    blocTitre(px, S.ville, u, 1480);
    px.setTransform(1, 0, 0, 1, 0, 0);
  }

  function rendre(t) {
    t = borner(t, 0, DUREE - 1e-6);
    var i = 0;
    while (i < SCENES.length - 1 && t >= SCENES[i].fin) i++;
    var S = SCENES[i], u = t - S.debut, d = S.fin - S.debut;
    dessinerScene(i, u);

    // Plongée : la fin d'une scène accélère vers l'avant, la suivante
    // arrive encore lancée puis ralentit. Flou de mouvement radial.
    var depart = i < SCENES.length - 1 ? prog(u, d - 0.5, d) : 0;
    var arrivee = i > 0 ? 1 - prog(u, 0, 0.6) : 0;
    var zoom = 1, flou = 0;
    if (depart > 0) { zoom = 1 + depart * depart * 2.4; flou = depart; }
    if (arrivee > 0) { zoom = 1 + arrivee * arrivee * 1.1; flou = Math.max(flou, arrivee); }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';
    var cx = 540, cy = 960;
    function copie(s) { ctx.setTransform(s, 0, 0, s, cx * (1 - s), cy * (1 - s)); ctx.drawImage(plan, 0, 0); }
    copie(zoom);
    if (flou > 0.02) {
      var n = 11;
      for (var k = 1; k <= n; k++) { ctx.globalAlpha = 1 / (k + 1); copie(zoom * (1 + k * 0.028 * flou)); }
      ctx.globalAlpha = 1;
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);

    // Les nuages traversés au moment du changement de scène
    var b = null;
    for (var j = 1; j < SCENES.length; j++) if (Math.abs(t - SCENES[j].debut) < 0.5) b = SCENES[j].debut;
    if (b !== null) {
      var q = (t - b + 0.5);           // 0 → 1 autour de la coupe
      var dens = 1 - Math.abs(q - 0.5) * 2;
      dens = dens * dens * (3 - 2 * dens);
      var r = alea(Math.round(b * 10));
      for (var n2 = 0; n2 < 16; n2++) {
        var ang = r() * 6.28, d0 = r() * 0.6;
        var rad = (d0 + q * 1.3) * 900;
        var sc = (0.6 + q * 3.2) * (0.7 + r() * 0.6);
        var spr = NUAGES_BLANCS[n2 % 6];
        ctx.globalAlpha = dens * (0.65 + r() * 0.35);
        ctx.drawImage(spr, cx + Math.cos(ang) * rad - spr.width * sc / 2, cy + Math.sin(ang) * rad * 1.4 - spr.height * sc / 2, spr.width * sc, spr.height * sc);
      }
      ctx.globalAlpha = dens * dens * 0.85;
      ctx.fillStyle = '#eef4ff';
      ctx.fillRect(0, 0, W, H);
      ctx.globalAlpha = 1;
    }

    // Vignettage et léger étalonnage chaud
    // (la miniature a déjà le sien : la première image doit être nette)
    if (S.type !== 'miniature') ctx.drawImage(cache.vignette, 0, 0);
  }

  function chargerImage(src) {
    return new Promise(function (ok, ko) {
      var im = new Image();
      im.onload = function () { ok(im); };
      im.onerror = function () { ko(new Error('Image introuvable : ' + src)); };
      im.src = src;
    });
  }

  function preparer() {
    ecran = document.getElementById('ecran');
    ecran.width = W; ecran.height = H;
    ctx = ecran.getContext('2d');
    plan = toile(W, H); px = plan.getContext('2d');
    return Promise.all([
      document.fonts.load('italic 900 100px Montserrat'),
      document.fonts.load('italic 800 40px Montserrat'),
      document.fonts.load('800 40px Montserrat'),
      chargerImage('../../assets/img/logo-goship-grand.png').then(function (im) { images.logo = im; })
    ].concat(VILLES.map(function (v, i) {
      if (!v.photo) return null;
      return chargerImage('photos/' + v.photo.fichier + '.jpg').then(function (im) {
        images['photo' + i] = im;
        v.enPhoto = true;
        v.dessin = function (c, u, z) { dessinerPhoto(c, u, z, i); };
      }, function () { /* pas de photo : décor dessiné */ });
    }))).then(function () {
      for (var i = 0; i < 6; i++) { NUAGES.push(creerNuage(100 + i, false)); NUAGES_BLANCS.push(creerNuage(200 + i, true)); }
      VILLES.forEach(function (v, i) { cache['titre' + i] = preparerTitre(v.nom, 980, 190, PALETTE_CHROME); });
      cache.titreHaiti = preparerTitre('HAÏTI', 900, 230, PALETTE_CHROME);
      cache.titreMiniature = preparerTitre('HAÏTI', 900, 205, PALETTE_CHROME);
      cache.plop1 = preparerTitre('PLOP', 430, 160, PALETTE_ORANGE);
      cache.plop2 = preparerTitre('PLOP!', 470, 160, PALETTE_ORANGE);
      cache.slogan = preparerTitre("KOLI'W NAN MEN'W", 960, 104, PALETTE_CHROME);
      cache.vignette = couche('vignette', function (x) {
        var g = x.createRadialGradient(540, 900, 380, 540, 960, 1250);
        g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(1, 'rgba(0,5,25,0.55)');
        x.fillStyle = g; x.fillRect(0, 0, W, H);
      });
      // Premier passage sur chaque scène : remplit le cache des décors
      SCENES.forEach(function (S, i) { dessinerScene(i, 1); });
      return { duree: DUREE, largeur: W, hauteur: H,
        photos: VILLES.filter(function (v) { return v.enPhoto; }).length, scenes: SCENES.map(function (s) { return [s.type, s.debut, s.fin]; }) };
    });
  }

  window.GoshipVideo = {
    preparer: preparer,
    rendre: rendre,
    image: function (q) { return ecran.toDataURL('image/jpeg', q || 0.93); },
    // La miniature seule, en PNG (pour la publier comme couverture)
    miniature: function () { rendre(0); return ecran.toDataURL('image/png'); },
    duree: DUREE
  };
})();
