/* ==========================================================================
   Goship Express — QR codes et codes-barres
   ==========================================================================
   Les codes sont calculés ici et dessinés en SVG, sans bibliothèque et sans
   service extérieur. Deux raisons : un générateur en ligne
   (api.qrserver.com et compagnie) ferait sortir le numéro de chaque colis du
   site, et la règle de sécurité des pages (Content-Security-Policy) interdit
   de toute façon d'aller chercher une image ailleurs.

   Le SVG s'imprime net à n'importe quelle taille. Une image PNG, elle,
   sortirait floue de l'imprimante d'étiquettes, et un code-barres flou ne se
   lit pas au scanner.

     GoshipCodes.qr(texte, options)        QR code (ISO/IEC 18004, niveau M)
     GoshipCodes.code128(texte, options)   code-barres Code 128, celui des
                                           étiquettes d'expédition

   Chacune renvoie un <svg> prêt à poser dans la page. Les deux fonctions
   « …Modules » renvoient le calcul brut : elles servent aux essais
   (outils/essais-codes/), qui comparent ce fichier à deux bibliothèques de
   référence.
   ========================================================================== */
(function () {
  'use strict';

  var SVG = 'http://www.w3.org/2000/svg';

  function balise(nom, attributs) {
    var n = document.createElementNS(SVG, nom);
    Object.keys(attributs || {}).forEach(function (k) { n.setAttribute(k, String(attributs[k])); });
    return n;
  }

  /* ======================================================================
     QR code
     ======================================================================
     Niveau de correction M : 15 % du code peut être abîmé (pluie, ruban
     adhésif, coin plié) sans empêcher la lecture. C'est le niveau des
     étiquettes d'expédition.

     Versions 1 à 10, soit 213 caractères au plus : largement assez pour un
     lien de suivi. Au-delà, la fonction refuse plutôt que de produire un code
     silencieusement tronqué.
     ====================================================================== */

  // Par version : [mots de correction par bloc, blocs du 1er groupe,
  // mots de données par bloc, blocs du 2e groupe, mots de données par bloc]
  var VERSIONS = [
    [10, 1, 16, 0, 0],   // 1
    [16, 1, 28, 0, 0],   // 2
    [26, 1, 44, 0, 0],   // 3
    [18, 2, 32, 0, 0],   // 4
    [24, 2, 43, 0, 0],   // 5
    [16, 4, 27, 0, 0],   // 6
    [18, 4, 31, 0, 0],   // 7
    [22, 2, 38, 2, 39],  // 8
    [22, 3, 36, 2, 37],  // 9
    [26, 4, 43, 1, 44]   // 10
  ];

  // Centres des motifs d'alignement, par version (vide pour la version 1)
  var ALIGNEMENTS = [
    null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]
  ];

  // Bits de correction du niveau M dans l'information de format
  var NIVEAU_M = 0;

  var MASQUES = [
    function (i, j) { return (i + j) % 2 === 0; },
    function (i) { return i % 2 === 0; },
    function (i, j) { return j % 3 === 0; },
    function (i, j) { return (i + j) % 3 === 0; },
    function (i, j) { return (Math.floor(i / 2) + Math.floor(j / 3)) % 2 === 0; },
    function (i, j) { return (i * j) % 2 + (i * j) % 3 === 0; },
    function (i, j) { return ((i * j) % 2 + (i * j) % 3) % 2 === 0; },
    function (i, j) { return ((i + j) % 2 + (i * j) % 3) % 2 === 0; }
  ];

  /* ---- Corps de Galois GF(256), pour le calcul de la correction --------- */
  var EXP = [], LOG = [];
  (function () {
    var x = 1;
    for (var i = 0; i < 256; i++) {
      EXP[i] = x;
      if (i < 255) LOG[x] = i;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d;
    }
  })();

  function gfMul(a, b) { return (a === 0 || b === 0) ? 0 : EXP[(LOG[a] + LOG[b]) % 255]; }

  // Polynôme générateur de degré n
  function generateur(n) {
    var g = [1], i, j, suivant;
    for (i = 0; i < n; i++) {
      suivant = g.slice();
      suivant.push(0);
      for (j = 0; j < g.length; j++) suivant[j + 1] ^= gfMul(g[j], EXP[i]);
      g = suivant;
    }
    return g;
  }

  // Mots de correction d'un bloc de données (division euclidienne)
  function correction(donnees, nbEc) {
    var g = generateur(nbEc), reste = donnees.slice(), i, j, facteur;
    for (i = 0; i < nbEc; i++) reste.push(0);
    for (i = 0; i < donnees.length; i++) {
      facteur = reste[i];
      if (!facteur) continue;
      for (j = 0; j < g.length; j++) reste[i + j] ^= gfMul(g[j], facteur);
    }
    return reste.slice(donnees.length);
  }

  /* ---- Le texte, en octets puis en bits -------------------------------- */
  function octets(texte) {
    var out = [], i, c;
    for (i = 0; i < texte.length; i++) {
      c = texte.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < texte.length) {
        c = 0x10000 + ((c - 0xd800) << 10) + (texte.charCodeAt(++i) - 0xdc00);
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }

  function motsDeDonnees(version) {
    var v = VERSIONS[version - 1];
    return v[1] * v[2] + v[3] * v[4];
  }

  function bitsEnTete(version) { return 4 + (version < 10 ? 8 : 16); }

  function versionPour(nbOctets) {
    for (var v = 1; v <= VERSIONS.length; v++) {
      if (nbOctets * 8 <= motsDeDonnees(v) * 8 - bitsEnTete(v)) return v;
    }
    return 0;
  }

  // Mots de données : en-tête, texte, terminaison, remplissage
  function motsDonnees(donnees, version) {
    var total = motsDeDonnees(version), bits = [], mots = [], i;

    function ajouter(valeur, longueur) {
      for (var k = longueur - 1; k >= 0; k--) bits.push((valeur >>> k) & 1);
    }

    ajouter(4, 4);                                  // mode « octets »
    ajouter(donnees.length, version < 10 ? 8 : 16);
    for (i = 0; i < donnees.length; i++) ajouter(donnees[i], 8);
    ajouter(0, Math.min(4, total * 8 - bits.length));  // terminaison
    while (bits.length % 8) bits.push(0);
    for (i = 0; i < bits.length; i += 8) {
      mots.push(bits[i] << 7 | bits[i + 1] << 6 | bits[i + 2] << 5 | bits[i + 3] << 4 |
                bits[i + 4] << 3 | bits[i + 5] << 2 | bits[i + 6] << 1 | bits[i + 7]);
    }
    // Les mots restants sont remplis par 0xEC puis 0x11, en alternance
    for (i = 0; mots.length < total; i++) mots.push(i % 2 === 0 ? 0xec : 0x11);
    return mots;
  }

  // Les blocs sont entrelacés : un mot de chaque bloc, puis le suivant.
  // Une déchirure sur l'étiquette abîme ainsi un peu de chaque bloc, et
  // chacun reste réparable, au lieu d'en perdre un tout entier.
  function motsFinaux(donnees, version) {
    var v = VERSIONS[version - 1], nbEc = v[0];
    var mots = motsDonnees(donnees, version);
    var blocs = [], ecs = [], pris = 0, i, k, taille;
    for (i = 0; i < v[1] + v[3]; i++) {
      taille = i < v[1] ? v[2] : v[4];
      blocs.push(mots.slice(pris, pris + taille));
      ecs.push(correction(blocs[i], nbEc));
      pris += taille;
    }
    var sortie = [];
    for (k = 0; k < v[4] || k < v[2]; k++) {
      for (i = 0; i < blocs.length; i++) if (k < blocs[i].length) sortie.push(blocs[i][k]);
    }
    for (k = 0; k < nbEc; k++) {
      for (i = 0; i < ecs.length; i++) sortie.push(ecs[i][k]);
    }
    return sortie;
  }

  /* ---- La grille -------------------------------------------------------- */
  function grilleVide(taille) {
    var m = [], i, j, ligne;
    for (i = 0; i < taille; i++) {
      ligne = [];
      for (j = 0; j < taille; j++) ligne.push(null);
      m.push(ligne);
    }
    return m;
  }

  // Motif de repérage 7 × 7 et sa bordure claire
  function poserReperage(m, l, c) {
    var taille = m.length, i, j, r, k;
    for (i = -1; i <= 7; i++) {
      for (j = -1; j <= 7; j++) {
        r = l + i;
        k = c + j;
        if (r < 0 || k < 0 || r >= taille || k >= taille) continue;
        m[r][k] = (i >= 0 && i <= 6 && (j === 0 || j === 6)) ||
                  (j >= 0 && j <= 6 && (i === 0 || i === 6)) ||
                  (i >= 2 && i <= 4 && j >= 2 && j <= 4);
      }
    }
  }

  function poserAlignement(m, l, c) {
    for (var i = -2; i <= 2; i++) {
      for (var j = -2; j <= 2; j++) {
        m[l + i][c + j] = Math.max(Math.abs(i), Math.abs(j)) !== 1;
      }
    }
  }

  function bitsFormat(masque) {
    var donnees = (NIVEAU_M << 3) | masque, reste = donnees << 10, i;
    for (i = 14; i >= 10; i--) if (reste & (1 << i)) reste ^= 0x537 << (i - 10);
    return ((donnees << 10) | reste) ^ 0x5412;
  }

  function bitsVersion(version) {
    var reste = version << 12, i;
    for (i = 17; i >= 12; i--) if (reste & (1 << i)) reste ^= 0x1f25 << (i - 12);
    return (version << 12) | reste;
  }

  function poserFormat(m, masque, version) {
    var f = bitsFormat(masque), taille = m.length, i, b, v;
    function bit(n) { return ((f >>> n) & 1) === 1; }
    for (i = 0; i <= 5; i++) m[i][8] = bit(i);
    m[7][8] = bit(6);
    m[8][8] = bit(7);
    m[8][7] = bit(8);
    for (i = 9; i <= 14; i++) m[8][14 - i] = bit(i);
    for (i = 0; i <= 7; i++) m[8][taille - 1 - i] = bit(i);
    for (i = 8; i <= 14; i++) m[taille - 15 + i][8] = bit(i);
    m[taille - 8][8] = true;   // module toujours sombre
    if (version < 7) return;
    v = bitsVersion(version);
    for (i = 0; i < 18; i++) {
      b = ((v >>> i) & 1) === 1;
      m[Math.floor(i / 3)][taille - 11 + i % 3] = b;
      m[taille - 11 + i % 3][Math.floor(i / 3)] = b;
    }
  }

  // Motifs fixes, puis réservation des zones de format et de version
  function poserMotifs(m, version) {
    var taille = m.length, centres = ALIGNEMENTS[version], i, j, l, c;
    poserReperage(m, 0, 0);
    poserReperage(m, 0, taille - 7);
    poserReperage(m, taille - 7, 0);
    for (i = 8; i < taille - 8; i++) {
      m[6][i] = i % 2 === 0;
      m[i][6] = i % 2 === 0;
    }
    for (i = 0; i < centres.length; i++) {
      for (j = 0; j < centres.length; j++) {
        l = centres[i];
        c = centres[j];
        // Les trois coins portent déjà un motif de repérage
        if ((l === 6 && c === 6) || (l === 6 && c === taille - 7) || (l === taille - 7 && c === 6)) continue;
        poserAlignement(m, l, c);
      }
    }
    poserFormat(m, 0, version);
  }

  function poserDonnees(m, fixe, mots) {
    var taille = m.length, bits = [], i, k, col, ligne, c, montant = true;
    for (i = 0; i < mots.length; i++) {
      for (k = 7; k >= 0; k--) bits.push((mots[i] >>> k) & 1);
    }
    var n = 0;
    for (col = taille - 1; col >= 1; col -= 2) {
      if (col === 6) col = 5;   // la colonne de synchronisation est sautée
      for (i = 0; i < taille; i++) {
        ligne = montant ? taille - 1 - i : i;
        for (k = 0; k < 2; k++) {
          c = col - k;
          if (fixe[ligne][c]) continue;
          m[ligne][c] = n < bits.length ? bits[n] === 1 : false;
          n++;
        }
      }
      montant = !montant;
    }
  }

  /* ---- Choix du masque -------------------------------------------------- */
  // Un QR code est XORé par l'un des huit masques. Celui qui laisse le dessin
  // le plus irrégulier se lit le mieux : quatre règles comptent les défauts
  // (longues séries, carrés uniformes, faux motifs de repérage, déséquilibre
  // clair/sombre) et le masque le moins pénalisé gagne.
  function penalite(m) {
    var taille = m.length, total = 0, sombres = 0, i, j;

    function serie(lire) {
      var p = 0, k, n, courant, precedent;
      for (k = 0; k < taille; k++) {
        n = 1;
        precedent = lire(k, 0);
        for (j = 1; j < taille; j++) {
          courant = lire(k, j);
          if (courant === precedent) {
            n++;
          } else {
            if (n >= 5) p += 3 + (n - 5);
            n = 1;
            precedent = courant;
          }
        }
        if (n >= 5) p += 3 + (n - 5);
      }
      return p;
    }

    total += serie(function (l, c) { return m[l][c]; });
    total += serie(function (c, l) { return m[l][c]; });

    for (i = 0; i < taille - 1; i++) {
      for (j = 0; j < taille - 1; j++) {
        if (m[i][j] === m[i][j + 1] && m[i][j] === m[i + 1][j] && m[i][j] === m[i + 1][j + 1]) total += 3;
      }
    }

    // Faux motif de repérage : sombre-clair-sombre×3-clair-sombre bordé de
    // quatre modules clairs. Les deux côtés comptent séparément — un motif
    // encadré de clair des deux côtés trompe le scanner deux fois plus.
    var motif = [true, false, true, true, true, false, true];
    function faux(lire) {
      var p = 0, k, d, n, clair;
      function clairs(depart) {
        for (var i = depart; i < depart + 4; i++) {
          if (i < 0 || i >= taille || lire(k, i)) return false;
        }
        return true;
      }
      for (k = 0; k < taille; k++) {
        for (d = 0; d + 7 <= taille; d++) {
          for (n = 0; n < 7; n++) if (lire(k, d + n) !== motif[n]) break;
          if (n < 7) continue;
          if (clairs(d - 4)) p += 40;
          if (clairs(d + 7)) p += 40;
        }
      }
      return p;
    }
    total += faux(function (l, c) { return m[l][c]; });
    total += faux(function (c, l) { return m[l][c]; });

    for (i = 0; i < taille; i++) {
      for (j = 0; j < taille; j++) if (m[i][j]) sombres++;
    }
    total += 10 * Math.floor(Math.abs(sombres * 100 / (taille * taille) - 50) / 5);
    return total;
  }

  function copier(m) {
    return m.map(function (l) { return l.slice(); });
  }

  /* ---- Le QR code complet ----------------------------------------------- */
  function qrModules(texte, options) {
    options = options || {};
    var donnees = octets(String(texte === undefined || texte === null ? '' : texte));
    var version = options.version || versionPour(donnees.length);
    if (!version) {
      throw new Error('QR code : ' + donnees.length + ' octets, 213 au plus (versions 1 à 10, correction M).');
    }
    var taille = 17 + 4 * version;
    var base = grilleVide(taille);
    poserMotifs(base, version);
    var fixe = base.map(function (l) { return l.map(function (c) { return c !== null; }); });
    poserDonnees(base, fixe, motsFinaux(donnees, version));

    var meilleur = null, meilleure = Infinity, masque, m, i, j, p;
    for (masque = 0; masque < 8; masque++) {
      if (options.masque !== undefined && options.masque !== masque) continue;
      m = copier(base);
      for (i = 0; i < taille; i++) {
        for (j = 0; j < taille; j++) if (!fixe[i][j] && MASQUES[masque](i, j)) m[i][j] = !m[i][j];
      }
      poserFormat(m, masque, version);
      p = penalite(m);
      if (p < meilleure) { meilleure = p; meilleur = m; }
    }
    return meilleur;
  }

  function qr(texte, options) {
    options = options || {};
    var m = qrModules(texte, options);
    var n = m.length;
    var marge = options.marge === undefined ? 4 : options.marge;
    var total = n + marge * 2;
    var svg = balise('svg', {
      viewBox: '0 0 ' + total + ' ' + total,
      'shape-rendering': 'crispEdges',
      role: 'img',
      class: options.classe || 'gs-qr'
    });
    if (options.titre) {
      var titre = balise('title', {});
      titre.textContent = options.titre;
      svg.appendChild(titre);
    } else {
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('role', 'presentation');
    }
    // Le fond clair fait partie de la norme : sans lui, un scanner ne trouve
    // pas les bords du code.
    svg.appendChild(balise('rect', { x: 0, y: 0, width: total, height: total, fill: options.fond || '#fff' }));
    var d = [], i, j;
    for (i = 0; i < n; i++) {
      for (j = 0; j < n; j++) if (m[i][j]) d.push('M' + (j + marge) + ' ' + (i + marge) + 'h1v1h-1z');
    }
    svg.appendChild(balise('path', { d: d.join(''), fill: options.couleur || '#000' }));
    return svg;
  }

  /* ======================================================================
     Code-barres Code 128
     ======================================================================
     Le code-barres des étiquettes d'expédition. Jeu B : lettres, chiffres et
     ponctuation. Chaque caractère devient six largeurs de barres et
     d'espaces ; un caractère de contrôle calculé à la fin permet au scanner
     de refuser une lecture douteuse au lieu de renvoyer un mauvais numéro.
     ====================================================================== */
  var MOTIFS = [
    '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312', '132212', '221213',
    '221312', '231212', '112232', '122132', '122231', '113222', '123122', '123221', '223211', '221132',
    '221231', '213212', '223112', '312131', '311222', '321122', '321221', '312212', '322112', '322211',
    '212123', '212321', '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
    '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121', '313121', '211331',
    '231131', '213113', '213311', '213131', '311123', '311321', '331121', '312113', '312311', '332111',
    '314111', '221411', '431111', '111224', '111422', '121124', '121421', '141122', '141221', '112214',
    '112412', '122114', '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
    '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112', '421211', '212141',
    '214121', '412121', '111143', '111341', '131141', '114113', '114311', '411113', '411311', '113141',
    '114131', '311141', '411131', '211412', '211214', '211232', '2331112'
  ];
  var VERS_C = 99, VERS_B = 100, DEPART_B = 104, DEPART_C = 105, ARRET = 106;

  // Les chiffres s'écrivent deux par deux dans le jeu C : « GSE-10001-HT »
  // tient ainsi sur moins de barres, donc des barres plus larges à surface
  // égale — et une barre large se lit mieux au scanner qu'une barre fine
  // sortie d'une imprimante d'étiquettes. On y passe dès quatre chiffres de
  // suite, et on revient au jeu B pour le reste.
  function valeurs128(t) {
    var codes = [DEPART_C], jeu = 'C', tampon = '', i, c, chiffres, k;

    function estChiffre(n) { return n >= 48 && n <= 57; }

    for (i = 0; i < t.length; i++) {
      c = t.charCodeAt(i);
      if (c < 32 || c > 126) {
        throw new Error('Code-barres : « ' + t.charAt(i) + ' » ne s\'écrit pas en Code 128 (jeu B).');
      }
      if (jeu === 'C' && !estChiffre(c)) {
        codes.push(VERS_B);
        jeu = 'B';
        if (tampon.length === 1) {
          codes.push(tampon.charCodeAt(0) - 32);
          tampon = '';
        }
      } else if (jeu === 'B') {
        chiffres = 0;
        for (k = i; k < t.length && k < i + 10; k++) {
          if (!estChiffre(t.charCodeAt(k))) break;
          chiffres++;
        }
        if (chiffres > 3) {
          codes.push(VERS_C);
          jeu = 'C';
        }
      }
      if (jeu === 'B') {
        codes.push(c - 32);
      } else {
        tampon += t.charAt(i);
        if (tampon.length === 2) {
          codes.push(Number(tampon));
          tampon = '';
        }
      }
    }
    // Un chiffre tout seul à la fin ne fait pas une paire
    if (tampon.length === 1) {
      codes.push(VERS_B);
      codes.push(tampon.charCodeAt(0) - 32);
    }
    // Commencer par « départ C » puis « passer en B » ne sert à rien
    if (codes[1] === VERS_B) codes.splice(0, 2, DEPART_B);
    return codes;
  }

  // Largeurs successives, en commençant par une barre
  function code128Modules(texte) {
    var t = String(texte === undefined || texte === null ? '' : texte);
    if (!t.length) throw new Error('Code-barres : texte vide.');
    var codes = valeurs128(t), somme = codes[0], largeurs = [], i;
    for (i = 1; i < codes.length; i++) somme += i * codes[i];
    codes.push(somme % 103);
    codes.push(ARRET);
    codes.forEach(function (v) {
      MOTIFS[v].split('').forEach(function (n) { largeurs.push(Number(n)); });
    });
    return largeurs;
  }

  function code128(texte, options) {
    options = options || {};
    var largeurs = code128Modules(texte);
    var hauteur = options.hauteur || 30;
    var marge = options.marge === undefined ? 10 : options.marge;   // zone claire : 10 modules
    var total = largeurs.reduce(function (a, b) { return a + b; }, 0);
    var svg = balise('svg', {
      viewBox: '0 0 ' + (total + marge * 2) + ' ' + hauteur,
      preserveAspectRatio: 'none',
      'shape-rendering': 'crispEdges',
      role: 'img',
      class: options.classe || 'gs-codebarre'
    });
    if (options.titre) {
      var titre = balise('title', {});
      titre.textContent = options.titre;
      svg.appendChild(titre);
    } else {
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('role', 'presentation');
    }
    svg.appendChild(balise('rect', {
      x: 0, y: 0, width: total + marge * 2, height: hauteur, fill: options.fond || '#fff'
    }));
    var d = [], x = marge, i;
    for (i = 0; i < largeurs.length; i++) {
      if (i % 2 === 0) d.push('M' + x + ' 0h' + largeurs[i] + 'v' + hauteur + 'h-' + largeurs[i] + 'z');
      x += largeurs[i];
    }
    svg.appendChild(balise('path', { d: d.join(''), fill: options.couleur || '#000' }));
    return svg;
  }

  window.GoshipCodes = {
    qr: qr,
    qrModules: qrModules,
    code128: code128,
    code128Modules: code128Modules
  };
})();
