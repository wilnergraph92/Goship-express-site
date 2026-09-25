/* ==========================================================================
   Goship Express — le poste de scan (onglet « Scanner » du tableau de bord)
   --------------------------------------------------------------------------
   Le trajet d'un scan :

     EntreeScanner     les frappes du scanner (ou du clavier) → une chaîne
          ↓
     GoshipScan        la chaîne → une référence de colis (scan-parser.js),
          ↓            sans aucune requête si elle est illisible
     ServiceScanner    la référence → API.admin.scannerColis / operationScanner
          ↓            → le moteur de la base (outils/supabase-scanner.sql,
          ↓            qui appelle executer_operation)
     Poste             ce que la base a répondu, et rien d'autre

   Le poste n'invente rien : pas de statut calculé ici, pas de succès affiché
   avant la réponse de la base, pas d'opération proposée que la base n'ait
   listée. La saisie à la main et le scanner passent par le même chemin.
   ========================================================================== */
(function () {
  'use strict';

  var API = window.GoshipAPI;
  var SCAN = window.GoshipScan;
  var vue = document.querySelector('[data-vue="scanner"]');
  if (!API || !SCAN || !vue || !API.admin || !API.admin.scannerColis) return;
  var O = API.outils, R = API.regles;

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function el(balise, classe, texte) {
    var n = document.createElement(balise);
    if (classe) n.className = classe;
    if (texte !== undefined && texte !== null) n.textContent = texte;
    return n;
  }

  // Une clé par opération envoyée : renvoyée telle quelle après une coupure,
  // elle rend le résultat déjà enregistré au lieu d'en écrire un second.
  function nouvelleCle() {
    var octets = new Uint8Array(12);
    if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(octets);
    else for (var i = 0; i < octets.length; i++) octets[i] = Math.floor(Math.random() * 256);
    return 'scan-' + Array.prototype.map.call(octets, function (o) { return (o < 16 ? '0' : '') + o.toString(16); }).join('');
  }

  /* ======================================================================
     ServiceScanner : la référence → la base → un résultat normalisé
     ====================================================================== */
  // Ce qu'une erreur veut dire pour la personne au poste. Jamais le message
  // technique de PostgreSQL : la phrase de la base (err.detail) quand elle
  // en donne une, sinon un titre simple.
  function etatDe(err) {
    var code = err && err.code;
    if (code === 'reseau') return 'reseau';
    if (code === 'non-autorise') return 'refuse';
    if (code === 'SHIPMENT_NOT_FOUND') return 'introuvable';
    if (code === 'INVALID_SCAN_FORMAT') return 'invalide';
    if (code === 'STATUS_CONFLICT' || code === 'CONCURRENT_MODIFICATION') return 'conflit';
    if (err && err.metier) return 'impossible';
    if (code === 'absent') return 'absent';
    return 'serveur';
  }

  var ServiceScanner = {
    // Le texte lu → { etat: 'trouve' | 'introuvable' | 'invalide' | …, analyse, fiche, erreur }
    chercher: function (texte) {
      var analyse = SCAN.analyser(texte);
      if (!analyse.ok) return Promise.resolve({ etat: 'invalide', analyse: analyse });
      return API.admin.scannerColis(analyse.reference).then(function (fiche) {
        return fiche ? { etat: 'trouve', analyse: analyse, fiche: fiche } : { etat: 'introuvable', analyse: analyse };
      }, function (err) {
        return { etat: etatDe(err), analyse: analyse, erreur: err };
      });
    },

    // Une opération sur une référence. Le succès n'existe que si la base l'a
    // confirmé : « fait » (événement écrit) ou « deja » (rien de neuf).
    operer: function (reference, type, o) {
      return API.admin.operationScanner(reference, type, o).then(function (r) {
        return { etat: r.code === 'OK' ? 'fait' : 'deja', reponse: r, fiche: r.fiche };
      }, function (err) {
        return { etat: etatDe(err), erreur: err };
      });
    }
  };

  /* ======================================================================
     Le son : un bip court pour un succès, deux graves pour une erreur.
     Facultatif — sans son (navigateur, réglage du poste), rien ne change.
     ====================================================================== */
  var Son = (function () {
    var ctx = null;
    function jouer(notes) {
      if (!$('[data-scan-son]', vue).checked) return;
      try {
        ctx = ctx || new (window.AudioContext || window.webkitAudioContext)();
        var t = ctx.currentTime;
        notes.forEach(function (n) {
          var osc = ctx.createOscillator(), gain = ctx.createGain();
          osc.frequency.value = n[0];
          gain.gain.setValueAtTime(0.18, t + n[1]);
          gain.gain.exponentialRampToValueAtTime(0.001, t + n[1] + n[2]);
          osc.connect(gain);
          gain.connect(ctx.destination);
          osc.start(t + n[1]);
          osc.stop(t + n[1] + n[2]);
        });
      } catch (e) { /* pas de son : le retour visuel suffit */ }
    }
    return {
      succes: function () { jouer([[1046, 0, 0.09]]); },
      info: function () { jouer([[784, 0, 0.08], [784, 0.12, 0.08]]); },
      erreur: function () { jouer([[220, 0, 0.14], [196, 0.18, 0.18]]); }
    };
  })();

  /* ======================================================================
     Le poste
     ====================================================================== */
  var champ = $('[data-scan-code]', vue);
  var champLieu = $('[data-scan-lieu]', vue);
  var choixMode = $('[data-scan-mode]', vue);
  var zoneEtat = $('[data-scan-etat]', vue);
  var zoneFiche = $('[data-scan-fiche]', vue);
  var journal = $('[data-scan-journal]', vue);

  var TYPES = R.typesEvenement;
  var LIBELLES = R.libellesStatut;
  // Le mode rapide enchaîne les colis sans question : on y garde les
  // opérations qui n'en demandent pas. « Action requise » (une raison à
  // donner) et « Action résolue » (une décision) se font colis par colis.
  var RAPIDES = R.operationsScanner.filter(function (t) { return t !== 'ACTION_REQUISE' && t !== 'ACTION_RESOLUE'; });

  var ficheActuelle = null;      // la dernière fiche renvoyée par la base
  var confirmation = null;       // l'opération en attente de « Confirmer »
  var aRejouer = null;           // la dernière opération coupée par le réseau
  var file = [];                 // les codes scannés pendant qu'une requête est en cours
  var occupe = false;
  var derniers = [];

  // Réglages du poste (lieu, mode, son) : une commodité de cet ordinateur,
  // pas une donnée. Ils peuvent manquer (navigation privée) sans rien casser.
  function lireReglage(cle, defaut) {
    try { var v = localStorage.getItem('gse-scan-' + cle); return v === null ? defaut : v; } catch (e) { return defaut; }
  }
  function ecrireReglage(cle, valeur) {
    try { localStorage.setItem('gse-scan-' + cle, valeur); } catch (e) { /* tant pis */ }
  }

  RAPIDES.forEach(function (t) {
    var opt = el('option', null, 'Rapide : ' + TYPES[t].libelle + ' à chaque scan');
    opt.value = t;
    choixMode.appendChild(opt);
  });
  choixMode.value = RAPIDES.indexOf(lireReglage('mode', '')) >= 0 ? lireReglage('mode', '') : '';
  champLieu.value = lireReglage('lieu', '');
  $('[data-scan-son]', vue).checked = lireReglage('son', 'oui') === 'oui';

  function majAideMode() {
    var t = choixMode.value;
    $('[data-scan-mode-aide]', vue).textContent = t
      ? 'Mode rapide : chaque colis scanné est enregistré « ' + TYPES[t].libelle + ' », sans confirmation. ' +
        'La base refuse ce qui ne suit pas le parcours.'
      : 'Chaque scan affiche le colis et les opérations permises.';
    vue.classList.toggle('is-rapide', !!t);
  }
  choixMode.addEventListener('change', function () { ecrireReglage('mode', choixMode.value); majAideMode(); annulerConfirmation(); pret(); });
  champLieu.addEventListener('change', function () { ecrireReglage('lieu', champLieu.value.trim()); });
  $('[data-scan-son]', vue).addEventListener('change', function (e) { ecrireReglage('son', e.target.checked ? 'oui' : 'non'); });
  majAideMode();

  // Le champ du scanner reprend la main après chaque résultat, sauf si
  // quelqu'un est en train d'écrire ailleurs dans le poste (lieu, raison).
  function pret() {
    champ.value = '';
    var actif = document.activeElement;
    var ailleurs = actif && actif !== champ && vue.contains(actif) && /^(INPUT|TEXTAREA|SELECT)$/.test(actif.tagName);
    if (!ailleurs && !vue.hidden) champ.focus();
  }

  /* ---- L'état : un titre, un détail, une couleur ---------------------------- */
  var ETATS = {
    pret: ['info', 'Prêt : scannez un colis'],
    recherche: ['info', 'Recherche…'],
    envoi: ['info', 'Enregistrement…'],
    trouve: ['succes', '✓ COLIS TROUVÉ'],
    livre: ['attention', 'COLIS DÉJÀ LIVRÉ'],
    incident: ['attention', '⚠ ACTION REQUISE'],
    introuvable: ['erreur', '✕ COLIS INTROUVABLE'],
    invalide: ['attention', '⚠ CODE INVALIDE'],
    refuse: ['erreur', '⚠ ACTION NON AUTORISÉE'],
    impossible: ['attention', '⚠ OPÉRATION IMPOSSIBLE'],
    conflit: ['attention', '⚠ LE COLIS A CHANGÉ ENTRE-TEMPS'],
    reseau: ['erreur', '⚠ CONNEXION IMPOSSIBLE'],
    absent: ['erreur', '⚠ BASE PAS À JOUR'],
    serveur: ['erreur', '⚠ ERREUR SERVEUR'],
    fait: ['succes', '✓'],
    deja: ['info', 'ℹ DÉJÀ FAIT']
  };

  function montrerEtat(nom, titre, detail, boutons) {
    var e = ETATS[nom] || ETATS.serveur;
    zoneEtat.className = 'gs-scan__etat is-' + e[0];
    $('[data-scan-titre]', zoneEtat).textContent = titre || e[1];
    $('[data-scan-detail]', zoneEtat).textContent = detail || '';
    var zb = $('[data-scan-boutons-etat]', zoneEtat);
    zb.textContent = '';
    (boutons || []).forEach(function (b) { zb.appendChild(b); });
  }

  function bouton(texte, classe, action) {
    var b = el('button', 'gs-bouton gs-bouton--petit ' + (classe || 'gs-bouton--contour'), texte);
    b.type = 'button';
    b.addEventListener('click', action);
    return b;
  }

  // Le texte d'une erreur : la phrase de la base si c'en est une, jamais un
  // message technique.
  function phrase(err, defaut) {
    if (err && err.metier && err.detail) return err.detail;
    if (err && err.code === 'reseau') return 'Rien n’a été enregistré. Vérifiez la connexion, puis réessayez.';
    if (err && err.code === 'absent') return 'Lancez outils/supabase-scanner.sql dans Supabase.';
    return defaut || '';
  }

  /* ---- La liste des derniers scans : ce que la base a répondu --------------- */
  function noter(reference, nom, libelle) {
    var d = new Date();
    derniers.unshift({ heure: (d.getHours() < 10 ? '0' : '') + d.getHours() + ':' + (d.getMinutes() < 10 ? '0' : '') +
      d.getMinutes(), reference: reference, nom: nom, libelle: libelle });
    derniers = derniers.slice(0, 15);
    journal.textContent = '';
    derniers.forEach(function (x) {
      var li = el('li', 'is-' + (ETATS[x.nom] || ETATS.serveur)[0]);
      li.appendChild(el('span', 'gs-scan__heure', x.heure));
      li.appendChild(el('strong', null, x.reference));
      li.appendChild(el('span', null, x.libelle));
      journal.appendChild(li);
    });
    $('[data-scan-journal-vide]', vue).hidden = derniers.length > 0;
  }

  /* ---- La fiche du colis ------------------------------------------------------ */
  function libelleEvenement(statut, h) {
    h = h || {};
    var t = TYPES[h.type_evenement];
    var texte = t && (!t.statut || t.special) && h.type_evenement !== 'ACTION_RESOLUE'
      ? t.libelle : (LIBELLES[statut] || statut);
    if (h.corrige) texte += ' (annulé)';
    if (h.auteur) texte += ' · ' + h.auteur;
    return texte;
  }

  function ligne(dl, terme, valeur) {
    if (valeur === null || valeur === undefined || valeur === '') return;
    dl.appendChild(el('dt', null, terme));
    dl.appendChild(el('dd', null, valeur));
  }

  function afficherFiche(f) {
    ficheActuelle = f;
    zoneFiche.textContent = '';
    zoneFiche.hidden = !f;
    if (!f) return;
    var c = f.colis, cl = f.client || {};

    var tete = el('div', 'gs-scan__tete');
    tete.appendChild(el('strong', 'gs-scan__numero', c.numero));
    var st = el('span', 'gs-scan__statut');
    st.appendChild(el('i', 'gs-pastille gs-pastille--' + c.statut));
    st.appendChild(document.createTextNode(LIBELLES[c.statut] || c.statut));
    tete.appendChild(st);
    zoneFiche.appendChild(tete);

    var dl = el('dl', 'gs-scan__infos');
    ligne(dl, 'Client', [cl.nom_complet, cl.code].filter(Boolean).join(' · '));
    ligne(dl, 'Contenu', c.description);
    ligne(dl, 'Poids', c.poids_lb != null ? O.nombre(Number(c.poids_lb)) + ' lb' : '');
    ligne(dl, 'Origine', f.origine);
    ligne(dl, 'Destination', [c.destination, c.pays_destination].filter(Boolean).join(', '));
    ligne(dl, 'Suivi vendeur', c.suivi_transporteur);
    ligne(dl, 'Localisation', c.lieu);
    ligne(dl, 'Dernier événement', f.dernier_evenement
      ? libelleEvenement(f.dernier_evenement.statut, f.dernier_evenement) + ' — ' + O.date(f.dernier_evenement.cree_le, true)
      : '');
    ligne(dl, 'Mis à jour', O.date(c.maj_le, true));
    if (c.prix_usd != null) ligne(dl, 'Prix du transport', O.argent(c.prix_usd));
    zoneFiche.appendChild(dl);

    // Livré ou en action requise : ce qu'il faut savoir avant de toucher au colis
    if (f.livraison) {
      zoneFiche.appendChild(el('p', 'gs-scan__alerte',
        'Livré le ' + O.date(f.livraison.cree_le, true) + (f.livraison.lieu ? ' à ' + f.livraison.lieu : '') +
        (f.livraison.auteur ? ', par ' + f.livraison.auteur : '') + '.'));
    }
    if (f.action_requise) {
      var raison = (f.action_requise.metadonnees || {}).raison || f.action_requise.note;
      zoneFiche.appendChild(el('p', 'gs-scan__alerte gs-scan__alerte--incident',
        'Action requise' + (raison ? ' : ' + raison : '') + ' — depuis le ' + O.date(f.action_requise.cree_le, true) + '.'));
    }

    // Les opérations : celles que la base permet, et seulement celles-là
    var ops = el('div', 'gs-scan__operations');
    if (!f.operations.length) {
      ops.appendChild(el('p', 'gs-champ__aide', c.statut === 'livre'
        ? 'Colis livré : plus aucune opération. Une erreur se corrige depuis sa fiche, onglet Colis.'
        : 'Aucune opération permise pour ce colis à ce statut.'));
    }
    f.operations.forEach(function (op) {
      var b = bouton(op.libelle.toUpperCase(), op.change_statut ? 'gs-bouton--plein' : 'gs-bouton--contour', function () {
        demanderOperation(op);
      });
      b.setAttribute('data-operation', op.type);
      ops.appendChild(b);
    });
    zoneFiche.appendChild(ops);
    zoneFiche.appendChild(el('div', 'gs-scan__confirmation', null)).setAttribute('data-scan-confirmation', '');

    var h = el('div', 'gs-scan__historique');
    h.appendChild(el('h3', null, 'Historique'));
    var ol = el('ol', 'gs-chrono');
    O.remplirHistorique(ol, f.historique, { notes: true, libelle: libelleEvenement });
    h.appendChild(ol);
    zoneFiche.appendChild(h);
  }

  /* ---- Mode normal : choisir l'opération, confirmer ------------------------- */
  function annulerConfirmation() {
    confirmation = null;
    var z = $('[data-scan-confirmation]', zoneFiche);
    if (z) z.textContent = '';
  }

  function demanderOperation(op) {
    if (!ficheActuelle) return;
    var c = ficheActuelle.colis;
    // Une opération qui ne change pas le statut (inspection…) se fait sans
    // question ; un changement de statut se confirme.
    if (!op.change_statut && op.type !== 'ACTION_REQUISE') {
      envoyer(c.numero, op, { attendu: c.statut });
      return;
    }
    confirmation = op;
    var z = $('[data-scan-confirmation]', zoneFiche);
    z.textContent = '';
    z.appendChild(el('p', null, 'Vous êtes sur le point de marquer ' + c.numero + ' comme « ' +
      op.libelle.toUpperCase() + ' ».'));
    var raison = null, lieu = null;
    if (op.type === 'ACTION_REQUISE') {
      raison = el('input', 'gs-scan__raison');
      raison.maxLength = 300;
      raison.placeholder = 'Raison, visible par le client (ex. adresse à vérifier)';
      raison.setAttribute('aria-label', 'Raison de l’action requise');
      z.appendChild(raison);
    }
    if (op.lieu_requis && !champLieu.value.trim()) {
      lieu = el('input', 'gs-scan__raison');
      lieu.maxLength = 80;
      lieu.setAttribute('list', 'lieux-frequents');
      lieu.placeholder = 'Agence où le client retire son colis';
      lieu.setAttribute('aria-label', 'Agence');
      z.appendChild(lieu);
    }
    var actions = el('div', 'gs-scan__actions');
    actions.appendChild(bouton('Annuler', 'gs-bouton--contour', function () { annulerConfirmation(); pret(); }));
    actions.appendChild(bouton('Confirmer', 'gs-bouton--plein', function () {
      var note = raison ? raison.value.trim() : null;
      var o = { attendu: c.statut, note: note, metadonnees: note ? { raison: note } : {} };
      if (lieu) o.lieu = lieu.value.trim();
      annulerConfirmation();
      envoyer(c.numero, op, o);
    }));
    z.appendChild(actions);
    (raison || lieu || actions.lastChild).focus();
  }

  // Une opération part vers la base. Rien n'est affiché comme fait avant sa
  // réponse ; une coupure garde l'opération, avec sa clé, pour « Réessayer ».
  function envoyer(reference, op, o) {
    o = o || {};
    if (o.lieu === undefined) o.lieu = champLieu.value.trim() || null;
    if (!o.cle) o.cle = nouvelleCle();
    occupe = true;
    montrerEtat('envoi', 'Enregistrement : ' + op.libelle + '…', reference);
    return ServiceScanner.operer(reference, op.type, o).then(function (r) {
      occupe = false;
      aRejouer = null;
      if (r.etat === 'fait' || r.etat === 'deja') {
        var e = r.reponse.resultat && r.reponse.resultat.evenement;
        var detail = reference + (e && e.statut_precedent !== e.statut
          ? ' · ' + (LIBELLES[e.statut_precedent] || e.statut_precedent) + ' → ' + (LIBELLES[e.statut] || e.statut) : '') +
          (e && e.lieu ? ' · ' + e.lieu : '') + ' — Prêt pour le prochain scan.';
        montrerEtat(r.etat, r.etat === 'fait' ? '✓ ' + op.libelle.toUpperCase() : 'ℹ DÉJÀ FAIT : ' + op.libelle.toUpperCase(),
                    detail);
        (r.etat === 'fait' ? Son.succes : Son.info)();
        noter(reference, r.etat, (r.etat === 'fait' ? '✓ ' : 'ℹ déjà : ') + op.libelle);
        afficherFiche(r.fiche);
      } else {
        echec(reference, r, op);
        if (r.etat === 'reseau') {
          aRejouer = { reference: reference, op: op, o: o };
        } else if (r.etat === 'conflit' || r.etat === 'impossible') {
          // Le colis a bougé, ou l'opération ne va plus : on remontre son état réel
          ServiceScanner.chercher(reference).then(function (x) { if (x.fiche) afficherFiche(x.fiche); });
        }
      }
      pret();
      suivant();
    });
  }

  function echec(reference, r, op) {
    var boutons = [];
    if (r.etat === 'reseau') {
      boutons.push(bouton('Réessayer', 'gs-bouton--plein', function () {
        if (aRejouer) envoyer(aRejouer.reference, aRejouer.op, aRejouer.o);   // même clé : jamais deux fois
      }));
    }
    if (r.etat === 'introuvable') boutons.push(bouton('Rescanner', null, pret));
    montrerEtat(r.etat, null, [reference, phrase(r.erreur, r.analyse && r.analyse.detail)].filter(Boolean).join(' — '), boutons);
    Son.erreur();
    var libelle = ETATS[r.etat] ? ETATS[r.etat][1].replace(/^[^A-ZÀ-Ü]+/, '').toLowerCase() : 'erreur';
    noter(reference || '—', r.etat, '✕ ' + libelle + (op ? ' (' + op.libelle + ')' : ''));
  }

  /* ---- Un code lu ------------------------------------------------------------- */
  function traiter(texte) {
    annulerConfirmation();
    var analyse = SCAN.analyser(texte);
    if (!analyse.ok) {
      // Refusé ici : aucune requête pour un code illisible
      echec(analyse.brut.slice(0, 40), { etat: 'invalide', analyse: analyse });
      pret();
      return suivant();
    }
    var mode = choixMode.value;
    if (mode) {
      // Mode rapide : l'opération part directement ; la base valide tout
      var op = { type: mode, libelle: TYPES[mode].libelle, lieu_requis: TYPES[mode].lieu_requis };
      if (op.lieu_requis && !champLieu.value.trim()) {
        montrerEtat('impossible', null, 'Indiquez d’abord le lieu de ce poste (l’agence) : « ' + op.libelle +
                    ' » en a besoin.');
        Son.erreur();
        champLieu.focus();
        return suivant();
      }
      return envoyer(analyse.reference, op, { metadonnees: { mode: 'rapide' } });
    }
    occupe = true;
    montrerEtat('recherche', null, analyse.reference);
    return ServiceScanner.chercher(texte).then(function (r) {
      occupe = false;
      if (r.etat === 'trouve') {
        var c = r.fiche.colis;
        var nom = c.statut === 'livre' ? 'livre' : (c.statut === 'incident' ? 'incident' : 'trouve');
        montrerEtat(nom, null, c.numero + ' — ' + (LIBELLES[c.statut] || c.statut) + '. Choisissez l’opération.');
        (nom === 'trouve' ? Son.succes : Son.info)();
        noter(c.numero, nom, (nom === 'trouve' ? '✓ trouvé' : ETATS[nom][1].replace(/^[^A-ZÀ-Ü]+/, '').toLowerCase()));
        afficherFiche(r.fiche);
      } else {
        echec(r.analyse.reference, r);
        if (r.etat === 'introuvable') afficherFiche(null);
      }
      pret();
      suivant();
    });
  }

  // Les codes arrivés pendant une requête attendent leur tour, dans l'ordre
  function recevoir(texte) {
    if (!String(texte || '').trim()) return;
    file.push(texte);
    if (!occupe) suivant();
  }
  function suivant() {
    if (occupe || !file.length) return;
    traiter(file.shift());
  }

  /* ======================================================================
     EntreeScanner : les frappes → un code
     ======================================================================
     Un scanner en mode clavier tape son code puis Entrée (ou Tab). Rien ne
     part avant : pas de recherche à chaque lettre. Si un scanner est réglé
     sans touche de fin, son code part après un court silence — seulement si
     les frappes avaient le rythme d'un scanner. À la main, on tape puis
     Entrée ou « Rechercher » : même chemin, même logique.
     ====================================================================== */
  var lecteur = new SCAN.Lecteur();
  var minuteurSilence = null;

  function envoyerChamp() {
    clearTimeout(minuteurSilence);
    var v = champ.value;
    champ.value = '';
    lecteur.oublier();
    recevoir(v);
  }

  champ.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' || e.key === 'Tab') {
      if (champ.value.trim()) { e.preventDefault(); envoyerChamp(); }
      return;
    }
    if (e.key && e.key.length === 1) lecteur.noter(e.timeStamp || Date.now());
  });
  champ.addEventListener('input', function () {
    clearTimeout(minuteurSilence);
    if (!champ.value) { lecteur.oublier(); return; }
    minuteurSilence = setTimeout(function () {
      if (lecteur.estScanner() && champ.value.trim()) envoyerChamp();
    }, SCAN.SILENCE_MS);
  });
  $('[data-scan-form]', vue).addEventListener('submit', function (e) {
    e.preventDefault();
    envoyerChamp();
  });

  // Le poste ne perd jamais un scan : si le curseur s'est égaré (après un clic
  // sur la fiche), la première frappe le ramène dans le champ du scanner.
  document.addEventListener('keydown', function (e) {
    if (vue.hidden || e.ctrlKey || e.metaKey || e.altKey || !e.key || e.key.length !== 1 || e.key === ' ') return;
    var cible = e.target;
    if (cible === champ || /^(INPUT|TEXTAREA|SELECT)$/.test(cible.tagName) || cible.isContentEditable) return;
    if (document.querySelector('dialog[open]')) return;
    champ.focus();
  }, true);

  // L'onglet s'ouvre : le champ est prêt. Et admin.html#scanner ouvre le
  // tableau de bord directement sur le poste de scan.
  var onglet = document.querySelector('[data-onglet-vue="scanner"]');
  if (onglet) onglet.addEventListener('click', function () { setTimeout(pret, 0); });
  if (location.hash === '#scanner' && onglet) {
    var tableau = document.querySelector('[data-ecran="tableau"]');
    var ouvrir = function () {
      if (tableau && !tableau.hidden) { onglet.click(); return true; }
      return false;
    };
    if (!ouvrir() && tableau && window.MutationObserver) {
      var obs = new MutationObserver(function () { if (ouvrir()) obs.disconnect(); });
      obs.observe(tableau, { attributes: true, attributeFilter: ['hidden'] });
    }
  }

  // Pour les essais automatiques et la console : la même porte que le scanner
  window.GoshipScanner = { recevoir: recevoir, service: ServiceScanner };
})();
