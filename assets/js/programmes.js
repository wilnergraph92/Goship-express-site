/* ==========================================================================
   Goship Express — les programmes du tableau de bord (onglet « Programmes »)
   --------------------------------------------------------------------------
   Anniversaires, offre de bienvenue (GOship APP Welcome), parrainage (GOship
   Refer), GOPOINTS et les avantages qu'ils accordent. Cette page ne décide de
   rien : elle lit et règle ce que la base expose (outils/supabase-fidelite.sql,
   supabase-anniversaires.sql, supabase-campagnes.sql, par API.admin.programmes).
   Le solde d'un client, une date de naissance, un avantage accordé ou refusé :
   tout vient de la base, qui refuse d'elle-même ce que le rôle ne permet pas.
   Les cases cachées selon les permissions ne sont qu'un confort. Un programme
   incomplet ne se publie pas, et aucun montant n'est écrit ici : les valeurs
   commerciales sont celles que l'équipe saisit.
   ========================================================================== */
(function () {
  'use strict';

  var API = window.GoshipAPI;
  var vue = document.querySelector('[data-vue="programmes"]');
  if (!API || !vue || !API.admin || !API.admin.programmes) return;
  var P = API.admin.programmes, O = API.outils;

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function $$(sel, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(sel)); }
  function el(balise, classe, texte) {
    var n = document.createElement(balise);
    if (classe) n.className = classe;
    if (texte !== undefined && texte !== null) n.textContent = texte;
    return n;
  }

  /* ---- Les mots de la base, en français lisible --------------------------- */
  var STATUTS = {
    brouillon: 'Brouillon', programmee: 'Programmée', active: 'Active', suspendue: 'Suspendue', terminee: 'Terminée',
    inscrit: 'Inscrit', qualifie: 'Qualifié', recompense: 'Récompensé', refuse: 'Refusé', annule: 'Annulé', suspect: 'À examiner',
    en_attente: 'En attente', obtenue: 'Obtenu', utilisee: 'Utilisé', annulee: 'Annulé', expiree: 'Expiré',
    a_venir: 'À venir', prepare: 'Préparé', ignore: 'Ignoré', erreur: 'Erreur', valide: 'Valide',
    attente: 'En attente', envoi: 'En cours', envoye: 'Envoyé', livre: 'Livré', echec: 'Échec'
  };
  var TONS = { active: 'ok', obtenue: 'ok', utilisee: 'ok', recompense: 'ok', valide: 'ok', livre: 'ok', envoye: 'ok', prepare: 'ok',
               suspect: 'alerte', erreur: 'alerte', echec: 'alerte', suspendue: 'alerte', en_attente: 'attente', attente: 'attente',
               qualifie: 'attente', programmee: 'attente', refuse: 'neutre', annule: 'neutre', annulee: 'neutre', expiree: 'neutre',
               terminee: 'neutre', brouillon: 'neutre', ignore: 'neutre' };
  var TYPES_AVANTAGE = [['credit_expedition', 'Crédit d\'expédition'], ['reduction_frais', 'Réduction sur les frais de service'],
                        ['bonus_fixe', 'Bonus fixe'], ['gopoints', 'GOPOINTS'], ['avantage_colis', 'Avantage sur un prochain colis']];
  var TYPES_OFFRE = TYPES_AVANTAGE.filter(function (t) { return t[0] !== 'gopoints'; });
  var OPERATIONS = [['colis_recu', 'Colis reçu à l\'entrepôt'], ['facture_payee', 'Facture payée']];
  var PROGRAMMES = { welcome: 'Bienvenue', refer_parrain: 'Parrain', refer_filleul: 'Filleul', anniversaire: 'Anniversaire',
                     points: 'GOPOINTS', manuel: 'À la main' };
  var MOUVEMENTS = { gain: 'Gain', utilisation: 'Utilisation', expiration: 'Expiration', correction: 'Correction', annulation: 'Annulation' };
  var MOTIFS = { MEME_TELEPHONE: 'Même téléphone que le parrain', MEME_ADRESSE: 'Même adresse que le parrain',
                 MEME_IDENTIFIANT_EMAIL: 'Même identifiant e-mail que le parrain', RAFALE_INSCRIPTIONS: 'Beaucoup d\'inscriptions en 24 heures',
                 PLAFOND_PARRAIN: 'Plafond par parrain atteint', PLAFOND_GLOBAL: 'Plafond global atteint',
                 OPERATION_ANNULEE: 'Opération annulée', DESACTIVE_PAR_LE_CLIENT: 'Désactivé par le client',
                 POINTS_INDISPONIBLES: 'GOPOINTS éteint' };
  var LANGUES = [['fr', 'Français'], ['en', 'Anglais'], ['es', 'Espagnol'], ['ht', 'Créole']];
  var MODELES = [['birthday', 'Anniversaire', 'Variable permise : {{prenom}}.'],
                 ['birthday_avantage', 'Anniversaire avec avantage', 'Variables permises : {{prenom}}, {{avantage}}.'],
                 ['birthday_upcoming', 'Rappel au client', 'Variables permises : {{prenom}}, {{jours}}.'],
                 ['birthday_reminder', 'Rappel à l\'équipe', 'Variables permises : {{nombre}}, {{jours}}.']];

  function libelle(liste, cle) {
    for (var i = 0; i < liste.length; i++) if (liste[i][0] === cle) return liste[i][1];
    return cle == null ? '' : String(cle);
  }
  function statutTexte(s) { return STATUTS[s] || String(s || ''); }
  function motifTexte(m) {
    return String(m || '').split(/\s+/).filter(Boolean).map(function (c) { return MOTIFS[c] || c; }).join(' · ');
  }
  function valeurTexte(type, valeur) {
    if (valeur == null || valeur === '') return '—';
    return type === 'gopoints' ? O.nombre(valeur) + ' GOPOINTS' : O.argent(valeur);
  }
  function dateTexte(iso) { return iso ? O.date(iso) : '—'; }
  function jourAvecDecalage(n) {
    var t = new Date(Date.now() + n * 864e5);
    return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Santo_Domingo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(t);
  }

  /* ---- Les droits (confort d'affichage : la base refuse d'elle-même) ------ */
  var droits = [];
  function peut(p) { return droits.indexOf(p) >= 0; }

  /* ---- Messages ----------------------------------------------------------- */
  var zoneMessage = $('[data-prog-message]', vue);
  var minuteur = null;
  function annoncer(texte, erreur) {
    zoneMessage.textContent = texte;
    zoneMessage.hidden = !texte;
    zoneMessage.className = 'gs-apercu__message' + (erreur ? ' gs-prog__erreur' : ' gs-prog__succes');
    zoneMessage.setAttribute('role', erreur ? 'alert' : 'status');
    clearTimeout(minuteur);
    if (texte && !erreur) minuteur = setTimeout(function () { zoneMessage.hidden = true; }, 4500);
    if (texte && erreur) zoneMessage.scrollIntoView({ block: 'nearest' });
  }
  // La phrase de la base pour une erreur métier ; sinon un titre simple, jamais le message technique
  function erreurTexte(err) {
    if (!err) return 'Une erreur est survenue. Réessayez.';
    if (err.code === 'absent') return 'La base n\'est pas à jour : lancez les fichiers SQL des programmes (outils/migrations.txt).';
    if (err.code === 'non-autorise') return 'Accès refusé : votre rôle ne permet pas cette action.';
    if (err.code === 'reseau') return 'Connexion impossible. Vérifiez votre réseau et réessayez.';
    if (err.metier && err.detail) return err.detail;
    return 'Une erreur est survenue. Réessayez.';
  }
  function echouer(err) { annoncer(erreurTexte(err), true); }

  /* ---- Composants --------------------------------------------------------- */
  var numero = 0;
  // def : { nom, libelle, type (texte, nombre, date, heure, case, select, zone), options, aide, desactive }
  function champ(def, valeur) {
    numero += 1;
    var id = 'prog-' + numero;
    var racine = el('div', 'gs-champ gs-prog__champ' + (def.type === 'case' ? ' gs-prog__champ--case' : '') + (def.large ? ' gs-prog__champ--large' : ''));
    var saisie;
    if (def.type === 'case') {
      saisie = el('input'); saisie.type = 'checkbox'; saisie.checked = !!valeur;
      var l = el('label', null, def.libelle); l.setAttribute('for', id);
      racine.appendChild(saisie); racine.appendChild(l);
    } else {
      var etiq = el('label', null, def.libelle); etiq.setAttribute('for', id);
      racine.appendChild(etiq);
      if (def.type === 'select') {
        saisie = el('select');
        (def.options || []).forEach(function (o) { var op = el('option', null, o[1]); op.value = o[0]; saisie.appendChild(op); });
        saisie.value = valeur == null ? '' : valeur;
      } else if (def.type === 'zone') {
        saisie = el('textarea'); saisie.rows = def.lignes || 4; saisie.value = valeur == null ? '' : valeur;
      } else {
        saisie = el('input');
        saisie.type = def.type === 'nombre' ? 'text' : (def.type === 'date' ? 'date' : (def.type === 'heure' ? 'time' : 'text'));
        if (def.type === 'nombre') saisie.setAttribute('inputmode', 'decimal');
        saisie.value = valeur == null ? '' : valeur;
        saisie.autocomplete = 'off';
      }
      racine.appendChild(saisie);
    }
    saisie.id = id; saisie.name = def.nom;
    if (def.desactive) saisie.disabled = true;
    if (def.aide) {
      var a = el('p', 'gs-prog__aide', def.aide); a.id = id + '-aide';
      saisie.setAttribute('aria-describedby', a.id); racine.appendChild(a);
    }
    racine.saisie = saisie;
    return racine;
  }

  // Un formulaire de champs : lire() rend un objet (nombre vide → null, case → vrai/faux)
  function formulaire(defs, valeurs, lectureSeule) {
    var f = el('form', 'gs-prog__formulaire'); f.noValidate = true;
    var champs = defs.map(function (d) {
      var c = champ(lectureSeule ? Object.assign({}, d, { desactive: true }) : d, valeurs ? valeurs[d.nom] : null);
      f.appendChild(c); return { def: d, c: c };
    });
    f.lire = function () {
      var out = {};
      champs.forEach(function (x) {
        var s = x.c.saisie, v;
        if (x.def.type === 'case') v = s.checked;
        else if (x.def.type === 'nombre') v = s.value.trim() === '' ? null : s.value.trim().replace(',', '.');
        else if (x.def.type === 'select') v = s.value === '' ? null : s.value;
        else if (x.def.type === 'date') v = s.value === '' ? null : s.value;
        else v = s.value;
        out[x.def.nom] = v;
      });
      return out;
    };
    return f;
  }

  function bouton(texte, classe, action) {
    var b = el('button', 'gs-bouton gs-bouton--petit ' + (classe || 'gs-bouton--sombre'), texte);
    b.type = 'button';
    if (action) b.addEventListener('click', function () {
      b.disabled = true;
      Promise.resolve().then(action).catch(echouer).then(function () { b.disabled = false; });
    });
    return b;
  }

  function etiquette(statut) {
    return el('span', 'gs-prog__etat gs-prog__etat--' + (TONS[statut] || 'neutre'), statutTexte(statut));
  }

  function titre(parent, texte, intro) {
    var s = el('section', 'gs-prog__bloc');
    s.appendChild(el('h3', 'gs-prog__titre', texte));
    if (intro) s.appendChild(el('p', 'gs-rapports__intro', intro));
    parent.appendChild(s);
    return s;
  }

  function chiffres(parent, liste) {
    var g = el('div', 'gs-kpis gs-prog__kpis');
    liste.forEach(function (k) {
      var c = el('div', 'gs-kpi' + (k.ton ? ' gs-kpi--' + k.ton : ''));
      c.appendChild(el('span', 'gs-kpi__libelle', k.libelle));
      c.appendChild(el('strong', 'gs-kpi__valeur', k.valeur));
      if (k.sous) c.appendChild(el('span', 'gs-kpi__sous', k.sous));
      g.appendChild(c);
    });
    parent.appendChild(g);
  }

  // colonnes : [{ titre, rendu(ligne) → texte ou nœud, classe }]
  function tableau(parent, colonnes, lignes, vide) {
    if (!lignes.length) { parent.appendChild(el('p', 'gs-admin-vide', vide)); return null; }
    var cadre = el('div', 'gs-tableau-cadre gs-prog__cadre');
    var t = el('table', 'gs-tableau gs-prog__tableau'), tete = el('tr');
    colonnes.forEach(function (c) { var th = el('th', c.classe, c.titre); th.scope = 'col'; tete.appendChild(th); });
    t.appendChild(el('thead')).appendChild(tete);
    var corps = el('tbody');
    lignes.forEach(function (l) {
      var tr = el('tr');
      colonnes.forEach(function (c) {
        var td = el('td', c.classe), v = c.rendu(l);
        td.setAttribute('data-libelle', c.titre);
        if (v && v.nodeType) td.appendChild(v); else td.textContent = v == null ? '' : v;
        tr.appendChild(td);
      });
      corps.appendChild(tr);
    });
    t.appendChild(corps); cadre.appendChild(t); parent.appendChild(cadre);
    return t;
  }

  function actions(parent) { var d = el('div', 'gs-prog__actions'); parent.appendChild(d); return d; }

  // Demander un motif (obligatoire à la base) : une fenêtre, jamais un prompt du navigateur
  var dlgMotif = $('[data-dialogue="prog-motif"]');
  function demanderMotif(titreTexte, aide, confirmer) {
    return new Promise(function (ok) {
      if (!dlgMotif || !dlgMotif.showModal) { ok(null); return; }
      $('[data-prog-motif-titre]', dlgMotif).textContent = titreTexte;
      $('[data-prog-motif-aide]', dlgMotif).textContent = aide || '';
      var saisie = $('[data-prog-motif-saisie]', dlgMotif), bouton1 = $('[data-prog-motif-confirmer]', dlgMotif);
      var erreur = $('[data-prog-motif-erreur]', dlgMotif);
      bouton1.textContent = confirmer;
      saisie.value = ''; erreur.hidden = true;
      function fin(v) {
        bouton1.removeEventListener('click', valider);
        $('[data-prog-motif-annuler]', dlgMotif).removeEventListener('click', annuler);
        dlgMotif.removeEventListener('cancel', annuler);
        if (dlgMotif.open) dlgMotif.close();
        ok(v);
      }
      function valider() {
        if (saisie.value.trim().length < 3) { erreur.textContent = 'Écrivez un motif d\'au moins 3 signes.'; erreur.hidden = false; saisie.focus(); return; }
        fin(saisie.value.trim());
      }
      function annuler(e) { if (e && e.preventDefault) e.preventDefault(); fin(null); }
      bouton1.addEventListener('click', valider);
      $('[data-prog-motif-annuler]', dlgMotif).addEventListener('click', annuler);
      dlgMotif.addEventListener('cancel', annuler);
      dlgMotif.showModal();
      saisie.focus();
    });
  }

  // Un client à partir de son code (GSE-1234) : pour corriger un solde ou accorder un avantage
  function clientParCode(texte) {
    var code = API.normaliserCode(texte);
    if (!code) return Promise.reject({ metier: true, code: 'CLIENT_NOT_FOUND', detail: 'Écrivez le code du client, par exemple GSE-1234.' });
    return API.admin.clients({ recherche: code, parPage: 5 }).then(function (r) {
      var c = (r.lignes || []).filter(function (x) { return x.code === code; })[0];
      if (!c) throw { metier: true, code: 'CLIENT_NOT_FOUND', detail: 'Aucun client ne porte le code ' + code + '.' };
      return c;
    });
  }

  function pagination(parent, total, page, parPage, aller) {
    if (total <= parPage) return;
    var barre = el('div', 'gs-pagination gs-prog__pagination');
    var pages = Math.ceil(total / parPage);
    var premier = page * parPage + 1, dernier = Math.min(total, (page + 1) * parPage);
    var prec = bouton('Précédent', 'gs-bouton--contour', function () { aller(page - 1); });
    prec.disabled = page <= 0;
    var suiv = bouton('Suivant', 'gs-bouton--contour', function () { aller(page + 1); });
    suiv.disabled = page >= pages - 1;
    barre.appendChild(prec);
    barre.appendChild(el('span', 'gs-pagination__texte', premier + '–' + dernier + ' sur ' + total));
    barre.appendChild(suiv);
    parent.appendChild(barre);
  }

  /* ======================================================================
     Onglets internes
     ====================================================================== */
  // version : chaque affichage a la sienne, et seul le dernier écrit (un clic répété ne efface pas un formulaire ouvert)
  var etat = { onglet: null, version: 0 };
  var onglets = $$('[data-prog-onglet]', vue);

  function visibles() { return onglets.filter(function (b) { return !b.hasAttribute('data-interdit'); }); }

  function choisir(nom) {
    var b = $('[data-prog-onglet="' + nom + '"]', vue);
    if (!b || b.hasAttribute('data-interdit')) { b = visibles()[0]; if (!b) return; nom = b.getAttribute('data-prog-onglet'); }
    etat.onglet = nom;
    onglets.forEach(function (o) {
      var actif = o === b;
      o.setAttribute('aria-selected', String(actif)); o.tabIndex = actif ? 0 : -1;
    });
    $$('[data-prog-panneau]', vue).forEach(function (p) { p.hidden = p.getAttribute('data-prog-panneau') !== nom; });
    annoncer('', false);
    ({ anniversaires: afficherAnniversaires, bienvenue: afficherBienvenue, parrainage: afficherParrainage,
       points: afficherPoints, avantages: afficherAvantages })[nom]();
  }
  onglets.forEach(function (b) {
    b.addEventListener('click', function () { choisir(b.getAttribute('data-prog-onglet')); });
    b.addEventListener('keydown', function (e) {
      var sens = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!sens) return;
      e.preventDefault();
      var l = visibles(), a = l[(l.indexOf(b) + sens + l.length) % l.length];
      a.focus(); choisir(a.getAttribute('data-prog-onglet'));
    });
  });

  function ouvrir() {
    API.permissions().then(function (p) {
      droits = (p && p.permissions) || [];
      onglets.forEach(function (b) {
        var requis = (b.getAttribute('data-permission') || 'programs.view').split(/\s+/);
        if (requis.every(peut)) b.removeAttribute('data-interdit'); else b.setAttribute('data-interdit', '');
      });
      choisir(etat.onglet || 'bienvenue');
    }).catch(echouer);
  }
  window.addEventListener('goship:vue', function (e) { if (e.detail === 'programmes') ouvrir(); });

  function panneau(nom) { var p = $('[data-prog-panneau="' + nom + '"]', vue); p.textContent = ''; return p; }
  function chargement(p) { p.appendChild(el('p', 'gs-admin-vide', 'Chargement…')); }

  /* ======================================================================
     Anniversaires
     ====================================================================== */
  var periodeAnniv = { debut: '', fin: '', statut: '', page: 0 };

  function afficherAnniversaires() {
    var zone = $('[data-prog-panneau="anniversaires"]', vue);
    var version = ++etat.version;
    if (!periodeAnniv.debut) { periodeAnniv.debut = jourAvecDecalage(0); periodeAnniv.fin = jourAvecDecalage(30); }
    var gerer = peut('birthdays.manage');
    Promise.all([P.anniversaireReglages(), P.anniversaires({ debut: periodeAnniv.debut, fin: periodeAnniv.fin, page: periodeAnniv.page }),
                 P.anniversairesMessages({ statut: periodeAnniv.statut }), P.anniversairesErreurs(), P.anniversaireModeles()])
      .then(function (r) {
        if (version !== etat.version || etat.onglet !== 'anniversaires') return;
        zone.textContent = '';
        dessinerAnniversaires(zone, r[0], r[1], r[2], r[3], r[4], gerer);
      }).catch(echouer);
  }

  function dessinerAnniversaires(zone, reg, liste, messages, erreurs, modeles, gerer) {
    var s = reg.reglages, c = reg.chiffres;
    var tete = titre(zone, 'Anniversaires',
      'Un message par client et par année, le jour de son anniversaire, envoyé par le système de notifications existant. Le programme est éteint tant que vous ne l\'allumez pas, et rien ne part sans un canal réellement configuré. La date de naissance n\'est visible que par les comptes autorisés.');
    tete.appendChild(el('p', 'gs-prog__statut', 'État :')).appendChild(etiquetteProgramme(s.actif));
    chiffres(tete, [
      { libelle: 'Aujourd\'hui', valeur: O.nombre(c.aujourdhui) }, { libelle: 'Dans 7 jours', valeur: O.nombre(c.sept_jours) },
      { libelle: 'Clients avec date', valeur: O.nombre(c.clients_avec_date) },
      { libelle: 'Clients sans date', valeur: O.nombre(c.clients_sans_date), sous: 'Une étape les invite à la compléter.', ton: c.clients_sans_date ? 'attention' : '' },
      { libelle: 'Messages cette année', valeur: O.nombre(c.messages_annee) },
      { libelle: 'Erreurs', valeur: O.nombre(c.erreurs), ton: c.erreurs ? 'critique' : '' }
    ]);

    // Les réglages
    var rg = titre(zone, 'Réglages', gerer ? '' : 'Lecture seule : seuls les administrateurs règlent le programme.');
    // L'état des canaux : « configuré » veut dire que la base a de quoi envoyer, jamais qu'un message est parti
    var canaux = el('ul', 'gs-prog__canaux');
    [['Application', 'toujours actif'], ['E-mail', reg.canaux_configures.email ? 'configuré' : 'non configuré'],
     ['Téléphone (push)', reg.canaux_configures.push ? 'configuré' : 'non configuré'],
     ['WhatsApp', 'pas encore disponible pour les anniversaires']].forEach(function (c) {
      var li = el('li'); li.appendChild(el('strong', null, c[0])); li.appendChild(el('span', 'gs-prog__canal-etat', c[1])); canaux.appendChild(li);
    });
    rg.appendChild(canaux);
    var valeurs = Object.assign({}, s, { canal_push: s.canaux.indexOf('push') >= 0, canal_email: s.canaux.indexOf('email') >= 0 });
    var f = formulaire([
      { nom: 'actif', type: 'case', libelle: 'Envoyer les messages d\'anniversaire' },
      { nom: 'fuseau', type: 'texte', libelle: 'Fuseau horaire de l\'entreprise', aide: 'Par exemple America/Santo_Domingo.' },
      { nom: 'heure_envoi', type: 'heure', libelle: 'Heure d\'envoi' },
      { nom: 'regle_29_fevrier', type: 'select', libelle: 'Né le 29 février : fêté', options: [['fev28', 'Le 28 février'], ['mars1', 'Le 1er mars']] },
      { nom: 'rattrapage_jours', type: 'nombre', libelle: 'Rattrapage si un envoi est manqué (jours)', aide: '0 à 7.' },
      { nom: 'canal_push', type: 'case', libelle: 'Notification du téléphone (push)' },
      { nom: 'canal_email', type: 'case', libelle: 'E-mail' },
      { nom: 'rappel_admin_jours', type: 'nombre', libelle: 'Rappel à l\'équipe, jours avant', aide: '0 pour aucun rappel.' },
      { nom: 'rappel_client_actif', type: 'case', libelle: 'Rappeler au client son anniversaire à venir (désactivé par défaut)' },
      { nom: 'rappel_client_jours', type: 'nombre', libelle: 'Rappel au client, jours avant' },
      { nom: 'avantage_actif', type: 'case', libelle: 'Offrir un avantage d\'anniversaire (désactivé par défaut)' },
      { nom: 'avantage_type', type: 'select', libelle: 'Type d\'avantage', options: [['aucun', 'Aucun']].concat(TYPES_AVANTAGE) },
      { nom: 'avantage_valeur', type: 'nombre', libelle: 'Valeur de l\'avantage', aide: 'Aucune promesse n\'est faite au client tant que l\'avantage n\'est pas complet et allumé.' },
      { nom: 'avantage_libelle', type: 'texte', libelle: 'Texte de l\'avantage', aide: 'Par exemple « 5 $ de crédit d\'expédition ». Vous le choisissez.' }
    ], valeurs, !gerer);
    rg.appendChild(f);
    if (gerer) {
      actions(rg).appendChild(bouton('Enregistrer les réglages', 'gs-bouton--sombre', function () {
        var v = f.lire(), canauxChoisis = [];
        if (v.canal_push) canauxChoisis.push('push');
        if (v.canal_email) canauxChoisis.push('email');
        return P.anniversaireReglagesModifier({
          actif: v.actif, fuseau: v.fuseau, heure_envoi: v.heure_envoi, regle_29_fevrier: v.regle_29_fevrier, rattrapage_jours: v.rattrapage_jours,
          canaux: canauxChoisis, rappel_admin_jours: v.rappel_admin_jours, rappel_client_actif: v.rappel_client_actif,
          rappel_client_jours: v.rappel_client_jours, avantage_actif: v.avantage_actif, avantage_type: v.avantage_type,
          avantage_valeur: v.avantage_valeur, avantage_libelle: v.avantage_libelle
        }).then(function () { annoncer('Réglages enregistrés.'); afficherAnniversaires(); });
      }));
    }

    // Les anniversaires à venir
    var av = titre(zone, 'Anniversaires de la période');
    var barre = formulaire([{ nom: 'debut', type: 'date', libelle: 'Du' }, { nom: 'fin', type: 'date', libelle: 'Au' }], { debut: periodeAnniv.debut, fin: periodeAnniv.fin });
    barre.classList.add('gs-prog__filtres');
    av.appendChild(barre);
    actions(av).appendChild(bouton('Afficher', 'gs-bouton--contour', function () {
      var v = barre.lire(); periodeAnniv.debut = v.debut || jourAvecDecalage(0); periodeAnniv.fin = v.fin || periodeAnniv.debut; periodeAnniv.page = 0;
      afficherAnniversaires();
    }));
    tableau(av, [
      { titre: 'Date', rendu: function (l) { return dateTexte(l.date); } },
      { titre: 'Client', rendu: function (l) { return l.nom + ' (' + l.code + ')'; } },
      { titre: 'Âge', rendu: function (l) { return l.age; }, classe: 'gs-droite' },
      { titre: 'Message', rendu: function (l) { return etiquette(l.statut); } },
      { titre: 'Envois', rendu: function (l) { return l.envois.length ? l.envois.map(function (e) { return libelle([['push', 'Téléphone'], ['email', 'E-mail'], ['app', 'Application']], e.canal) + ' : ' + statutTexte(e.statut); }).join(' · ') : '—'; } }
    ], liste.elements, 'Aucun anniversaire sur cette période.');
    pagination(av, liste.total, periodeAnniv.page, 50, function (p) { periodeAnniv.page = p; afficherAnniversaires(); });

    // Les messages préparés
    var ms = titre(zone, 'Messages préparés', 'Chaque message est suivi canal par canal. Un envoi n\'est « envoyé » ou « livré » que sur réponse du fournisseur.');
    var filtre = formulaire([{ nom: 'statut', type: 'select', libelle: 'Statut', options: [['', 'Tous'], ['prepare', 'Préparés'], ['ignore', 'Ignorés'], ['erreur', 'En erreur']] }], { statut: periodeAnniv.statut });
    filtre.classList.add('gs-prog__filtres');
    $('select', filtre).addEventListener('change', function () { periodeAnniv.statut = filtre.lire().statut || ''; afficherAnniversaires(); });
    ms.appendChild(filtre);
    tableau(ms, [
      { titre: 'Date', rendu: function (l) { return dateTexte(l.date); } },
      { titre: 'Client', rendu: function (l) { return l.nom + ' (' + l.code + ')'; } },
      { titre: 'Statut', rendu: function (l) { return etiquette(l.statut); } },
      { titre: 'Détail', rendu: function (l) { return motifTexte(l.motif) || '—'; } },
      { titre: 'Envois', rendu: function (l) { return l.envois.length ? l.envois.map(function (e) { return libelle([['push', 'Téléphone'], ['email', 'E-mail'], ['app', 'Application']], e.canal) + ' : ' + statutTexte(e.statut) + (e.code_erreur ? ' (' + e.code_erreur + ')' : ''); }).join(' · ') : '—'; } }
    ], messages.elements, 'Aucun message pour ce filtre.');

    // Les erreurs
    var er = titre(zone, 'Erreurs');
    tableau(er, [
      { titre: 'Date', rendu: function (l) { return dateTexte(l.date); } },
      { titre: 'Client', rendu: function (l) { return l.nom + ' (' + l.code + ')'; } },
      { titre: 'Origine', rendu: function (l) { return l.origine === 'preparation' ? 'Préparation' : 'Envoi'; } },
      { titre: 'Détail', rendu: function (l) { return (l.canal ? libelle([['push', 'Téléphone'], ['email', 'E-mail']], l.canal) + ' : ' : '') + (motifTexte(l.code_erreur) || statutTexte(l.statut)); } }
    ], erreurs.elements, 'Aucune erreur.');

    // Les modèles
    var md = titre(zone, 'Modèles de messages', 'Quatre langues ; la langue du client décide de celle du message. Le prénom du client remplace {{prenom}}. Le modèle d\'origine se restaure.');
    MODELES.forEach(function (t) {
      var groupe = el('div', 'gs-prog__groupe');
      groupe.appendChild(el('h4', 'gs-prog__sous-titre', t[1]));
      groupe.appendChild(el('p', 'gs-prog__aide', t[2]));
      LANGUES.forEach(function (l) {
        var m = modeles.filter(function (x) { return x.type === t[0] && x.langue === l[0]; })[0];
        if (!m) return;
        var d = el('details', 'gs-prog__modele'), r = el('summary', null, l[1]);
        if (m.modifie) r.appendChild(el('span', 'gs-prog__etat gs-prog__etat--attente', 'Modifié'));
        d.appendChild(r);
        var form = formulaire([{ nom: 'titre', type: 'texte', libelle: 'Titre' }, { nom: 'message', type: 'zone', libelle: 'Message', lignes: 7, large: true }], m, !gerer);
        d.appendChild(form);
        if (gerer) {
          var a = actions(d);
          a.appendChild(bouton('Enregistrer', 'gs-bouton--sombre', function () {
            var v = form.lire();
            return P.anniversaireModele(t[0], l[0], v.titre, v.message).then(function () { annoncer('Modèle enregistré.'); afficherAnniversaires(); });
          }));
          a.appendChild(bouton('Restaurer le modèle d\'origine', 'gs-bouton--contour', function () {
            return P.anniversaireModeleRestaurer(t[0], l[0]).then(function () { annoncer('Modèle restauré.'); afficherAnniversaires(); });
          }));
        }
        groupe.appendChild(d);
      });
      md.appendChild(groupe);
    });
  }

  function etiquetteProgramme(actif) {
    return el('span', 'gs-prog__etat gs-prog__etat--' + (actif ? 'ok' : 'neutre'), actif ? 'Allumé' : 'Éteint');
  }

  /* ======================================================================
     GOship APP Welcome
     ====================================================================== */
  var CHAMPS_CAMPAGNE = [
    { nom: 'nom', type: 'texte', libelle: 'Nom de la campagne' },
    { nom: 'description', type: 'zone', libelle: 'Description', lignes: 2, large: true },
    { nom: 'debut', type: 'date', libelle: 'Début' }, { nom: 'fin', type: 'date', libelle: 'Fin' },
    { nom: 'type_recompense', type: 'select', libelle: 'Type de récompense', options: [['', 'À choisir']].concat(TYPES_AVANTAGE) },
    { nom: 'valeur_recompense', type: 'nombre', libelle: 'Valeur', aide: 'En dollars, ou en points pour des GOPOINTS. Aucune valeur n\'est proposée : c\'est à vous de la fixer.' },
    { nom: 'operation', type: 'select', libelle: 'Opération qualifiante', options: [['', 'À choisir']].concat(OPERATIONS), aide: 'Le téléchargement de l\'application n\'est pas une opération vérifiable.' },
    { nom: 'budget_max', type: 'nombre', libelle: 'Budget : nombre maximal d\'avantages', aide: 'Vide : sans limite.' },
    { nom: 'delai_validation_jours', type: 'nombre', libelle: 'Délai de validation (jours)', aide: '0 : accordé aussitôt. Sinon l\'avantage attend, et s\'annule si l\'opération est annulée.' },
    { nom: 'cumul_parrainage', type: 'case', libelle: 'Cumulable avec le parrainage' },
    { nom: 'conditions', type: 'zone', libelle: 'Conditions générales (visibles par le client)', lignes: 4, large: true }
  ];

  function afficherBienvenue() {
    var zone = $('[data-prog-panneau="bienvenue"]', vue);
    var version = ++etat.version;
    P.bienvenueListe().then(function (r) {
      if (version !== etat.version || etat.onglet !== 'bienvenue') return;
      zone.textContent = '';
      dessinerBienvenue(zone, r, peut('programs.manage'));
    }).catch(echouer);
  }

  function dessinerBienvenue(zone, r, gerer) {
    var tete = titre(zone, 'Offre de bienvenue — GOship APP Welcome',
      'Un avantage, une seule fois par client, après sa première opération qualifiante vue par la base. Une opération annulée ou échouée ne donne rien. Une campagne incomplète ne se publie pas.');
    var ouvertes = r.campagnes.filter(function (c) { return c.statut === 'active'; }).length;
    chiffres(tete, [{ libelle: 'Campagnes actives', valeur: O.nombre(ouvertes) }, { libelle: 'Campagnes', valeur: O.nombre(r.campagnes.length) },
                    { libelle: 'Erreurs des programmes', valeur: O.nombre(r.erreurs), ton: r.erreurs ? 'critique' : '' }]);
    var zoneForm = el('div', 'gs-prog__edition');
    function modifier(c, copie) {
      zoneForm.textContent = '';
      var h = el('h4', 'gs-prog__sous-titre', c && !copie ? 'Modifier la campagne' : 'Nouvelle campagne');
      zoneForm.appendChild(h);
      var valeurs = c ? Object.assign({}, c, copie ? { nom: c.nom + ' (copie)' } : {}) : { cumul_parrainage: true, delai_validation_jours: 0 };
      var f = formulaire(CHAMPS_CAMPAGNE, valeurs);
      zoneForm.appendChild(f);
      var a = actions(zoneForm);
      a.appendChild(bouton('Enregistrer en brouillon', 'gs-bouton--sombre', function () {
        return P.bienvenueEnregistrer(c && !copie ? c.id : null, f.lire()).then(function () { annoncer('Campagne enregistrée.'); afficherBienvenue(); });
      }));
      a.appendChild(bouton('Annuler', 'gs-bouton--contour', function () { zoneForm.textContent = ''; }));
      zoneForm.scrollIntoView({ block: 'nearest' });
    }
    if (gerer) actions(tete).appendChild(bouton('Nouvelle campagne', 'gs-bouton--sombre', function () { modifier(null); }));
    zone.appendChild(zoneForm);

    var liste = titre(zone, 'Campagnes');
    if (!r.campagnes.length) liste.appendChild(el('p', 'gs-admin-vide', 'Aucune campagne. Créez-en une : elle reste en brouillon tant qu\'elle est incomplète.'));
    r.campagnes.forEach(function (c) {
      var carte = el('article', 'gs-prog__carte');
      var t = el('div', 'gs-prog__carte-tete');
      t.appendChild(el('h4', 'gs-prog__sous-titre', c.nom || 'Sans nom'));
      t.appendChild(etiquette(c.statut));
      carte.appendChild(t);
      if (c.description) carte.appendChild(el('p', 'gs-prog__aide', c.description));
      var dl = el('dl', 'gs-prog__dl');
      [['Période', dateTexte(c.debut) + ' → ' + dateTexte(c.fin)], ['Récompense', c.type_recompense ? libelle(TYPES_AVANTAGE, c.type_recompense) + ' : ' + valeurTexte(c.type_recompense, c.valeur_recompense) : '—'],
       ['Opération qualifiante', libelle(OPERATIONS, c.operation) || '—'], ['Budget', c.budget_max == null ? 'Sans limite' : O.nombre(c.budget_max) + ' avantages'],
       ['Délai de validation', c.delai_validation_jours ? c.delai_validation_jours + ' jours' : 'Aucun'], ['Clients admissibles', O.nombre(c.clients_admissibles)],
       ['Avantages', c.recompenses ? Object.keys(c.recompenses).map(function (k) { return statutTexte(k) + ' : ' + c.recompenses[k]; }).join(' · ') : 'Aucun']
      ].forEach(function (x) { dl.appendChild(el('dt', null, x[0])); dl.appendChild(el('dd', null, x[1])); });
      carte.appendChild(dl);
      if (c.manques && c.manques.length && (c.statut === 'brouillon' || c.statut === 'suspendue')) {
        var mq = el('p', 'gs-prog__manque'); mq.appendChild(el('strong', null, 'Pour publier, il manque :')); mq.appendChild(el('span', null, c.manques.join(', ') + '.')); carte.appendChild(mq);
      }
      if (gerer) {
        var a = actions(carte);
        if (c.statut === 'brouillon' || c.statut === 'suspendue') {
          a.appendChild(bouton('Modifier', 'gs-bouton--contour', function () { modifier(c); }));
          a.appendChild(bouton(c.statut === 'brouillon' ? 'Publier' : 'Reprendre', 'gs-bouton--sombre', function () {
            var appel = c.statut === 'brouillon' ? P.bienvenuePublier(c.id) : P.bienvenueStatut(c.id, 'reprendre');
            return appel.then(function () { annoncer('Campagne publiée.'); afficherBienvenue(); });
          }));
        }
        if (c.statut === 'active' || c.statut === 'programmee') {
          a.appendChild(bouton('Suspendre', 'gs-bouton--contour', function () {
            return P.bienvenueStatut(c.id, 'suspendre').then(function () { annoncer('Campagne suspendue.'); afficherBienvenue(); });
          }));
        }
        if (c.statut !== 'terminee') {
          a.appendChild(bouton('Terminer', 'gs-bouton--danger', function () {
            return P.bienvenueStatut(c.id, 'terminer').then(function () { annoncer('Campagne terminée.'); afficherBienvenue(); });
          }));
        }
        a.appendChild(bouton('Dupliquer', 'gs-bouton--contour', function () { modifier(c, true); }));
      }
      liste.appendChild(carte);
    });
  }

  /* ======================================================================
     GOship Refer
     ====================================================================== */
  var CHAMPS_PARRAINAGE = [
    { nom: 'nom', type: 'texte', libelle: 'Nom du programme' },
    { nom: 'debut', type: 'date', libelle: 'Début' }, { nom: 'fin', type: 'date', libelle: 'Fin' },
    { nom: 'parrain_type', type: 'select', libelle: 'Avantage du parrain : type', options: [['', 'À choisir']].concat(TYPES_AVANTAGE) },
    { nom: 'parrain_valeur', type: 'nombre', libelle: 'Avantage du parrain : valeur' },
    { nom: 'filleul_type', type: 'select', libelle: 'Avantage du filleul : type', options: [['', 'À choisir']].concat(TYPES_AVANTAGE) },
    { nom: 'filleul_valeur', type: 'nombre', libelle: 'Avantage du filleul : valeur' },
    { nom: 'operation', type: 'select', libelle: 'Transaction qualifiante', options: [['', 'À choisir']].concat(OPERATIONS) },
    { nom: 'delai_validation_jours', type: 'nombre', libelle: 'Délai de validation (jours)', aide: '0 : accordé aussitôt. Sinon les deux avantages attendent, et s\'annulent si l\'opération est annulée.' },
    { nom: 'max_par_parrain', type: 'nombre', libelle: 'Maximum de parrainages récompensés par parrain', aide: 'Vide : sans limite.' },
    { nom: 'max_recompenses', type: 'nombre', libelle: 'Maximum de parrainages récompensés au total', aide: 'Vide : sans limite.' },
    { nom: 'expiration_jours', type: 'nombre', libelle: 'Durée de vie d\'un avantage obtenu (jours)', aide: 'Vide : il n\'expire pas.' },
    { nom: 'cumul_bienvenue', type: 'case', libelle: 'Cumulable avec l\'offre de bienvenue' },
    { nom: 'conditions', type: 'zone', libelle: 'Conditions générales (visibles par le client)', lignes: 4, large: true },
    { nom: 'annulation', type: 'zone', libelle: 'Conditions d\'annulation', lignes: 3, large: true }
  ];
  var suivi = { statut: '', page: 0 };

  function afficherParrainage() {
    var zone = $('[data-prog-panneau="parrainage"]', vue);
    var version = ++etat.version;
    Promise.all([P.parrainageConfig(), P.parrainageApercu(), P.parrainages({ statut: suivi.statut, page: suivi.page })]).then(function (r) {
      if (version !== etat.version || etat.onglet !== 'parrainage') return;
      zone.textContent = '';
      dessinerParrainage(zone, r[0], r[1], r[2], peut('programs.manage'));
    }).catch(echouer);
  }

  function dessinerParrainage(zone, conf, apercu, liste, gerer) {
    var tete = titre(zone, 'Parrainage — GOship Refer',
      'Chaque client a un code unique et un lien à partager. Les deux avantages sont accordés après la première transaction qualifiante du filleul. Un cas suspect attend votre examen : rien n\'est bloqué ni accordé automatiquement.');
    var s = el('p', 'gs-prog__statut', 'État :'); s.appendChild(etiquette(conf.statut)); tete.appendChild(s);
    chiffres(tete, [
      { libelle: 'Parrains', valeur: O.nombre(apercu.parrains) }, { libelle: 'Filleuls inscrits', valeur: O.nombre(apercu.filleuls_inscrits) },
      { libelle: 'Transactions qualifiantes', valeur: O.nombre(apercu.transactions_qualifiantes) },
      { libelle: 'Avantages accordés', valeur: O.nombre(apercu.recompenses_accordees) },
      { libelle: 'Avantages en attente', valeur: O.nombre(apercu.recompenses_en_attente) },
      { libelle: 'En attente de première opération', valeur: O.nombre(apercu.en_attente_premiere_operation) },
      { libelle: 'Cas à examiner', valeur: O.nombre(apercu.suspects), ton: apercu.suspects ? 'attention' : '' }
    ]);

    var cf = titre(zone, 'Configuration', conf.statut === 'active' || conf.statut === 'terminee' ? 'Un parrainage actif ou terminé ne se modifie pas : suspendez-le d\'abord.' : '');
    var f = formulaire(CHAMPS_PARRAINAGE, conf, !gerer || conf.statut === 'active' || conf.statut === 'terminee');
    cf.appendChild(f);
    if (conf.manques && conf.manques.length && (conf.statut === 'brouillon' || conf.statut === 'suspendue')) {
      var mq = el('p', 'gs-prog__manque'); mq.appendChild(el('strong', null, 'Pour publier, il manque :')); mq.appendChild(el('span', null, conf.manques.join(', ') + '.')); cf.appendChild(mq);
    }
    if (gerer) {
      var a = actions(cf);
      if (conf.statut !== 'active' && conf.statut !== 'terminee') {
        a.appendChild(bouton('Enregistrer', 'gs-bouton--sombre', function () {
          return P.parrainageConfigModifier(f.lire()).then(function () { annoncer('Configuration enregistrée.'); afficherParrainage(); });
        }));
      }
      if (conf.statut === 'brouillon' || conf.statut === 'suspendue') {
        a.appendChild(bouton(conf.statut === 'brouillon' ? 'Publier' : 'Reprendre', 'gs-bouton--sombre', function () {
          return P.parrainageStatut(conf.statut === 'brouillon' ? 'publier' : 'reprendre').then(function () { annoncer('Parrainage publié.'); afficherParrainage(); });
        }));
      }
      if (conf.statut === 'active' || conf.statut === 'programmee') {
        a.appendChild(bouton('Suspendre', 'gs-bouton--contour', function () {
          return P.parrainageStatut('suspendre').then(function () { annoncer('Parrainage suspendu.'); afficherParrainage(); });
        }));
      }
      if (conf.statut !== 'terminee') {
        a.appendChild(bouton('Terminer', 'gs-bouton--danger', function () {
          return P.parrainageStatut('terminer').then(function () { annoncer('Parrainage terminé.'); afficherParrainage(); });
        }));
      }
    }

    var ls = titre(zone, 'Parrainages');
    var filtre = formulaire([{ nom: 'statut', type: 'select', libelle: 'Statut', options: [['', 'Tous'], ['suspect', 'À examiner'], ['inscrit', 'Inscrits'], ['qualifie', 'Qualifiés'], ['recompense', 'Récompensés'], ['refuse', 'Refusés'], ['annule', 'Annulés']] }], { statut: suivi.statut });
    filtre.classList.add('gs-prog__filtres');
    $('select', filtre).addEventListener('change', function () { suivi.statut = filtre.lire().statut || ''; suivi.page = 0; afficherParrainage(); });
    ls.appendChild(filtre);
    tableau(ls, [
      { titre: 'Date', rendu: function (l) { return dateTexte(l.date); } },
      { titre: 'Parrain', rendu: function (l) { return l.parrain_nom + ' (' + l.parrain_code + ')'; } },
      { titre: 'Filleul', rendu: function (l) { return l.filleul_nom + ' (' + l.filleul_code + ')'; } },
      { titre: 'Statut', rendu: function (l) { return etiquette(l.statut); } },
      { titre: 'Détail', rendu: function (l) { return motifTexte(l.motif) || '—'; } },
      { titre: 'Action', rendu: function (l) {
        if (l.statut !== 'suspect' || !gerer) return '—';
        var d = el('div', 'gs-prog__actions');
        function decision(libelleBouton, valeur, classe) {
          d.appendChild(bouton(libelleBouton, classe, function () {
            return demanderMotif(valeur === 'valider' ? 'Valider ce parrainage' : 'Refuser ce parrainage', 'Le motif est gardé au journal.', libelleBouton).then(function (m) {
              if (!m) return null;
              return P.parrainageExaminer(l.id, valeur, m).then(function () { annoncer('Décision enregistrée.'); afficherParrainage(); });
            });
          }));
        }
        decision('Valider', 'valider', 'gs-bouton--sombre'); decision('Refuser', 'refuser', 'gs-bouton--danger');
        return d;
      } }
    ], liste.elements, 'Aucun parrainage pour ce filtre.');
    pagination(ls, liste.total, suivi.page, 50, function (p) { suivi.page = p; afficherParrainage(); });
  }

  /* ======================================================================
     GOPOINTS
     ====================================================================== */
  var recherchePoints = { texte: '', type: '', page: 0 };
  var CHAMPS_OFFRE = [
    { nom: 'nom', type: 'texte', libelle: 'Nom de l\'offre' },
    { nom: 'description', type: 'texte', libelle: 'Description' },
    { nom: 'cout_points', type: 'nombre', libelle: 'Coût en points' },
    { nom: 'type', type: 'select', libelle: 'Avantage obtenu', options: [['', 'À choisir']].concat(TYPES_OFFRE) },
    { nom: 'valeur', type: 'nombre', libelle: 'Valeur de l\'avantage (en dollars)' },
    { nom: 'stock', type: 'nombre', libelle: 'Stock', aide: 'Vide : illimité.' },
    { nom: 'limite_client', type: 'nombre', libelle: 'Limite par client', aide: 'Vide : sans limite.' },
    { nom: 'debut', type: 'date', libelle: 'Début' }, { nom: 'fin', type: 'date', libelle: 'Fin' },
    { nom: 'actif', type: 'case', libelle: 'Offre visible par les clients' },
    { nom: 'conditions', type: 'zone', libelle: 'Conditions', lignes: 3, large: true }
  ];

  function afficherPoints() {
    var zone = $('[data-prog-panneau="points"]', vue);
    var version = ++etat.version;
    Promise.all([P.pointsRegles(), P.pointsApercu(), P.pointsMouvements(recherchePoints)]).then(function (r) {
      if (version !== etat.version || etat.onglet !== 'points') return;
      zone.textContent = '';
      dessinerPoints(zone, r[0], r[1], r[2], peut('programs.manage'), peut('points.adjust'));
    }).catch(echouer);
  }

  function dessinerPoints(zone, base, apercu, mouvements, gerer, ajuster) {
    var tete = titre(zone, 'GOPOINTS',
      'Un registre qui ne se modifie jamais : chaque gain, chaque utilisation, chaque correction est une ligne de plus. Aucune règle ni aucune offre n\'a de valeur tant que vous ne la fixez pas.');
    var s = el('p', 'gs-prog__statut', 'État :'); s.appendChild(etiquetteProgramme(apercu.actif)); tete.appendChild(s);
    chiffres(tete, [
      { libelle: 'Points en circulation', valeur: O.nombre(apercu.solde_total) }, { libelle: 'Clients avec des points', valeur: O.nombre(apercu.clients_avec_points) },
      { libelle: 'Points gagnés', valeur: O.nombre(apercu.gagnes) }, { libelle: 'Points utilisés', valeur: O.nombre(apercu.utilises) },
      { libelle: 'Points expirés', valeur: O.nombre(apercu.expires) }, { libelle: 'Avantages obtenus avec des points', valeur: O.nombre(apercu.recompenses_utilisees) }
    ]);

    var rg = titre(zone, 'Programme', gerer ? '' : 'Lecture seule : seuls les administrateurs règlent le programme.');
    var f = formulaire([
      { nom: 'actif', type: 'case', libelle: 'Programme GOPOINTS allumé' },
      { nom: 'expiration_jours', type: 'nombre', libelle: 'Durée de vie des points (jours)', aide: 'Vide : les points n\'expirent pas.' },
      { nom: 'conditions', type: 'zone', libelle: 'Conditions (visibles par le client)', lignes: 3, large: true }
    ], base.reglages, !gerer);
    rg.appendChild(f);
    if (gerer) {
      actions(rg).appendChild(bouton('Enregistrer', 'gs-bouton--sombre', function () {
        return P.pointsReglages(f.lire()).then(function () { annoncer('Programme enregistré.'); afficherPoints(); });
      }));
    }

    // Les règles : une ligne par événement, chacune se règle à part
    var rr = titre(zone, 'Règles', 'Une règle allumée doit accorder au moins 1 point. La première opération et les suivantes demandent l\'opération qualifiante.');
    base.regles.forEach(function (r) {
      var carte = el('article', 'gs-prog__carte gs-prog__carte--regle');
      var t = el('div', 'gs-prog__carte-tete'); t.appendChild(el('h4', 'gs-prog__sous-titre', r.libelle)); t.appendChild(etiquetteProgramme(r.actif)); carte.appendChild(t);
      var defs = [{ nom: 'actif', type: 'case', libelle: 'Règle allumée' }, { nom: 'points', type: 'nombre', libelle: 'Points accordés' }];
      if (r.evenement === 'first_operation' || r.evenement === 'repeat_operation') defs.push({ nom: 'operation', type: 'select', libelle: 'Opération qualifiante', options: [['', 'À choisir']].concat(OPERATIONS) });
      defs.push({ nom: 'limite_jour', type: 'nombre', libelle: 'Limite par jour' }, { nom: 'limite_mois', type: 'nombre', libelle: 'Limite par mois' },
                { nom: 'limite_client', type: 'nombre', libelle: 'Limite par client' }, { nom: 'expiration_jours', type: 'nombre', libelle: 'Durée de vie (jours)', aide: 'Vide : celle du programme.' });
      var fr = formulaire(defs, r, !gerer);
      carte.appendChild(fr);
      if (gerer) {
        actions(carte).appendChild(bouton('Enregistrer cette règle', 'gs-bouton--sombre', function () {
          return P.pointsRegle(r.evenement, fr.lire()).then(function () { annoncer('Règle enregistrée.'); afficherPoints(); });
        }));
      }
      rr.appendChild(carte);
    });

    // Les offres échangeables
    var of = titre(zone, 'Offres échangeables', 'Le catalogue reste vide tant que vous n\'y ajoutez rien. L\'avantage obtenu est enregistré ; l\'équipe l\'applique à la facture à la main.');
    var zoneOffre = el('div', 'gs-prog__edition');
    function editerOffre(o) {
      zoneOffre.textContent = '';
      zoneOffre.appendChild(el('h4', 'gs-prog__sous-titre', o ? 'Modifier l\'offre' : 'Nouvelle offre'));
      var fo = formulaire(CHAMPS_OFFRE, o || { actif: false });
      zoneOffre.appendChild(fo);
      var a = actions(zoneOffre);
      a.appendChild(bouton('Enregistrer', 'gs-bouton--sombre', function () {
        return P.pointsOffre(o ? o.id : null, fo.lire()).then(function () { annoncer('Offre enregistrée.'); afficherPoints(); });
      }));
      a.appendChild(bouton('Annuler', 'gs-bouton--contour', function () { zoneOffre.textContent = ''; }));
    }
    if (gerer) actions(of).appendChild(bouton('Nouvelle offre', 'gs-bouton--sombre', function () { editerOffre(null); }));
    of.appendChild(zoneOffre);
    tableau(of, [
      { titre: 'Offre', rendu: function (o) { return o.nom; } },
      { titre: 'Coût', rendu: function (o) { return O.nombre(o.cout_points) + ' points'; }, classe: 'gs-droite' },
      { titre: 'Avantage', rendu: function (o) { return libelle(TYPES_OFFRE, o.type) + ' : ' + valeurTexte(o.type, o.valeur); } },
      { titre: 'Stock', rendu: function (o) { return o.stock == null ? 'Illimité' : O.nombre(o.stock); }, classe: 'gs-droite' },
      { titre: 'Statut', rendu: function (o) { return etiquetteProgramme(o.actif); } },
      { titre: 'Action', rendu: function (o) { return gerer ? bouton('Modifier', 'gs-bouton--contour', function () { editerOffre(o); }) : '—'; } }
    ], base.offres, 'Aucune offre : le catalogue est vide.');

    // Corriger un solde
    if (ajuster) {
      var co = titre(zone, 'Corriger un solde', 'Un mouvement de plus, avec un motif. Le solde ne peut jamais devenir négatif.');
      var fc = formulaire([{ nom: 'code', type: 'texte', libelle: 'Code du client', aide: 'Par exemple GSE-1234.' },
                           { nom: 'points', type: 'nombre', libelle: 'Points (négatif pour retirer)' }, { nom: 'motif', type: 'texte', libelle: 'Motif', large: true }]);
      co.appendChild(fc);
      actions(co).appendChild(bouton('Corriger', 'gs-bouton--sombre', function () {
        var v = fc.lire();
        return clientParCode(v.code).then(function (c) {
          return P.pointsCorriger(c.id, parseInt(v.points, 10), v.motif).then(function (r) { annoncer('Solde corrigé.'); afficherPoints(); });
        });
      }));
    }

    // Les mouvements
    var mv = titre(zone, 'Registre des mouvements');
    var fm = formulaire([{ nom: 'texte', type: 'texte', libelle: 'Client, source ou référence' },
                         { nom: 'type', type: 'select', libelle: 'Type', options: [['', 'Tous']].concat(Object.keys(MOUVEMENTS).map(function (k) { return [k, MOUVEMENTS[k]]; })) }],
                        { texte: recherchePoints.texte, type: recherchePoints.type });
    fm.classList.add('gs-prog__filtres');
    mv.appendChild(fm);
    actions(mv).appendChild(bouton('Chercher', 'gs-bouton--contour', function () {
      var v = fm.lire(); recherchePoints.texte = v.texte.trim(); recherchePoints.type = v.type || ''; recherchePoints.page = 0; afficherPoints();
    }));
    tableau(mv, [
      { titre: 'Date', rendu: function (m) { return dateTexte(m.date); } },
      { titre: 'Client', rendu: function (m) { return m.client_nom + ' (' + m.client_code + ')'; } },
      { titre: 'Type', rendu: function (m) { return libelle(Object.keys(MOUVEMENTS).map(function (k) { return [k, MOUVEMENTS[k]]; }), m.type); } },
      { titre: 'Points', rendu: function (m) { return (m.points > 0 ? '+' : '') + O.nombre(m.points); }, classe: 'gs-droite' },
      { titre: 'Source', rendu: function (m) { return libelle(base.regles.map(function (r) { return [r.evenement, r.libelle]; }), m.source) + (m.motif ? ' — ' + m.motif : ''); } },
      { titre: 'Statut', rendu: function (m) { return etiquette(m.statut); } },
      { titre: 'Action', rendu: function (m) {
        if (!ajuster || m.statut === 'annule' || (m.type !== 'gain' && m.type !== 'utilisation')) return '—';
        return bouton('Annuler', 'gs-bouton--contour', function () {
          return demanderMotif('Annuler ce mouvement', 'Un mouvement inverse est ajouté au registre ; le motif est gardé au journal.', 'Annuler le mouvement').then(function (motif) {
            if (!motif) return null;
            return P.pointsAnnuler(m.id, motif).then(function () { annoncer('Mouvement annulé.'); afficherPoints(); });
          });
        });
      } }
    ], mouvements.elements, 'Aucun mouvement.');
    pagination(mv, mouvements.total, recherchePoints.page, 50, function (p) { recherchePoints.page = p; afficherPoints(); });
  }

  /* ======================================================================
     Avantages accordés, erreurs
     ====================================================================== */
  var filtreAvantages = { programme: '', statut: '', page: 0 };

  function afficherAvantages() {
    var zone = $('[data-prog-panneau="avantages"]', vue);
    var version = ++etat.version;
    Promise.all([P.recompenses(filtreAvantages), P.erreurs()]).then(function (r) {
      if (version !== etat.version || etat.onglet !== 'avantages') return;
      zone.textContent = '';
      dessinerAvantages(zone, r[0], r[1], peut('points.adjust'));
    }).catch(echouer);
  }

  function dessinerAvantages(zone, liste, erreurs, ajuster) {
    var ls = titre(zone, 'Avantages accordés',
      'Tous les programmes. Un crédit, une réduction ou un bonus est enregistré ici : l\'équipe l\'applique à la facture du client (la facturation n\'est jamais modifiée automatiquement).');
    var fl = formulaire([
      { nom: 'programme', type: 'select', libelle: 'Programme', options: [['', 'Tous']].concat(Object.keys(PROGRAMMES).map(function (k) { return [k, PROGRAMMES[k]]; })) },
      { nom: 'statut', type: 'select', libelle: 'Statut', options: [['', 'Tous'], ['en_attente', 'En attente'], ['obtenue', 'Obtenus'], ['utilisee', 'Utilisés'], ['annulee', 'Annulés'], ['expiree', 'Expirés']] }
    ], filtreAvantages);
    fl.classList.add('gs-prog__filtres');
    $$('select', fl).forEach(function (s) {
      s.addEventListener('change', function () { var v = fl.lire(); filtreAvantages.programme = v.programme || ''; filtreAvantages.statut = v.statut || ''; filtreAvantages.page = 0; afficherAvantages(); });
    });
    ls.appendChild(fl);
    tableau(ls, [
      { titre: 'Date', rendu: function (r) { return dateTexte(r.date); } },
      { titre: 'Client', rendu: function (r) { return r.client_nom + ' (' + r.client_code + ')'; } },
      { titre: 'Programme', rendu: function (r) { return PROGRAMMES[r.programme] || r.programme; } },
      { titre: 'Avantage', rendu: function (r) { return libelle(TYPES_AVANTAGE, r.type) + ' : ' + valeurTexte(r.type, r.valeur); } },
      { titre: 'Statut', rendu: function (r) {
        var n = el('span'); n.appendChild(etiquette(r.statut));
        if (r.valide_apres && r.statut === 'en_attente') {
          n.appendChild(el('span', 'gs-prog__aide gs-prog__suite', 'jusqu\'au'));
          n.appendChild(el('span', 'gs-prog__aide', dateTexte(r.valide_apres)));
        }
        if (r.motif) n.appendChild(el('span', 'gs-prog__aide gs-prog__suite', motifTexte(r.motif)));
        return n;
      } },
      { titre: 'Action', rendu: function (r) {
        if (!ajuster || (r.statut !== 'en_attente' && r.statut !== 'obtenue')) return '—';
        return bouton('Annuler', 'gs-bouton--contour', function () {
          return demanderMotif('Annuler cet avantage', 'Le client en est prévenu ; le motif est gardé au journal.', 'Annuler l\'avantage').then(function (m) {
            if (!m) return null;
            return P.recompenseAnnuler(r.id, m).then(function () { annoncer('Avantage annulé.'); afficherAvantages(); });
          });
        });
      } }
    ], liste.elements, 'Aucun avantage.');
    pagination(ls, liste.total, filtreAvantages.page, 50, function (p) { filtreAvantages.page = p; afficherAvantages(); });

    if (ajuster) {
      var ac = titre(zone, 'Accorder un avantage à la main', 'Un motif est obligatoire ; l\'action est journalisée.');
      var fa = formulaire([{ nom: 'code', type: 'texte', libelle: 'Code du client', aide: 'Par exemple GSE-1234.' },
                           { nom: 'type', type: 'select', libelle: 'Type', options: [['', 'À choisir']].concat(TYPES_AVANTAGE) },
                           { nom: 'valeur', type: 'nombre', libelle: 'Valeur' }, { nom: 'motif', type: 'texte', libelle: 'Motif', large: true }]);
      ac.appendChild(fa);
      actions(ac).appendChild(bouton('Accorder', 'gs-bouton--sombre', function () {
        var v = fa.lire();
        return clientParCode(v.code).then(function (c) {
          return P.recompenseAccorder(c.id, v.type, v.valeur, v.motif).then(function () { annoncer('Avantage accordé.'); afficherAvantages(); });
        });
      }));
    }

    var er = titre(zone, 'Erreurs des programmes', 'Une erreur dans le calcul d\'un programme ne bloque jamais l\'opération qui l\'a causée (réception d\'un colis, paiement) : elle est notée ici.');
    tableau(er, [
      { titre: 'Date', rendu: function (e) { return dateTexte(e.date); } },
      { titre: 'Programme', rendu: function (e) { return e.programme; } },
      { titre: 'Événement', rendu: function (e) { return e.evenement; } },
      { titre: 'Client', rendu: function (e) { return e.client_code || '—'; } },
      { titre: 'Détail', rendu: function (e) { return e.message; } }
    ], erreurs.elements, 'Aucune erreur.');
  }
})();
