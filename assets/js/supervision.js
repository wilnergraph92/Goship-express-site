/* ==========================================================================
   Goship Express — le suivi des transporteurs (onglet « Suivi transporteurs »)
   --------------------------------------------------------------------------
   Suivi universel, Phase 6 (dossier validé par le CEO le 13/11/2026). Jusqu'ici,
   l'équipe ne voyait rien du suivi externe : tout se lisait en SQL. Cet onglet
   répond à trois questions :
     1. le moteur va-t-il bien ? (santé, quota, arrêt, erreurs, notifications) ;
     2. quels achats demandent une action ? (livré mais pas reçu à Miami, colis
        reçu chez un autre client, incident, numéro refusé, sans nouvelles) ;
     3. que s'est-il passé sur ce numéro ? (la fiche : admin.js, ouvrirFicheSuivi).

   Il ne décide de rien : tout vient de API.admin.supervisionSuivi (la base compte,
   trie et pagine), et aucun statut de colis ne change ici. « Livré » par le
   transporteur n'est jamais « reçu » : seul le scan de l'entrepôt le dit.
   L'administrateur (tracking.manage, dit par la base : peut_piloter) arrête ou
   reprend le moteur, change le plafond mensuel (motif obligatoire, journalisé) et
   suit un numéro à la main ; les autres rôles lisent.
   ========================================================================== */
