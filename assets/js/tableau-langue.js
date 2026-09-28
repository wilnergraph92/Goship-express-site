/* ==========================================================================
   Goship Express — la langue du tableau de bord (admin.html)
   Le tableau de bord s'écrit en français ; ce fichier l'affiche en anglais, en
   espagnol ou en créole. Il ne touche à aucune donnée ni à aucune règle : il
   remplace, à l'écran seulement, les textes qu'il connaît (assets/js/
   tableau-textes.js) et remet le français quand on le rechoisit. Les textes qu'admin.js écrit
   après coup (listes, fiches, messages) passent par le même chemin, grâce à un
   MutationObserver. Ce qu'il ne connaît pas (noms, adresses, notes, textes
   rares) reste tel quel.
   - Préférence de l'appareil : localStorage « gse-tableau-langue » (fr par défaut).
   - Le sélecteur : <select data-langue-tableau> dans la barre du haut.
   - Les factures et étiquettes imprimées gardent la langue du client (impression.js).
   Les traductions sont celles du site : outils/traductions/<langue>.json. Un texte
   ajouté au tableau de bord : sa ligne dans outils/traductions/tableau.txt, ses trois
   traductions dans ces dictionnaires, puis python3 outils/traduire.py.
   ========================================================================== */
(function () {
  'use strict';

  var CLE = 'gse-tableau-langue';
  var LANGUES = ['fr', 'en', 'es', 'ht'];
  var RANG = { en: 0, es: 1, ht: 2 };
  var ATTRIBUTS = ['placeholder', 'aria-label', 'title', 'data-libelle', 'label'];
  var IGNORES = 'script, style, textarea, code, [translate="no"] option, [data-langue-tableau] option';

  // Français → [anglais, espagnol, créole]
  // Français → [anglais, espagnol, créole] : assets/js/tableau-textes.js, généré par
  // outils/traduire.py à partir des dictionnaires du site (outils/traductions/)
  var D = window.GoshipTextesTableau || {};


  // Les dates (O.date et l'horloge) : mois et jours de la semaine
  var MOIS_COURTS = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
  var MOIS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  var JOURS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
  var JOURS_COURTS = ['dim.', 'lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.'];
  var MOIS_T = {
    en: [['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
         ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']],
    es: [['ene.', 'feb.', 'mar.', 'abr.', 'may.', 'jun.', 'jul.', 'ago.', 'sept.', 'oct.', 'nov.', 'dic.'],
         ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']],
    ht: [['jan.', 'fev.', 'mas', 'avr.', 'me', 'jen', 'jiy.', 'out', 'sept.', 'okt.', 'nov.', 'des.'],
         ['janvye', 'fevriye', 'mas', 'avril', 'me', 'jen', 'jiyè', 'out', 'septanm', 'oktòb', 'novanm', 'desanm']]
  };
  var JOURS_T = {
    en: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
    es: ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'],
    ht: ['dimanch', 'lendi', 'madi', 'mèkredi', 'jedi', 'vandredi', 'samdi']
  };
  var JOURS_COURTS_T = {
    en: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
    es: ['dom.', 'lun.', 'mar.', 'mié.', 'jue.', 'vie.', 'sáb.'],
    ht: ['dim.', 'len.', 'mad.', 'mèk.', 'jed.', 'van.', 'sam.']
  };
  // Les débuts de phrase suivis d'une valeur (« Reçu le 12 sept. 2026 », « Payé 20,00 $ »…).
  // date : la suite doit être une date ou un texte connu ; nombre : commencer par un chiffre ;
  // libre : n'importe quelle suite (un nom, un lieu)
  var PREFIXES = [
    ['Inscrit le', 'date'], ['Reçu le', 'date'], ['Échue le', 'date'], ['Avant le', 'date'], ['Annulée le', 'date'],
    ['Annulé le', 'date'], ['Livré le', 'date'], ['Créée le', 'date'], ['Le', 'date'], ['Du', 'date'], ['au', 'date'],
    ['Payé', 'nombre'], ['payé', 'nombre'], ['Reste', 'nombre'], ['reste', 'nombre'], ['solde', 'nombre'], ['total', 'nombre'],
    ['max.', 'nombre'], ['avant :', 'nombre'], ['moyenne :', 'nombre'],
    ['Payée ·', 'libre'], ['Période précédente :', 'libre'], ['Dernier événement :', 'libre'], ['depuis', 'libre'],
    ['vers', 'libre'], ['par', 'libre'], ['via', 'libre']
  ];
  var PREFIXES_T = {
    'Payée ·': ['Paid ·', 'Pagada ·', 'Peye ·'], 'reste': ['left', 'resta', 'rete'], 'solde': ['balance', 'saldo', 'balans'],
    'total': ['total', 'total', 'total'], 'payé': ['paid', 'pagado', 'peye'],
    'Période précédente :': ['Previous period:', 'Período anterior:', 'Peryòd anvan :'],
    'Dernier événement :': ['Latest event:', 'Último evento:', 'Dènye evènman :'], 'depuis': ['for', 'desde hace', 'depi'],
    'Le': ['On', 'El', 'Le'], 'vers': ['to', 'hacia', 'pou'], 'par': ['by', 'por', 'pa'], 'via': ['via', 'vía', 'via'],
    'moyenne :': ['average:', 'media:', 'mwayèn :'], 'avant :': ['before:', 'antes:', 'anvan :'], 'max.': ['max.', 'máx.', 'maks.'],
    'Annulé le': ['Cancelled on', 'Anulado el', 'Anile le'], 'Annulée le': ['Cancelled on', 'Anulada el', 'Anile le'],
    'Livré le': ['Delivered on', 'Entregado el', 'Livre le']
  };
  // Des phrases à trous : $1… reprend un morceau tel quel, {1}… le reprend traduit
  var REGLES = [
    [/^Du (\S+) au (\S+) \(jours de Santo Domingo\)$/, ['From $1 to $2 (Santo Domingo days)', 'Del $1 al $2 (días de Santo Domingo)', 'Depi $1 rive $2 (jou Santo Domingo)']],
    [/^Le (\S+) \(jours de Santo Domingo\)$/, ['On $1 (Santo Domingo days)', 'El $1 (días de Santo Domingo)', 'Le $1 (jou Santo Domingo)']],
    [/^Du (\S+) au (\S+), comparé du (\S+) au (\S+)$/, ['From $1 to $2, compared with $3 to $4', 'Del $1 al $2, comparado con del $3 al $4', 'Depi $1 rive $2, konpare ak $3 rive $4']],
    [/^jours de Santo Domingo$/, ['Santo Domingo days', 'días de Santo Domingo', 'jou Santo Domingo']],
    [/^chiffres de (\S+)$/, ['figures as of $1', 'cifras de las $1', 'chif a $1']],
    [/^par rapport au (.+)$/, ['vs. $1', 'respecto al $1', 'konpare ak $1']],
    [/^(\d+) j ou plus$/, ['$1 d or more', '$1 d o más', '$1 j oswa plis']],
    [/^Rapide : (.+) à chaque scan$/, ['Fast: {1} on each scan', 'Rápido: {1} en cada escaneo', 'Rapid : {1} nan chak eskan']],
    [/^(.+) : (.+), contre aucun sur la période précédente\.$/, ['{1}: $2, versus none in the previous period.', '{1}: $2, frente a ninguno en el período anterior.', '{1} : $2, kont zewo nan peryòd anvan an.']],
    [/^(.+) : stable \((.+)\)\.$/, ['{1}: stable ($2).', '{1}: estable ($2).', '{1} : estab ($2).']],
    [/^(.+) \((\d+) lignes?\)$/, ['{1} ($2 rows)', '{1} ($2 filas)', '{1} ($2 liy)']],
    [/^(.+) — ([\d\s  .,]+ ?%)$/, ['{1} — $2', '{1} — $2', '{1} — $2']],
    [/^(.+) \(vous\)$/, ['$1 (you)', '$1 (usted)', '$1 (ou)']],
    [/^(.+) \(démonstration\)$/, ['{1} (demo)', '{1} (demo)', '{1} (demo)']],
    [/^Facture (\d{4}-\d{2}-\d+)$/, ['Invoice $1', 'Factura $1', 'Fakti $1']],
    [/^Miami → ([^·]+)$/, ['Miami → {1}', 'Miami → {1}', 'Miami → {1}']],
    [/^(.+), (Haïti|République dominicaine|États-Unis)$/, ['$1, {2}', '$1, {2}', '$1, {2}']],
    // Les rapports (onglet « Rapport »)
    [/^(Voir le rapport|Détails du rapport|Imprimer le rapport|PDF du rapport|Modifier le rapport|Supprimer le rapport) (.+)$/, ['{1} $2', '{1} $2', '{1} $2']],
    [/^(\d+)–(\d+) sur (\d+)$/, ['$1–$2 of $3', '$1–$2 de $3', '$1–$2 sou $3']],
    [/^Calculé le (.+), sur les données actuelles\.$/, ['Calculated on {1}, from current data.', 'Calculado el {1}, con los datos actuales.', 'Kalkile le {1}, sou done aktyèl yo.']],
    [/^(.+) \((Administrateur|Gérant|Employé)\)$/, ['$1 ({2})', '$1 ({2})', '$1 ({2})']],
    [/^Les (\S+) premières lignes sur (\S+) — affinez la période ou les filtres pour le reste\.$/, ['First $1 rows of $2 — narrow the period or the filters for the rest.', 'Primeras $1 filas de $2 — acote el período o los filtros para ver el resto.', '$1 premye liy sou $2 — chwazi yon peryòd oswa filt ki pi jis pou rès la.']]
  ];
  // « 1 colis » : le singulier, là où le français ne change pas
  var SINGULIERS = { colis: ['package', 'paquete', 'koli'] };

  var langue = lire();
  var TEXTES = new WeakMap();      // nœud texte → { fr, pose }
  var ATTRS = new WeakMap();       // élément → { attribut: { fr, pose } }

  function lire() {
    try {
      var l = localStorage.getItem(CLE);
      return LANGUES.indexOf(l) >= 0 ? l : 'fr';
    } catch (e) { return 'fr'; }
  }

  function motsDate(t, l) {
    var i = RANG[l];
    // « 27 sept. 2026, 20:50 », « dimanche 27 septembre 2026 », « 27 sept. »
    var m = /^(?:(\S+) )?(\d{1,2}) (\S+)(?: (\d{4}))?(,? (?:à )?\d{1,2}[:h]\d{2})?$/i.exec(t);
    if (!m) return null;
    var jour = m[1] ? JOURS.indexOf(m[1].toLowerCase()) : -1;
    var court = m[1] && jour < 0 ? JOURS_COURTS.indexOf(m[1].toLowerCase()) : -1;
    if (m[1] && jour < 0 && court < 0) return null;
    var mc = MOIS_COURTS.indexOf(m[3].toLowerCase()), ml = MOIS.indexOf(m[3].toLowerCase());
    if (mc < 0 && ml < 0) return null;
    var mois = mc >= 0 ? MOIS_T[l][0][mc] : MOIS_T[l][1][ml];
    var heure = m[5] ? m[5].replace(/^,? (?:à )?/, '').replace('h', ':') : '';
    var nomJour = jour >= 0 ? JOURS_T[l][jour] : (court >= 0 ? JOURS_COURTS_T[l][court] : '');
    if (jour >= 0 && m[1].charAt(0) === m[1].charAt(0).toUpperCase()) nomJour = nomJour.charAt(0).toUpperCase() + nomJour.slice(1);
    var r = l === 'en'
      ? (nomJour ? nomJour + ', ' : '') + mois + ' ' + m[2] + (m[4] ? ', ' + m[4] : '')
      : (nomJour ? nomJour + ' ' : '') + m[2] + (l === 'es' && ml >= 0 ? ' de ' : ' ') + mois + (m[4] ? (l === 'es' && ml >= 0 ? ' de ' : ' ') + m[4] : '');
    return r + (heure ? ', ' + heure : '');
  }

  // Le français t, dans la langue l ; null si le texte n'est pas connu
  function traduire(t, l) {
    var i = RANG[l];
    if (D[t]) return D[t][i];
    var m, k;
    for (k = 0; k < REGLES.length; k++) {
      if ((m = REGLES[k][0].exec(t))) {
        return REGLES[k][1][i].replace(/\$(\d)/g, function (x, n) { return m[n]; })
          .replace(/\{(\d)\}/g, function (x, n) { var y = traduire(m[n], l); return y === null ? m[n] : y; });
      }
    }
    // « Haïti (5) », « Livrés (25 %) »
    if ((m = /^(.*\S) \(([\d\s  .,%]+)\)$/.exec(t))) {
      var a = traduire(m[1], l);
      return a === null ? null : a + ' (' + m[2] + ')';
    }
    // « · avant : 0 »
    if ((m = /^· (.+)$/.exec(t))) { var b = traduire(m[1], l); return b === null ? null : '· ' + b; }
    // Des morceaux séparés par « · » : chacun pour soi
    if (t.indexOf(' · ') > 0) {
      var connus = 0;
      var r = t.split(' · ').map(function (x) { var y = traduire(x, l); if (y !== null) connus++; return y === null ? x : y; });
      return connus ? r.join(' · ') : null;
    }
    var d = motsDate(t, l);
    if (d) return d;
    // « 12 colis », « 3 colis correspondent aux filtres », « 4 jours »
    if ((m = /^([\d\s  .,]+) (.+)$/.exec(t)) && D[m[2]]) {
      return m[1] + ' ' + (m[1].trim() === '1' && SINGULIERS[m[2]] ? SINGULIERS[m[2]][i] : D[m[2]][i]);
    }
    // « Reçu le 12 sept. 2026 », « Payé 20,00 $ », « par Marie »
    for (k = 0; k < PREFIXES.length; k++) {
      var p = PREFIXES[k][0], genre = PREFIXES[k][1];
      if (t.length <= p.length + 1 || t.indexOf(p + ' ') !== 0) continue;
      var reste = t.slice(p.length + 1);
      var tp = PREFIXES_T[p] ? PREFIXES_T[p][i] : (D[p] ? D[p][i] : null);
      if (tp === null) continue;
      var tr = motsDate(reste, l) || traduire(reste, l);
      if (genre === 'date' && tr === null) continue;
      if (genre === 'nombre' && !/^[-+−\d]/.test(reste)) continue;
      return tp + ' ' + (tr === null ? reste : tr);
    }
    var deuxPoints = l === 'ht' ? ' :' : ':';
    // « Facturé : 431,50 $ », « Départ : Miami (Medley), FL »
    if ((m = /^(.+?) : (.+)$/.exec(t)) && D[m[1]]) {
      var v = traduire(m[2], l);
      return D[m[1]][i] + deuxPoints + ' ' + (v === null ? m[2] : v);
    }
    // « Pays : », « Démonstration : »
    if ((m = /^(.*\S) ?:$/.exec(t)) && D[m[1]]) return D[m[1]][i] + deuxPoints;
    return null;
  }

  function ignore(n) {
    var e = n.nodeType === 1 ? n : n.parentElement;
    return !e || !!e.closest(IGNORES);
  }

  function texte(n) {
    if (ignore(n)) return;
    var info = TEXTES.get(n);
    var brut = n.data;
    if (info && brut === info.pose) {
      if (langue === 'fr' && info.pose !== info.fr) { info.pose = info.fr; n.data = info.fr; }
      else if (langue !== 'fr') {
        var t0 = poser(info.fr);
        if (t0 !== n.data) { info.pose = t0; n.data = t0; }
      }
      return;
    }
    // Un nouveau texte (écrit par la page) : en français
    info = { fr: brut, pose: brut };
    TEXTES.set(n, info);
    if (langue === 'fr') return;
    var t = poser(brut);
    if (t !== brut) { info.pose = t; n.data = t; }
  }

  // Le texte brut traduit, espaces autour gardés
  function poser(brut) {
    if (langue === 'fr') return brut;
    var coeur = brut.trim();
    if (!coeur || !/[A-Za-zÀ-ÿ]/.test(coeur)) return brut;
    var tr = traduire(coeur.replace(/\s+/g, ' '), langue);
    return tr === null ? brut : brut.replace(coeur, tr);
  }

  function attributs(e) {
    if (ignore(e)) return;
    var memo = ATTRS.get(e);
    ATTRIBUTS.forEach(function (a) {
      if (!e.hasAttribute(a)) return;
      var v = e.getAttribute(a);
      var info = memo && memo[a];
      if (!info || v !== info.pose) info = { fr: v, pose: v };
      var t = poser(info.fr);
      if (!memo) { memo = {}; ATTRS.set(e, memo); }
      memo[a] = info;
      if (t !== v) { info.pose = t; e.setAttribute(a, t); } else info.pose = v;
    });
  }

  function parcourir(racine) {
    if (racine.nodeType === 3) { texte(racine); return; }
    if (racine.nodeType !== 1 && racine.nodeType !== 9) return;
    var marche = document.createTreeWalker(racine, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
    var n = racine.nodeType === 1 ? racine : marche.nextNode();
    while (n) {
      if (n.nodeType === 3) texte(n); else attributs(n);
      n = marche.nextNode();
    }
  }

  function appliquer() {
    document.documentElement.lang = langue === 'ht' ? 'ht' : langue;
    parcourir(document.body);
    if (!appliquer.titre) appliquer.titre = document.title;
    document.title = langue === 'fr' ? appliquer.titre : (traduire(appliquer.titre, langue) || appliquer.titre);
    Array.prototype.forEach.call(document.querySelectorAll('[data-langue-tableau]'), function (s) { s.value = langue; });
  }

  function choisir(l) {
    if (LANGUES.indexOf(l) < 0) return;
    langue = l;
    try { localStorage.setItem(CLE, l); } catch (e) { /* préférence facultative */ }
    appliquer();
  }

  function demarrer() {
    appliquer();
    new MutationObserver(function (liste) {
      liste.forEach(function (m) {
        if (m.type === 'characterData') texte(m.target);
        else if (m.type === 'attributes') attributs(m.target);
        else Array.prototype.forEach.call(m.addedNodes, parcourir);
      });
    }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRIBUTS });
    document.addEventListener('change', function (e) {
      if (e.target.matches && e.target.matches('[data-langue-tableau]')) choisir(e.target.value);
    });
  }

  window.GoshipLangueTableau = {
    langue: function () { return langue; },
    choisir: choisir,
    traduire: function (t) { return langue === 'fr' ? t : (traduire(t, langue) || t); }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrer); else demarrer();
})();