(function () {
  'use strict';

  var API = window.GoshipAPI;
  var vue = document.querySelector('[data-vue="suivi"]');
  if (!API || !vue || !API.admin || !API.admin.supervisionSuivi) return;
  var O = API.outils;

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function $$(sel, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(sel)); }
  function el(balise, classe, texte) {
    var n = document.createElement(balise);
    if (classe) n.className = classe;
    if (texte !== undefined && texte !== null) n.textContent = texte;
    return n;
  }

  // Les mots de la base, en phrases (les mêmes que la fiche, admin.js)
  var STATUTS = {
    PENDING: 'Pas encore de nouvelles', INFO_RECEIVED: 'Annoncé au transporteur', IN_TRANSIT: 'En route',
    CUSTOMS: 'En douane', OUT_FOR_DELIVERY: 'En cours de livraison', AVAILABLE_FOR_PICKUP: 'Disponible au point de retrait',
    DELIVERED: 'Livré par le transporteur', FAILED_ATTEMPT: 'Tentative de livraison échouée', EXCEPTION: 'Incident',
    RETURNED: 'Retourné à l’expéditeur', EXPIRED: 'Suivi expiré', NOT_FOUND: 'Introuvable chez le transporteur'
  };
  var CODES = {
    INVALID_TRACKING: 'Numéro refusé par le transporteur', PENDING_FIRST_SCAN: 'En attente du premier scan',
    CARRIER_UNKNOWN: 'Transporteur inconnu', PROVIDER_UNAVAILABLE: 'Fournisseur indisponible',
    UNSUPPORTED_TRACKING: 'Numéro non pris en charge', AMAZON_TBA_LIMITATION: 'Numéro Amazon (TBA) : suivi limité',
    ORDER_NUMBER_DETECTED: 'Numéro de commande, pas de suivi', TRACKING_EXPIRED: 'Suivi expiré'
  };
  var RAISONS = {
    LIVRE_NON_RECU: 'Livré, pas reçu', AUTRE_CLIENT: 'Reçu chez un autre client', INCIDENT: 'Incident',
    NUMERO_REFUSE: 'Numéro refusé', SILENCE: 'Sans nouvelles'
  };
  var COULEURS_RAISON = { LIVRE_NON_RECU: 'gs-badge--incident', AUTRE_CLIENT: 'gs-badge--incident',
                          INCIDENT: 'gs-badge--incident', NUMERO_REFUSE: 'gs-badge--facture-partielle',
                          SILENCE: 'gs-badge--facture-annulee' };
  var ETATS = { en_attente: 'En attente', actif: 'Suivi', arrete: 'Arrêté', erreur: 'En erreur' };
  var FINS = { LIVRE: 'Terminé : livré', ARRIVE_MIAMI: 'Terminé : arrivé à Miami',
               SILENCE_30J: 'Terminé : 30 jours sans nouvelles', TERMINE: 'Terminé' };
  var CONFORMITES = { VERIFIED: 'Vérifié', PENDING_VERIFICATION: 'En cours de vérification',
                      NOT_AUTHORIZED: 'Non autorisé', DISABLED: 'Désactivé' };

  function couleurStatut(s) {
    if (s === 'DELIVERED') return 'gs-badge--disponible';
    if (s === 'EXCEPTION' || s === 'FAILED_ATTEMPT' || s === 'RETURNED') return 'gs-badge--incident';
    if (s === 'OUT_FOR_DELIVERY') return 'gs-badge--distribution';
    if (s) return 'gs-badge--embarque';
    return 'gs-badge--facture-annulee';
  }
  function phraseSuivi(s) {
    if (s && s.statut) return STATUTS[s.statut] || s.statut;
    if (s && s.code_resultat) return CODES[s.code_resultat] || s.code_resultat;
    return 'Pas encore de nouvelles';
  }

  var etat = { filtres: { recherche: '', suivi: '', statut: '', etat: '' }, page: 1, requete: 0,
               derniere: null, raison: '' };
  var zone = $('[data-suivi-zone]', vue);
  var absent = $('[data-suivi-absent]', vue);
  var sante = $('[data-suivi-sante]', vue);
  var actions = $('[data-suivi-actions]', vue);
  var corpsSurv = $('[data-lignes="surveiller"]', vue);
  var videSurv = $('[data-vide="surveiller"]', vue);
  var puces = $('[data-suivi-raisons]', vue);
  var corpsSuivis = $('[data-lignes="suivis"]', vue);
  var videSuivis = $('[data-vide="suivis"]', vue);
  var total = document.querySelector('[data-total="suivi"]');

  function messageErreur(err) {
    if (err && err.metier && err.detail) return err.detail;
    if (err && err.code === 'reseau') return 'Connexion impossible : vérifiez le réseau, puis réessayez.';
    if (err && err.code === 'non-autorise') return 'Votre rôle ne permet pas de voir le suivi des transporteurs.';
    if (err && err.code === 'absent') return 'La base n’est pas encore à jour pour le suivi des transporteurs.';
    return 'Le suivi des transporteurs n’a pas pu être lu.';
  }

  /* ---- La santé ------------------------------------------------------------ */
  function chiffre(libelle, valeur, detail, alerte) {
    var bloc = el('div', 'gs-sv__chiffre' + (alerte ? ' is-alerte' : ''));
    bloc.appendChild(el('dt', '', libelle));
    var dd = el('dd');
    dd.appendChild(el('span', 'gs-sv__valeur', valeur));
    if (detail) dd.appendChild(el('span', 'gs-sv__detail', detail));
    bloc.appendChild(dd);
    sante.appendChild(bloc);
  }

  function montrerSante(r) {
    sante.textContent = '';
    var s = r.sante || {}, f = (r.fournisseurs || []).filter(function (x) { return x.code === s.fournisseur; })[0]
      || (r.fournisseurs || []).filter(function (x) { return x.conformite !== 'DISABLED'; })[0] || null;
    var service = !f ? 'Aucun fournisseur' : f.actif ? 'En service'
      : f.essai ? 'En essai : rien n’est montré aux clients' : 'Arrêté';
    chiffre('Fournisseur', f ? f.nom : '—', [service, f ? CONFORMITES[f.conformite] || f.conformite : ''].filter(Boolean).join(' · '),
            !!f && !f.actif && !f.essai);
    (s.arrets || []).forEach(function (a) { chiffre('Arrêt automatique', a.motif || '—', null, true); });
    chiffre('Quota restant', s.quota_restant == null ? '—' : O.nombre(s.quota_restant),
            s.quota_lu_le ? O.date(s.quota_lu_le, true) : '', s.quota_restant != null && s.quota_restant < 50);
    chiffre('Suivis en cours', O.nombre(s.en_cours || 0));
    chiffre('Relectures en retard', O.nombre(s.en_retard || 0), null, (s.en_retard || 0) > 0);
    chiffre('Erreurs (24 h)', O.nombre(s.erreurs_24h || 0), null, (s.erreurs_24h || 0) > 0);
    chiffre('Dernière lecture réussie', s.derniere_lecture_ok ? O.date(s.derniere_lecture_ok, true) : 'Aucune');
    if (f) {
      chiffre('Pré-alertes suivies ce mois', O.nombre(f.prealertes_ce_mois || 0) +
              (f.plafond_mensuel != null ? ' / ' + O.nombre(f.plafond_mensuel) : ''),
              f.suivre_prealertes ? 'Suivi automatique allumé' : 'Suivi automatique éteint');
    }
    var a = r.alertes || {}, regles = a.regles || [];
    var envoyees = 0;
    Object.keys(a.notifications || {}).forEach(function (k) { envoyees += Number(a.notifications[k]) || 0; });
    var allumees = regles.filter(function (x) { return x.actif; }).length;
    chiffre('Notifications aux clients', O.nombre(envoyees),
            allumees === regles.length && regles.length ? 'Allumées' : allumees ? 'En partie allumées' : 'Éteintes',
            (a.erreurs_24h || 0) > 0);

    // Les commandes de l'administrateur (la base les refuse de toute façon aux autres)
    actions.hidden = !r.peut_piloter || !f;
    if (r.peut_piloter && f) {
      $('[data-suivi-action="arreter"]', actions).hidden = !(f.actif || f.essai);
      $('[data-suivi-action="reprendre"]', actions).hidden = !!(f.actif || f.essai);
      etat.fournisseur = f;
    }
    etat.quota = s.quota_restant;
  }

  /* ---- À surveiller ---------------------------------------------------------- */
  function cellule(libelle) {
    var td = el('td');
    if (libelle) td.setAttribute('data-libelle', libelle);
    return td;
  }
  function client(c) { return c ? [c.code, c.nom].filter(Boolean).join(' · ') : ''; }

  function ligneSurveiller(c) {
    var tr = el('tr');
    // La fiche qu'ouvre la ligne (admin.js) : celle du suivi, sinon celle du colis
    if (c.suivi && c.suivi.id) tr.setAttribute('data-suivi-id', c.suivi.id);
    else if (c.colis && c.colis.numero) tr.setAttribute('data-colis-numero', c.colis.numero);
    tr.setAttribute('data-raison', c.raison);

    var tdR = cellule('Raison');
    tdR.appendChild(el('span', 'gs-badge ' + (COULEURS_RAISON[c.raison] || ''), RAISONS[c.raison] || c.raison));
    tr.appendChild(tdR);

    var tdA = cellule('Achat');
    tdA.appendChild(el('span', 'gs-cellule-principale', [c.achat.magasin, c.achat.description].filter(Boolean).join(' — ') || '—'));
    tdA.appendChild(el('span', 'gs-cellule-sous gs-cellule-num', c.achat.numero_suivi || ''));
    tr.appendChild(tdA);

    var tdC = cellule('Client');
    tdC.appendChild(el('span', 'gs-cellule-principale', client(c.achat.client) || '—'));
    if (c.raison === 'AUTRE_CLIENT' && c.colis) {
      // Le colis reçu et son client, sans phrase à traduire : « GSE-… → GSE-… · Nom »
      tdC.appendChild(el('span', 'gs-cellule-sous', c.colis.numero + ' → ' + (client(c.colis.client) || '—')));
    }
    tr.appendChild(tdC);

    var tdT = cellule('Chez le transporteur');
    if (c.suivi) {
      tdT.appendChild(el('span', 'gs-cellule-principale', phraseSuivi(c.suivi)));
      tdT.appendChild(el('span', 'gs-cellule-sous', [c.suivi.transporteur_nom || c.suivi.transporteur, c.suivi.dernier_lieu]
        .filter(Boolean).join(' · ')));
    } else {
      tdT.appendChild(el('span', 'gs-cellule-sous', 'Pas de suivi'));
    }
    tr.appendChild(tdT);

    var tdD = cellule('Depuis le');
    tdD.appendChild(el('span', null, c.depuis ? O.date(c.depuis, true) : '—'));
    tr.appendChild(tdD);
    return tr;
  }

  function montrerSurveiller(r) {
    var a = r.a_surveiller || { compteurs: {}, cas: [] };
    var cpt = a.compteurs || {};
    if (total) total.textContent = cpt.total ? O.nombre(cpt.total) : '';
    puces.textContent = '';
    [''].concat(Object.keys(RAISONS)).forEach(function (k) {
      var n = k ? cpt[k] || 0 : cpt.total || 0;
      if (k && !n) return;
      var b = el('button', 'gs-sv__puce' + (etat.raison === k ? ' is-actif' : ''));
      b.type = 'button';
      b.setAttribute('aria-pressed', etat.raison === k ? 'true' : 'false');
      b.setAttribute('data-suivi-raison', k);
      b.appendChild(el('span', null, k ? RAISONS[k] : 'Tous'));
      b.appendChild(el('span', 'gs-sv__puce-n', O.nombre(n)));
      b.addEventListener('click', function () { etat.raison = k; montrerSurveiller(etat.derniere); });
      puces.appendChild(b);
    });
    var cas = (a.cas || []).filter(function (c) { return !etat.raison || c.raison === etat.raison; });
    corpsSurv.textContent = '';
    cas.forEach(function (c) { corpsSurv.appendChild(ligneSurveiller(c)); });
    videSurv.hidden = cas.length > 0;
    videSurv.textContent = 'Rien à surveiller : chaque achat suivi va son chemin.';
  }

  /* ---- Tous les suivis ---------------------------------------------------------- */
  function ligneSuivi(s) {
    var tr = el('tr');
    tr.setAttribute('data-suivi-id', s.id);

    var tdN = cellule('Numéro de suivi');
    tdN.appendChild(el('span', 'gs-cellule-num', s.numero));
    tdN.appendChild(el('span', 'gs-cellule-sous', s.transporteur_nom || s.transporteur || 'Transporteur non déterminé'));
    tr.appendChild(tdN);

    var tdS = cellule('Chez le transporteur');
    tdS.appendChild(el('span', 'gs-badge ' + couleurStatut(s.statut), phraseSuivi(s)));
    if (s.dernier_lieu) tdS.appendChild(el('span', 'gs-cellule-sous', s.dernier_lieu));
    tr.appendChild(tdS);

    var tdA = cellule('Achats');
    tdA.appendChild(el('span', 'gs-cellule-principale', O.nombre(s.achats || 0)));
    if (s.clients && s.clients.length) tdA.appendChild(el('span', 'gs-cellule-sous', s.clients.join(' · ')));
    tr.appendChild(tdA);

    var tdC = cellule('Colis GoShip');
    tdC.appendChild(el('span', s.colis ? 'gs-cellule-num' : 'gs-cellule-sous', s.colis ? s.colis.numero : '—'));
    tr.appendChild(tdC);

    var tdD = cellule('Dernière nouvelle');
    tdD.appendChild(el('span', null, s.dernier_evenement_le ? O.date(s.dernier_evenement_le, true) : '—'));
    tr.appendChild(tdD);

    var tdE = cellule('Suivi');
    tdE.appendChild(el('span', 'gs-cellule-principale', s.fin_motif ? FINS[s.fin_motif] || s.fin_motif : ETATS[s.etat] || s.etat));
    tdE.appendChild(el('span', 'gs-cellule-sous', s.origine === 'equipe' ? 'Demandé par l’équipe' : 'Pré-alerte'));
    tr.appendChild(tdE);
    return tr;
  }

  function paginer(r) {
    var z = $('[data-pagination="suivis"]', vue);
    z.textContent = '';
    z.hidden = r.pages <= 1;
    if (z.hidden) return;
    var premier = (r.page - 1) * 50 + 1, dernier = Math.min(r.total, r.page * 50);
    z.appendChild(el('span', 'gs-pagination__texte', premier + '–' + dernier + ' sur ' + r.total));
    var prec = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Précédente');
    prec.type = 'button';
    prec.disabled = r.page <= 1;
    prec.addEventListener('click', function () { etat.page -= 1; charger(); });
    var suiv = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Suivante');
    suiv.type = 'button';
    suiv.disabled = r.page >= r.pages;
    suiv.addEventListener('click', function () { etat.page += 1; charger(); });
    z.appendChild(prec);
    z.appendChild(suiv);
  }

  function montrerSuivis(r) {
    corpsSuivis.textContent = '';
    (r.suivis || []).forEach(function (s) { corpsSuivis.appendChild(ligneSuivi(s)); });
    videSuivis.hidden = (r.suivis || []).length > 0;
    var filtre = etat.filtres.recherche || etat.filtres.suivi || etat.filtres.statut || etat.filtres.etat;
    videSuivis.textContent = filtre ? 'Aucun suivi ne correspond à ces filtres.' : 'Aucun suivi pour l’instant.';
    paginer(r);
  }

  /* ---- Charger ----------------------------------------------------------------- */
  function charger() {
    var n = ++etat.requete;
    vue.setAttribute('aria-busy', 'true');
    var filtres = {};
    Object.keys(etat.filtres).forEach(function (k) { if (etat.filtres[k]) filtres[k] = etat.filtres[k]; });
    return API.admin.supervisionSuivi(filtres, etat.page).then(function (r) {
      if (n !== etat.requete) return;
      if (!r) throw { code: 'absent' };
      if (!(r.suivis || []).length && etat.page > 1 && r.total > 0) { etat.page = r.pages; return charger(); }
      etat.derniere = r;
      zone.hidden = false;
      absent.hidden = true;
      montrerSante(r);
      montrerSurveiller(r);
      montrerSuivis(r);
    }).catch(function (err) {
      if (n !== etat.requete) return;
      zone.hidden = true;
      absent.hidden = false;
      absent.textContent = messageErreur(err);
    }).then(function () {
      if (n === etat.requete) vue.removeAttribute('aria-busy');
    });
  }

  var minuteur = null;
  $('[data-recherche-suivis]', vue).addEventListener('input', function (e) {
    clearTimeout(minuteur);
    var v = e.target.value.trim();
    minuteur = setTimeout(function () { etat.filtres.recherche = v; etat.page = 1; charger(); }, 250);
  });
  $$('[data-filtre-suivis]', vue).forEach(function (s) {
    s.addEventListener('change', function () { etat.filtres[s.getAttribute('data-filtre-suivis')] = s.value; etat.page = 1; charger(); });
  });

  /* ---- Piloter (administrateur) ------------------------------------------------- */
  var dlg = document.querySelector('[data-dialogue="suivi-pilote"]');
  var formulaire = dlg && $('[data-suivi-pilote-form]', dlg);
  var action = null;
  var DIALOGUES = {
    arreter: { titre: 'Arrêter le suivi', aide: 'Plus aucun numéro n’est inscrit ni relu chez le fournisseur tant que le suivi n’est pas repris. Les clients gardent ce qu’ils voient déjà.', blocs: ['motif'], bouton: 'Arrêter' },
    reprendre: { titre: 'Reprendre le suivi', aide: 'Le fournisseur revient en service : en production s’il est vérifié, sinon en essai (rien n’est montré aux clients).', blocs: ['motif'], bouton: 'Reprendre' },
    plafond: { titre: 'Plafond mensuel', aide: 'Le nombre de pré-alertes suivies automatiquement chaque mois, au plus (jours de Santo Domingo). Au-delà, elles attendent le mois suivant.', blocs: ['valeur', 'motif'], bouton: 'Enregistrer' },
    suivre: { titre: 'Suivre un numéro', aide: 'Le numéro est inscrit chez le fournisseur à la minute suivante : cela utilise une inscription de son quota.', blocs: ['numero'], bouton: 'Suivre ce numéro' }
  };

  // Le bandeau du tableau de bord (admin.js, [data-toast]) : la même place que les autres messages
  var minuteurAnnonce = null;
  function annonce(message) {
    var t = document.querySelector('[data-toast]');
    if (!t) return;
    t.textContent = message;
    t.className = 'gs-toast';
    t.hidden = false;
    clearTimeout(minuteurAnnonce);
    minuteurAnnonce = setTimeout(function () { t.hidden = true; }, 3600);
  }

  function erreurPilote(texte) {
    var p = $('[data-suivi-pilote-erreur]', dlg);
    p.textContent = texte || '';
    p.hidden = !texte;
  }

  function ouvrirPilote(nom) {
    if (!dlg) return;
    action = nom;
    var d = DIALOGUES[nom];
    $('[data-suivi-pilote-titre]', dlg).textContent = d.titre;
    var aide = $('[data-suivi-pilote-aide]', dlg);
    aide.textContent = d.aide;
    if (nom === 'suivre' && etat.quota != null) {
      aide.appendChild(document.createTextNode(' '));
      var q = el('span', 'gs-sv__quota');
      q.appendChild(el('strong', null, 'Quota restant'));
      q.appendChild(document.createTextNode(' ' + O.nombre(etat.quota)));
      aide.appendChild(q);
    }
    $$('[data-suivi-pilote-bloc]', dlg).forEach(function (b) {
      b.hidden = d.blocs.indexOf(b.getAttribute('data-suivi-pilote-bloc')) < 0;
    });
    $('[data-suivi-pilote-motif]', dlg).value = '';
    $('[data-suivi-pilote-numero]', dlg).value = '';
    $('[data-suivi-pilote-valeur]', dlg).value = etat.fournisseur && etat.fournisseur.plafond_mensuel != null
      ? String(etat.fournisseur.plafond_mensuel) : '';
    $('[data-suivi-pilote-confirmer]', dlg).textContent = d.bouton;
    $('[data-suivi-pilote-confirmer]', dlg).disabled = false;
    erreurPilote('');
    dlg.showModal();
    var premier = $('[data-suivi-pilote-bloc]:not([hidden]) input', dlg);
    if (premier) premier.focus();
  }

  $$('[data-suivi-action]', vue).forEach(function (b) {
    b.addEventListener('click', function () { ouvrirPilote(b.getAttribute('data-suivi-action')); });
  });

  if (formulaire) {
    formulaire.addEventListener('submit', function (e) {
      e.preventDefault();
      var motif = $('[data-suivi-pilote-motif]', dlg).value.trim();
      var promesse;
      if (action === 'suivre') {
        var numero = $('[data-suivi-pilote-numero]', dlg).value.trim();
        if (!numero) { erreurPilote('Entrez le numéro de suivi du transporteur.'); return; }
        promesse = API.admin.demanderSuivi(numero);
      } else {
        if (motif.length < 5) { erreurPilote('Indiquez un motif (5 caractères au moins).'); return; }
        var f = etat.fournisseur || {};
        promesse = API.admin.piloterSuivi(f.code, action, motif,
          action === 'plafond' ? $('[data-suivi-pilote-valeur]', dlg).value : null);
      }
      var bouton = $('[data-suivi-pilote-confirmer]', dlg);
      bouton.disabled = true;
      promesse.then(function (r) {
        dlg.close();
        if (action === 'suivre' && r && r.enregistre === false) annonce('Ce numéro n’est pas pris en charge par le fournisseur.');
        else if (action === 'suivre') annonce(r && r.deja ? 'Ce numéro est déjà suivi.' : 'Numéro inscrit : il sera suivi dans une minute.');
        else annonce('Réglage enregistré.');
        charger();
      }).catch(function (err) {
        bouton.disabled = false;
        erreurPilote(messageErreur(err));
      });
    });
  }

  // L'onglet s'ouvre (admin.js, choisirVue) : tout se relit, jamais d'il y a une heure
  var compte = false;
  window.addEventListener('goship:vue', function (e) {
    if (e.detail === 'suivi') { charger(); return; }
    // Le nombre de cas à surveiller, à côté du nom de l'onglet, une fois par session
    if (!compte) {
      compte = true;
      API.admin.supervisionSuivi({}, 1).then(function (r) {
        var n = r && r.a_surveiller && r.a_surveiller.compteurs ? r.a_surveiller.compteurs.total : 0;
        if (total) total.textContent = n ? O.nombre(n) : '';
      }, function () { /* sans le compte, l'onglet reste utilisable */ });
    }
  });

  // Pour la fiche d'un suivi et celle d'un colis (admin.js : mêmes mots qu'ici), les essais
  // automatiques et la console
  window.GoshipSupervision = { charger: charger, phraseSuivi: phraseSuivi, STATUTS: STATUTS, CODES: CODES,
                               ETATS: ETATS, FINS: FINS, couleurStatut: couleurStatut };
})();
