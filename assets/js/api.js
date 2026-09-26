/* ==========================================================================
   Goship Express — accès aux comptes clients et aux colis
   --------------------------------------------------------------------------
   Une même interface (window.GoshipAPI), trois fonctionnements :
   - « supabase » : adresse et clé Supabase renseignées dans config.js ;
                    comptes et colis sont enregistrés en ligne.
   - « demo »     : sans configuration, sur votre ordinateur (fichier ouvert
                    directement ou localhost). Les données restent dans ce
                    navigateur : de quoi essayer le site avant sa mise en ligne.
   - « off »      : sans configuration, sur un vrai nom de domaine. L'espace
                    client reste fermé (aucun compte fictif).
   ========================================================================== */
(function () {
  'use strict';

  var CFG = window.GOSHIP_CONFIG || {};
  // Bibliothèque Supabase rangée dans le site lui-même : aucun script extérieur ne
  // s'exécute dans les pages des clients (voir README, « Sécurité »).
  // Adresse calculée à partir de ce fichier, pour que /en/, /es/ et /ht/ la trouvent aussi.
  var SUPABASE_JS = (function () {
    var moi = document.currentScript;
    var base = moi && moi.src ? moi.src.replace(/[^/]*$/, '') : 'assets/js/';
    return base + 'vendor/supabase-2.116.0.js';
  })();
  // Ordinateur ou réseau local (fichier ouvert directement, localhost, Wi-Fi de la maison…)
  var LOCAL = location.protocol === 'file:' ||
    /^(localhost|127(\.\d+){3}|\[::1\]|10(\.\d+){3}|192\.168(\.\d+){2}|172\.(1[6-9]|2\d|3[01])(\.\d+){2}|[\w-]+\.local)$/.test(location.hostname);
  var MODE = CFG.supabaseUrl && CFG.supabaseKey ? 'supabase' : (LOCAL ? 'demo' : 'off');
  var LANGUE = (document.documentElement.lang || 'fr').slice(0, 2).toLowerCase();
  // L'application GoShip Express pour Windows et macOS (bureau/) ouvre ces mêmes
  // pages et donne window.GoshipBureau : la session y est chiffrée par le
  // système plutôt que laissée dans le localStorage, et un scan y dit de quel
  // poste il vient. Dans un navigateur, BUREAU est null et rien ne change.
  var BUREAU = window.GoshipBureau && window.GoshipBureau.contrat >= 1 ? window.GoshipBureau : null;
  // Les précisions d'une opération, avec le poste qui l'a faite (application de bureau)
  function avecPoste(meta) {
    var m = Object.assign({}, meta || {});
    if (BUREAU) { m.poste = 'bureau'; m.plateforme = BUREAU.plateforme; m.version_bureau = BUREAU.version; }
    return m;
  }

  var STATUTS = ['recu', 'emballe', 'embarque', 'distribution', 'succursale', 'disponible', 'livre', 'incident'];
  var CHAMPS_PROFIL = ['nom_complet', 'pays', 'region', 'ville', 'adresse', 'telephone', 'langue'];
  // Ce que la page peut proposer pour un colis. Ni le prix, ni le statut, ni le
  // numéro : la base les décide (outils/supabase-services.sql, regles_colis).
  var CHAMPS_MODIFIABLES = ['client_id', 'suivi_transporteur', 'expediteur', 'description', 'poids_lb', 'service',
                            'pays_destination', 'destination', 'recu_le', 'tarif_lb_usd'];
  // À la création s'ajoutent le lieu et le message de l'événement initial.
  var CHAMPS_CREATION = CHAMPS_MODIFIABLES.concat(['lieu', 'note']);
  // Ce qu'une page peut encore changer sur une facture émise. Le payé, le
  // statut, le moyen et la date de paiement suivent les paiements
  // (outils/supabase-finances.sql, garde_facture) ; le total ne se change que
  // sur une facture sans colis.
  var CHAMPS_FACTURE = ['montant_usd', 'note', 'lien_paiement', 'echeance_le'];
  // Une nouvelle facture : le client, et ce que la base ne peut pas deviner.
  // Le montant n'est retenu que pour une facture sans colis.
  var CHAMPS_NOUVELLE_FACTURE = ['montant_usd', 'montant_paye_usd', 'echeance_le', 'lien_paiement', 'note'];
  // Un paiement : ce que la page saisit. Le client, l'auteur et la date
  // d'enregistrement sont ceux de la base.
  var CHAMPS_PAIEMENT = ['montant_usd', 'moyen', 'reference', 'paye_le', 'note'];

  /* ---- Les tarifs ------------------------------------------------------------
     Le transport est facturé à la livre. Le tarif peut être remplacé colis par
     colis depuis le tableau de bord (un envoi volumineux, un accord
     particulier) ; les frais de service, eux, sont fixes et ne sont exposés
     dans aucun formulaire. Les deux sont gelés ici pour qu'aucune page ne
     puisse les modifier au passage.
     -------------------------------------------------------------------------- */
  var TARIF_LB_DEFAUT = 5;
  var FRAIS_SERVICE = 10;

  /* ---- Les rôles et leurs permissions ---------------------------------------
     La copie de public.permissions_du_role (outils/supabase.sql, partie 4),
     pour le mode démonstration et pour que les pages sachent quels menus
     montrer. Elle ne protège rien : en ligne, c'est la base qui refuse.
     outils/essais-services/essai-permissions.py vérifie que les deux listes
     sont identiques.
     -------------------------------------------------------------------------- */
  var PERMISSIONS_DES_ROLES = {
    admin: ['clients.view', 'clients.create', 'clients.edit',
            'shipments.view', 'shipments.create', 'shipments.edit', 'shipments.delete',
            'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
            'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
            'payments.view', 'payments.create', 'payments.cancel',
            'reports.view',
            'users.view', 'roles.manage', 'settings.manage', 'audit_logs.view'],
    gerant: ['clients.view', 'clients.create', 'clients.edit',
             'shipments.view', 'shipments.create', 'shipments.edit',
             'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
             'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
             'payments.view', 'payments.create', 'payments.cancel',
             'reports.view',
             'users.view'],
    employe: ['clients.view', 'clients.create',
              'shipments.view', 'shipments.create', 'shipments.edit',
              'shipments.scan', 'shipments.change_status', 'shipments.view_history',
              'invoices.view', 'payments.view'],
    client: ['clients.view:own', 'clients.edit:own',
             'shipments.view:own', 'shipments.view_history:own',
             'invoices.view:own', 'payments.view:own']
  };
  Object.keys(PERMISSIONS_DES_ROLES).forEach(function (r) { Object.freeze(PERMISSIONS_DES_ROLES[r]); });
  var ROLES_EQUIPE = ['employe', 'gerant', 'admin'];

  // peut() de la base : la permission, ou sa forme « :own » sur ses propres données
  function peutCompte(compte, action, proprietaire) {
    if (!compte) return false;
    var liste = PERMISSIONS_DES_ROLES[compte.role] || [];
    return liste.indexOf(action) >= 0 ||
           (proprietaire != null && proprietaire === compte.id && liste.indexOf(action + ':own') >= 0);
  }

  // Les moyens de paiement acceptés : même liste que public.moyens_paiement()
  // dans la base (outils/supabase-finances.sql), qui refuse tout autre.
  var MOYENS_PAIEMENT = ['paypal', 'banque', 'azul', 'moncash', 'natcash', 'especes', 'transfert', 'autre'];

  // Au cent près, 0,005 montant — comme round() dans la base. Le détour par
  // toFixed corrige les nombres à virgule du navigateur : 2,25 × 1,5 y vaut
  // 3,3749999…, qui s'arrondirait à 3,37 là où la facture dit 3,38.
  function arrondi(n) { return Math.round(Number(((Number(n) || 0) * 100).toFixed(6))) / 100; }

  // Tarif réellement appliqué à un colis : le sien s'il en porte un (zéro
  // compris, pour un envoi offert), sinon celui de la maison.
  function tarifDe(colis) {
    var brut = (colis || {}).tarif_lb_usd;
    if (brut == null || brut === '') return TARIF_LB_DEFAUT;
    var t = Number(brut);
    return isFinite(t) && t >= 0 ? t : TARIF_LB_DEFAUT;
  }

  // Poids × tarif. Même calcul que public.prix_transport dans la base, qui
  // seule fait foi : ici, ce n'est qu'un aperçu (et le mode démonstration).
  function prixTransport(poids, tarif) {
    return arrondi((Number(poids) || 0) * (Number(tarif) || 0));
  }

  // Prix du transport d'un colis. Un colis déjà facturé garde le prix inscrit
  // sur lui : changer le tarif demain ne doit pas changer une facture d'hier.
  function prixColis(colis) {
    var c = colis || {};
    if (c.prix_usd != null && c.prix_usd !== '') return arrondi(c.prix_usd);
    return prixTransport(c.poids_lb, tarifDe(c));
  }

  /* ---- Les transitions de statut ----------------------------------------------
     Elles font foi dans la base (outils/supabase-services.sql, partie 5), qui
     refuse toute transition hors de cette matrice, quel que soit le chemin.
     La même matrice vit ici pour une seule raison : que le mode démonstration
     refuse exactement ce que la vraie base refuserait. outils/essais-services/
     vérifie, cas par cas, que les deux répondent pareil.
     -------------------------------------------------------------------------- */
  var TRANSITIONS = {
    recu: ['emballe', 'embarque', 'incident'],
    emballe: ['embarque', 'incident'],
    embarque: ['distribution', 'succursale', 'disponible', 'incident'],
    distribution: ['succursale', 'disponible', 'incident'],
    succursale: ['disponible', 'incident'],
    disponible: ['livre', 'incident'],
    livre: [],
    incident: []
  };
  Object.keys(TRANSITIONS).forEach(function (k) { Object.freeze(TRANSITIONS[k]); });
  Object.freeze(TRANSITIONS);

  // precedent : l'étape d'avant dans l'historique du colis (statutPrecedent)
  function transitionPermise(de, vers, precedent) {
    if (!vers || !TRANSITIONS[vers]) return false;
    if (de === vers) return true;                        // lieu ou message corrigé
    if (!de || !TRANSITIONS[de]) return true;            // ancien statut à convertir
    if (precedent && vers === precedent) return true;    // retour à l'étape précédente
    if (de === 'incident') {
      var avant = precedent || 'recu';
      return vers === avant || (vers !== 'incident' && TRANSITIONS[avant].indexOf(vers) >= 0);
    }
    return TRANSITIONS[de].indexOf(vers) >= 0;
  }

  // Le dernier statut de l'historique (dans l'ordre d'écriture) qui n'est ni
  // l'actuel, ni un incident, ni une étape annulée par une correction.
  function statutPrecedent(historique, actuel) {
    var h = historique || [];
    var corriges = h.map(function (e) { return e.corrige_id; }).filter(function (x) { return x != null; });
    for (var i = h.length - 1; i >= 0; i--) {
      if (h[i].statut !== actuel && h[i].statut !== 'incident' && corriges.indexOf(h[i].id) < 0) return h[i].statut;
    }
    return null;
  }

  /* ---- Les événements (Phase 3) ----------------------------------------------
     Comme les transitions : ils font foi dans la base
     (outils/supabase-evenements.sql), et sont copiés ici pour le mode
     démonstration. outils/essais-services/essai-evenements.py compare le
     catalogue, la nature de chaque transition et chaque validation, cas par
     cas.
     -------------------------------------------------------------------------- */
  var LIBELLES = {
    recu: 'Reçu', emballe: 'Emballé', embarque: 'Embarqué', distribution: 'Centre de distribution',
    succursale: 'Transféré à la succursale', disponible: 'Disponible', livre: 'Livré', incident: 'Action requise'
  };

  var TYPES_EVENEMENT = (function () {
    function t(libelle, statut, depuis, visibilite, permission, special, lieuRequis) {
      return { libelle: libelle, statut: statut, depuis: depuis, visibilite: visibilite, permission: permission,
               special: special, lieu_requis: lieuRequis };
    }
    var maj = 'shipments.change_status', scan = 'shipments.scan', entrepot = ['recu', 'emballe'];
    return {
      COLIS_RECU: t("Reçu à l'entrepôt", 'recu', null, 'publique', 'shipments.create', null, false),
      COLIS_INSPECTE: t('Inspecté', null, entrepot, 'interne', scan, null, false),
      COLIS_EMBALLE: t('Emballé', 'emballe', null, 'publique', maj, null, false),
      COLIS_CONSOLIDE: t('Consolidé', null, entrepot, 'interne', scan, null, false),
      COLIS_CHARGE: t('Chargé', null, entrepot, 'interne', scan, null, false),
      COLIS_EXPEDIE: t('Expédié', 'embarque', null, 'publique', maj, null, false),
      COLIS_ARRIVE: t('Arrivé au centre de distribution', 'distribution', null, 'publique', maj, null, false),
      COLIS_TRANSFERE: t('Transféré à la succursale', 'succursale', null, 'publique', maj, null, false),
      COLIS_DISPONIBLE: t('Disponible', 'disponible', null, 'publique', maj, null, true),
      COLIS_LIVRE: t('Livré', 'livre', null, 'publique', maj, null, false),
      ACTION_REQUISE: t('Action requise', 'incident', null, 'publique', maj, null, false),
      ACTION_RESOLUE: t('Action résolue', null, ['incident'], 'publique', maj, 'sortie', false),
      CORRECTION: t('Correction', null, null, 'interne', 'shipments.correct', 'correction', false),
      MISE_A_JOUR: t('Étape mise à jour', null, null, 'publique', maj, 'mise_a_jour', false)
    };
  })();
  Object.keys(TYPES_EVENEMENT).forEach(function (k) {
    if (TYPES_EVENEMENT[k].depuis) Object.freeze(TYPES_EVENEMENT[k].depuis);
    Object.freeze(TYPES_EVENEMENT[k]);
  });
  Object.freeze(TYPES_EVENEMENT);
  var TYPE_DU_STATUT = {
    recu: 'COLIS_RECU', emballe: 'COLIS_EMBALLE', embarque: 'COLIS_EXPEDIE', distribution: 'COLIS_ARRIVE',
    succursale: 'COLIS_TRANSFERE', disponible: 'COLIS_DISPONIBLE', livre: 'COLIS_LIVRE', incident: 'ACTION_REQUISE'
  };

  // nature_transition : identique, normale, sortie_incident, correction, ou null
  function natureTransition(de, vers, precedent) {
    if (!vers || !TRANSITIONS[vers]) return null;
    if (de === vers) return 'identique';
    if (!de || !TRANSITIONS[de]) return 'normale';
    if (de === 'incident') {
      var avant = precedent || 'recu';
      return vers === avant || (vers !== 'incident' && (TRANSITIONS[avant] || []).indexOf(vers) >= 0)
        ? 'sortie_incident' : null;
    }
    if (TRANSITIONS[de].indexOf(vers) >= 0) return 'normale';
    if (precedent && vers === precedent) return 'correction';
    return null;
  }

  // type_pour_statut : l'événement qui mène au statut coché
  function typePourStatut(de, vers, precedent) {
    switch (natureTransition(de, vers, precedent)) {
      case 'identique': return 'MISE_A_JOUR';
      case 'correction': return 'CORRECTION';
      case 'sortie_incident': return 'ACTION_RESOLUE';
      case 'normale': return TYPE_DU_STATUT[vers] || null;
      default: return null;
    }
  }

  // valider_operation : { code (null si permis), detail, cible, nature }
  function validerOperation(actuel, precedent, type, cible) {
    var t = TYPES_EVENEMENT[type];
    function non(code, detail, c, n) { return { code: code, detail: detail, cible: c, nature: n || null }; }
    function lib(s) { return LIBELLES[s] || s; }
    if (!t) return non('EVENT_TYPE_INVALID', 'Type d’événement inconnu : ' + (type || '(vide)') + '.', null);
    var c, n;
    if (t.special === 'correction') {
      c = cible || precedent;
      n = natureTransition(actuel, c, precedent);
      if (!precedent || c !== precedent || n !== 'correction') {
        return non('INVALID_STATUS_TRANSITION', 'Correction impossible : on ne revient qu’à l’étape précédente du colis.', c, n);
      }
    } else if (t.special === 'sortie') {
      c = cible || precedent || 'recu';
      n = natureTransition(actuel, c, precedent);
      if (actuel !== 'incident' || n !== 'sortie_incident') {
        return non('INVALID_STATUS_TRANSITION', 'Action résolue : le colis doit être en « Action requise » et reprendre son étape, ou une suivante.', c, n);
      }
    } else if (t.special === 'mise_a_jour') {
      c = actuel;
      n = 'identique';
      if (cible && cible !== actuel) return non('INVALID_EVENT_DATA', 'Une mise à jour ne change pas le statut.', cible);
    } else if (!t.statut) {
      c = actuel;
      n = 'identique';
      if (cible && cible !== actuel) return non('INVALID_EVENT_DATA', t.libelle + ' ne change pas le statut du colis.', cible);
      if (t.depuis && t.depuis.indexOf(actuel) < 0) {
        return non('INVALID_STATUS_TRANSITION', t.libelle + ' : impossible au statut « ' + lib(actuel) + ' ».', c);
      }
    } else {
      c = t.statut;
      if (cible && cible !== c) {
        return non('INVALID_EVENT_DATA', t.libelle + ' mène au statut « ' + lib(c) + ' », pas ailleurs.', cible);
      }
      if (c === actuel) return non('STATUS_ALREADY_SET', 'Le colis est déjà au statut « ' + lib(c) + ' ».', c, 'identique');
      n = natureTransition(actuel, c, precedent);
      if (n !== 'normale' && n !== 'sortie_incident') {
        return non('INVALID_STATUS_TRANSITION', lib(actuel) + ' → ' + lib(c) + ' : transition interdite.', c, n);
      }
    }
    return { code: null, detail: null, cible: c, nature: n };
  }

  /* ---- Payé, solde, état d'une facture ------------------------------------
     La base les calcule (outils/supabase-finances.sql : paye_usd, solde_usd,
     etat_paiement) et les renvoie avec chaque facture ; les pages les
     affichent tels quels. Les fonctions ci-dessous ne recalculent que ce que
     la réponse ne porte pas : une facture du mode démonstration, ou une
     réponse d'avant la Phase 5. Même règle que la base, au mot près.
     -------------------------------------------------------------------------- */
  // « Aujourd'hui » à Santo Domingo, comme public.aujourdhui()
  function aujourdhui() {
    try {
      return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Santo_Domingo', year: 'numeric',
                                                month: '2-digit', day: '2-digit' }).format(new Date());
    } catch (e) {
      return new Date(Date.now() - 4 * 36e5).toISOString().slice(0, 10);
    }
  }

  function paiementsValides(f) {
    return ((f || {}).paiements || []).filter(function (p) { return !p.annule_le; });
  }

  // Le payé : la somme des paiements valides
  function payeDe(f) {
    f = f || {};
    if (f.paye_usd != null) return arrondi(f.paye_usd);
    if (f.paiements) return arrondi(paiementsValides(f).reduce(function (s, p) { return s + (Number(p.montant_usd) || 0); }, 0));
    return arrondi(f.montant_paye_usd);
  }

  // Le solde : ce qui reste dû ; rien sur une facture annulée
  function soldeDe(f) {
    f = f || {};
    if (f.solde_usd != null) return arrondi(f.solde_usd);
    if (f.statut === 'annulee') return 0;
    return arrondi(Math.max((Number(f.montant_usd) || 0) - payeDe(f), 0));
  }

  // annulee, payee, en_retard (échue, solde > 0), partielle, a_payer
  function etatFacture(f) {
    f = f || {};
    if (f.etat_paiement) return f.etat_paiement;
    if (f.etat) return f.etat;
    if (f.statut === 'annulee') return 'annulee';
    if (soldeDe(f) <= 0) return 'payee';
    if (f.echeance_le && String(f.echeance_le).slice(0, 10) < aujourdhui()) return 'en_retard';
    return payeDe(f) > 0 ? 'partielle' : 'a_payer';
  }

  // Les montants d'une facture, pour l'écran et le papier. Le grand total est
  // « montant_usd », arrêté à la création : on ne le refait pas à partir des
  // lignes. Les colis valent le total moins les frais de service.
  function totauxFacture(facture) {
    var f = facture || {};
    var frais = arrondi(f.frais_service_usd);
    var grandTotal = arrondi(f.montant_usd);
    return {
      colis: arrondi(Math.max(grandTotal - frais, 0)),
      frais: frais,
      grandTotal: grandTotal,
      paye: payeDe(f),
      balance: soldeDe(f),
      etat: etatFacture(f)
    };
  }

  // Les paiements d'une facture, dans l'ordre où ils ont été reçus
  function trierPaiements(f) {
    if (f && f.paiements) {
      f.paiements.sort(function (a, b) {
        return new Date(a.paye_le) - new Date(b.paye_le) || new Date(a.cree_le) - new Date(b.cree_le);
      });
    }
    return f;
  }

  // code : « reseau », « identifiants »… ou un code métier de la base
  // (INVALID_WEIGHT, INVALID_STATUS_TRANSITION…). detail : pour un code
  // métier, la phrase de la base, écrite pour l'équipe et affichable telle
  // quelle ; pour les autres, un message technique à ne pas montrer.
  function Erreur(code, detail) {
    var e = new Error(detail || code);
    e.code = code;
    e.detail = detail || '';
    e.metier = /^[A-Z_]+$/.test(code);
    return e;
  }

  function choisir(source, champs) {
    var out = {};
    champs.forEach(function (k) { if (source[k] !== undefined) out[k] = source[k]; });
    return out;
  }

  // Adresse d'une page du site dans la langue courante (même dossier)
  function urlPage(nom) {
    return new URL(nom, location.href).href.split('#')[0];
  }

  // Longueur minimale du mot de passe. 6 est le plancher de Supabase : sa
  // console ne descend pas plus bas, et accepter moins ici ne servirait qu'à
  // laisser passer un mot de passe que le serveur refuserait ensuite.
  // À changer aussi dans les formulaires (minlength) et dans l'application
  // (application-mobile/lib/session.js).
  var MDP_MINIMUM = 6;

  // Code client : « GSE- » suivi de 4 chiffres (gse 4323 -> GSE-4323). Les codes
  // plus longs des versions précédentes restent reconnus tels quels : un ancien
  // client garde le sien. En dessous de 4 chiffres, c'est une saisie incomplète.
  function normaliserCode(code) {
    var n = String(code || '').replace(/\D/g, '');
    if (n.length < 4) return '';
    return 'GSE-' + n;
  }

  // Code tiré au hasard, jamais deux fois le même (comptes de démonstration)
  function nouveauCode(comptes) {
    var code;
    do {
      code = 'GSE-' + (1000 + Math.floor(Math.random() * 9000));
    } while (comptes.some(function (c) { return c.code === code; }));
    return code;
  }

  // Texte de recherche sûr pour les filtres (virgules et parenthèses retirées)
  function nettoyer(texte) {
    return String(texte || '').replace(/[,()*%\\:"']/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
  }

  // Dans l'ordre où les événements ont été écrits (leur identifiant), comme
  // la base les rend ; à défaut d'identifiant, par date.
  function trierHistorique(colis) {
    colis.historique = (colis.historique || colis.colis_historique || []).slice().sort(function (a, b) {
      if (a.id != null && b.id != null) return a.id - b.id;
      return new Date(a.cree_le) - new Date(b.cree_le);
    });
    delete colis.colis_historique;
    return colis;
  }

  /* ======================================================================
     Supabase
     ====================================================================== */
  var promesseClient = null;

  function chargerScript(src) {
    return new Promise(function (ok, ko) {
      var s = document.createElement('script');
      s.src = src;
      s.async = true;
      s.onload = ok;
      s.onerror = function () { s.remove(); ko(Erreur('reseau')); };
      document.head.appendChild(s);
    });
  }

  function sb() {
    if (!promesseClient) {
      promesseClient = (window.supabase && window.supabase.createClient ? Promise.resolve() : chargerScript(SUPABASE_JS))
        .then(function () {
          if (!window.supabase || !window.supabase.createClient) throw Erreur('reseau');
          // flowType « implicit » : le lien reçu par e-mail fonctionne même ouvert sur
          // un autre appareil que celui qui l'a demandé (téléphone → ordinateur).
          // Les jetons qu'il dépose dans l'adresse sont effacés aussitôt (nettoyerAdresse).
          var auth = { flowType: 'implicit', persistSession: true, autoRefreshToken: true, detectSessionInUrl: true };
          if (BUREAU && BUREAU.stockageSession) auth.storage = BUREAU.stockageSession;
          return window.supabase.createClient(String(CFG.supabaseUrl).replace(/\/+$/, ''), CFG.supabaseKey, { auth: auth });
        });
      promesseClient.catch(function () { promesseClient = null; });
    }
    return promesseClient;
  }

  // Les liens reçus par e-mail (confirmation, nouveau mot de passe) déposent les
  // jetons de session dans l'adresse de la page (#access_token=…). Une fois la
  // session enregistrée, ils n'ont plus rien à y faire : on les efface de la barre
  // d'adresse et de l'historique du navigateur.
  function nettoyerAdresse() {
    if (!/(access_token|refresh_token|provider_token)=/.test(location.hash)) return;
    try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
  }

  function erreurSupabase(e) {
    if (!e) return Erreur('inconnu');
    if (e.code && /^(identifiants|email-existe|reseau|non-autorise)$/.test(e.code)) return e;
    // Erreur métier levée par la base (public.erreur_metier) : le code est le
    // message, la phrase est le détail, l'indice « goship » les signe. Le refus
    // de permission garde le nom que les pages connaissent déjà.
    if (e.hint === 'goship' && /^[A-Z_]+$/.test(String(e.message || ''))) {
      return Erreur(e.message === 'PERMISSION_DENIED' ? 'non-autorise' : e.message, e.details || '');
    }
    var code = String(e.code || ''), msg = String(e.message || '').toLowerCase(), statut = e.status;
    if (code === 'invalid_credentials' || msg.indexOf('invalid login') >= 0) return Erreur('identifiants');
    if (code === 'user_already_exists' || code === 'email_exists' || msg.indexOf('already registered') >= 0) return Erreur('email-existe');
    if (code === 'same_password' || msg.indexOf('different from the old') >= 0) return Erreur('meme-mot-de-passe');
    if (code === 'weak_password' || msg.indexOf('password should') >= 0) return Erreur('mot-de-passe-faible');
    if (code === 'email_address_invalid' || code === 'validation_failed' || msg.indexOf('invalid format') >= 0) return Erreur('email-invalide');
    if (code === 'email_not_confirmed' || msg.indexOf('not confirmed') >= 0) return Erreur('non-confirme');
    if (code === 'signup_disabled' || code === 'email_provider_disabled') return Erreur('inscriptions-fermees');
    if (statut === 429 || code.indexOf('rate_limit') >= 0) return Erreur('trop-de-tentatives');
    if (code === 'otp_expired' || code === 'session_not_found' || code === 'session_expired') return Erreur('lien-invalide');
    if (code === '42501' || code === 'PGRST301' || statut === 401 || statut === 403) return Erreur('non-autorise');
    // La fonction n'existe pas encore : le script SQL correspondant n'a pas été
    // lancé dans Supabase. Ce n'est pas une panne — la partie du site qui s'en
    // sert se contente de ne pas s'afficher.
    if (code === 'PGRST202' || code === '42883' || code === '42703') return Erreur('absent', e.message);
    if (e.name === 'TypeError' || msg.indexOf('failed to fetch') >= 0 || msg.indexOf('network') >= 0 ||
        msg.indexOf('load failed') >= 0) return Erreur('reseau');
    return Erreur('inconnu', e.message);
  }

  function resultat(res) {
    if (res.error) throw erreurSupabase(res.error);
    return res.data;
  }

  var supabaseAPI = {
    session: function () {
      return sb().then(function (c) { return c.auth.getSession(); }).then(function (res) {
        nettoyerAdresse();
        var s = res.data && res.data.session;
        return s ? { id: s.user.id, email: s.user.email } : null;
      });
    },

    profil: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) return null;
        return sb().then(function (c) {
          return c.from('clients').select('*').eq('id', s.id).maybeSingle();
        }).then(resultat);
      });
    },

    inscrire: function (d) {
      var client;
      return sb().then(function (c) {
        client = c;
        return c.auth.signUp({
          email: d.email,
          password: d.motDePasse,
          options: {
            data: {
              nom_complet: d.nom_complet, pays: d.pays, region: d.region, ville: d.ville,
              adresse: d.adresse, telephone: d.telephone, langue: LANGUE
            },
            emailRedirectTo: urlPage('mon-compte.html')
          }
        });
      }).then(function (res) {
        if (res.error) throw erreurSupabase(res.error);
        var u = res.data.user;
        // Adresse déjà inscrite (réponse volontairement neutre de Supabase)
        if (u && Array.isArray(u.identities) && u.identities.length === 0) throw Erreur('email-existe');
        if (!res.data.session) return { profil: null, confirmation: true };
        return client.from('clients').select('*').eq('id', u.id).maybeSingle().then(resultat).then(function (p) {
          return { profil: p, confirmation: false };
        });
      });
    },

    connecter: function (email, motDePasse) {
      return sb().then(function (c) {
        return c.auth.signInWithPassword({ email: email, password: motDePasse });
      }).then(function (res) {
        if (res.error) throw erreurSupabase(res.error);
        return supabaseAPI.profil();
      });
    },

    deconnecter: function () {
      return sb().then(function (c) { return c.auth.signOut({ scope: 'local' }); });
    },

    // rappel() quand la session se termine sans que la page l'ait demandé :
    // jeton de renouvellement expiré ou révoqué. Rend de quoi arrêter d'écouter.
    surSessionPerdue: function (rappel) {
      var abonnement = null, arrete = false;
      sb().then(function (c) {
        if (arrete) return;
        abonnement = c.auth.onAuthStateChange(function (evenement) {
          if (evenement === 'SIGNED_OUT') rappel();
        }).data.subscription;
      }).catch(function () { /* sans client, pas de session à perdre */ });
      return function () { arrete = true; if (abonnement) abonnement.unsubscribe(); };
    },

    envoyerLienMotDePasse: function (email) {
      return sb().then(function (c) {
        return c.auth.resetPasswordForEmail(email, { redirectTo: urlPage('nouveau-mot-de-passe.html') });
      }).then(resultat).then(function () { return {}; });
    },

    // Page « Nouveau mot de passe » : vrai si le lien reçu par e-mail est valide
    attendreRecuperation: function () {
      var h = location.hash + location.search;
      if (/error_code=|error=/.test(h)) return Promise.resolve(false);
      return supabaseAPI.session().then(function (s) { return !!s; });
    },

    changerMotDePasse: function (motDePasse) {
      return sb().then(function (c) {
        return c.auth.updateUser({ password: motDePasse });
      }).then(resultat).then(function () { return true; });
    },

    modifierProfil: function (champs) {
      return supabaseAPI.session().then(function (s) {
        if (!s) throw Erreur('non-autorise');
        return sb().then(function (c) {
          return c.from('clients').update(choisir(champs, CHAMPS_PROFIL)).eq('id', s.id).select().single();
        }).then(resultat);
      });
    },

    mesColis: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) throw Erreur('non-autorise');
        return sb().then(function (c) {
          return c.from('colis')
            .select('id, numero, suivi_transporteur, expediteur, description, poids_lb, service, pays_destination, ' +
                    'destination, statut, lieu, note, recu_le, cree_le, maj_le, ' +
                    'colis_historique(id, type_evenement, statut, lieu, note, cree_le)')
            .eq('client_id', s.id)
            .order('maj_le', { ascending: false });
        }).then(resultat).then(function (lignes) { return lignes.map(trierHistorique); });
      });
    },

    // Les factures du client, avec leurs lignes et le numéro du colis facturé.
    // Passe par une fonction de la base (mes_factures) : elle sait joindre les
    // colis aux lignes, et elle ne montre que les factures du compte connecté.
    mesFactures: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) throw Erreur('non-autorise');
        return sb().then(function (c) { return c.rpc('mes_factures'); });
      }).then(resultat).then(function (lignes) { return lignes || []; });
    },

    // Le résumé de l'espace client (mon_resume) : ses colis comptés par état,
    // ses factures (facturé, payé, solde, en retard) et ses derniers messages
    monResume: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) throw Erreur('non-autorise');
        return sb().then(function (c) { return c.rpc('mon_resume'); });
      }).then(resultat);
    },

    // Les notifications du client (mes_notifications, outils/supabase-notifications.sql) :
    // la base les écrit, les traduit et compte les non lues ; la page les affiche.
    // o : { filtre: toutes | non_lues | colis | factures | paiements, page, parPage, langue }
    mesNotifications: function (o) {
      o = o || {};
      return sb().then(function (c) {
        return c.rpc('mes_notifications', { p_filtre: o.filtre || 'toutes', p_page: o.page || 0,
                                            p_par_page: o.parPage || 20, p_langue: o.langue || LANGUE });
      }).then(resultat);
    },

    notificationsNonLues: function () {
      return sb().then(function (c) { return c.rpc('notifications_non_lues'); }).then(resultat).then(Number);
    },

    // ids : les notifications à marquer lues ; rien = toutes
    marquerNotificationsLues: function (ids) {
      return sb().then(function (c) {
        return c.rpc('marquer_notifications_lues', { p_ids: ids && ids.length ? ids : null });
      }).then(resultat);
    },

    // { canaux: { push: { configure }, email…, sms… }, preferences: [{ categorie, push, email, whatsapp, sms }] }
    mesPreferencesNotifications: function () {
      return sb().then(function (c) { return c.rpc('mes_preferences_notifications'); }).then(resultat);
    },

    reglerPreferenceNotification: function (categorie, canal, actif) {
      return sb().then(function (c) {
        return c.rpc('regler_preference_notification', { p_categorie: categorie, p_canal: canal, p_actif: !!actif });
      }).then(resultat);
    },

    // Mises à jour en direct. options.tout : tous les colis et clients (administrateur)
    surveiller: function (rappel, options) {
      options = options || {};
      var canal = null, arrete = false;
      Promise.all([sb(), supabaseAPI.session()]).then(function (r) {
        var c = r[0], s = r[1];
        if (arrete || !s) return;
        var filtre = { event: '*', schema: 'public', table: 'colis' };
        var filtreFactures = { event: '*', schema: 'public', table: 'factures' };
        if (!options.tout) {
          filtre.filter = 'client_id=eq.' + s.id;
          filtreFactures.filter = 'client_id=eq.' + s.id;
        }
        canal = c.channel('gse-' + Math.random().toString(36).slice(2))
          .on('postgres_changes', filtre, function () { rappel('colis'); })
          .on('postgres_changes', filtreFactures, function () { rappel('factures'); });
        if (!options.tout) {
          // Une nouvelle notification (supabase-notifications.sql) : le badge se met à jour
          canal.on('postgres_changes', { event: '*', schema: 'public', table: 'notifications',
                                         filter: 'client_id=eq.' + s.id }, function () { rappel('notifications'); });
        }
        if (options.tout) {
          canal.on('postgres_changes', { event: '*', schema: 'public', table: 'clients' }, function () { rappel('clients'); });
        }
        canal.subscribe(function (etat) {
          if (options.etat) options.etat(etat === 'SUBSCRIBED');
        });
      }).catch(function () { if (options.etat) options.etat(false); });
      return function () {
        arrete = true;
        if (canal) sb().then(function (c) { c.removeChannel(canal); });
      };
    },

    suivre: function (numero) {
      return sb().then(function (c) {
        return c.rpc('suivre_colis', { p_numero: String(numero || '').trim() });
      }).then(resultat).then(function (d) { return d ? trierHistorique(d) : null; });
    },

    estAdmin: function () {
      return sb().then(function (c) { return c.rpc('est_admin'); }).then(resultat).then(Boolean);
    },

    // { role, equipe, permissions } du compte connecté, lus dans la base
    // (mes_permissions) : de quoi montrer les bons menus. Chaque action reste
    // revérifiée par la base.
    permissions: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) return { role: null, equipe: false, permissions: [] };
        return sb().then(function (c) { return c.rpc('mes_permissions'); }).then(resultat);
      });
    },

    admin: {
      statistiques: function () {
        return sb().then(function (c) { return c.rpc('statistiques_admin'); }).then(resultat);
      },

      // L'équipe et ses rôles (users.view)
      equipe: function () {
        return sb().then(function (c) { return c.rpc('equipe'); }).then(resultat).then(function (r) { return r || []; });
      },

      // Donner un rôle à un compte, retrouvé par son e-mail (roles.manage)
      changerRole: function (compte, role) {
        return sb().then(function (c) { return c.rpc('changer_role', { p_compte: compte, p_role: role }); })
          .then(resultat);
      },

      colis: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('colis_details').select('*', { count: 'exact' })
            .order('maj_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          if (o.statut === 'actifs') q = q.neq('statut', 'livre');
          else if (o.statut) q = q.eq('statut', o.statut);
          if (o.clientId) q = q.eq('client_id', o.clientId);
          // Filtres prêts pour les écrans à venir (scanner, rapports) : une
          // seule requête, paginée, quel que soit le nombre de critères.
          if (o.pays) q = q.eq('pays_destination', o.pays);
          if (o.service) q = q.eq('service', o.service);
          if (o.depuis) q = q.gte('recu_le', o.depuis);
          if (o.jusqua) q = q.lt('recu_le', o.jusqua);
          var t = nettoyer(o.recherche);
          if (t) {
            q = q.or(['numero', 'suivi_transporteur', 'code_client', 'nom_client', 'telephone_client', 'description', 'destination']
              .map(function (k) { return k + '.ilike."*' + t + '*"'; }).join(','));
          }
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      // Tous les événements du colis, dans l'ordre où ils ont été écrits :
      // type, statut avant et après, auteur, lieu, précisions, corrections.
      historique: function (id) {
        return sb().then(function (c) { return c.rpc('historique_colis', { p_colis: id }); }).then(resultat);
      },

      chercherClient: function (code) {
        var n = normaliserCode(code);
        if (!n) return Promise.resolve(null);
        return sb().then(function (c) {
          return c.from('clients').select('id, code, nom_complet, pays, region, ville, telephone, email, langue')
            .eq('code', n).maybeSingle();
        }).then(resultat);
      },

      clients: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('clients').select('*', { count: 'exact' }).eq('role', 'client')
            .order('cree_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          var t = nettoyer(o.recherche);
          if (t) {
            q = q.or(['code', 'nom_complet', 'telephone', 'email', 'ville', 'region']
              .map(function (k) { return k + '.ilike."*' + t + '*"'; }).join(','));
          }
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      /* ---- Colis : tout passe par les fonctions de service de la base ----
         (outils/supabase-services.sql). Elles vérifient la permission,
         valident, calculent le prix, contrôlent le statut et écrivent
         l'historique et le journal dans une seule transaction. */

      // Réponse : { colis, facture, deja }. « cle » identifie cette demande
      // d'enregistrement : renvoyée après une coupure, elle retrouve le colis
      // déjà créé au lieu d'en créer un second (deja: true).
      creerColis: function (d, cle) {
        return sb().then(function (c) {
          return c.rpc('creer_colis', { p_colis: choisir(d, CHAMPS_CREATION), p_cle: cle || null, p_facturer: true });
        }).then(resultat);
      },

      // majLe : la date de dernière modification que la page avait sous les
      // yeux ; si quelqu'un a modifié le colis entre-temps, la base refuse
      // (CONCURRENT_MODIFICATION) au lieu d'écraser son travail.
      modifierColis: function (id, champs, majLe) {
        return sb().then(function (c) {
          return c.rpc('modifier_colis', { p_id: id, p_champs: choisir(champs, CHAMPS_MODIFIABLES), p_maj_le: majLe || null });
        }).then(resultat);
      },

      // Chaque statut coché devient l'événement qui y mène, écrit par le
      // moteur (outils/supabase-evenements.sql). Tout ou rien. Réponse :
      // { modifies, inchanges, ids, evenements, refus: [{ id, numero, code,
      // detail }] }. attendus : { id: statut affiché } pour repérer un colis
      // changé par quelqu'un d'autre entre-temps. motif : obligatoire pour un
      // retour à l'étape d'avant (correction). cle : la même demande renvoyée
      // ne refait rien.
      changerStatut: function (ids, etape, attendus, motif, cle) {
        return sb().then(function (c) {
          return c.rpc('changer_statut_colis', {
            p_ids: ids, p_statut: etape.statut, p_lieu: etape.lieu || '', p_note: etape.note || '',
            p_attendus: attendus || null, p_motif: motif || null, p_cle: cle || null
          });
        }).then(resultat);
      },

      // Les statuts que ce colis peut prendre maintenant : { actuel, precedent, possibles }
      statutsPossibles: function (id) {
        return sb().then(function (c) { return c.rpc('statuts_possibles', { p_colis: id }); }).then(resultat);
      },

      // Suivi interne : un colis par son numéro GSE ou le suivi du vendeur,
      // avec son historique complet (notes comprises). null s'il n'existe pas.
      /* ---- Le poste de scan (outils/supabase-scanner.sql) ----------------
         Deux appels, une requête chacun. Aucune règle ici : la base cherche,
         valide et écrit ; la page affiche ce qu'elle répond. */

      // Le code lu → la fiche du colis (client, dernier événement, livraison
      // ou action requise, historique, opérations permises), ou null.
      scannerColis: function (reference) {
        return sb().then(function (c) { return c.rpc('scanner_colis', { p_reference: String(reference || '') }); })
          .then(resultat);
      },

      // Le code lu + une opération → le moteur d'événements → { code
      // (« OK » ou « ALREADY_IN_TARGET_STATE »), message, resultat, fiche }.
      // o : { lieu, note, metadonnees, cle, attendu, cible }
      operationScanner: function (reference, type, o) {
        o = o || {};
        return sb().then(function (c) {
          return c.rpc('scanner_operation', {
            p_reference: String(reference || ''), p_type: type, p_lieu: o.lieu == null ? null : o.lieu,
            p_note: o.note == null ? null : o.note, p_metadonnees: avecPoste(o.metadonnees), p_cle: o.cle || null,
            p_statut_attendu: o.attendu || null, p_cible: o.cible || null
          });
        }).then(resultat);
      },

      trouverColis: function (reference) {
        return sb().then(function (c) { return c.rpc('trouver_colis', { p_reference: String(reference || '') }); })
          .then(resultat);
      },

      // Journal d'audit, du plus récent au plus ancien (équipe uniquement)
      journal: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('journal_audit').select('*', { count: 'exact' })
            .order('cree_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          if (o.entite) q = q.eq('entite', o.entite);
          if (o.entiteId) q = q.eq('entite_id', String(o.entiteId));
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      supprimerColis: function (id) {
        return sb().then(function (c) { return c.from('colis').delete().eq('id', id); }).then(resultat);
      },

      /* ---- Notifications (outils/supabase-notifications.sql) ------------------
         La base prévient le client à chaque étape, selon ses règles : aucune page
         n'envoie d'e-mail ni de WhatsApp. Ici, on regarde ce qui est parti. */

      // Les envois d'un colis (fiche « Mettre à jour », dialogue d'enregistrement)
      envoisColis: function (id) {
        return sb().then(function (c) { return c.rpc('envois_colis', { p_colis: id }); }).then(resultat);
      },

      // Le centre des envois : totaux par statut et canal, alertes, liste paginée.
      // o : { debut, fin, type, canal, statut, page, parPage }
      centreNotifications: function (o) {
        o = o || {};
        return sb().then(function (c) {
          return c.rpc('centre_notifications', {
            p_debut: o.debut || null, p_fin: o.fin || null, p_type: o.type || null, p_canal: o.canal || null,
            p_statut: o.statut || null, p_page: o.page || 0, p_par_page: o.parPage || 25
          });
        }).then(resultat);
      },

      // Événement → notification → envois, pour une notification
      suiviNotification: function (id) {
        return sb().then(function (c) { return c.rpc('suivi_notification', { p_notification: id }); }).then(resultat);
      },

      // { modifiable, canaux: { push: true… }, regles: [...] }
      reglesNotifications: function () {
        return sb().then(function (c) { return c.rpc('regles_notifications'); }).then(resultat);
      },

      modifierRegleNotification: function (type, actif, canaux) {
        return sb().then(function (c) {
          return c.rpc('modifier_regle_notification', { p_type: type, p_actif: !!actif, p_canaux: canaux || [] });
        }).then(resultat);
      },

      // Un essai vers son propre compte (une fois par minute), pour vérifier un canal
      testerNotification: function (canal) {
        return sb().then(function (c) { return c.rpc('tester_notification', { p_canal: canal }); }).then(resultat);
      },

      /* ---- Factures ---------------------------------------------------- */

      // Les factures, avec leur payé, leur solde et leur état calculés par la
      // base (colonnes calculées de outils/supabase-finances.sql), leurs lignes
      // et tous leurs paiements. o.etat : « a_payer » (tout ce qui reste dû),
      // « partielle », « en_retard », « payee », « annulee », ou rien.
      factures: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('factures')
            .select('*, paye_usd, solde_usd, etat_paiement, ' +
                    'clients(code, nom_complet, telephone, email, adresse, region, ville, pays, langue), ' +
                    'facture_lignes(id, colis_id, libelle, montant_usd, quantite, poids_lb, tarif_lb_usd, ' +
                    'colis(numero, description, poids_lb)), paiements(*)',
                    { count: 'exact' })
            .order('cree_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          var etat = o.etat || o.statut;
          if (etat === 'payee' || etat === 'annulee' || etat === 'a_payer') q = q.eq('statut', etat);
          if (etat === 'partielle') q = q.eq('statut', 'a_payer').gt('montant_paye_usd', 0);
          if (etat === 'en_retard') q = q.eq('statut', 'a_payer').lt('echeance_le', aujourdhui());
          if (o.client_id) q = q.eq('client_id', o.client_id);
          if (o.id) q = q.eq('id', o.id);
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          (res.data || []).forEach(trierPaiements);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      // Une facture pour des colis d'un même client (leurs prix + les frais de
      // service, calculés par la base), ou d'un montant libre sans colis.
      // Réponse : { facture, deja }. La facture et ses lignes sont écrites
      // ensemble : plus de facture sans lignes si la connexion coupe entre les deux.
      creerFacture: function (d, colisIds, cle) {
        return sb().then(function (c) {
          return c.rpc('creer_facture', {
            p_client: d.client_id,
            p_colis: colisIds && colisIds.length ? colisIds : null,
            p_champs: choisir(d, CHAMPS_NOUVELLE_FACTURE),
            p_cle: cle || null
          });
        }).then(resultat);
      },

      // La facture d'un colis, créée s'il n'en a pas encore : { facture, deja }
      facturerColis: function (colisId) {
        return sb().then(function (c) { return c.rpc('facturer_colis', { p_colis: colisId }); }).then(resultat);
      },

      // La facture d'un colis, pour le bouton « Voir la facture » de sa fiche.
      // La plus récente si le colis a été refacturé.
      factureDuColis: function (colisId) {
        return sb().then(function (c) {
          return c.from('facture_lignes')
            .select('facture_id, factures!inner(*, paye_usd, solde_usd, etat_paiement, ' +
                    'clients(code, nom_complet, telephone, email, adresse, ville, region, pays, langue), ' +
                    'facture_lignes(*, colis(numero, description, poids_lb)), paiements(*))')
            .eq('colis_id', colisId);
        }).then(resultat).then(function (lignes) {
          var factures = (lignes || []).map(function (l) { return l.factures; }).filter(Boolean);
          factures.sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); });
          return trierPaiements(factures[0]) || null;
        });
      },

      // Échéance, note, lien de paiement ; le total d'une facture sans colis.
      // Le reste suit les paiements : la base refuse qu'on l'écrive ici.
      modifierFacture: function (id, champs) {
        return sb().then(function (c) {
          return c.from('factures').update(choisir(champs, CHAMPS_FACTURE)).eq('id', id).select().single();
        }).then(resultat);
      },

      /* ---- Paiements (outils/supabase-finances.sql) -------------------- */

      // Un encaissement : { montant_usd, moyen, reference, paye_le, note }.
      // « cle » identifie la demande : renvoyée après une coupure, elle rend
      // le paiement déjà enregistré. Réponse : { paiement, facture, deja }.
      enregistrerPaiement: function (factureId, d, cle) {
        return sb().then(function (c) {
          return c.rpc('enregistrer_paiement', {
            p_facture: factureId, p_paiement: choisir(d || {}, CHAMPS_PAIEMENT), p_cle: cle || null
          });
        }).then(resultat).then(function (r) { if (r && r.facture) trierPaiements(r.facture); return r; });
      },

      // Le lien de paiement d'une facture : invoices.edit, ou le premier lien
      // d'une facture neuve pour qui enregistre les colis
      poserLienPaiement: function (id, lien) {
        return sb().then(function (c) { return c.rpc('definir_lien_paiement', { p_facture: id, p_lien: lien }); })
          .then(resultat);
      },

      // Un paiement saisi par erreur, un chèque rejeté : il reste, barré, avec son motif
      annulerPaiement: function (id, motif) {
        return sb().then(function (c) {
          return c.rpc('annuler_paiement', { p_paiement: id, p_motif: motif || '' });
        }).then(resultat).then(function (r) { if (r && r.facture) trierPaiements(r.facture); return r; });
      },

      // Une facture ne se supprime plus : elle s'annule, avec son motif.
      // Réponse : { facture, deja }.
      annulerFacture: function (id, motif) {
        return sb().then(function (c) {
          return c.rpc('annuler_facture', { p_facture: id, p_motif: motif || '' });
        }).then(resultat);
      },

      // Plusieurs factures d'un client en une : { facture, annulees, deja }
      regrouperFactures: function (ids, cle) {
        return sb().then(function (c) {
          return c.rpc('regrouper_factures', { p_factures: ids, p_cle: cle || null });
        }).then(resultat).then(function (r) { if (r && r.facture) trierPaiements(r.facture); return r; });
      },

      // Ce que la base facturerait pour ces colis, sans rien créer :
      // { lignes, sous_total, frais_service, total }
      calculerFacture: function (colisIds) {
        return sb().then(function (c) { return c.rpc('calculer_facture', { p_colis: colisIds || [] }); })
          .then(resultat);
      },

      // Les chiffres du haut de l'onglet Factures
      resumeFacturation: function () {
        return sb().then(function (c) { return c.rpc('resume_facturation'); }).then(resultat);
      },

      // Le rapport d'anomalies : [{ type, gravite, facture_id, numero, detail }]
      anomaliesFacturation: function () {
        return sb().then(function (c) { return c.rpc('rapport_anomalies_facturation'); }).then(resultat)
          .then(function (r) { return r || []; });
      },

      /* ---- Analytics (outils/supabase-analytics.sql) ---------------------
         Ce qui s'est passé et comment cela évolue, période contre période
         précédente. Tout est compté par la base (reports.view) ; la page
         n'agrège rien. module : synthese, serie, operations, clients,
         finances, routes, scanner, qualite. o : { periode, debut, fin,
         granularite (jour, semaine, mois), tri, page, parPage }. */
      analytics: function (module, o) {
        o = o || {};
        var RPC = { synthese: 'analytics_synthese', serie: 'analytics_serie', operations: 'analytics_operations',
                    clients: 'analytics_clients', finances: 'analytics_finances', routes: 'analytics_routes',
                    scanner: 'analytics_scanner', qualite: 'analytics_qualite' };
        if (!RPC[module]) return Promise.reject(Erreur('INVALID_INPUT', 'Module inconnu : ' + module + '.'));
        var params = {};
        if (module !== 'qualite') {
          params = { p_periode: o.periode || '30j', p_debut: o.debut || null, p_fin: o.fin || null };
        }
        if (module === 'serie') params.p_granularite = o.granularite || 'jour';
        if (module === 'clients') {
          var parPage = o.parPage || 25;
          params.p_tri = o.tri || 'colis';
          params.p_limite = parPage;
          params.p_decalage = (o.page || 0) * parPage;
        }
        return sb().then(function (c) { return c.rpc(RPC[module], params); }).then(resultat);
      },

      /* ---- Tableau de bord (outils/supabase-tableau-de-bord.sql) -------
         Chaque chiffre est compté par la base, sur les vraies tables et avec
         leurs règles : la page n'additionne rien. Une partie que le rôle ne
         peut pas voir n'est tout simplement pas dans la réponse. */

      // o : { periode (aujourdhui, 7j, 30j, mois, mois_precedent, annee,
      // personnalise), debut, fin (AAAA-MM-JJ, pour « personnalise »), jours
      // (sans mouvement au-delà de, 7 par défaut) }
      vueGenerale: function (o) {
        o = o || {};
        return sb().then(function (c) {
          return c.rpc('vue_generale', {
            p_periode: o.periode || '30j', p_debut: o.debut || null, p_fin: o.fin || null, p_jours: o.jours || 7
          });
        }).then(resultat);
      },

      // liste : « action_requise » ou « sans_mouvement ». Réponse : { liste,
      // jours, total, lignes }, les plus anciens d'abord.
      colisATraiter: function (liste, o) {
        o = o || {};
        var parPage = o.parPage || 25, page = o.page || 0;
        return sb().then(function (c) {
          return c.rpc('colis_a_traiter', {
            p_liste: liste, p_jours: o.jours || 7, p_limite: parPage, p_decalage: page * parPage
          });
        }).then(resultat);
      },

      // Un n° de colis, de suivi, de facture, un code-barres ou le QR d'une
      // étiquette, un nom, un téléphone, un e-mail : { colis, clients, factures }
      rechercheRapide: function (texte) {
        return sb().then(function (c) { return c.rpc('recherche_rapide', { p_texte: String(texte || '') }); })
          .then(resultat);
      },

      // L'onglet Clients : o = { recherche, tri (recent, nom, solde, activite,
      // colis), filtre (tous, avec_solde, avec_colis), page, parPage }.
      // Réponse : { lignes, total, finances }
      clientsSoldes: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          return c.rpc('clients_soldes', {
            p_recherche: nettoyer(o.recherche) || null, p_tri: o.tri || 'recent', p_filtre: o.filtre || 'tous',
            p_limite: parPage, p_decalage: page * parPage
          });
        }).then(resultat);
      },

      // Copie le logo des e-mails dans le dossier public de Supabase s'il n'y est pas encore
      preparerLogo: function (logo) {
        var publique = String(CFG.supabaseUrl).replace(/\/+$/, '') + '/storage/v1/object/public/' +
          logo.dossier + '/' + logo.fichier;
        return fetch(publique, { method: 'HEAD', cache: 'no-store' }).then(function (r) {
          if (r.ok) return 'present';
          return fetch(logo.source).then(function (image) {
            if (!image.ok) throw Erreur('inconnu', 'fichier ' + logo.source + ' introuvable');
            return image.blob();
          }).then(function (image) {
            return sb().then(function (c) {
              return c.storage.from(logo.dossier).upload(logo.fichier, image,
                { upsert: true, contentType: 'image/png', cacheControl: '604800' });
            });
          }).then(function (res) {
            if (res.error) throw Erreur('inconnu', res.error.message);
            return 'envoye';
          });
        });
      }
    }
  };

  /* ======================================================================
     Démonstration (données dans ce navigateur uniquement)
     ====================================================================== */
  var CLE_DONNEES = 'gse-demo-donnees';
  var CLE_SESSION = 'gse-demo-session';
  var CLE_RECUP = 'gse-demo-recuperation';
  var ADMIN_DEMO = { email: 'admin@goship.demo', motDePasse: 'demo1234' };
  // Un compte de démonstration par rôle de l'équipe, même mot de passe
  var EQUIPE_DEMO = [
    { id: 'admin-demo', email: ADMIN_DEMO.email, role: 'admin', nom: 'Équipe Goship Express' },
    { id: 'gerant-demo', email: 'gerant@goship.demo', role: 'gerant', nom: 'Gérant (démonstration)' },
    { id: 'employe-demo', email: 'employe@goship.demo', role: 'employe', nom: 'Employé (démonstration)' }
  ];
  var abonnes = [];

  // Stockage du navigateur ; s'il est bloqué (fichier ouvert directement dans Safari,
  // navigation privée…), les données restent dans la mémoire de la page.
  var memoire = {};
  var stockageBloque = false;
  function stockage(action, cle, valeur) {
    if (!stockageBloque) {
      try {
        if (action === 'lire') return localStorage.getItem(cle);
        if (action === 'ecrire') localStorage.setItem(cle, valeur);
        if (action === 'effacer') localStorage.removeItem(cle);
        return null;
      } catch (e) {
        stockageBloque = true;
      }
    }
    if (action === 'lire') return Object.prototype.hasOwnProperty.call(memoire, cle) ? memoire[cle] : null;
    if (action === 'ecrire') memoire[cle] = String(valeur);
    if (action === 'effacer') delete memoire[cle];
    return null;
  }

  function empreinte(texte) {
    // Démonstration uniquement : les vrais mots de passe sont gérés par Supabase.
    var h = 2166136261;
    var s = 'goship-demo:' + texte;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h.toString(16);
  }

  function identifiant() {
    return 'd' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  function maintenant() { return new Date().toISOString(); }

  function compteEquipeDemo(e) {
    return {
      id: e.id, email: e.email, mdp: empreinte(ADMIN_DEMO.motDePasse), role: e.role, code: null,
      nom_complet: e.nom, pays: 'US', region: 'Florida', ville: 'Medley',
      adresse: '8140 NW 74th Ave, Unit 3', telephone: '+1 849 538-6262', langue: 'fr', cree_le: maintenant()
    };
  }

  function nouvellesDonnees() {
    return { v: 1, seqColis: 1000, comptes: EQUIPE_DEMO.map(compteEquipeDemo), colis: [], historique: [] };
  }

  function lireDonnees() {
    try {
      var d = JSON.parse(stockage('lire', CLE_DONNEES));
      if (d && d.v === 1) {
        // Données d'avant la Phase 6 : on ajoute le gérant et l'employé de démonstration
        EQUIPE_DEMO.forEach(function (e) {
          if (!d.comptes.some(function (c) { return c.id === e.id; })) d.comptes.push(compteEquipeDemo(e));
        });
        return d;
      }
    } catch (e) { /* données illisibles : on repart de zéro */ }
    return nouvellesDonnees();
  }

  // « quoi » dit ce qui a changé, comme le fait le temps réel de Supabase :
  // les pages ne rechargent ainsi que la liste concernée.
  function ecrireDonnees(d, quoi) {
    stockage('ecrire', CLE_DONNEES, JSON.stringify(d));
    prevenir(quoi || 'colis');
  }

  function prevenir(quoi) {
    abonnes.slice().forEach(function (a) { a(quoi); });
  }

  window.addEventListener('storage', function (e) {
    if (e.key === CLE_DONNEES) prevenir('colis');
  });

  // Délai d'un vrai serveur, pour voir les états de chargement
  function plusTard(valeur) {
    return new Promise(function (ok) { setTimeout(function () { ok(valeur); }, 180 + Math.random() * 220); });
  }
  function echec(code) {
    return new Promise(function (ok, ko) { setTimeout(function () { ko(Erreur(code)); }, 220); });
  }

  function publicProfil(compte) {
    if (!compte) return null;
    var p = {};
    Object.keys(compte).forEach(function (k) { if (k !== 'mdp') p[k] = compte[k]; });
    return p;
  }

  function compteConnecte(d) {
    var id = stockage('lire', CLE_SESSION);
    if (!id) return null;
    for (var i = 0; i < d.comptes.length; i++) if (d.comptes[i].id === id) return d.comptes[i];
    return null;
  }

  function trouverCompte(d, email) {
    email = String(email || '').trim().toLowerCase();
    for (var i = 0; i < d.comptes.length; i++) if (d.comptes[i].email === email) return d.comptes[i];
    return null;
  }

  // Ce que voient le client et le suivi public : ni les opérations internes,
  // ni une étape annulée par une correction (règle historique_lecture et
  // suivre_colis dans outils/supabase.sql). tout : la vue de l'équipe.
  function evenementVisible(h, liste) {
    if (h.visibilite === 'interne') return false;
    return h.id == null || !liste.some(function (x) { return x.corrige_id === h.id; });
  }

  function avecHistorique(d, c, tout) {
    var x = JSON.parse(JSON.stringify(c));
    var liste = historiqueDe(d, c.id);
    x.historique = liste.filter(function (h) { return tout || evenementVisible(h, liste); })
      .map(function (h) {
        return { statut: h.statut, lieu: h.lieu, note: h.note, cree_le: h.cree_le, type_evenement: h.type_evenement || null };
      });
    return x;
  }

  // Un événement tel que le rend la base (evenement_json)
  function evenementJson(d, h) {
    var auteur = d.comptes.filter(function (c) { return c.id === h.auteur_id; })[0];
    return {
      id: h.id, colis_id: h.colis_id, type_evenement: h.type_evenement || null,
      statut_precedent: h.statut_precedent == null ? null : h.statut_precedent, statut: h.statut,
      lieu: h.lieu || '', note: h.note || '', metadonnees: h.metadonnees || {},
      auteur_id: h.auteur_id || null, auteur_role: h.auteur_role || null,
      auteur: auteur ? (auteur.nom_complet || auteur.email) : null,
      visibilite: h.visibilite || 'publique', corrige_id: h.corrige_id == null ? null : h.corrige_id,
      corrige: h.id != null && d.historique.some(function (x) { return x.corrige_id === h.id; }),
      cree_le: h.cree_le
    };
  }

  function detailsColis(d, c) {
    var x = JSON.parse(JSON.stringify(c));
    var cl = null;
    for (var i = 0; i < d.comptes.length; i++) if (d.comptes[i].id === c.client_id) cl = d.comptes[i];
    x.code_client = cl ? cl.code : null;
    x.nom_client = cl ? cl.nom_complet : null;
    x.telephone_client = cl ? cl.telephone : null;
    x.email_client = cl ? cl.email : null;
    // Adresse et région : l'étiquette d'expédition s'en sert (voir la vue
    // colis_details dans outils/supabase.sql, partie 4)
    x.adresse_client = cl ? cl.adresse : null;
    x.region_client = cl ? cl.region : null;
    x.ville_client = cl ? cl.ville : null;
    x.pays_client = cl ? cl.pays : null;
    x.langue_client = cl ? cl.langue : null;
    return x;
  }

  // L'événement écrit quand un colis naît (completer_evenement, chemin de la
  // création) : COLIS_RECU, sans statut précédent, par le compte connecté.
  function historiser(d, c, date) {
    var h = historiqueDe(d, c.id);
    var avant = h.length ? h[h.length - 1].statut : null;
    var moi = compteConnecte(d);
    d.seqEvenement = (d.seqEvenement || 0) + 1;
    d.historique.push({
      id: d.seqEvenement, colis_id: c.id, statut: c.statut, lieu: c.lieu || '', note: c.note || '',
      type_evenement: !avant ? 'COLIS_RECU'
        : (avant === c.statut ? 'MISE_A_JOUR' : (typePourStatut(avant, c.statut, null) || 'MISE_A_JOUR')),
      statut_precedent: avant, auteur_id: moi ? moi.id : null, auteur_role: moi ? moi.role : null,
      metadonnees: avant ? {} : { source: 'creation' }, cle_idempotence: null, visibilite: 'publique',
      corrige_id: null, cree_le: date || maintenant()
    });
    notifierEtapeDemo(d, d.historique[d.historique.length - 1]);
  }

  // Les opérations du poste de scan, et la fiche qu'il affiche : même
  // contenu que operations_du_scanner et fiche_scanner (supabase-scanner.sql).
  var OPERATIONS_SCANNER = ['COLIS_INSPECTE', 'COLIS_EMBALLE', 'COLIS_CONSOLIDE', 'COLIS_CHARGE', 'COLIS_EXPEDIE',
                            'COLIS_ARRIVE', 'COLIS_TRANSFERE', 'COLIS_DISPONIBLE', 'COLIS_LIVRE', 'ACTION_REQUISE',
                            'ACTION_RESOLUE'];

  function colisParReference(d, reference) {
    var r = String(reference || '').trim().toUpperCase();
    return d.colis.filter(function (x) { return x.numero === r; })[0] ||
      d.colis.filter(function (x) { return x.suivi_transporteur && x.suivi_transporteur === r; })
        .sort(function (a, b) { return new Date(b.maj_le) - new Date(a.maj_le); })[0] || null;
  }

  function ficheScanner(d, c) {
    var liste = historiqueDe(d, c.id);
    var precedent = statutPrecedent(liste, c.statut);
    var cl = d.comptes.filter(function (x) { return x.id === c.client_id; })[0];
    function derniere(statut) {
      var e = liste.filter(function (h) { return h.statut === statut && h.id != null && evenementVisible(h, liste); }).pop();
      return e ? evenementJson(d, e) : null;
    }
    return {
      colis: {
        id: c.id, numero: c.numero, suivi_transporteur: c.suivi_transporteur || '', description: c.description || '',
        expediteur: c.expediteur || '', poids_lb: c.poids_lb, service: c.service, pays_destination: c.pays_destination,
        destination: c.destination || '', statut: c.statut, lieu: c.lieu || '', note: c.note || '',
        recu_le: c.recu_le, maj_le: c.maj_le, prix_usd: prixColis(c)
      },
      client: cl ? { code: cl.code, nom_complet: cl.nom_complet, ville: cl.ville, pays: cl.pays } : null,
      origine: 'Miami (Medley), FL',
      precedent: precedent,
      dernier_evenement: liste.length ? evenementJson(d, liste[liste.length - 1]) : null,
      livraison: c.statut === 'livre' ? derniere('livre') : null,
      action_requise: c.statut === 'incident' ? derniere('incident') : null,
      operations: OPERATIONS_SCANNER.filter(function (k) {
        return !validerOperation(c.statut, precedent, k, null).code;
      }).map(function (k) {
        var cible = validerOperation(c.statut, precedent, k, null).cible;
        return { type: k, libelle: TYPES_EVENEMENT[k].libelle, statut: cible, change_statut: cible !== c.statut,
                 lieu_requis: TYPES_EVENEMENT[k].lieu_requis };
      }),
      historique: liste.map(function (h) { return evenementJson(d, h); })
    };
  }

  function resultatOperation(d, colisId, e, deja) {
    var c = trouverColisDemo(d, colisId);
    return {
      deja: deja,
      change_statut: !deja && !!e && e.statut_precedent !== e.statut,
      colis: c ? { id: c.id, numero: c.numero, statut: c.statut, lieu: c.lieu || '', note: c.note || '', maj_le: c.maj_le } : null,
      evenement: e ? evenementJson(d, e) : null
    };
  }

  // executer_operation, version démonstration : mêmes étapes, mêmes refus.
  // o : { lieu, note, metadonnees, cle, attendu, cible, motif }
  function operationDemo(d, moi, colisId, type, o) {
    o = o || {};
    var v = String(type || '').trim().toUpperCase();
    var t = TYPES_EVENEMENT[v];
    if (!t) throw Erreur('EVENT_TYPE_INVALID', 'Type d\u2019événement inconnu : ' + (type || '(vide)') + '.');
    // Chaque type a sa permission : scanner, changer le statut, corriger
    if (!peutCompte(moi, t.permission)) {
      throw Erreur('non-autorise', 'Action « ' + t.permission + ' » réservée : reconnectez-vous avec un compte autorisé.');
    }
    var meta = o.metadonnees == null ? {} : o.metadonnees;
    if (typeof meta !== 'object' || Array.isArray(meta)) {
      throw Erreur('INVALID_EVENT_DATA', 'Les précisions d\u2019un événement sont un objet JSON.');
    }
    var texteMeta = JSON.stringify(meta);
    if (texteMeta.length > 4000) throw Erreur('INVALID_EVENT_DATA', 'Précisions trop longues (4 000 caractères au plus).');
    if (/"[^"]*(pass|mot_de_passe|secret|token|jeton|api_?key|cle_api|service_role)[^"]*"\s*:/i.test(texteMeta)) {
      throw Erreur('INVALID_EVENT_DATA', 'Aucun mot de passe, jeton ni clé dans les précisions d\u2019un événement.');
    }
    var motif = String(o.motif || '').trim().slice(0, 300);
    if (t.special === 'correction') {
      if (!motif) throw Erreur('INVALID_EVENT_DATA', 'Une correction exige son motif.');
      meta = Object.assign({}, meta, { motif: motif });
    }
    if (o.lieu != null && String(o.lieu).length > 80) throw Erreur('INVALID_LOCATION', 'Lieu trop long (80 caractères au plus).');
    if (o.note != null && String(o.note).length > 300) {
      throw Erreur('INVALID_EVENT_DATA', 'Message trop long (300 caractères au plus).');
    }
    var cle = o.cle ? String(o.cle).trim() : null;
    if (cle) {
      var connu = d.historique.filter(function (h) { return h.cle_idempotence === cle; })[0];
      if (connu) {
        if (connu.colis_id !== colisId || connu.type_evenement !== v) {
          throw Erreur('DUPLICATE_OPERATION', 'Cette clé de requête a déjà servi pour une autre opération.');
        }
        return resultatOperation(d, colisId, connu, true);
      }
    }
    var c = trouverColisDemo(d, colisId);
    if (!c) throw Erreur('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
    var liste = historiqueDe(d, c.id);
    var precedent = statutPrecedent(liste, c.statut);
    var dernier = liste[liste.length - 1] || null;

    if (o.attendu && o.attendu !== c.statut) {
      if (dernier && dernier.type_evenement === v && (!t.statut || t.statut === c.statut)) {
        return resultatOperation(d, c.id, dernier, true);
      }
      throw Erreur('STATUS_CONFLICT', c.numero + ' est passé à « ' + LIBELLES[c.statut] + ' » entre-temps : rechargez-le.');
    }
    var r = validerOperation(c.statut, precedent, v, o.cible || null);
    if (r.code === 'STATUS_ALREADY_SET' && dernier && dernier.type_evenement === v) {
      return resultatOperation(d, c.id, dernier, true);
    }
    if (r.code) throw Erreur(r.code, c.numero + ' — ' + r.detail);
    var cible = r.cible, lieu, note;

    if (!t.statut && (!t.special || t.special === 'mise_a_jour')) {
      lieu = String(o.lieu != null ? o.lieu : (c.lieu || '')).trim();
      note = String(o.note != null ? o.note : (t.special === 'mise_a_jour' ? (c.note || '') : '')).trim();
    } else if (t.special === 'correction' || t.special === 'sortie') {
      var etape = liste.filter(function (h) {
        return h.statut === cible && h.visibilite !== 'interne' && evenementVisible(h, liste);
      }).pop();
      lieu = String(o.lieu != null ? o.lieu : (etape ? etape.lieu || '' : '')).trim();
      note = String(o.note != null ? o.note : (etape ? etape.note || '' : '')).trim();
    } else {
      lieu = String(o.lieu || '').trim();
      note = String(o.note || '').trim();
    }
    if (t.lieu_requis && !lieu) throw Erreur('LOCATION_REQUIRED', 'Indiquez l\u2019agence où le client peut retirer son colis.');
    if (t.special === 'mise_a_jour' && (c.lieu || '') === lieu && (c.note || '') === note) {
      return resultatOperation(d, c.id, dernier, true);
    }
    if (!t.statut && !t.special && dernier && dernier.type_evenement === v && dernier.lieu === lieu &&
        (dernier.note || '') === note && Date.now() - new Date(dernier.cree_le).getTime() < 120e3) {
      return resultatOperation(d, c.id, dernier, true);
    }
    var corrige = null;
    if (t.special === 'correction') {
      var annule = liste.filter(function (h) {
        return h.statut === c.statut && h.visibilite !== 'interne' && evenementVisible(h, liste);
      }).pop();
      corrige = annule ? annule.id : null;
    }

    d.seqEvenement = (d.seqEvenement || 0) + 1;
    var e = {
      id: d.seqEvenement, colis_id: c.id, type_evenement: v, statut_precedent: c.statut, statut: cible,
      lieu: lieu, note: note, metadonnees: meta, auteur_id: moi ? moi.id : null, auteur_role: moi ? moi.role : null,
      cle_idempotence: cle, visibilite: t.visibilite, corrige_id: corrige, cree_le: maintenant()
    };
    d.historique.push(e);
    notifierEtapeDemo(d, e);
    if (cible !== c.statut || t.special === 'mise_a_jour') {
      var avant = { statut: c.statut, lieu: c.lieu || '', note: c.note || '' };
      c.statut = cible;
      c.lieu = lieu;
      c.note = note;
      c.maj_le = maintenant();
      var diff = difference(avant, c, ['statut', 'lieu', 'note']);
      if (diff) {
        journaliser(d, moi, avant.statut !== cible ? 'colis.statut' : 'colis.modification', 'colis', c.id,
                    diff.avant, diff.apres);
      }
    }
    if (t.special === 'correction') {
      journaliser(d, moi, 'colis.correction', 'colis', c.id, { statut: e.statut_precedent, evenement: corrige },
                  { statut: cible, evenement: e.id, motif: motif });
    }
    return resultatOperation(d, c.id, e, false);
  }

  // exiger_permission de la base : le compte connecté a-t-il cette permission ?
  // Le refus a le code que le site reçoit en ligne (« non-autorise »).
  function exiger(d, action) {
    var moi = compteConnecte(d);
    if (!peutCompte(moi, action)) throw Erreur('non-autorise');
    return moi;
  }

  /* ---- Les règles métier, version démonstration ---------------------------
     La copie, dans le navigateur, de regles_colis et des fonctions de service
     de outils/supabase-services.sql : mêmes contrôles, mêmes codes d'erreur,
     mêmes phrases. Toute règle changée là-bas se change ici, et
     outils/essais-services/essai-demo.js rejoue les mêmes cas des deux côtés.
     Aucune écriture n'a lieu tant que tout n'est pas validé : une erreur au
     milieu laisse les données telles qu'elles étaient, comme une transaction.
     -------------------------------------------------------------------------- */
  function rejeter(e) {
    return new Promise(function (ok, ko) { setTimeout(function () { ko(e); }, 220); });
  }

  // « 4,5 », 4.5 ou « » : un nombre, null, ou l'erreur métier demandée
  function lireNombre(valeur, code, detail) {
    if (valeur == null || String(valeur).trim() === '') return null;
    var n = Number(String(valeur).replace(',', '.').trim());
    if (!isFinite(n)) throw Erreur(code, detail);
    return n;
  }

  function historiqueDe(d, id) {
    return d.historique.filter(function (h) { return h.colis_id === id; });
  }

  function trouverColisDemo(d, id) {
    return d.colis.filter(function (x) { return x.id === id; })[0] || null;
  }

  // Le journal d'audit : ce qui a changé, et par qui
  function journaliser(d, moi, action, entite, id, avant, apres) {
    d.journal = d.journal || [];
    d.journal.push({ id: d.journal.length + 1, auteur_id: moi ? moi.id : null, action: action, entite: entite,
                     entite_id: String(id), avant: avant || null, apres: apres || null, cree_le: maintenant() });
  }

  function difference(avant, apres, champs) {
    var a = {}, b = {}, n = 0;
    champs.forEach(function (k) {
      if (JSON.stringify(avant[k]) !== JSON.stringify(apres[k])) { a[k] = avant[k]; b[k] = apres[k]; n++; }
    });
    return n ? { avant: a, apres: b } : null;
  }

  var RESUME_COLIS = ['numero', 'client_id', 'statut', 'poids_lb', 'tarif_lb_usd', 'prix_usd', 'service',
                      'pays_destination', 'suivi_transporteur', 'description', 'expediteur', 'destination',
                      'recu_le', 'lieu', 'note'];

  // regles_colis : c est le colis tel qu'il sera écrit, avant la version
  // précédente (null à la création). Complète c (tarif, prix, textes bornés)
  // ou lève l'erreur métier.
  function reglesColis(d, c, avant) {
    var nouveau = !avant;
    function change(k) { return nouveau || c[k] !== avant[k]; }
    c.description = String(c.description || '').trim().slice(0, 300);
    c.expediteur = String(c.expediteur || '').trim().slice(0, 80);
    c.destination = String(c.destination || '').trim().slice(0, 80);
    c.lieu = String(c.lieu || '').trim().slice(0, 80);
    c.note = String(c.note || '').trim().slice(0, 300);
    c.suivi_transporteur = String(c.suivi_transporteur || '').trim().toUpperCase().slice(0, 60);

    if (change('client_id')) {
      if (nouveau && !c.client_id) throw Erreur('CLIENT_NOT_FOUND', 'Choisissez le client à qui appartient ce colis.');
      if (c.client_id && !d.comptes.some(function (x) { return x.id === c.client_id && x.role === 'client'; })) {
        throw Erreur('CLIENT_NOT_FOUND', 'Aucun client avec cet identifiant.');
      }
    }
    if (change('description') && !c.description) throw Erreur('INVALID_DESCRIPTION', 'Décrivez le contenu du colis.');
    if (change('poids_lb')) {
      if (c.poids_lb == null || !(c.poids_lb > 0)) {
        throw Erreur('INVALID_WEIGHT', 'Le poids doit être supérieur à zéro, en livres.');
      }
      if (c.poids_lb > 10000) throw Erreur('INVALID_WEIGHT', 'Poids supérieur à 10 000 lb : vérifiez la saisie.');
    }
    if (change('service') && ['aerien', 'maritime', 'terrestre'].indexOf(c.service) < 0) {
      throw Erreur('INVALID_SERVICE', 'Service inconnu : aérien, maritime ou terrestre.');
    }
    if (change('pays_destination') && ['HT', 'DO', 'US'].indexOf(c.pays_destination) < 0) {
      throw Erreur('INVALID_DESTINATION', 'Destination inconnue : HT, DO ou US.');
    }
    if (change('recu_le') && new Date(c.recu_le).getTime() > Date.now() + 36e5) {
      throw Erreur('INVALID_DATE', 'La date de réception ne peut pas être dans le futur.');
    }
    if (c.suivi_transporteur && change('suivi_transporteur')) {
      var autre = d.colis.filter(function (x) {
        return x.id !== c.id && x.suivi_transporteur === c.suivi_transporteur;
      })[0];
      if (autre) {
        throw Erreur('TRACKING_ALREADY_EXISTS', 'Le numéro de suivi ' + c.suivi_transporteur +
                     ' est déjà celui du colis ' + autre.numero + '.');
      }
    }

    if (c.tarif_lb_usd == null) c.tarif_lb_usd = nouveau || avant.tarif_lb_usd == null ? TARIF_LB_DEFAUT : avant.tarif_lb_usd;
    if (change('tarif_lb_usd') && (c.tarif_lb_usd < 0 || c.tarif_lb_usd > 1000)) {
      throw Erreur('INVALID_RATE', 'Le tarif doit être compris entre 0 et 1 000 $ la livre.');
    }
    // Un tarif autre que celui de la maison est un geste de facturation
    var auteur = compteConnecte(d);
    if (auteur && !peutCompte(auteur, 'invoices.edit') &&
        ((nouveau && c.tarif_lb_usd !== TARIF_LB_DEFAUT) || (!nouveau && c.tarif_lb_usd !== avant.tarif_lb_usd))) {
      throw Erreur('non-autorise', 'Un tarif particulier est réservé à qui peut modifier les factures.');
    }
    if (nouveau || change('poids_lb') || change('tarif_lb_usd') || avant.prix_usd == null) {
      c.prix_usd = prixTransport(c.poids_lb, c.tarif_lb_usd);
    } else {
      c.prix_usd = avant.prix_usd;
    }

    if (nouveau) {
      if ((c.statut || 'recu') !== 'recu') {
        throw Erreur('INVALID_STATUS', 'Un colis est enregistré au statut « Reçu » ; changez ensuite son statut.');
      }
      c.statut = 'recu';
    } else if (c.statut !== avant.statut) {
      if (!TRANSITIONS[c.statut]) throw Erreur('INVALID_STATUS', 'Statut inconnu : ' + (c.statut || '(vide)') + '.');
      if (!transitionPermise(avant.statut, c.statut, statutPrecedent(historiqueDe(d, c.id), avant.statut))) {
        throw Erreur('INVALID_STATUS_TRANSITION', LIBELLES[avant.statut] + ' → ' + LIBELLES[c.statut] +
                     ' : transition interdite pour le colis ' + c.numero + '.');
      }
    }
    if (c.statut === 'disponible' && !c.lieu && (nouveau || change('statut') || change('lieu'))) {
      throw Erreur('LOCATION_REQUIRED', 'Indiquez l’agence où le client peut retirer son colis.');
    }
    if (!nouveau) c.cle_idempotence = avant.cle_idempotence;
    return c;
  }

  /* ---- Les finances, version démonstration ---------------------------------
     La copie de outils/supabase-finances.sql : paiements, recalcul du payé et
     du statut, annulations, regroupement. Mêmes contrôles, dans le même
     ordre, mêmes codes et mêmes phrases ; outils/essais-services/
     essai-finances.js rejoue les cas de essai-finances.py.
     -------------------------------------------------------------------------- */
  function montantTexte(n) { return (Number(n) || 0).toFixed(2); }

  // La file des événements de facturation (evenements_facturation)
  function noterEvenementDemo(d, type, f, p, donnees) {
    d.evenementsFacturation = d.evenementsFacturation || [];
    d.evenementsFacturation.push({ id: d.evenementsFacturation.length + 1, type: type, facture_id: f ? f.id : null,
                                   paiement_id: p ? p.id : null, client_id: f ? f.client_id : null,
                                   donnees: donnees || {}, cree_le: maintenant(), traite_le: null });
    notifierFacturationDemo(d, d.evenementsFacturation[d.evenementsFacturation.length - 1]);
  }

  /* ---- Les notifications, version démonstration ---------------------------
     La copie de outils/supabase-notifications.sql : mêmes règles, mêmes textes,
     mêmes clés d'idempotence. Une étape publique d'un colis ou un événement de
     facturation crée une notification (espace client) et un envoi par canal.
     En démonstration aucune clé n'est posée : l'e-mail, WhatsApp et le SMS
     sont « annule, NON_CONFIGURE » et le téléphone « SANS_APPAREIL », comme
     sur une base sans réglages — rien n'est jamais présenté comme envoyé.
     essai-notifications.py compare ces règles et ces textes avec la base.
     -------------------------------------------------------------------------- */
  var REGLES_NOTIFICATIONS = [
    { type: 'shipment_received', source: 'colis', evenement: 'COLIS_RECU', categorie: 'colis', priorite: 'normale', canaux: ['push', 'email', 'whatsapp'], sensible: false, libelle: 'Colis reçu à l\'entrepôt' },
    { type: 'shipment_packed', source: 'colis', evenement: 'COLIS_EMBALLE', categorie: 'colis', priorite: 'normale', canaux: ['push'], sensible: false, libelle: 'Colis emballé' },
    { type: 'shipment_shipped', source: 'colis', evenement: 'COLIS_EXPEDIE', categorie: 'colis', priorite: 'normale', canaux: ['push'], sensible: false, libelle: 'Colis expédié' },
    { type: 'shipment_arrived', source: 'colis', evenement: 'COLIS_ARRIVE', categorie: 'colis', priorite: 'normale', canaux: ['push'], sensible: false, libelle: 'Arrivé au centre de distribution' },
    { type: 'shipment_transferred', source: 'colis', evenement: 'COLIS_TRANSFERE', categorie: 'colis', priorite: 'normale', canaux: ['push'], sensible: false, libelle: 'Transféré à la succursale' },
    { type: 'shipment_available', source: 'colis', evenement: 'COLIS_DISPONIBLE', categorie: 'colis', priorite: 'haute', canaux: ['push', 'email', 'whatsapp'], sensible: false, libelle: 'Colis disponible' },
    { type: 'shipment_delivered', source: 'colis', evenement: 'COLIS_LIVRE', categorie: 'colis', priorite: 'normale', canaux: ['push'], sensible: false, libelle: 'Colis livré' },
    { type: 'action_required', source: 'colis', evenement: 'ACTION_REQUISE', categorie: 'colis', priorite: 'haute', canaux: ['push', 'email'], sensible: true, libelle: 'Action requise' },
    { type: 'action_resolved', source: 'colis', evenement: 'ACTION_RESOLUE', categorie: 'colis', priorite: 'normale', canaux: ['push'], sensible: false, libelle: 'Action résolue' },
    { type: 'invoice_created', source: 'facturation', evenement: 'FACTURE_CREEE', categorie: 'factures', priorite: 'normale', canaux: ['push', 'email'], sensible: true, libelle: 'Nouvelle facture' },
    { type: 'payment_received', source: 'facturation', evenement: 'PAIEMENT_ENREGISTRE', categorie: 'paiements', priorite: 'normale', canaux: ['push', 'email'], sensible: true, libelle: 'Paiement enregistré' },
    { type: 'invoice_paid', source: 'facturation', evenement: 'FACTURE_PAYEE', categorie: 'factures', priorite: 'normale', canaux: ['push'], sensible: true, libelle: 'Facture payée' },
    { type: 'invoice_overdue', source: 'planifie', evenement: 'FACTURE_EN_RETARD', categorie: 'factures', priorite: 'normale', canaux: ['push', 'email'], sensible: true, libelle: 'Facture en retard' }
  ];
  var CANAUX_NOTIFICATIONS = ['push', 'email', 'whatsapp', 'sms'];

  // notification_textes() : titre et message dans les quatre langues
  var TEXTES_NOTIFICATIONS = {
    shipment_received: {
      fr: { titre: "Colis reçu", message: "Votre colis {{numero}} a été reçu à notre entrepôt de Miami." },
      en: { titre: "Package received", message: "Your package {{numero}} has been received at our Miami warehouse." },
      es: { titre: "Paquete recibido", message: "Su paquete {{numero}} fue recibido en nuestro almacén de Miami." },
      ht: { titre: "Koli resevwa", message: "Nou resevwa koli ou {{numero}} nan depo nou an Miami." }
    },
    shipment_packed: {
      fr: { titre: "Colis emballé", message: "Votre colis {{numero}} est emballé et prêt à partir." },
      en: { titre: "Package packed", message: "Your package {{numero}} is packed and ready to ship." },
      es: { titre: "Paquete embalado", message: "Su paquete {{numero}} está embalado y listo para salir." },
      ht: { titre: "Koli anbale", message: "Koli ou {{numero}} anbale, li pare pou l pati." }
    },
    shipment_shipped: {
      fr: { titre: "Colis expédié", message: "Votre colis {{numero}} a été expédié." },
      en: { titre: "Package shipped", message: "Your package {{numero}} has been shipped." },
      es: { titre: "Paquete enviado", message: "Su paquete {{numero}} fue enviado." },
      ht: { titre: "Koli voye", message: "Koli ou {{numero}} pati." }
    },
    shipment_arrived: {
      fr: { titre: "Colis arrivé", message: "Votre colis {{numero}} est arrivé au centre de distribution." },
      en: { titre: "Package arrived", message: "Your package {{numero}} has arrived at the distribution centre." },
      es: { titre: "Paquete llegó", message: "Su paquete {{numero}} llegó al centro de distribución." },
      ht: { titre: "Koli rive", message: "Koli ou {{numero}} rive nan sant distribisyon an." }
    },
    shipment_transferred: {
      fr: { titre: "Colis transféré", message: "Votre colis {{numero}} a été transféré à la succursale." },
      en: { titre: "Package transferred", message: "Your package {{numero}} has been transferred to the branch." },
      es: { titre: "Paquete transferido", message: "Su paquete {{numero}} fue transferido a la sucursal." },
      ht: { titre: "Koli transfere", message: "Koli ou {{numero}} transfere nan sikisal la." }
    },
    shipment_available: {
      fr: { titre: "Colis disponible", message: "Votre colis {{numero}} est disponible. Présentez votre code client pour le retirer." },
      en: { titre: "Package ready for pickup", message: "Your package {{numero}} is ready for pickup. Please show your customer code." },
      es: { titre: "Paquete disponible", message: "Su paquete {{numero}} está disponible. Presente su código de cliente para retirarlo." },
      ht: { titre: "Koli disponib", message: "Koli ou {{numero}} disponib. Montre kòd kliyan ou pou w vin chèche l." }
    },
    shipment_delivered: {
      fr: { titre: "Colis livré", message: "Votre colis {{numero}} a été livré." },
      en: { titre: "Package delivered", message: "Your package {{numero}} has been delivered." },
      es: { titre: "Paquete entregado", message: "Su paquete {{numero}} fue entregado." },
      ht: { titre: "Koli livre", message: "Koli ou {{numero}} livre." }
    },
    action_required: {
      fr: { titre: "Action requise", message: "Une action est requise concernant votre colis {{numero}}. Ouvrez votre espace pour en savoir plus." },
      en: { titre: "Action required", message: "An action is required regarding your package {{numero}}. Open your account to learn more." },
      es: { titre: "Acción requerida", message: "Se requiere una acción sobre su paquete {{numero}}. Abra su cuenta para más detalles." },
      ht: { titre: "Aksyon nesesè", message: "Gen yon aksyon pou fè sou koli ou {{numero}}. Louvri espas ou pou w konnen plis." }
    },
    action_resolved: {
      fr: { titre: "Action résolue", message: "Le point en attente sur votre colis {{numero}} est réglé." },
      en: { titre: "Action resolved", message: "The pending issue with your package {{numero}} has been resolved." },
      es: { titre: "Acción resuelta", message: "El asunto pendiente de su paquete {{numero}} fue resuelto." },
      ht: { titre: "Aksyon regle", message: "Pwoblèm ki te genyen sou koli ou {{numero}} an regle." }
    },
    invoice_created: {
      fr: { titre: "Nouvelle facture", message: "Une nouvelle facture ({{facture}}, {{montant}}) est disponible dans votre espace GoShip Express." },
      en: { titre: "New invoice", message: "A new invoice ({{facture}}, {{montant}}) is available in your GoShip Express account." },
      es: { titre: "Nueva factura", message: "Una nueva factura ({{facture}}, {{montant}}) está disponible en su cuenta GoShip Express." },
      ht: { titre: "Nouvo fakti", message: "Yon nouvo fakti ({{facture}}, {{montant}}) disponib nan espas GoShip Express ou." }
    },
    payment_received: {
      fr: { titre: "Paiement enregistré", message: "Votre paiement de {{montant}} sur la facture {{facture}} a été enregistré." },
      en: { titre: "Payment recorded", message: "Your payment of {{montant}} on invoice {{facture}} has been recorded." },
      es: { titre: "Pago registrado", message: "Su pago de {{montant}} de la factura {{facture}} fue registrado." },
      ht: { titre: "Peman anrejistre", message: "Nou anrejistre peman ou {{montant}} sou fakti {{facture}}." }
    },
    invoice_paid: {
      fr: { titre: "Facture payée", message: "Votre facture {{facture}} est entièrement payée. Merci !" },
      en: { titre: "Invoice paid", message: "Your invoice {{facture}} is fully paid. Thank you!" },
      es: { titre: "Factura pagada", message: "Su factura {{facture}} está totalmente pagada. ¡Gracias!" },
      ht: { titre: "Fakti peye", message: "Fakti ou {{facture}} peye nèt. Mèsi !" }
    },
    invoice_overdue: {
      fr: { titre: "Facture en retard", message: "Votre facture {{facture}} a dépassé sa date d'échéance. Consultez-la dans votre espace." },
      en: { titre: "Invoice overdue", message: "Your invoice {{facture}} is past its due date. Please check it in your account." },
      es: { titre: "Factura vencida", message: "Su factura {{facture}} superó su fecha de vencimiento. Consúltela en su cuenta." },
      ht: { titre: "Fakti an reta", message: "Fakti ou {{facture}} depase dat li te dwe peye a. Gade l nan espas ou." }
    },
    test: {
      fr: { titre: "Notification d'essai", message: "Ceci est un essai des notifications GoShip Express." },
      en: { titre: "Test notification", message: "This is a test of GoShip Express notifications." },
      es: { titre: "Notificación de prueba", message: "Esta es una prueba de las notificaciones de GoShip Express." },
      ht: { titre: "Notifikasyon esè", message: "Sa se yon esè notifikasyon GoShip Express." }
    },
    verrou: {
      fr: { titre: "GoShip Express", message: "Une mise à jour concernant votre compte est disponible." },
      en: { titre: "GoShip Express", message: "An update about your account is available." },
      es: { titre: "GoShip Express", message: "Hay una actualización sobre su cuenta." },
      ht: { titre: "GoShip Express", message: "Gen yon nouvèl sou kont ou." }
    },
    email: {
      fr: { salutation: "Bonjour {{nom}},", bouton: "OUVRIR MON ESPACE", pied: "Vous recevez ce message car vous avez un compte client Goship Express. Réglez vos notifications dans votre espace." },
      en: { salutation: "Hello {{nom}},", bouton: "OPEN MY ACCOUNT", pied: "You receive this message because you have a Goship Express customer account. Manage your notifications in your account." },
      es: { salutation: "Estimado/a {{nom}}:", bouton: "ABRIR MI CUENTA", pied: "Recibe este mensaje porque tiene una cuenta de cliente Goship Express. Configure sus notificaciones en su cuenta." },
      ht: { salutation: "Bonjou {{nom}},", bouton: "LOUVRI ESPAS MWEN", pied: "Ou resevwa mesaj sa a paske ou gen yon kont kliyan Goship Express. Regle notifikasyon ou nan espas ou." }
    }
  };

  // Les règles de la démo : celles de départ, avec les réglages de l'administrateur
  function reglesNotificationsDemo(d) {
    var reglees = d.reglesNotifications || {};
    return REGLES_NOTIFICATIONS.map(function (r) {
      var x = JSON.parse(JSON.stringify(r));
      if (reglees[r.type]) { x.actif = reglees[r.type].actif; x.canaux = reglees[r.type].canaux; x.maj_le = reglees[r.type].maj_le; }
      if (x.actif === undefined) x.actif = true;
      return x;
    });
  }

  function langueNotification(l) { return ['fr', 'en', 'es', 'ht'].indexOf(l) >= 0 ? l : 'fr'; }

  // montant_notification : 40,00 $ en français et en créole, $40.00 en anglais et en espagnol
  function montantNotification(n, langue) {
    if (n == null || n === '') return '';
    var t = (Math.round(Number(n) * 100) / 100).toFixed(2);
    return langue === 'en' || langue === 'es' ? '$' + t : t.replace('.', ',') + ' $';
  }

  // rendre_notification : seules {{numero}}, {{facture}} et {{montant}} sont remplacées
  function rendreNotification(modele, vars) {
    return String(modele || '').replace('{{numero}}', vars.numero || '').replace('{{facture}}', vars.facture || '')
      .replace('{{montant}}', vars.montant || '').replace(/\{\{[a-z_]*\}\}/g, '');
  }

  function texteNotification(type, langue, donnees) {
    var l = langueNotification(langue);
    var t = (TEXTES_NOTIFICATIONS[type] || {})[l] || { titre: 'GoShip Express', message: '' };
    var vars = Object.assign({}, donnees || {}, { montant: montantNotification((donnees || {}).montant_usd, l) });
    return { titre: rendreNotification(t.titre, vars), message: rendreNotification(t.message, vars) };
  }

  // canal_configure : en démonstration, seul le téléphone l'est (et aucun n'est enregistré)
  function canalConfigureDemo(canal) { return canal === 'push'; }

  // creer_notification : une notification par clé ; ses envois, ou la raison de ne pas envoyer
  function creerNotificationDemo(d, type, clientId, cle, liens, donnees, canauxEssai) {
    var client = d.comptes.filter(function (c) { return c.id === clientId; })[0];
    if (!client) return null;
    var categorie = 'compte', priorite = 'normale', canaux = canauxEssai;
    if (!canauxEssai) {
      var regle = reglesNotificationsDemo(d).filter(function (r) { return r.type === type; })[0];
      if (!regle || !regle.actif) return null;
      categorie = regle.categorie;
      priorite = regle.priorite;
      canaux = regle.canaux;
    }
    d.notificationsApp = d.notificationsApp || [];
    if (cle && d.notificationsApp.some(function (n) { return n.cle === cle; })) return null; // déjà traitée
    d.seqNotification = (d.seqNotification || 0) + 1;
    var n = {
      id: d.seqNotification, client_id: clientId, type: type, categorie: categorie, priorite: priorite, cle: cle,
      colis_id: liens.colis_id || null, facture_id: liens.facture_id || null, paiement_id: liens.paiement_id || null,
      historique_id: liens.historique_id || null, donnees: donnees || {}, cree_le: maintenant(), lu_le: null
    };
    d.notificationsApp.push(n);
    d.envoisNotifications = d.envoisNotifications || [];
    var prefs = d.preferencesNotifications || {};
    canaux.forEach(function (canal) {
      var raison = prefs[clientId + ':' + categorie + ':' + canal] === false ? 'PREFERENCE'
        : !canalConfigureDemo(canal) ? 'NON_CONFIGURE'
        : canal === 'push' ? 'SANS_APPAREIL' : null;
      d.seqEnvoi = (d.seqEnvoi || 0) + 1;
      d.envoisNotifications.push({
        id: d.seqEnvoi, notification_id: n.id, canal: canal, cible: canal, statut: raison ? 'annule' : 'attente',
        code_erreur: raison, tentative: 0, priorite: priorite, fournisseur: { push: 'expo', email: 'brevo', whatsapp: 'meta' }[canal] || '',
        cree_le: n.cree_le, envoye_le: null
      });
    });
    return n.id;
  }

  // notifier_etape_colis : une étape publique d'un colis de client
  function notifierEtapeDemo(d, e) {
    if (!e || e.visibilite !== 'publique' || !e.type_evenement) return;
    var regle = REGLES_NOTIFICATIONS.filter(function (r) { return r.source === 'colis' && r.evenement === e.type_evenement; })[0];
    var c = trouverColisDemo(d, e.colis_id);
    if (!regle || !c || !c.client_id) return;
    creerNotificationDemo(d, regle.type, c.client_id, 'etape:' + e.id + ':' + regle.type,
                          { colis_id: c.id, historique_id: e.id }, { numero: c.numero, statut: e.statut });
  }

  // notifier_evenement_facturation : un paiement qui solde la facture ne donne
  // que « facture payée », notée juste avant dans la même opération
  var payeeALInstant = null;
  function notifierFacturationDemo(d, evt) {
    var regle = REGLES_NOTIFICATIONS.filter(function (r) { return r.source === 'facturation' && r.evenement === evt.type; })[0];
    if (regle && evt.client_id) {
      var cle = regle.type === 'invoice_created' ? 'facture:' + evt.facture_id
        : regle.type === 'payment_received' ? 'paiement:' + evt.paiement_id : 'facturation:' + evt.id;
      var donnees = { facture: evt.donnees.numero || evt.donnees.facture || null,
                      montant_usd: evt.donnees.montant_usd != null ? Number(evt.donnees.montant_usd).toFixed(2) : null };
      if (regle.type === 'payment_received' && payeeALInstant === evt.facture_id) {
        payeeALInstant = null; // regroupé dans « facture payée »
      } else {
        creerNotificationDemo(d, regle.type, evt.client_id, cle,
                              { facture_id: evt.facture_id, paiement_id: evt.paiement_id }, donnees);
        payeeALInstant = regle.type === 'invoice_paid' ? evt.facture_id : null;
      }
    }
    evt.traite_le = maintenant();
  }

  // recalculer_facture : payé, statut, date et moyen suivent les paiements valides

  function recalculerFactureDemo(d, f) {
    var valides = paiementsValides(f).sort(function (a, b) {
      return new Date(a.paye_le) - new Date(b.paye_le) || new Date(a.cree_le) - new Date(b.cree_le);
    });
    var paye = arrondi(valides.reduce(function (s, p) { return s + p.montant_usd; }, 0));
    var dernier = valides[valides.length - 1];
    var avant = f.statut;
    f.montant_paye_usd = paye;
    if (f.statut !== 'annulee') f.statut = f.montant_usd > 0 && paye >= f.montant_usd ? 'payee' : 'a_payer';
    f.payee_le = f.statut === 'payee' ? (dernier ? dernier.paye_le : maintenant()) : null;
    f.moyen = paye > 0 && dernier && dernier.moyen !== 'autre' ? dernier.moyen : '';
    if (f.statut === 'payee' && avant !== 'payee') {
      noterEvenementDemo(d, 'FACTURE_PAYEE', f, null, { numero: f.numero, montant_usd: f.montant_usd });
    }
  }

  // La facture telle que la renvoie la base (facture_complete) : client,
  // lignes, payé, solde, état et paiements
  function factureComplete(d, f) {
    if (!f) return null;
    var client = d.comptes.filter(function (c) { return c.id === f.client_id; })[0];
    var sortie = Object.assign({}, f, {
      clients: client ? {
        code: client.code, nom_complet: client.nom_complet, telephone: client.telephone,
        email: client.email, adresse: client.adresse, region: client.region,
        ville: client.ville, pays: client.pays, langue: client.langue
      } : null,
      facture_lignes: (f.facture_lignes || []).map(function (l) {
        var colis = trouverColisDemo(d, l.colis_id);
        return Object.assign({}, l, {
          colis: colis ? { numero: colis.numero, description: colis.description, poids_lb: colis.poids_lb } : null
        });
      }),
      paiements: (f.paiements || []).map(function (p) { return Object.assign({}, p); })
    });
    sortie.paye_usd = payeDe({ paiements: f.paiements || [] });
    sortie.solde_usd = soldeDe({ statut: f.statut, montant_usd: f.montant_usd, paye_usd: sortie.paye_usd });
    sortie.etat_paiement = etatFacture({ statut: f.statut, montant_usd: f.montant_usd, echeance_le: f.echeance_le,
                                         paye_usd: sortie.paye_usd, solde_usd: sortie.solde_usd });
    return trierPaiements(sortie);
  }

  // La facture active (non annulée) qui porte ce colis, s'il y en a une
  function factureActiveDu(d, colisId, sauf) {
    return (d.factures || []).filter(function (f) {
      return f.statut !== 'annulee' && f.id !== sauf &&
        (f.facture_lignes || []).some(function (l) { return l.colis_id === colisId; });
    }).sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); })[0] || null;
  }

  // Un numéro jamais attribué (preparer_facture + reserver_numero_facture)
  function numeroFactureDemo(d) {
    d.numerosFactures = d.numerosFactures || [];
    var mois = new Date(), numero;
    do {
      numero = mois.getFullYear() + '-' + String(mois.getMonth() + 1).padStart(2, '0') + '-' +
               String(Math.floor(Math.random() * 10000)).padStart(4, '0');
    } while (d.numerosFactures.indexOf(numero) >= 0 ||
             (d.factures || []).some(function (f) { return f.numero === numero; }));
    d.numerosFactures.push(numero);
    return numero;
  }

  // Une facture neuve (garde_facture à l'insertion, puis suivre_facture) : elle
  // naît à payer ; ce qui est payé à sa création devient un paiement.
  function nouvelleFacture(d, moi, champs, colis) {
    d.factures = d.factures || [];
    d.numeroFacture = (d.numeroFacture || 0) + 1;
    var paye = arrondi(champs.montant_paye_usd || 0);
    var f = Object.assign({
      id: 'fac-' + d.numeroFacture,
      statut: 'a_payer', note: '', lien_paiement: '', moyen: '', echeance_le: null,
      frais_service_usd: 0, cle_idempotence: null, cree_le: maintenant(), payee_le: null,
      annulee_le: null, annulee_par: null, motif_annulation: '', remplacee_par: null
    }, choisir(champs, ['client_id', 'montant_usd', 'frais_service_usd', 'echeance_le', 'lien_paiement', 'note',
                        'cle_idempotence']));
    f.numero = numeroFactureDemo(d);
    f.montant_paye_usd = 0;
    if (f.montant_usd > 0 && paye >= f.montant_usd) f.statut = 'payee';
    f.paiements = [];
    f.facture_lignes = (colis || []).map(function (c, i) {
      return { id: i + 1, facture_id: f.id, colis_id: c.id, libelle: c.description || 'Transport',
               montant_usd: prixColis(c), quantite: 1, poids_lb: c.poids_lb != null ? c.poids_lb : null,
               tarif_lb_usd: tarifDe(c) };
    });
    d.factures.push(f);
    journaliser(d, moi, 'facture.creation', 'facture', f.id, null,
                choisir(f, ['numero', 'client_id', 'montant_usd', 'frais_service_usd', 'montant_paye_usd', 'statut']));
    noterEvenementDemo(d, 'FACTURE_CREEE', f, null, { numero: f.numero, montant_usd: f.montant_usd });
    if (paye > 0) {
      ajouterPaiementDemo(d, moi, f, { montant_usd: paye, moyen: 'autre', note: 'Payé à la création de la facture.',
                                       paye_le: maintenant() }, 'creation', null);
    }
    return f;
  }

  // regles_paiement, puis l'écriture et suivre_paiement. Rien n'est écrit si
  // une règle refuse.
  function ajouterPaiementDemo(d, moi, f, v, origine, cle) {
    var montant = arrondi(v.montant_usd);
    var moyen = String(v.moyen || '').trim().toLowerCase();
    if (!(montant > 0)) throw Erreur('INVALID_AMOUNT', 'Le montant du paiement doit être supérieur à zéro.');
    if (MOYENS_PAIEMENT.indexOf(moyen) < 0) {
      throw Erreur('INVALID_PAYMENT_METHOD', 'Moyen de paiement inconnu : ' + (moyen || '(vide)') + '.');
    }
    var date = v.paye_le ? new Date(v.paye_le) : new Date();
    if (date.getTime() > Date.now() + 36e5) {
      throw Erreur('INVALID_DATE', 'La date du paiement ne peut pas être dans le futur.');
    }
    if (f.statut === 'annulee') {
      throw Erreur('INVOICE_CANCELLED', 'La facture ' + f.numero + ' est annulée : elle ne reçoit plus de paiement.');
    }
    var paye = payeDe({ paiements: f.paiements || [] });
    if (paye >= f.montant_usd) throw Erreur('INVOICE_ALREADY_PAID', 'La facture ' + f.numero + ' est déjà entièrement payée.');
    if (montant > arrondi(f.montant_usd - paye)) {
      throw Erreur('OVERPAYMENT', 'Le paiement de ' + montantTexte(montant) + ' $ dépasse le solde de ' +
                   montantTexte(f.montant_usd - paye) + ' $ de la facture ' + f.numero + '.');
    }
    var reference = String(v.reference || '').trim().slice(0, 100);
    if (reference && paiementsValides(f).some(function (p) {
      return p.moyen === moyen && p.reference.toLowerCase() === reference.toLowerCase();
    })) {
      throw Erreur('DUPLICATE_PAYMENT', 'Ce paiement (référence ' + reference + ') est déjà enregistré sur la facture ' +
                   f.numero + '.');
    }
    d.numeroPaiement = (d.numeroPaiement || 0) + 1;
    var p = {
      id: 'pai-' + d.numeroPaiement, facture_id: f.id, client_id: f.client_id, montant_usd: montant, moyen: moyen,
      reference: reference, paye_le: date.toISOString(), note: String(v.note || '').trim().slice(0, 300),
      origine: origine || 'saisie', cle_idempotence: cle || null, cree_par: moi ? moi.id : null,
      cree_le: maintenant(), annule_le: null, annule_par: null, motif_annulation: ''
    };
    f.paiements = f.paiements || [];
    f.paiements.push(p);
    recalculerFactureDemo(d, f);
    var resume = { facture: f.numero, montant_usd: p.montant_usd, moyen: p.moyen, reference: p.reference,
                   paye_le: p.paye_le, origine: p.origine };
    journaliser(d, moi, 'paiement.enregistrement', 'paiement', p.id, null, resume);
    noterEvenementDemo(d, 'PAIEMENT_ENREGISTRE', f, p, resume);
    return p;
  }

  // Une facture de colis qui peut se regrouper, ou la raison du refus
  function refusRegroupement(f) {
    if (f.statut !== 'a_payer') {
      return Erreur('INVOICE_NOT_GROUPABLE', 'La facture ' + f.numero + ' est ' +
                    (f.statut === 'payee' ? 'payée' : 'annulée') + ' : elle ne se regroupe pas.');
    }
    if (paiementsValides(f).length) {
      return Erreur('INVOICE_HAS_PAYMENTS', 'La facture ' + f.numero + ' a déjà reçu un paiement : elle ne se regroupe pas.');
    }
    var lignes = f.facture_lignes || [];
    if (!lignes.length || lignes.some(function (l) { return !l.colis_id; })) {
      return Erreur('INVOICE_NOT_GROUPABLE', 'La facture ' + f.numero + ' n’est pas une facture de colis : elle ne se regroupe pas.');
    }
    return null;
  }

  // facturer_colis : sa facture, ou celle qu'il a déjà
  function facturerColisDemo(d, moi, c) {
    if (!c.client_id) throw Erreur('CLIENT_NOT_FOUND', 'Ce colis n’a plus de client : impossible de le facturer.');
    var existante = factureActiveDu(d, c.id);
    if (existante) return { facture: factureComplete(d, existante), deja: true };
    var prix = prixColis(c);
    var f = nouvelleFacture(d, moi, {
      client_id: c.client_id, montant_usd: arrondi(prix + FRAIS_SERVICE), frais_service_usd: FRAIS_SERVICE
    }, [c]);
    return { facture: factureComplete(d, f), deja: false };
  }

  function contient(valeurs, texte) {
    texte = texte.toLowerCase();
    return valeurs.some(function (v) { return v && String(v).toLowerCase().indexOf(texte) >= 0; });
  }

  function page(lignes, o) {
    var parPage = o.parPage || 50, p = o.page || 0;
    return { lignes: lignes.slice(p * parPage, p * parPage + parPage), total: lignes.length };
  }


  /* ---- Tableau de bord : la copie démo de outils/supabase-tableau-de-bord.sql
     Mêmes périodes (jours de Santo Domingo), mêmes règles, même forme de
     réponse : essai-tableau.py compare les deux. ---- */

  // Le jour de Santo Domingo d'un instant (AAAA-MM-JJ)
  function jourSD(iso) {
    var t = new Date(iso);
    if (isNaN(t.getTime())) return '';
    try {
      return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Santo_Domingo', year: 'numeric',
                                                month: '2-digit', day: '2-digit' }).format(t);
    } catch (e) {
      return new Date(t.getTime() - 4 * 36e5).toISOString().slice(0, 10);
    }
  }

  function decalerJour(jour, n) {
    var t = new Date(jour + 'T00:00:00Z');
    t.setUTCDate(t.getUTCDate() + n);
    return t.toISOString().slice(0, 10);
  }

  function joursEntre(debut, fin) {
    var liste = [];
    for (var j = debut; j <= fin; j = decalerJour(j, 1)) liste.push(j);
    return liste;
  }

  // bornes_periode : { code, debut, fin }, jours inclus
  function bornesPeriode(code, debut, fin) {
    var c = String(code || '').trim().toLowerCase() || '30j';
    var j = aujourdhui();
    var jourValide = /^\d{4}-\d{2}-\d{2}$/;
    if (c === 'aujourdhui') return { code: c, debut: j, fin: j };
    if (c === '7j') return { code: c, debut: decalerJour(j, -6), fin: j };
    if (c === '30j') return { code: c, debut: decalerJour(j, -29), fin: j };
    if (c === 'mois') return { code: c, debut: j.slice(0, 8) + '01', fin: j };
    if (c === 'mois_precedent') {
      var veille = decalerJour(j.slice(0, 8) + '01', -1);
      return { code: c, debut: veille.slice(0, 8) + '01', fin: veille };
    }
    if (c === 'annee') return { code: c, debut: j.slice(0, 5) + '01-01', fin: j };
    if (c === 'personnalise') {
      debut = String(debut || '').slice(0, 10);
      fin = String(fin || '').slice(0, 10);
      if (!jourValide.test(debut) || !jourValide.test(fin)) {
        throw Erreur('INVALID_PERIOD', 'Choisissez une date de début et une date de fin.');
      }
      if (fin < debut) throw Erreur('INVALID_PERIOD', 'La date de fin est avant la date de début.');
      if ((new Date(fin + 'T00:00:00Z') - new Date(debut + 'T00:00:00Z')) / 864e5 > 366) {
        throw Erreur('INVALID_PERIOD', 'Une période de 367 jours au plus.');
      }
      return { code: c, debut: debut, fin: fin };
    }
    throw Erreur('INVALID_PERIOD', 'Période inconnue : ' + c.slice(0, 30) + '.');
  }

  function joursSansMouvement(valeur) {
    var n = valeur == null || valeur === '' ? 7 : Number(valeur);
    if (!(n >= 1 && n <= 365) || Math.floor(n) !== n) {
      throw Erreur('INVALID_INPUT', 'Le nombre de jours sans mouvement va de 1 à 365.');
    }
    return n;
  }

  // Le dernier événement d'un colis (le plus récent, puis le dernier écrit)
  function dernierEvenementDemo(d, colisId) {
    return historiqueDe(d, colisId).slice().sort(function (a, b) {
      return new Date(b.cree_le) - new Date(a.cree_le) || b.id - a.id;
    })[0] || null;
  }

  function corrigeDemo(d, h) {
    return d.historique.some(function (x) { return x.corrige_id === h.id; });
  }

  function trancheDemo(limite, defaut, maximum) {
    var n = Math.floor(Number(limite) || defaut);
    return Math.min(Math.max(n, 1), maximum);
  }

  // La facture active la plus récente d'un colis, en résumé
  function factureResumeDemo(d, colisId) {
    var f = (d.factures || []).filter(function (x) {
      return x.statut !== 'annulee' && (x.facture_lignes || []).some(function (l) { return l.colis_id === colisId; });
    }).sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); })[0];
    if (!f) return null;
    var c = factureComplete(d, f);
    return { id: f.id, numero: f.numero, montant_usd: f.montant_usd, paye_usd: c.paye_usd, solde_usd: c.solde_usd,
             etat: c.etat_paiement };
  }

  function clientResumeDemo(d, id, avecTelephone) {
    var cl = d.comptes.filter(function (c) { return c.id === id; })[0];
    if (!cl) return null;
    var r = { id: cl.id, code: cl.code, nom_complet: cl.nom_complet };
    if (avecTelephone) r.telephone = cl.telephone || '';
    return r;
  }


  /* ---- Analytics : la copie démo de outils/supabase-analytics.sql ----
     Mêmes périodes et même période précédente, mêmes définitions, même
     forme de réponse : essai-analytics.py compare les deux. ---- */

  // AAAA-MM-JJ − n mois, comme PostgreSQL : le 31 mars − 1 mois = le 28 février
  function moinsMois(jour, n) {
    var y = Number(jour.slice(0, 4)), m = Number(jour.slice(5, 7)) - 1 - n, j = Number(jour.slice(8, 10));
    y += Math.floor(m / 12);
    m = ((m % 12) + 12) % 12;
    var dernier = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    return new Date(Date.UTC(y, m, Math.min(j, dernier))).toISOString().slice(0, 10);
  }
  function ecartJours(d1, d2) { return Math.round((new Date(d2 + 'T00:00:00Z') - new Date(d1 + 'T00:00:00Z')) / 864e5); }

  // bornes_analytics : { code, debut, fin, precDebut, precFin } (jours inclus)
  function bornesAnalytics(code, debut, fin) {
    var c = String(code || '').trim().toLowerCase() || '30j';
    var j = aujourdhui(), b;
    if (c === '3m' || c === '6m' || c === '12m') {
      b = { code: c, debut: decalerJour(moinsMois(j, parseInt(c, 10)), 1), fin: j };
    } else if (c === 'personnalise') {
      debut = String(debut || '').slice(0, 10);
      fin = String(fin || '').slice(0, 10);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(debut) || !/^\d{4}-\d{2}-\d{2}$/.test(fin)) {
        throw Erreur('INVALID_PERIOD', 'Choisissez une date de début et une date de fin.');
      }
      if (fin < debut) throw Erreur('INVALID_PERIOD', 'La date de fin est avant la date de début.');
      if (ecartJours(debut, fin) > 1095) throw Erreur('INVALID_PERIOD', 'Une période de trois ans au plus.');
      b = { code: c, debut: debut, fin: fin };
    } else {
      b = bornesPeriode(c);
    }
    if (b.code === 'mois') {
      b.precDebut = moinsMois(b.debut, 1);
      b.precFin = moinsMois(b.fin, 1) < b.debut ? moinsMois(b.fin, 1) : decalerJour(b.debut, -1);
    } else if (b.code === 'mois_precedent') {
      b.precDebut = moinsMois(b.debut, 1);
      b.precFin = decalerJour(b.debut, -1);
    } else if (b.code === 'annee') {
      b.precDebut = moinsMois(b.debut, 12);
      b.precFin = moinsMois(b.fin, 12);
    } else {
      b.precDebut = decalerJour(b.debut, -(ecartJours(b.debut, b.fin) + 1));
      b.precFin = decalerJour(b.debut, -1);
    }
    return b;
  }

  // comparer_valeurs
  function comparerValeurs(a, b) {
    a = Number(a) || 0;
    b = Number(b) || 0;
    return { actuel: a, precedent: b, ecart: arrondi(a - b),
             variation_pct: b === 0 ? null : Math.round((a - b) / Math.abs(b) * 1000) / 10,
             tendance: a > b ? 'hausse' : (a < b ? 'baisse' : 'stable') };
  }

  function entreJours(iso, d1, d2) {
    if (!iso) return false;
    var j = jourSD(iso);
    return (!d1 || j >= d1) && (!d2 || j <= d2);
  }

  // evenements_de_statut : venus d'un autre statut, sans correction qui les annule
  function evenementsDeStatut(d, d1, d2) {
    return d.historique.filter(function (h) {
      return h.statut_precedent !== h.statut && entreJours(h.cree_le, d1, d2) && !corrigeDemo(d, h);
    }).map(function (h) {
      return { id: h.id, colis_id: h.colis_id, de: h.statut_precedent == null ? null : h.statut_precedent, vers: h.statut,
               type_evenement: h.type_evenement || null, auteur_id: h.auteur_id || null, lieu: h.lieu || '',
               note: h.note || '', cree_le: h.cree_le };
    });
  }

  function nbColisDistincts(liste) {
    var vus = {};
    liste.forEach(function (e) { vus[e.colis_id] = true; });
    return Object.keys(vus).length;
  }

  // analytics_mesures : les définitions d'une période
  function mesuresAnalytics(d, d1, d2) {
    var ev = evenementsDeStatut(d, d1, d2);
    function vers(s) { return nbColisDistincts(ev.filter(function (e) { return e.vers === s; })); }
    var colis = d.colis.filter(function (c) { return entreJours(c.recu_le, d1, d2); });
    var pesees = colis.filter(function (c) { return c.poids_lb != null; });
    var prixes = colis.filter(function (c) { return c.prix_usd != null; });
    var poids = arrondi(pesees.reduce(function (t, c) { return t + Number(c.poids_lb); }, 0));
    var prix = arrondi(prixes.reduce(function (t, c) { return t + Number(c.prix_usd); }, 0));
    var factures = (d.factures || []).filter(function (f) { return f.statut !== 'annulee' && entreJours(f.cree_le, d1, d2); });
    var montant = 0, reste = 0;
    factures.forEach(function (f) {
      var c = factureComplete(d, f);
      montant = arrondi(montant + f.montant_usd);
      reste = arrondi(reste + c.solde_usd);
    });
    var paiements = [];
    (d.factures || []).forEach(function (f) {
      paiementsValides(f).forEach(function (p) { if (entreJours(p.paye_le, d1, d2)) paiements.push(p); });
    });
    return {
      recus: colis.length, poids: poids,
      poids_moyen: pesees.length ? arrondi(poids / pesees.length) : null,
      prix_moyen: prixes.length ? arrondi(prix / prixes.length) : null,
      expedies: vers('embarque'), disponibles: vers('disponible'), livres: vers('livre'), actions_requises: vers('incident'),
      nouveaux_clients: d.comptes.filter(function (c) { return c.role === 'client' && entreJours(c.cree_le, d1, d2); }).length,
      factures_emises: factures.length, facture: montant, reste: reste,
      revenu_moyen_facture: factures.length ? arrondi(montant / factures.length) : null,
      paiements: paiements.length,
      encaisse: arrondi(paiements.reduce(function (t, p) { return t + p.montant_usd; }, 0)),
      scans: d.historique.filter(function (h) { return (h.metadonnees || {}).source === 'scanner' && entreJours(h.cree_le, d1, d2); }).length
    };
  }

  // creances_au : ce qui restait dû à la fin du jour « jusqua » (inclus)
  function creancesAu(d, jusqua) {
    var du = 0, maintenantMs = Date.now();
    function avant(iso) { return iso && jourSD(iso) <= jusqua && new Date(iso).getTime() <= maintenantMs; }
    (d.factures || []).forEach(function (f) {
      if (avant(f.cree_le)) du += f.montant_usd;
      if (f.statut === 'annulee' && avant(f.annulee_le || f.cree_le)) du -= f.montant_usd;
      (f.paiements || []).forEach(function (p) {
        if (avant(p.paye_le)) du -= p.montant_usd;
        if (p.annule_le && avant(p.annule_le) && avant(p.paye_le)) du += p.montant_usd;
      });
    });
    return arrondi(du);
  }

  // statistiques_durees : heures ; percentile continu, comme PostgreSQL
  function statistiquesDurees(liste) {
    var ok = liste.filter(function (x) { return x >= 0; }).sort(function (a, b) { return a - b; });
    function rang(p) {
      if (!ok.length) return null;
      var i = p * (ok.length - 1), bas = Math.floor(i), haut = Math.ceil(i);
      return ok[bas] + (ok[haut] - ok[bas]) * (i - bas);
    }
    function un(x) { return x == null ? null : Math.round(x * 10) / 10; }
    var q1 = rang(0.25), q3 = rang(0.75);
    return {
      nombre: ok.length,
      moyenne_h: ok.length ? un(ok.reduce(function (t, x) { return t + x; }, 0) / ok.length) : null,
      mediane_h: un(rang(0.5)), minimum_h: ok.length ? un(ok[0]) : null, maximum_h: ok.length ? un(ok[ok.length - 1]) : null,
      p90_h: un(rang(0.9)),
      extremes: ok.length >= 4 ? ok.filter(function (x) { return x > q3 + 1.5 * (q3 - q1); }).length : 0,
      negatives: liste.filter(function (x) { return x < 0; }).length
    };
  }

  function heuresEntre(a, b) { return (new Date(b).getTime() - new Date(a).getTime()) / 36e5; }

  var MODULES_ANALYTICS = ['synthese', 'serie', 'operations', 'clients', 'finances', 'routes', 'scanner', 'qualite'];

  function analyticsDemo(d, module, o) {
    var p = module === 'qualite' ? null : bornesAnalytics(o.periode, o.debut, o.fin);
    var periode = p ? { code: p.code, debut: p.debut, fin: p.fin } : null;
    var a, b;
    if (module === 'synthese') {
      a = mesuresAnalytics(d, p.debut, p.fin);
      b = mesuresAnalytics(d, p.precDebut, p.precFin);
      var mesures = {};
      ['recus', 'poids', 'expedies', 'disponibles', 'livres', 'actions_requises', 'nouveaux_clients', 'factures_emises',
       'facture', 'reste', 'paiements', 'encaisse', 'scans'].forEach(function (k) { mesures[k] = comparerValeurs(a[k], b[k]); });
      var statuts = {};
      STATUTS.forEach(function (s) { statuts[s] = 0; });
      d.colis.forEach(function (c) { statuts[c.statut] = (statuts[c.statut] || 0) + 1; });
      function inscrits(fin) {
        return d.comptes.filter(function (c) { return c.role === 'client' && entreJours(c.cree_le, null, fin); }).length;
      }
      return {
        periode: { code: p.code, debut: p.debut, fin: p.fin, jours: ecartJours(p.debut, p.fin) + 1,
                   precedente: { debut: p.precDebut, fin: p.precFin }, fuseau: 'America/Santo_Domingo' },
        genere_le: maintenant(), mesures: mesures,
        moyennes: { poids_moyen: a.poids_moyen, prix_moyen: a.prix_moyen, revenu_moyen_facture: a.revenu_moyen_facture },
        clients_total: comparerValeurs(inscrits(p.fin), inscrits(p.precFin)),
        creances_fin: comparerValeurs(creancesAu(d, p.fin), creancesAu(d, p.precFin)),
        maintenant: { total: d.colis.length, actifs: d.colis.length - statuts.livre, statuts: statuts }
      };
    }
    if (module === 'serie') {
      var g = String(o.granularite || 'jour').toLowerCase();
      if (['jour', 'semaine', 'mois'].indexOf(g) < 0) throw Erreur('INVALID_INPUT', 'Découpage inconnu : ' + g.slice(0, 20) + '.');
      var cles = {}, ordre = [];
      joursEntre(p.debut, p.fin).forEach(function (j) {
        var cle = j;
        if (g === 'mois') cle = j.slice(0, 8) + '01';
        if (g === 'semaine') cle = decalerJour(j, -((new Date(j + 'T00:00:00Z').getUTCDay() + 6) % 7));
        if (!cles[cle]) { cles[cle] = { jour: cle, debut: j, fin: j }; ordre.push(cle); }
        cles[cle].fin = j;
      });
      function caseDe(iso) {
        var j = jourSD(iso);
        for (var k = 0; k < ordre.length; k++) if (j >= cles[ordre[k]].debut && j <= cles[ordre[k]].fin) return cles[ordre[k]];
        return null;
      }
      ordre.forEach(function (k) {
        Object.assign(cles[k], { recus: 0, poids: 0, expedies: 0, livres: 0, factures: 0, facture: 0, encaisse: 0, scans: 0,
                                 creances_fin: creancesAu(d, cles[k].fin) });
      });
      d.colis.forEach(function (c) {
        var x = entreJours(c.recu_le, p.debut, p.fin) && caseDe(c.recu_le);
        if (x) { x.recus++; x.poids = arrondi(x.poids + (Number(c.poids_lb) || 0)); }
      });
      var premiers = {};
      evenementsDeStatut(d, p.debut, p.fin).forEach(function (e) {
        if (e.vers !== 'embarque' && e.vers !== 'livre') return;
        var k = e.vers + ':' + e.colis_id;
        if (!premiers[k] || jourSD(e.cree_le) < jourSD(premiers[k].cree_le)) premiers[k] = e;
      });
      Object.keys(premiers).forEach(function (k) {
        var x = caseDe(premiers[k].cree_le);
        if (x) x[premiers[k].vers === 'embarque' ? 'expedies' : 'livres']++;
      });
      (d.factures || []).forEach(function (f) {
        var x = f.statut !== 'annulee' && entreJours(f.cree_le, p.debut, p.fin) && caseDe(f.cree_le);
        if (x) { x.factures++; x.facture = arrondi(x.facture + f.montant_usd); }
        paiementsValides(f).forEach(function (pa) {
          var y = entreJours(pa.paye_le, p.debut, p.fin) && caseDe(pa.paye_le);
          if (y) y.encaisse = arrondi(y.encaisse + pa.montant_usd);
        });
      });
      d.historique.forEach(function (h) {
        var x = (h.metadonnees || {}).source === 'scanner' && entreJours(h.cree_le, p.debut, p.fin) && caseDe(h.cree_le);
        if (x) x.scans++;
      });
      return { periode: periode, granularite: g, cases: ordre.map(function (k) { return cles[k]; }) };
    }
    if (module === 'operations') {
      var arrivees = {};
      evenementsDeStatut(d).forEach(function (e) {
        if (['embarque', 'disponible', 'livre'].indexOf(e.vers) < 0) return;
        var x = arrivees[e.colis_id] || (arrivees[e.colis_id] = {});
        if (!x[e.vers] || new Date(e.cree_le) < new Date(x[e.vers])) x[e.vers] = e.cree_le;
      });
      var durees = { reception_expedition: [], expedition_disponible: [], disponible_livraison: [], reception_livraison: [] };
      Object.keys(arrivees).forEach(function (id) {
        var c = trouverColisDemo(d, id), x = arrivees[id];
        if (!c) return;
        [['reception_expedition', c.recu_le, x.embarque], ['expedition_disponible', x.embarque, x.disponible],
         ['disponible_livraison', x.disponible, x.livre], ['reception_livraison', c.recu_le, x.livre]].forEach(function (t) {
          if (t[1] && t[2] && entreJours(t[2], p.debut, p.fin)) durees[t[0]].push(heuresEntre(t[1], t[2]));
        });
      });
      // La chaîne des changements de statut, colis par colis
      var chaine = evenementsDeStatut(d).sort(function (x, y) {
        return x.colis_id < y.colis_id ? -1 : (x.colis_id > y.colis_id ? 1 : (new Date(x.cree_le) - new Date(y.cree_le) || x.id - y.id));
      });
      var parTransition = {}, retours = 0, sorties = [];
      var ORDRE = ['recu', 'emballe', 'embarque', 'distribution', 'succursale', 'disponible', 'livre'];
      chaine.forEach(function (e, i) {
        var prec = i > 0 && chaine[i - 1].colis_id === e.colis_id ? chaine[i - 1] : null;
        if (!entreJours(e.cree_le, p.debut, p.fin)) return;
        if (e.de === 'incident' && prec) sorties.push(heuresEntre(prec.cree_le, e.cree_le));
        if (e.de == null || e.type_evenement === 'CORRECTION') return;
        var c = trouverColisDemo(d, e.colis_id);
        var depuis = !prec || prec.de == null ? (c ? c.recu_le : e.cree_le) : prec.cree_le;
        var k = e.de + '>' + e.vers;
        (parTransition[k] = parTransition[k] || { de: e.de, vers: e.vers, h: [] }).h.push(heuresEntre(depuis, e.cree_le));
        if (ORDRE.indexOf(e.vers) >= 0 && ORDRE.indexOf(e.de) >= 0 && ORDRE.indexOf(e.vers) < ORDRE.indexOf(e.de)) retours++;
      });
      var transitions = Object.keys(parTransition).map(function (k) {
        var t = parTransition[k], st = statistiquesDurees(t.h);
        return { de: t.de, vers: t.vers, nombre: t.h.length, moyenne_h: st.moyenne_h, mediane_h: st.mediane_h };
      }).sort(function (x, y) { return y.nombre - x.nombre || (x.de < y.de ? -1 : 1) || (x.vers < y.vers ? -1 : 1); });
      var ages = { moins_24h: 0, de_24_a_48h: 0, de_48_a_72h: 0, de_72h_a_7j: 0, plus_de_7j: 0, actifs: 0 };
      d.colis.forEach(function (c) {
        if (c.statut === 'livre') return;
        var dernier = dernierEvenementDemo(d, c.id);
        var h = heuresEntre(dernier ? dernier.cree_le : c.recu_le, maintenant());
        ages.actifs++;
        ages[h < 24 ? 'moins_24h' : (h < 48 ? 'de_24_a_48h' : (h < 72 ? 'de_48_a_72h' : (h < 168 ? 'de_72h_a_7j' : 'plus_de_7j')))]++;
      });
      function cohorte(d1, d2) {
        var l = d.colis.filter(function (c) { return entreJours(c.recu_le, d1, d2); });
        return { recus: l.length, livres: l.filter(function (c) { return c.statut === 'livre'; }).length };
      }
      var co = cohorte(p.debut, p.fin), cp = cohorte(p.precDebut, p.precFin);
      var incidents = evenementsDeStatut(d, p.debut, p.fin).filter(function (e) { return e.vers === 'incident'; });
      var parPays = {}, notes = {}, clientsVus = {};
      incidents.forEach(function (e) {
        var c = trouverColisDemo(d, e.colis_id) || {};
        (parPays[c.pays_destination] = parPays[c.pays_destination] || {})[e.colis_id] = true;
        if (c.client_id) clientsVus[c.client_id] = true;
        var n = String(e.note || '').trim();
        if (n) notes[n] = (notes[n] || 0) + 1;
      });
      return {
        periode: periode,
        durees: { reception_expedition: statistiquesDurees(durees.reception_expedition),
                  expedition_disponible: statistiquesDurees(durees.expedition_disponible),
                  disponible_livraison: statistiquesDurees(durees.disponible_livraison),
                  reception_livraison: statistiquesDurees(durees.reception_livraison) },
        transitions: transitions,
        anomalies: { corrections: d.historique.filter(function (h) {
                       return h.type_evenement === 'CORRECTION' && entreJours(h.cree_le, p.debut, p.fin); }).length,
                     retours_en_arriere: retours },
        sans_mouvement: ages,
        livraison: { livres: mesuresAnalytics(d, p.debut, p.fin).livres, cohorte_recus: co.recus, cohorte_livres: co.livres,
                     taux_cohorte: co.recus ? Math.round(co.livres * 1000 / co.recus) / 10 : null,
                     taux_cohorte_precedente: cp.recus ? Math.round(cp.livres * 1000 / cp.recus) / 10 : null },
        action_requise: {
          entrees: comparerValeurs(nbColisDistincts(incidents), nbColisDistincts(evenementsDeStatut(d, p.precDebut, p.precFin)
            .filter(function (e) { return e.vers === 'incident'; }))),
          en_cours: d.colis.filter(function (c) { return c.statut === 'incident'; }).length,
          duree_episodes: statistiquesDurees(sorties),
          clients: Object.keys(clientsVus).length,
          par_destination: Object.keys(parPays).map(function (k) { return { pays: k, nombre: Object.keys(parPays[k]).length }; })
            .sort(function (x, y) { return y.nombre - x.nombre || (x.pays < y.pays ? -1 : 1); }),
          notes: Object.keys(notes).map(function (k) { return { note: k, nombre: notes[k] }; })
            .sort(function (x, y) { return y.nombre - x.nombre || (x.note < y.note ? -1 : 1); }).slice(0, 5),
          cause_structuree: false
        }
      };
    }
    if (module === 'clients') {
      var tri = String(o.tri || 'colis').toLowerCase();
      if (['colis', 'poids', 'facture', 'paye', 'solde'].indexOf(tri) < 0) throw Erreur('INVALID_INPUT', 'Tri inconnu : ' + tri.slice(0, 30) + '.');
      var parPage = trancheDemo(o.parPage, 25, 100), decalage = Math.max(0, (o.page || 0) * parPage);
      function colisPar(d1, d2) {
        var r = {};
        d.colis.forEach(function (c) {
          if (!c.client_id || !entreJours(c.recu_le, d1, d2)) return;
          var x = r[c.client_id] || (r[c.client_id] = { n: 0, poids: 0, dernier: null });
          x.n++;
          x.poids = arrondi(x.poids + (Number(c.poids_lb) || 0));
          if (!x.dernier || new Date(c.recu_le) > new Date(x.dernier)) x.dernier = c.recu_le;
        });
        return r;
      }
      var actifs = colisPar(p.debut, p.fin), actifsPrec = colisPar(p.precDebut, p.precFin);
      var clients = d.comptes.filter(function (c) { return c.role === 'client'; });
      var liste = clients.map(function (cl) {
        var facture = 0, paye = 0, solde = 0, derniere = actifs[cl.id] ? actifs[cl.id].dernier : null, touche = !!actifs[cl.id];
        (d.factures || []).forEach(function (f) {
          if (f.client_id !== cl.id || f.statut === 'annulee') return;
          solde = arrondi(solde + factureComplete(d, f).solde_usd);
          if (entreJours(f.cree_le, p.debut, p.fin)) { facture = arrondi(facture + f.montant_usd); touche = true; }
        });
        (d.factures || []).forEach(function (f) {
          paiementsValides(f).forEach(function (pa) {
            if (pa.client_id !== cl.id || !entreJours(pa.paye_le, p.debut, p.fin)) return;
            paye = arrondi(paye + pa.montant_usd);
            touche = true;
            if (!derniere || new Date(pa.paye_le) > new Date(derniere)) derniere = pa.paye_le;
          });
        });
        if (!touche) return null;
        return { id: cl.id, code: cl.code, nom_complet: cl.nom_complet, ville: cl.ville || '', pays: cl.pays || '',
                 colis: actifs[cl.id] ? actifs[cl.id].n : 0, poids: actifs[cl.id] ? actifs[cl.id].poids : 0,
                 facture: facture, paye: paye, solde: solde, derniere_activite: derniere };
      }).filter(Boolean).sort(function (x, y) {
        return (y[tri] - x[tri]) || String(x.nom_complet).localeCompare(String(y.nom_complet));
      });
      var n = Object.keys(actifs).map(function (k) { return actifs[k].n; });
      function segment(nom, def, test) {
        var l = n.filter(test);
        return { segment: nom, definition: def, clients: l.length, colis: l.reduce(function (t, x) { return t + x; }, 0) };
      }
      return {
        periode: periode,
        total_fin: clients.filter(function (c) { return entreJours(c.cree_le, null, p.fin) || actifs[c.id]; }).length,
        nouveaux: comparerValeurs(clients.filter(function (c) { return entreJours(c.cree_le, p.debut, p.fin); }).length,
                                  clients.filter(function (c) { return entreJours(c.cree_le, p.precDebut, p.precFin); }).length),
        actifs: comparerValeurs(n.length, Object.keys(actifsPrec).length),
        inactifs: clients.filter(function (c) { return entreJours(c.cree_le, null, p.fin) && !actifs[c.id]; }).length,
        colis_par_client_actif: n.length ? arrondi(n.reduce(function (t, x) { return t + x; }, 0) / n.length) : null,
        segments: [segment('petite', '1 colis sur la période', function (x) { return x === 1; }),
                   segment('moyenne', '2 à 4 colis sur la période', function (x) { return x >= 2 && x <= 4; }),
                   segment('forte', '5 colis ou plus sur la période', function (x) { return x >= 5; })],
        tri: tri, total_liste: liste.length, lignes: liste.slice(decalage, decalage + parPage)
      };
    }
    if (module === 'finances') {
      a = mesuresAnalytics(d, p.debut, p.fin);
      b = mesuresAnalytics(d, p.precDebut, p.precFin);
      var jour = aujourdhui(), frais = 0, transport = 0, moyens = {};
      var cr = { total: 0, factures: 0, impayees: 0, partielles: 0, en_retard: 0, montant_en_retard: 0, non_echues: 0, sans_echeance: 0 };
      var tranches = [['0_30', 0, 30], ['31_60', 31, 60], ['61_90', 61, 90], ['90_plus', 91, Infinity]].map(function (t) {
        return { tranche: t[0], factures: 0, montant: 0, min: t[1], max: t[2] };
      });
      (d.factures || []).forEach(function (f) {
        if (f.statut !== 'annulee' && entreJours(f.cree_le, p.debut, p.fin)) {
          frais = arrondi(frais + (f.frais_service_usd || 0));
          transport = arrondi(transport + f.montant_usd - (f.frais_service_usd || 0));
        }
        paiementsValides(f).forEach(function (pa) {
          if (!entreJours(pa.paye_le, p.debut, p.fin)) return;
          var m = moyens[pa.moyen] || (moyens[pa.moyen] = { moyen: pa.moyen, nombre: 0, montant: 0 });
          m.nombre++;
          m.montant = arrondi(m.montant + pa.montant_usd);
        });
        if (f.statut === 'annulee') return;
        var c = factureComplete(d, f);
        if (!(c.solde_usd > 0)) return;
        cr.total = arrondi(cr.total + c.solde_usd);
        cr.factures++;
        if (c.paye_usd === 0) cr.impayees++; else cr.partielles++;
        var e = f.echeance_le ? String(f.echeance_le).slice(0, 10) : null;
        if (!e) cr.sans_echeance++;
        else if (e < jour) { cr.en_retard++; cr.montant_en_retard = arrondi(cr.montant_en_retard + c.solde_usd); }
        else cr.non_echues++;
        var age = ecartJours(jourSD(f.cree_le), jour);
        tranches.forEach(function (t) {
          if (age >= t.min && age <= t.max) { t.factures++; t.montant = arrondi(t.montant + c.solde_usd); }
        });
      });
      cr.age = tranches.map(function (t) { return { tranche: t.tranche, factures: t.factures, montant: t.montant }; });
      return {
        periode: periode,
        facture: comparerValeurs(a.facture, b.facture), encaisse: comparerValeurs(a.encaisse, b.encaisse),
        reste: comparerValeurs(a.reste, b.reste), factures_emises: comparerValeurs(a.factures_emises, b.factures_emises),
        frais_service: frais, transport: transport,
        par_moyen: Object.keys(moyens).map(function (k) { return moyens[k]; })
          .sort(function (x, y) { return y.montant - x.montant || (x.moyen < y.moyen ? -1 : 1); }),
        creances: cr,
        creances_fin: comparerValeurs(creancesAu(d, p.fin), creancesAu(d, p.precFin)),
        depenses: { suivi: false }, dettes: { suivi: false }, resultat: { suivi: false }
      };
    }
    if (module === 'routes') {
      function ville(c) { var v = String(c.destination || '').trim().toLowerCase(); return v || null; }
      var co2 = d.colis.filter(function (c) { return entreJours(c.recu_le, p.debut, p.fin); });
      var prec = d.colis.filter(function (c) { return entreJours(c.recu_le, p.precDebut, p.precFin); });
      var livraisons = {};
      evenementsDeStatut(d, p.debut).forEach(function (e) {
        if (e.vers === 'livre' && (!livraisons[e.colis_id] || new Date(e.cree_le) < new Date(livraisons[e.colis_id]))) livraisons[e.colis_id] = e.cree_le;
      });
      var routes = {}, pays = {}, villes = {};
      co2.forEach(function (c) {
        var k = c.pays_destination + '|' + c.service;
        var r = routes[k] || (routes[k] = { pays: c.pays_destination, service: c.service, colis: 0, poids: 0, facture: 0, livres: 0, d: [] });
        r.colis++;
        r.poids = arrondi(r.poids + (Number(c.poids_lb) || 0));
        (d.factures || []).forEach(function (f) {
          if (f.statut === 'annulee') return;
          (f.facture_lignes || []).forEach(function (l) { if (l.colis_id === c.id) r.facture = arrondi(r.facture + l.montant_usd); });
        });
        if (c.statut === 'livre') r.livres++;
        if (livraisons[c.id]) { var h = heuresEntre(c.recu_le, livraisons[c.id]); if (h >= 0) r.d.push(h); }
        pays[c.pays_destination] = pays[c.pays_destination] || { pays: c.pays_destination, colis: 0, colis_precedents: 0 };
        pays[c.pays_destination].colis++;
        var v = ville(c);
        if (v) {
          var kv = v + '|' + c.pays_destination;
          var nom = v.replace(/(^|[^a-zà-ÿ])([a-zà-ÿ])/g, function (m0, s0, l0) { return s0 + l0.toUpperCase(); });
          (villes[kv] = villes[kv] || { ville: nom, pays: c.pays_destination, colis: 0, cle: v }).colis++;
        }
      });
      prec.forEach(function (c) {
        pays[c.pays_destination] = pays[c.pays_destination] || { pays: c.pays_destination, colis: 0, colis_precedents: 0 };
        pays[c.pays_destination].colis_precedents++;
      });
      return {
        periode: periode, origine: 'Miami (Medley), FL', origines_distinctes: 1,
        routes: Object.keys(routes).map(function (k) {
          var r = routes[k];
          return { pays: r.pays, service: r.service, colis: r.colis, poids: r.poids, facture: r.facture, livres: r.livres,
                   taux_livre: Math.round(r.livres * 1000 / r.colis) / 10,
                   delai_moyen_h: r.d.length ? Math.round(r.d.reduce(function (t, x) { return t + x; }, 0) / r.d.length * 10) / 10 : null,
                   colis_precedents: prec.filter(function (c) { return c.pays_destination === r.pays && c.service === r.service; }).length };
        }).sort(function (x, y) { return y.colis - x.colis || (x.pays < y.pays ? -1 : 1) || (x.service < y.service ? -1 : 1); }),
        pays: Object.keys(pays).map(function (k) { return pays[k]; })
          .sort(function (x, y) { return y.colis - x.colis || (x.pays < y.pays ? -1 : 1); }),
        villes: Object.keys(villes).map(function (k) { return villes[k]; })
          .sort(function (x, y) { return y.colis - x.colis || (x.cle < y.cle ? -1 : 1); }).slice(0, 10)
          .map(function (v) {
            return { ville: v.ville, pays: v.pays, colis: v.colis,
                     colis_precedents: prec.filter(function (c) { return ville(c) === v.cle && c.pays_destination === v.pays; }).length };
          }),
        sans_ville: co2.filter(function (c) { return !ville(c); }).length
      };
    }
    if (module === 'scanner') {
      function scans(d1, d2) {
        return d.historique.filter(function (h) { return (h.metadonnees || {}).source === 'scanner' && entreJours(h.cree_le, d1, d2); });
      }
      var s = scans(p.debut, p.fin);
      var ops = {}, comptes = {}, lieux = {}, colisVus = {}, joursVus = {}, parJourCompte = {};
      s.forEach(function (h) {
        ops[h.type_evenement] = (ops[h.type_evenement] || 0) + 1;
        var k = h.auteur_id || '';
        var c = comptes[k] || (comptes[k] = { operations: 0, jours: {} });
        c.operations++;
        c.jours[jourSD(h.cree_le)] = true;
        var l = String(h.lieu || '').trim();
        lieux[l] = (lieux[l] || 0) + 1;
        colisVus[h.colis_id] = true;
        joursVus[jourSD(h.cree_le)] = true;
        (parJourCompte[k + '|' + jourSD(h.cree_le)] = parJourCompte[k + '|' + jourSD(h.cree_le)] || []).push(h);
      });
      var ecarts = [];
      Object.keys(parJourCompte).forEach(function (k) {
        var l = parJourCompte[k].sort(function (x, y) { return new Date(x.cree_le) - new Date(y.cree_le) || x.id - y.id; });
        for (var i = 1; i < l.length; i++) ecarts.push(heuresEntre(l[i - 1].cree_le, l[i].cree_le) * 60);
      });
      var st = statistiquesDurees(ecarts);
      return {
        periode: periode,
        total: comparerValeurs(s.length, scans(p.precDebut, p.precFin).length),
        colis: Object.keys(colisVus).length, jours_actifs: Object.keys(joursVus).length, echecs_suivis: false,
        par_operation: Object.keys(ops).map(function (k) {
          return { type: k, libelle: TYPES_EVENEMENT[k] ? TYPES_EVENEMENT[k].libelle : k, nombre: ops[k] };
        }).sort(function (x, y) { return y.nombre - x.nombre || (x.type < y.type ? -1 : 1); }),
        par_compte: Object.keys(comptes).map(function (k) {
          var cl = d.comptes.filter(function (c) { return c.id === k; })[0];
          return { nom: cl ? (cl.nom_complet || cl.email) : 'Compte supprimé', role: cl ? cl.role : null,
                   operations: comptes[k].operations, jours: Object.keys(comptes[k].jours).length };
        }).sort(function (x, y) { return String(x.nom).localeCompare(String(y.nom)); }),
        par_lieu: Object.keys(lieux).map(function (k) { return { lieu: k, nombre: lieux[k] }; })
          .sort(function (x, y) { return y.nombre - x.nombre || (x.lieu < y.lieu ? -1 : 1); }),
        intervalle_minutes: { nombre: st.nombre, mediane: st.mediane_h, moyenne: st.moyenne_h }
      };
    }
    // qualite : toute la base, sans période
    var dernier = {};
    d.historique.forEach(function (h) {
      if (corrigeDemo(d, h)) return;
      var x = dernier[h.colis_id];
      if (!x || new Date(h.cree_le) > new Date(x.cree_le) || (h.cree_le === x.cree_le && h.id > x.id)) dernier[h.colis_id] = h;
    });
    var avecEv = {}, avecRecu = {};
    d.historique.forEach(function (h) { avecEv[h.colis_id] = true; if (h.statut === 'recu') avecRecu[h.colis_id] = true; });
    var ids = d.comptes.map(function (c) { return c.id; });
    var paiements = [];
    (d.factures || []).forEach(function (f) { (f.paiements || []).forEach(function (pa) { paiements.push({ p: pa, f: f }); }); });
    var colisEv = d.colis.filter(function (c) { return avecEv[c.id]; });
    return {
      genere_le: maintenant(),
      indicateurs: [
        { code: 'colis_historique_complet', libelle: 'Colis avec un événement de réception',
          ok: d.colis.filter(function (c) { return avecRecu[c.id]; }).length, total: d.colis.length },
        { code: 'colis_historique_coherent', libelle: 'Colis dont le statut est celui du dernier événement',
          ok: colisEv.filter(function (c) { return dernier[c.id] && dernier[c.id].statut === c.statut; }).length, total: colisEv.length },
        { code: 'evenements_attribues', libelle: 'Événements avec le compte qui les a faits',
          ok: d.historique.filter(function (h) { return h.auteur_id; }).length, total: d.historique.length },
        { code: 'factures_liees', libelle: 'Factures liées à un client existant',
          ok: (d.factures || []).filter(function (f) { return ids.indexOf(f.client_id) >= 0; }).length, total: (d.factures || []).length },
        { code: 'paiements_lies', libelle: 'Paiements liés à une facture du même client',
          ok: paiements.filter(function (x) { return x.p.client_id === x.f.client_id; }).length, total: paiements.length }
      ],
      anomalies: [
        { code: 'colis_sans_evenement', libelle: 'Colis sans aucun événement', nombre: d.colis.length - colisEv.length },
        { code: 'colis_statut_incoherent', libelle: 'Colis dont le statut diffère du dernier événement',
          nombre: colisEv.filter(function (c) { return !dernier[c.id] || dernier[c.id].statut !== c.statut; }).length },
        { code: 'colis_sans_client', libelle: 'Colis sans client (compte supprimé)',
          nombre: d.colis.filter(function (c) { return !c.client_id; }).length },
        { code: 'colis_sans_poids', libelle: 'Colis sans poids (prix non calculable)',
          nombre: d.colis.filter(function (c) { return c.poids_lb == null; }).length },
        { code: 'colis_sans_facture', libelle: 'Colis d’un client sur aucune facture active',
          nombre: d.colis.filter(function (c) { return c.client_id && !factureActiveDu(d, c.id); }).length },
        { code: 'evenements_sans_auteur', libelle: 'Événements sans compte (antérieurs à la Phase 3)',
          nombre: d.historique.filter(function (h) { return !h.auteur_id; }).length },
        { code: 'factures_sans_client', libelle: 'Factures sans client existant',
          nombre: (d.factures || []).filter(function (f) { return ids.indexOf(f.client_id) < 0; }).length },
        { code: 'paiements_sans_facture', libelle: 'Paiements sans facture, ou d’un autre client',
          nombre: paiements.filter(function (x) { return x.p.client_id !== x.f.client_id; }).length }
      ],
      facturation: []
    };
  }

  var demoAPI = {
    identifiantsAdmin: ADMIN_DEMO,

    session: function () {
      var moi = compteConnecte(lireDonnees());
      return plusTard(moi ? { id: moi.id, email: moi.email } : null);
    },

    profil: function () {
      return plusTard(publicProfil(compteConnecte(lireDonnees())));
    },

    inscrire: function (x) {
      var d = lireDonnees();
      var email = String(x.email || '').trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return echec('email-invalide');
      if (trouverCompte(d, email)) return echec('email-existe');
      if (String(x.motDePasse || '').length < MDP_MINIMUM) return echec('mot-de-passe-faible');
      var compte = {
        id: identifiant(), email: email, mdp: empreinte(x.motDePasse), role: 'client', code: nouveauCode(d.comptes),
        nom_complet: x.nom_complet, pays: x.pays, region: x.region, ville: x.ville, adresse: x.adresse,
        telephone: x.telephone, langue: LANGUE, cree_le: maintenant()
      };
      d.comptes.push(compte);
      ecrireDonnees(d);
      stockage('ecrire', CLE_SESSION, compte.id);
      return plusTard({ profil: publicProfil(compte), confirmation: false });
    },

    connecter: function (email, motDePasse) {
      var compte = trouverCompte(lireDonnees(), email);
      if (!compte || compte.mdp !== empreinte(motDePasse)) return echec('identifiants');
      stockage('ecrire', CLE_SESSION, compte.id);
      return plusTard(publicProfil(compte));
    },

    deconnecter: function () {
      stockage('effacer', CLE_SESSION);
      return plusTard(true);
    },

    // En démonstration, une session ne se termine que si un autre onglet se
    // déconnecte : on écoute le stockage du navigateur.
    surSessionPerdue: function (rappel) {
      var ecoute = function (e) { if (e.key === CLE_SESSION && !e.newValue) rappel(); };
      window.addEventListener('storage', ecoute);
      return function () { window.removeEventListener('storage', ecoute); };
    },

    // En démonstration, aucun e-mail n'est envoyé : le lien est affiché à l'écran.
    envoyerLienMotDePasse: function (email) {
      var compte = trouverCompte(lireDonnees(), email);
      if (!compte) return plusTard({});
      var jeton = Math.random().toString(36).slice(2, 12);
      stockage('ecrire', CLE_RECUP, JSON.stringify({ id: compte.id, jeton: jeton, expire: Date.now() + 3600e3 }));
      return plusTard({ lienDemo: 'nouveau-mot-de-passe.html#recuperation=' + jeton });
    },

    attendreRecuperation: function () {
      var m = /recuperation=([a-z0-9]+)/.exec(location.hash);
      var r = null;
      try { r = JSON.parse(stockage('lire', CLE_RECUP)); } catch (e) { r = null; }
      if (m && r && r.jeton === m[1] && r.expire > Date.now()) {
        stockage('ecrire', CLE_SESSION, r.id);
        stockage('effacer', CLE_RECUP);
        return plusTard(true);
      }
      return plusTard(!!compteConnecte(lireDonnees()));
    },

    changerMotDePasse: function (motDePasse) {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('lien-invalide');
      if (String(motDePasse).length < MDP_MINIMUM) return echec('mot-de-passe-faible');
      if (moi.mdp === empreinte(motDePasse)) return echec('meme-mot-de-passe');
      moi.mdp = empreinte(motDePasse);
      ecrireDonnees(d);
      return plusTard(true);
    },

    modifierProfil: function (champs) {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var c = choisir(champs, CHAMPS_PROFIL);
      Object.keys(c).forEach(function (k) { moi[k] = c[k]; });
      ecrireDonnees(d);
      return plusTard(publicProfil(moi));
    },

    mesColis: function () {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var lignes = d.colis.filter(function (c) { return c.client_id === moi.id; })
        .sort(function (a, b) { return new Date(b.maj_le) - new Date(a.maj_le); })
        .map(function (c) { return avecHistorique(d, c); });
      return plusTard(lignes);
    },

    mesFactures: function () {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      // Les mêmes champs que public.mes_factures : payé, solde et état, le
      // tarif de chaque ligne, les paiements reçus (pas ceux annulés)
      var lignes = (d.factures || []).filter(function (f) { return f.client_id === moi.id; })
        .sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); })
        .map(function (f) {
          var c = factureComplete(d, f);
          return {
            id: f.id, numero: f.numero, montant_usd: f.montant_usd, frais_service_usd: f.frais_service_usd,
            montant_paye_usd: c.paye_usd, paye_usd: c.paye_usd, solde_usd: c.solde_usd, etat: c.etat_paiement,
            statut: f.statut, note: f.note, lien_paiement: f.lien_paiement, moyen: f.moyen,
            echeance_le: f.echeance_le, cree_le: f.cree_le, payee_le: f.payee_le, annulee_le: f.annulee_le || null,
            lignes: (f.facture_lignes || []).map(function (l) {
              var colis = trouverColisDemo(d, l.colis_id);
              return {
                libelle: l.libelle, montant_usd: l.montant_usd, quantite: l.quantite || 1,
                poids_lb: l.poids_lb != null ? l.poids_lb : (colis ? colis.poids_lb : null),
                tarif_lb_usd: l.tarif_lb_usd != null ? l.tarif_lb_usd : null,
                colis: colis ? colis.numero : null
              };
            }),
            paiements: paiementsValides(c).map(function (p) {
              return { montant_usd: p.montant_usd, moyen: p.moyen, paye_le: p.paye_le };
            })
          };
        });
      return plusTard(lignes);
    },

    // mon_resume : le compte connecté, sur ses propres données
    monResume: function () {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var colis = d.colis.filter(function (c) { return c.client_id === moi.id; });
      function nb(test) { return colis.filter(test).length; }
      var r = {
        colis: {
          en_cours: nb(function (c) { return c.statut !== 'livre'; }),
          livres: nb(function (c) { return c.statut === 'livre'; }),
          disponibles: nb(function (c) { return c.statut === 'disponible'; }),
          action_requise: nb(function (c) { return c.statut === 'incident'; })
        },
        factures: null,
        notifications: null
      };
      if (peutCompte(moi, 'invoices.view', moi.id)) {
        var f = { nombre: 0, facture_usd: 0, paye_usd: 0, solde_usd: 0, ouvertes: 0, en_retard: 0, montant_en_retard: 0,
                  prochaine_echeance: null };
        var jour = aujourdhui();
        (d.factures || []).forEach(function (x) {
          if (x.client_id !== moi.id || x.statut === 'annulee') return;
          var c = factureComplete(d, x);
          f.nombre++;
          f.facture_usd = arrondi(f.facture_usd + x.montant_usd);
          f.paye_usd = arrondi(f.paye_usd + c.paye_usd);
          f.solde_usd = arrondi(f.solde_usd + c.solde_usd);
          if (c.solde_usd > 0) f.ouvertes++;
          if (c.etat_paiement === 'en_retard') {
            f.en_retard++;
            f.montant_en_retard = arrondi(f.montant_en_retard + c.solde_usd);
          }
          var e = x.echeance_le ? String(x.echeance_le).slice(0, 10) : null;
          if (c.solde_usd > 0 && e && e >= jour && (!f.prochaine_echeance || e < f.prochaine_echeance)) f.prochaine_echeance = e;
        });
        r.factures = f;
      }
      if (peutCompte(moi, 'shipments.view', moi.id)) {
        var ids = colis.map(function (c) { return c.id; });
        r.notifications = (d.notifications || []).filter(function (n) {
          return n.client_id === moi.id || ids.indexOf(n.colis_id) >= 0;
        }).sort(function (a, b) { return new Date(b.envoye_le) - new Date(a.envoye_le); }).slice(0, 10)
          .map(function (n) {
            var c = n.colis_id ? trouverColisDemo(d, n.colis_id) : null;
            return { canal: n.canal, evenement: n.evenement, envoye_le: n.envoye_le, numero: c ? c.numero : null };
          });
      }
      return plusTard(r);
    },

    // mes_notifications : les siennes, traduites, les plus récentes d'abord
    mesNotifications: function (o) {
      o = o || {};
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var filtre = o.filtre || 'toutes';
      if (['toutes', 'non_lues', 'colis', 'factures', 'paiements', 'compte'].indexOf(filtre) < 0) {
        return rejeter(Erreur('INVALID_FILTER', 'Filtre inconnu.'));
      }
      var langue = ['fr', 'en', 'es', 'ht'].indexOf(o.langue) >= 0 ? o.langue : langueNotification(moi.langue);
      var miennes = (d.notificationsApp || []).filter(function (n) { return n.client_id === moi.id; });
      var liste = miennes.filter(function (n) {
        return filtre === 'toutes' || (filtre === 'non_lues' ? !n.lu_le : n.categorie === filtre);
      }).sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le) || b.id - a.id; });
      var parPage = Math.min(Math.max(Number(o.parPage) || 20, 1), 100), page = Math.max(Number(o.page) || 0, 0);
      return plusTard({
        total: liste.length,
        non_lues: miennes.filter(function (n) { return !n.lu_le; }).length,
        elements: liste.slice(page * parPage, page * parPage + parPage).map(function (n) {
          var t = texteNotification(n.type, langue, n.donnees);
          return { id: n.id, type: n.type, categorie: n.categorie, priorite: n.priorite, titre: t.titre, message: t.message,
                   lu: !!n.lu_le, date: n.cree_le, colis_id: n.colis_id, numero: n.donnees.numero || null,
                   facture_id: n.facture_id, facture_numero: n.donnees.facture || null };
        })
      });
    },

    notificationsNonLues: function () {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      return plusTard((d.notificationsApp || []).filter(function (n) { return n.client_id === moi.id && !n.lu_le; }).length);
    },

    marquerNotificationsLues: function (ids) {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var nb = 0;
      (d.notificationsApp || []).forEach(function (n) {
        if (n.client_id === moi.id && !n.lu_le && (!ids || !ids.length || ids.indexOf(n.id) >= 0)) {
          n.lu_le = maintenant();
          nb++;
        }
      });
      ecrireDonnees(d);
      return plusTard(nb);
    },

    mesPreferencesNotifications: function () {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var prefs = d.preferencesNotifications || {};
      var canaux = {};
      CANAUX_NOTIFICATIONS.forEach(function (c) {
        canaux[c] = { configure: canalConfigureDemo(c), appareils: c === 'push' ? 0 : null };
      });
      return plusTard({
        canaux: canaux,
        preferences: ['colis', 'factures', 'paiements'].map(function (cat) {
          var p = { categorie: cat };
          CANAUX_NOTIFICATIONS.forEach(function (c) { p[c] = prefs[moi.id + ':' + cat + ':' + c] !== false; });
          return p;
        })
      });
    },

    reglerPreferenceNotification: function (categorie, canal, actif) {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      if (['colis', 'factures', 'paiements'].indexOf(categorie) < 0 || CANAUX_NOTIFICATIONS.indexOf(canal) < 0) {
        return rejeter(Erreur('INVALID_PREFERENCE', 'Réglage de notification inconnu.'));
      }
      d.preferencesNotifications = d.preferencesNotifications || {};
      d.preferencesNotifications[moi.id + ':' + categorie + ':' + canal] = !!actif;
      journaliser(d, moi, 'notification.preference', 'client', moi.id, null,
                  { categorie: categorie, canal: canal, actif: !!actif });
      ecrireDonnees(d);
      return plusTard(null);
    },

    surveiller: function (rappel, options) {
      options = options || {};
      abonnes.push(rappel);
      if (options.etat) setTimeout(function () { options.etat(true); }, 300);
      return function () { abonnes = abonnes.filter(function (a) { return a !== rappel; }); };
    },

    suivre: function (numero) {
      var d = lireDonnees();
      var n = String(numero || '').trim().toUpperCase();
      if (n.length < 4) return plusTard(null);
      var c = d.colis.filter(function (x) { return x.numero === n || (x.suivi_transporteur && x.suivi_transporteur === n); })[0];
      if (!c) return plusTard(null);
      var x = avecHistorique(d, c);
      return plusTard({
        numero: x.numero, statut: x.statut, service: x.service, pays_destination: x.pays_destination, maj_le: x.maj_le,
        historique: x.historique.map(function (h) { return { statut: h.statut, lieu: h.lieu, cree_le: h.cree_le }; })
      });
    },

    estAdmin: function () {
      var moi = compteConnecte(lireDonnees());
      return plusTard(!!(moi && moi.role === 'admin'));
    },

    // mes_permissions de la base
    permissions: function () {
      var moi = compteConnecte(lireDonnees());
      return plusTard(moi ? { role: moi.role, equipe: moi.role !== 'client',
                              permissions: (PERMISSIONS_DES_ROLES[moi.role] || []).slice() }
                          : { role: null, equipe: false, permissions: [] });
    },

    admin: {
      statistiques: function () {
        var d = lireDonnees();
        try { exiger(d, 'shipments.view'); } catch (e) { return echec(e.code); }
        var statuts = {}, livres30 = 0, limite = Date.now() - 30 * 864e5;
        d.colis.forEach(function (c) {
          statuts[c.statut] = (statuts[c.statut] || 0) + 1;
          if (c.statut === 'livre' && new Date(c.maj_le).getTime() > limite) livres30 += 1;
        });
        var clients = d.comptes.filter(function (c) { return c.role === 'client'; }).length;
        return plusTard({ clients: clients, statuts: statuts, livres_30j: livres30 });
      },

      colis: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exiger(d, 'shipments.view'); } catch (e) { return echec(e.code); }
        var t = nettoyer(o.recherche);
        var lignes = d.colis.map(function (c) { return detailsColis(d, c); }).filter(function (c) {
          if (o.statut === 'actifs' && c.statut === 'livre') return false;
          if (o.statut && o.statut !== 'actifs' && c.statut !== o.statut) return false;
          if (o.clientId && c.client_id !== o.clientId) return false;
          if (o.pays && c.pays_destination !== o.pays) return false;
          if (o.service && c.service !== o.service) return false;
          if (o.depuis && new Date(c.recu_le) < new Date(o.depuis)) return false;
          if (o.jusqua && new Date(c.recu_le) >= new Date(o.jusqua)) return false;
          if (t && !contient([c.numero, c.suivi_transporteur, c.code_client, c.nom_client, c.telephone_client,
                              c.description, c.destination], t)) return false;
          return true;
        }).sort(function (a, b) { return new Date(b.maj_le) - new Date(a.maj_le); });
        return plusTard(page(lignes, o));
      },

      // historique_colis : tous les événements, dans l'ordre d'écriture
      historique: function (id) {
        var d = lireDonnees();
        try { exiger(d, 'shipments.view_history'); } catch (e) { return echec(e.code); }
        return plusTard(historiqueDe(d, id).map(function (h) { return evenementJson(d, h); }));
      },

      chercherClient: function (code) {
        var d = lireDonnees();
        try { exiger(d, 'clients.view'); } catch (e) { return echec(e.code); }
        var n = normaliserCode(code);
        var c = d.comptes.filter(function (x) { return n && x.code === n; })[0];
        return plusTard(c ? choisir(publicProfil(c), ['id', 'code', 'nom_complet', 'pays', 'region', 'ville', 'telephone', 'email', 'langue']) : null);
      },

      clients: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exiger(d, 'clients.view'); } catch (e) { return echec(e.code); }
        var t = nettoyer(o.recherche);
        var lignes = d.comptes.filter(function (c) {
          return c.role === 'client' && (!t || contient([c.code, c.nom_complet, c.telephone, c.email, c.ville, c.region], t));
        }).sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); }).map(publicProfil);
        return plusTard(page(lignes, o));
      },

      // Même contrat que creer_colis : { colis, facture, deja }
      creerColis: function (x, cle) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.create');
          var existant = cle ? d.colis.filter(function (c) { return c.cle_idempotence === cle; })[0] : null;
          if (existant) {
            if (existant.client_id !== x.client_id) {
              throw Erreur('DUPLICATE_OPERATION', 'Cette requête a déjà servi à enregistrer le colis ' +
                           existant.numero + ' pour un autre client.');
            }
            var dejaFacture = factureActiveDu(d, existant.id);
            return plusTard({ colis: detailsColis(d, existant), facture: factureComplete(d, dejaFacture), deja: true });
          }
          var c = choisir(x, CHAMPS_CREATION);
          c.id = identifiant();
          c.poids_lb = lireNombre(x.poids_lb, 'INVALID_WEIGHT', 'Poids illisible.');
          c.tarif_lb_usd = lireNombre(x.tarif_lb_usd, 'INVALID_RATE', 'Tarif illisible.');
          c.service = c.service || 'aerien';
          c.pays_destination = c.pays_destination || 'HT';
          c.lieu = c.lieu || 'Miami (Medley), FL';
          c.statut = 'recu';
          c.cle_idempotence = cle || null;
          c.cree_le = c.maj_le = maintenant();
          c.recu_le = c.recu_le || c.cree_le;
          reglesColis(d, c, null);
          d.seqColis += 1;
          c.numero = 'GSE-' + d.seqColis + '-' + c.pays_destination;
          d.colis.push(c);
          historiser(d, c, c.recu_le);
          journaliser(d, moi, 'colis.creation', 'colis', c.id, null, choisir(c, RESUME_COLIS.slice(0, 9)));
          var facture = facturerColisDemo(d, moi, c).facture;
          ecrireDonnees(d);
          prevenir('factures');
          return plusTard({ colis: detailsColis(d, c), facture: facture, deja: false });
        } catch (e) { return rejeter(e); }
      },

      modifierColis: function (id, champs, majLe) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.edit');
          var c = trouverColisDemo(d, id);
          if (!c) throw Erreur('SHIPMENT_NOT_FOUND', 'Ce colis n’existe plus.');
          if (majLe && c.maj_le !== majLe) {
            throw Erreur('CONCURRENT_MODIFICATION', 'Le colis ' + c.numero +
                         ' a été modifié par quelqu’un d’autre entre-temps : rechargez-le.');
          }
          var nouveau = Object.assign({}, c, choisir(champs, CHAMPS_MODIFIABLES));
          if ('poids_lb' in champs) nouveau.poids_lb = lireNombre(champs.poids_lb, 'INVALID_WEIGHT', 'Poids illisible.');
          if ('tarif_lb_usd' in champs) {
            nouveau.tarif_lb_usd = lireNombre(champs.tarif_lb_usd, 'INVALID_RATE', 'Tarif illisible.');
          }
          reglesColis(d, nouveau, c);
          var diff = difference(c, nouveau, RESUME_COLIS);
          Object.assign(c, nouveau, { maj_le: maintenant() });
          if (diff) journaliser(d, moi, 'colis.modification', 'colis', c.id, diff.avant, diff.apres);
          ecrireDonnees(d);
          return plusTard(detailsColis(d, c));
        } catch (e) { return rejeter(e); }
      },

      // Même contrat que changer_statut_colis : tout ou rien, et
      // { modifies, inchanges, ids, evenements, refus }
      changerStatut: function (ids, etape, attendus, motif, cle) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.change_status');
          var statut = etape.statut, lieu = String(etape.lieu || '').trim(), note = String(etape.note || '').trim();
          if (!TRANSITIONS[statut]) throw Erreur('INVALID_STATUS', 'Statut inconnu : ' + (statut || '(vide)') + '.');
          if (lieu.length > 80) throw Erreur('INVALID_LOCATION', 'Lieu trop long (80 caractères au plus).');
          if (statut === 'disponible' && !lieu) {
            throw Erreur('LOCATION_REQUIRED', 'Indiquez l\u2019agence où le client peut retirer son colis.');
          }
          var uniques = (ids || []).filter(function (i, k, t) { return i && t.indexOf(i) === k; });
          if (!uniques.length) throw Erreur('INVALID_INPUT', 'Aucun colis choisi.');
          if (uniques.length > 500) throw Erreur('INVALID_INPUT', 'Au plus 500 colis à la fois.');
          var plan = [], inchanges = 0, refus = [];
          uniques.forEach(function (id) {
            var c = trouverColisDemo(d, id);
            var attendu = attendus ? attendus[id] : null;
            if (!c) {
              refus.push({ id: id, numero: null, code: 'SHIPMENT_NOT_FOUND', statut: null,
                           detail: 'Un colis choisi n\u2019existe plus.' });
            } else if (cle && d.historique.some(function (h) { return h.cle_idempotence === cle + ':' + id; })) {
              inchanges++;
            } else if (c.statut === statut) {
              if ((attendu && attendu !== statut) || ((c.lieu || '') === lieu && (c.note || '') === note)) inchanges++;
              else plan.push({ c: c, type: 'MISE_A_JOUR' });
            } else if (attendu && attendu !== c.statut) {
              refus.push({ id: id, numero: c.numero, code: 'STATUS_CONFLICT', statut: c.statut,
                           detail: c.numero + ' est passé à « ' + LIBELLES[c.statut] + ' » entre-temps : rechargez la liste.' });
            } else {
              var type = typePourStatut(c.statut, statut, statutPrecedent(historiqueDe(d, c.id), c.statut));
              if (!type) {
                refus.push({ id: id, numero: c.numero, code: 'INVALID_STATUS_TRANSITION', statut: c.statut,
                             detail: c.numero + ' : ' + LIBELLES[c.statut] + ' → ' + LIBELLES[statut] + ' interdit.' });
              } else if (type === 'CORRECTION' && !String(motif || '').trim()) {
                refus.push({ id: id, numero: c.numero, code: 'INVALID_EVENT_DATA', statut: c.statut,
                             detail: c.numero + ' : revenir à « ' + LIBELLES[statut] + ' » est une correction, donnez-en le motif.' });
              } else {
                plan.push({ c: c, type: type });
              }
            }
          });
          if (refus.length) return plusTard({ modifies: 0, inchanges: 0, ids: [], evenements: [], refus: refus });
          var modifies = [], evenements = [];
          plan.forEach(function (p) {
            var r = operationDemo(d, moi, p.c.id, p.type, {
              lieu: lieu, note: note, metadonnees: { source: 'tableau_de_bord' }, cle: cle ? cle + ':' + p.c.id : null,
              attendu: p.c.statut, cible: p.type === 'ACTION_RESOLUE' ? statut : null, motif: motif
            });
            if (r.deja) inchanges++;
            else { modifies.push(p.c.id); evenements.push(r.evenement); }
          });
          if (modifies.length) ecrireDonnees(d);
          return plusTard({ modifies: modifies.length, inchanges: inchanges, ids: modifies, evenements: evenements,
                            refus: [] });
        } catch (e) { return rejeter(e); }
      },

      statutsPossibles: function (id) {
        var d = lireDonnees();
        try {
          exiger(d, 'shipments.change_status');
          var c = trouverColisDemo(d, id);
          if (!c) throw Erreur('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
          var precedent = statutPrecedent(historiqueDe(d, id), c.statut);
          return plusTard({
            actuel: c.statut, precedent: precedent,
            possibles: STATUTS.filter(function (s) {
              return ['identique', 'normale', 'sortie_incident'].indexOf(natureTransition(c.statut, s, precedent)) >= 0;
            }),
            correction: natureTransition(c.statut, precedent, precedent) === 'correction' ? precedent : null
          });
        } catch (e) { return rejeter(e); }
      },

      scannerColis: function (reference) {
        var d = lireDonnees();
        try {
          exiger(d, 'shipments.scan');
          var r = String(reference || '').trim();
          if (r.length < 4 || r.length > 60) throw Erreur('INVALID_SCAN_FORMAT', 'Code illisible : ' + r.slice(0, 60) + '.');
          var c = colisParReference(d, r);
          return plusTard(c ? ficheScanner(d, c) : null);
        } catch (e) { return rejeter(e); }
      },

      operationScanner: function (reference, type, o) {
        o = o || {};
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.scan');
          var v = String(type || '').trim().toUpperCase();
          if (OPERATIONS_SCANNER.indexOf(v) < 0) {
            throw Erreur('EVENT_TYPE_INVALID', 'Opération impossible depuis le scanner : ' + (type || '(vide)') + '.');
          }
          var r = String(reference || '').trim();
          if (r.length < 4 || r.length > 60) throw Erreur('INVALID_SCAN_FORMAT', 'Code illisible : ' + r.slice(0, 60) + '.');
          var c = colisParReference(d, r);
          if (!c) throw Erreur('SHIPMENT_NOT_FOUND', 'Aucun colis ne porte le numéro ' + r.toUpperCase() + '.');
          var res = operationDemo(d, moi, c.id, v, {
            lieu: o.lieu, note: o.note, metadonnees: Object.assign(avecPoste(o.metadonnees), { source: 'scanner' }),
            cle: o.cle, attendu: o.attendu, cible: o.cible
          });
          if (!res.deja) ecrireDonnees(d);
          return plusTard({
            code: res.deja ? 'ALREADY_IN_TARGET_STATE' : 'OK',
            message: (res.deja ? 'Déjà fait : ' : '') + TYPES_EVENEMENT[v].libelle,
            resultat: res,
            fiche: ficheScanner(d, trouverColisDemo(d, c.id))
          });
        } catch (e) { return rejeter(e); }
      },

      trouverColis: function (reference) {
        var d = lireDonnees();
        try { exiger(d, 'shipments.view'); } catch (e) { return rejeter(e); }
        var n = String(reference || '').trim().toUpperCase();
        if (n.length < 4) return plusTard(null);
        var c = d.colis.filter(function (x) { return x.numero === n || (x.suivi_transporteur && x.suivi_transporteur === n); })
          .sort(function (a, b) { return new Date(b.maj_le) - new Date(a.maj_le); })[0];
        if (!c) return plusTard(null);
        return plusTard(Object.assign(detailsColis(d, c), { historique: avecHistorique(d, c, true).historique }));
      },

      journal: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exiger(d, 'audit_logs.view'); } catch (e) { return rejeter(e); }
        var lignes = (d.journal || []).filter(function (j) {
          return (!o.entite || j.entite === o.entite) && (!o.entiteId || j.entite_id === String(o.entiteId));
        }).slice().reverse();
        return plusTard(page(lignes, o));
      },

      supprimerColis: function (id) {
        var d = lireDonnees();
        var moi;
        try { moi = exiger(d, 'shipments.delete'); } catch (e) { return echec(e.code); }
        var parti = trouverColisDemo(d, id);
        if (parti) journaliser(d, moi, 'colis.suppression', 'colis', id, choisir(parti, RESUME_COLIS.slice(0, 9)), null);
        d.colis = d.colis.filter(function (c) { return c.id !== id; });
        d.historique = d.historique.filter(function (h) { return h.colis_id !== id; });
        d.notifications = (d.notifications || []).filter(function (n) { return n.colis_id !== id; });
        ecrireDonnees(d);
        return plusTard(true);
      },

      /* ---- Notifications (copie de supabase-notifications.sql, partie 12) ---- */
      envoisColis: function (id) {
        var d = lireDonnees();
        try { exiger(d, 'shipments.view'); } catch (e) { return echec(e.code); }
        var lignes = [];
        (d.notificationsApp || []).filter(function (n) { return n.colis_id === id; })
          .sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); })
          .forEach(function (n) {
            (d.envoisNotifications || []).filter(function (e) { return e.notification_id === n.id; }).forEach(function (e) {
              lignes.push({ notification_id: n.id, type: n.type, cree_le: n.cree_le, canal: e.canal, statut: e.statut,
                            code_erreur: e.code_erreur, tentative: e.tentative });
            });
          });
        return plusTard(lignes);
      },

      centreNotifications: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exiger(d, 'reports.view'); } catch (e) { return echec(e.code); }
        var fin = o.fin ? new Date(o.fin) : new Date(), debut = o.debut ? new Date(o.debut) : new Date(fin - 30 * 864e5);
        var notifs = {};
        (d.notificationsApp || []).forEach(function (n) { notifs[n.id] = n; });
        var dans = function (date) { var t = new Date(date); return t >= debut && t < fin; };
        var e = (d.envoisNotifications || []).filter(function (x) {
          var n = notifs[x.notification_id];
          return n && dans(x.cree_le) && (!o.type || n.type === o.type) && (!o.canal || x.canal === o.canal) &&
                 (!o.statut || x.statut === o.statut);
        });
        var parStatut = {}, parCanal = {};
        e.forEach(function (x) {
          parStatut[x.statut] = (parStatut[x.statut] || 0) + 1;
          var c = parCanal[x.canal] = parCanal[x.canal] || { total: 0, envoye: 0, echec: 0, attente: 0, annule: 0, taux_echec: null };
          c.total++;
          if (x.statut === 'envoye' || x.statut === 'livre') c.envoye++;
          else if (x.statut === 'echec') c.echec++;
          else if (x.statut === 'attente' || x.statut === 'envoi') c.attente++;
          else if (x.statut === 'annule') c.annule++;
        });
        Object.keys(parCanal).forEach(function (k) {
          var c = parCanal[k];
          c.taux_echec = c.envoye + c.echec ? Math.round(1000 * c.echec / (c.envoye + c.echec)) / 10 : null;
        });
        var parPage = Math.min(Math.max(Number(o.parPage) || 25, 1), 100), page = Math.max(Number(o.page) || 0, 0);
        var tries = e.slice().sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le) || b.id - a.id; });
        var enPeriode = (d.notificationsApp || []).filter(function (n) { return dans(n.cree_le) && (!o.type || n.type === o.type); });
        return plusTard({
          periode: { debut: debut.toISOString(), fin: fin.toISOString() },
          notifications: enPeriode.length,
          non_lues: (d.notificationsApp || []).filter(function (n) { return dans(n.cree_le) && !n.lu_le; }).length,
          envois: e.length, par_statut: parStatut, par_canal: parCanal, delai_moyen_s: null, alertes: [], total: e.length,
          elements: tries.slice(page * parPage, page * parPage + parPage).map(function (x) {
            var n = notifs[x.notification_id];
            var cl = d.comptes.filter(function (c) { return c.id === n.client_id; })[0];
            return { id: x.id, notification_id: n.id, type: n.type, canal: x.canal, fournisseur: x.fournisseur,
                     statut: x.statut, tentative: x.tentative, code_erreur: x.code_erreur, cree_le: x.cree_le,
                     envoye_le: x.envoye_le, client_code: cl ? cl.code : null, numero: n.donnees.numero || null,
                     facture: n.donnees.facture || null };
          })
        });
      },

      suiviNotification: function (id) {
        var d = lireDonnees();
        try { exiger(d, 'reports.view'); } catch (e) { return echec(e.code); }
        var n = (d.notificationsApp || []).filter(function (x) { return x.id === Number(id); })[0];
        if (!n) return rejeter(Erreur('NOTIFICATION_NOT_FOUND', 'Notification introuvable.'));
        var cl = d.comptes.filter(function (c) { return c.id === n.client_id; })[0];
        var h = n.historique_id ? d.historique.filter(function (x) { return x.id === n.historique_id; })[0] : null;
        var regle = reglesNotificationsDemo(d).filter(function (r) { return r.type === n.type; })[0];
        var evtF = !h && n.facture_id ? (d.evenementsFacturation || []).filter(function (f) {
          return f.facture_id === n.facture_id && regle && f.type === regle.evenement &&
                 (!n.paiement_id || f.paiement_id === n.paiement_id);
        })[0] : null;
        return plusTard({
          notification: { id: n.id, type: n.type, categorie: n.categorie, priorite: n.priorite, cree_le: n.cree_le,
                          lu_le: n.lu_le, cle: n.cle, client_code: cl ? cl.code : null, numero: n.donnees.numero || null,
                          facture: n.donnees.facture || null },
          evenement: h ? { source: 'colis', id: h.id, type: h.type_evenement, statut: h.statut, date: h.cree_le }
            : evtF ? { source: 'facturation', id: evtF.facture_id, type: evtF.type, date: evtF.cree_le } : null,
          regle: regle ? { actif: regle.actif, canaux: regle.canaux, sensible: regle.sensible } : null,
          envois: (d.envoisNotifications || []).filter(function (e) { return e.notification_id === n.id; }).map(function (e) {
            return { canal: e.canal, fournisseur: e.fournisseur, statut: e.statut, tentative: e.tentative,
                     code_erreur: e.code_erreur, erreur: null, message_id: null, cree_le: e.cree_le, envoye_le: e.envoye_le,
                     prochain_essai_le: null };
          })
        });
      },

      reglesNotifications: function () {
        var d = lireDonnees();
        try { exiger(d, 'reports.view'); } catch (e) { return echec(e.code); }
        var canaux = {};
        CANAUX_NOTIFICATIONS.forEach(function (c) { canaux[c] = canalConfigureDemo(c); });
        var ordre = { colis: 0, facturation: 1, planifie: 2 };
        return plusTard({
          modifiable: peutCompte(compteConnecte(d), 'settings.manage'),
          canaux: canaux,
          regles: reglesNotificationsDemo(d).sort(function (a, b) {
            return ordre[a.source] - ordre[b.source] || (a.type < b.type ? -1 : 1);
          }).map(function (r) {
            return { type: r.type, libelle: r.libelle, evenement: r.evenement, categorie: r.categorie, priorite: r.priorite,
                     canaux: r.canaux, sensible: r.sensible, actif: r.actif, maj_le: r.maj_le || null };
          })
        });
      },

      modifierRegleNotification: function (type, actif, canaux) {
        var d = lireDonnees();
        var moi;
        try { moi = exiger(d, 'settings.manage'); } catch (e) { return echec(e.code); }
        var avant = reglesNotificationsDemo(d).filter(function (r) { return r.type === type; })[0];
        if (!avant) return rejeter(Erreur('RULE_NOT_FOUND', 'Règle de notification inconnue.'));
        canaux = canaux || [];
        if (canaux.some(function (c) { return CANAUX_NOTIFICATIONS.indexOf(c) < 0; })) {
          return rejeter(Erreur('INVALID_RULE', 'Canaux de notification inconnus.'));
        }
        d.reglesNotifications = d.reglesNotifications || {};
        d.reglesNotifications[type] = { actif: !!actif, canaux: canaux.filter(function (c, i) { return canaux.indexOf(c) === i; }).sort(),
                                        maj_le: maintenant() };
        journaliser(d, moi, 'notification.regle', 'notification_regle', type,
                    { actif: avant.actif, canaux: avant.canaux }, { actif: !!actif, canaux: canaux });
        ecrireDonnees(d);
        return plusTard(null);
      },

      testerNotification: function (canal) {
        var d = lireDonnees();
        var moi;
        try { moi = exiger(d, 'settings.manage'); } catch (e) { return echec(e.code); }
        if (CANAUX_NOTIFICATIONS.indexOf(canal) < 0) return rejeter(Erreur('INVALID_CHANNEL', 'Canal inconnu.'));
        var minute = new Date().toISOString().slice(0, 16);
        var id = creerNotificationDemo(d, 'test', moi.id, 'test:' + moi.id + ':' + canal + ':' + minute, {}, {}, [canal]);
        if (!id) return rejeter(Erreur('TOO_MANY_TESTS', 'Un essai par minute au plus.'));
        journaliser(d, moi, 'notification.test', 'notification', id, null, { canal: canal });
        ecrireDonnees(d);
        return demoAPI.admin.suiviNotification(id);
      },

      // L'équipe et ses rôles (equipe() de la base)
      equipe: function () {
        var d = lireDonnees();
        var moi;
        try { moi = exiger(d, 'users.view'); } catch (e) { return echec(e.code); }
        var ordre = ['admin', 'gerant', 'employe'];
        return plusTard(d.comptes.filter(function (c) { return ROLES_EQUIPE.indexOf(c.role) >= 0; })
          .sort(function (a, b) {
            return ordre.indexOf(a.role) - ordre.indexOf(b.role) || String(a.nom_complet).localeCompare(String(b.nom_complet));
          })
          .map(function (c) {
            return { id: c.id, nom_complet: c.nom_complet, email: c.email, role: c.role, cree_le: c.cree_le, moi: c.id === moi.id };
          }));
      },

      // changer_role de la base : mêmes refus, même journal
      changerRole: function (compte, role) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'roles.manage');
          role = String(role || '').trim().toLowerCase();
          if (ROLES_EQUIPE.concat(['client']).indexOf(role) < 0) {
            throw Erreur('INVALID_ROLE', 'Rôle inconnu : ' + (role || '(vide)') + '. Choisissez client, employe, gerant ou admin.');
          }
          var ref = String(compte || '').trim().toLowerCase();
          var c = d.comptes.filter(function (x) { return x.id === compte || (ref && x.email === ref); })[0];
          if (!c) {
            throw Erreur('USER_NOT_FOUND', 'Aucun compte avec l\u2019adresse ' + compte +
                         '. La personne doit d\u2019abord créer son compte sur le site.');
          }
          if (c.id === moi.id) {
            throw Erreur('SELF_ROLE_CHANGE', 'On ne change pas son propre rôle : demandez-le à un autre administrateur.');
          }
          var resume = { id: c.id, email: c.email, nom_complet: c.nom_complet };
          if (c.role === role) return plusTard({ compte: resume, ancien_role: c.role, nouveau_role: role, deja: true });
          if (c.role === 'admin' && d.comptes.filter(function (x) { return x.role === 'admin'; }).length <= 1) {
            throw Erreur('LAST_ADMIN', 'C\u2019est le dernier administrateur : nommez-en un autre d\u2019abord.');
          }
          var ancien = c.role;
          c.role = role;
          if (role === 'client' && !c.code) c.code = nouveauCode(d.comptes);
          journaliser(d, moi, 'utilisateur.role', 'client', c.id, { role: ancien, email: c.email }, { role: role, email: c.email });
          ecrireDonnees(d, 'clients');
          return plusTard({ compte: resume, ancien_role: ancien, nouveau_role: role, deja: false });
        } catch (e) { return rejeter(e); }
      },

      // definir_lien_paiement de la base
      poserLienPaiement: function (id, lien) {
        var d = lireDonnees();
        try {
          var moi = compteConnecte(d);
          var modifie = peutCompte(moi, 'invoices.edit');
          if (!modifie && !peutCompte(moi, 'shipments.create')) throw Erreur('non-autorise');
          lien = String(lien || '').trim();
          if (!/^https:\/\/\S+$/i.test(lien) || lien.length > 500) {
            throw Erreur('INVALID_INPUT', 'Le lien de paiement doit être une adresse https://.');
          }
          var f = (d.factures || []).filter(function (x) { return x.id === id; })[0];
          if (!f) throw Erreur('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
          if (!modifie && f.lien_paiement) throw Erreur('non-autorise');
          if (f.statut === 'annulee') throw Erreur('INVOICE_LOCKED', 'Une facture annulée ne se modifie plus.');
          f.lien_paiement = lien;
          ecrireDonnees(d, 'factures');
          return plusTard({ id: f.id, numero: f.numero, lien_paiement: lien });
        } catch (e) { return rejeter(e); }
      },

      preparerLogo: function () {
        return plusTard('demo');
      },

      /* ---- Factures (démonstration) ------------------------------------ */

      factures: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exiger(d, 'invoices.view'); } catch (e) { return echec(e.code); }
        var etat = o.etat || o.statut;
        var lignes = (d.factures || []).slice().sort(function (a, b) {
          return new Date(b.cree_le) - new Date(a.cree_le);
        }).filter(function (f) {
          if (o.client_id && f.client_id !== o.client_id) return false;
          if (o.id && f.id !== o.id) return false;
          if (etat === 'payee' || etat === 'annulee' || etat === 'a_payer') return f.statut === etat;
          if (etat === 'partielle') return f.statut === 'a_payer' && f.montant_paye_usd > 0;
          if (etat === 'en_retard') return f.statut === 'a_payer' && f.echeance_le && f.echeance_le < aujourdhui();
          return true;
        }).map(function (f) { return factureComplete(d, f); });
        return plusTard({ lignes: lignes, total: lignes.length });
      },

      // Même contrat que creer_facture : { facture, deja }
      creerFacture: function (champs, colisIds, cle) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'invoices.create');
          var clientId = champs.client_id;
          if (!d.comptes.some(function (c) { return c.id === clientId && c.role === 'client'; })) {
            throw Erreur('CLIENT_NOT_FOUND', 'Aucun client avec cet identifiant.');
          }
          var existante = cle ? (d.factures || []).filter(function (f) { return f.cle_idempotence === cle; })[0] : null;
          if (existante) {
            if (existante.client_id !== clientId) {
              throw Erreur('DUPLICATE_OPERATION', 'Cette requête a déjà servi pour un autre client.');
            }
            return plusTard({ facture: factureComplete(d, existante), deja: true });
          }
          var ids = (colisIds || []).filter(function (i, k, t) { return i && t.indexOf(i) === k; });
          if (ids.length > 200) throw Erreur('INVALID_INPUT', 'Au plus 200 colis par facture.');
          var colis = ids.map(function (id) { return trouverColisDemo(d, id); });
          if (colis.some(function (c) { return !c; })) throw Erreur('SHIPMENT_NOT_FOUND', 'Un colis choisi n’existe plus.');
          var montant, frais = 0;
          if (colis.length) {
            colis.forEach(function (c) {
              if (c.client_id !== clientId) {
                throw Erreur('INVOICE_CLIENT_MISMATCH', 'Le colis ' + c.numero +
                             ' appartient à un autre client : une facture n’en regroupe qu’un seul.');
              }
              var autre = factureActiveDu(d, c.id);
              if (autre) {
                throw Erreur('INVOICE_ALREADY_EXISTS', 'Le colis ' + c.numero + ' est déjà sur la facture ' + autre.numero + '.');
              }
            });
            frais = FRAIS_SERVICE;
            montant = arrondi(colis.reduce(function (s, c) { return s + prixColis(c); }, 0) + frais);
          } else {
            montant = lireNombre(champs.montant_usd, 'INVALID_AMOUNT', 'Montant illisible.');
            if (montant == null || montant < 0) throw Erreur('INVALID_AMOUNT', 'Indiquez le montant de la facture.');
            montant = arrondi(montant);
          }
          var paye = lireNombre(champs.montant_paye_usd, 'INVALID_AMOUNT', 'Montant payé illisible.') || 0;
          if (paye < 0) throw Erreur('INVALID_AMOUNT', 'Le montant payé ne peut pas être négatif.');
          paye = Math.min(arrondi(paye), montant);
          var f = nouvelleFacture(d, moi, {
            client_id: clientId, montant_usd: montant, frais_service_usd: frais, montant_paye_usd: paye,
            echeance_le: champs.echeance_le || null,
            lien_paiement: String(champs.lien_paiement || '').trim().slice(0, 500),
            note: String(champs.note || '').trim().slice(0, 500),
            cle_idempotence: cle || null
          }, colis.sort(function (a, b) { return new Date(a.recu_le) - new Date(b.recu_le); }));
          ecrireDonnees(d, 'factures');
          return plusTard({ facture: factureComplete(d, f), deja: false });
        } catch (e) { return rejeter(e); }
      },

      facturerColis: function (colisId) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'invoices.create');
          var c = trouverColisDemo(d, colisId);
          if (!c) throw Erreur('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
          var r = facturerColisDemo(d, moi, c);
          if (!r.deja) ecrireDonnees(d, 'factures');
          return plusTard(r);
        } catch (e) { return rejeter(e); }
      },

      // La facture d'un colis, pour le bouton « Voir la facture » de sa fiche.
      factureDuColis: function (colisId) {
        var d = lireDonnees();
        try { exiger(d, 'invoices.view'); } catch (e) { return echec(e.code); }
        var trouvees = (d.factures || []).filter(function (f) {
          return (f.facture_lignes || []).some(function (l) { return l.colis_id === colisId; });
        }).sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); });
        return plusTard(trouvees[0] ? factureComplete(d, trouvees[0]) : null);
      },

      // garde_facture et regles_facture : seuls l'échéance, la note, le lien
      // et le total d'une facture sans colis se changent ; une facture annulée
      // ne se change plus.
      modifierFacture: function (id, champs) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'invoices.edit');
          var f = (d.factures || []).filter(function (x) { return x.id === id; })[0];
          if (!f) return echec('inconnu');
          var n = Object.assign({}, f, choisir(champs, CHAMPS_FACTURE));
          if (n.montant_usd != null) n.montant_usd = arrondi(n.montant_usd);
          var change = CHAMPS_FACTURE.some(function (k) { return JSON.stringify(n[k]) !== JSON.stringify(f[k]); });
          if (f.statut === 'annulee' && change) throw Erreur('INVOICE_LOCKED', 'Une facture annulée ne se modifie plus.');
          if (n.montant_usd !== f.montant_usd) {
            if (n.montant_usd < f.montant_paye_usd) {
              throw Erreur('INVALID_AMOUNT', 'Le nouveau total est inférieur à ce qui est déjà payé (' +
                           montantTexte(f.montant_paye_usd) + ' $).');
            }
            if ((f.facture_lignes || []).some(function (l) { return l.colis_id; })) {
              throw Erreur('INVOICE_LOCKED', 'Le total d’une facture de colis est celui de ses colis et de ses frais : il ne se modifie pas.');
            }
          }
          var diff = difference(f, n, ['montant_usd', 'note', 'lien_paiement', 'echeance_le']);
          Object.assign(f, choisir(n, CHAMPS_FACTURE));
          if (diff && 'montant_usd' in diff.apres) recalculerFactureDemo(d, f);
          if (diff) journaliser(d, moi, 'facture.modification', 'facture', f.id, diff.avant, diff.apres);
          ecrireDonnees(d, 'factures');
          return plusTard(factureComplete(d, f));
        } catch (e) { return rejeter(e); }
      },

      enregistrerPaiement: function (factureId, v, cle) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'payments.create');
          v = v || {};
          if (cle) {
            var deja = null;
            (d.factures || []).forEach(function (f) {
              (f.paiements || []).forEach(function (p) { if (p.cle_idempotence === cle) deja = p; });
            });
            if (deja) {
              if (deja.facture_id !== factureId) {
                throw Erreur('DUPLICATE_OPERATION', 'Cette requête a déjà servi pour une autre facture.');
              }
              var fd = (d.factures || []).filter(function (x) { return x.id === factureId; })[0];
              return plusTard({ paiement: Object.assign({}, deja), facture: factureComplete(d, fd), deja: true });
            }
          }
          var montant = lireNombre(v.montant_usd, 'INVALID_AMOUNT', 'Montant illisible.');
          if (montant == null || montant <= 0) {
            throw Erreur('INVALID_AMOUNT', 'Le montant du paiement doit être supérieur à zéro.');
          }
          if (v.paye_le && isNaN(new Date(v.paye_le).getTime())) {
            throw Erreur('INVALID_DATE', 'Date du paiement illisible.');
          }
          var f = (d.factures || []).filter(function (x) { return x.id === factureId; })[0];
          if (!f) throw Erreur('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
          var p = ajouterPaiementDemo(d, moi, f, Object.assign({}, v, { montant_usd: montant }), 'saisie', cle);
          ecrireDonnees(d, 'factures');
          return plusTard({ paiement: Object.assign({}, p), facture: factureComplete(d, f), deja: false });
        } catch (e) { return rejeter(e); }
      },

      annulerPaiement: function (id, motif) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'payments.cancel');
          var f = null, p = null;
          (d.factures || []).forEach(function (x) {
            (x.paiements || []).forEach(function (y) { if (y.id === id) { f = x; p = y; } });
          });
          if (!p) throw Erreur('PAYMENT_NOT_FOUND', 'Aucun paiement avec cet identifiant.');
          if (p.annule_le) return plusTard({ paiement: Object.assign({}, p), facture: factureComplete(d, f), deja: true });
          motif = String(motif || '').trim().slice(0, 300);
          if (!motif) throw Erreur('REASON_REQUIRED', 'Indiquez pourquoi ce paiement est annulé.');
          p.annule_le = maintenant();
          p.annule_par = moi.id;
          p.motif_annulation = motif;
          recalculerFactureDemo(d, f);
          var resume = { facture: f.numero, montant_usd: p.montant_usd, moyen: p.moyen, reference: p.reference,
                         paye_le: p.paye_le, origine: p.origine };
          journaliser(d, moi, 'paiement.annulation', 'paiement', p.id, resume, { motif: motif });
          noterEvenementDemo(d, 'PAIEMENT_ANNULE', f, p, Object.assign({ motif: motif }, resume));
          ecrireDonnees(d, 'factures');
          return plusTard({ paiement: Object.assign({}, p), facture: factureComplete(d, f), deja: false });
        } catch (e) { return rejeter(e); }
      },

      annulerFacture: function (id, motif) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'invoices.cancel');
          var f = (d.factures || []).filter(function (x) { return x.id === id; })[0];
          if (!f) throw Erreur('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
          if (f.statut === 'annulee') return plusTard({ facture: factureComplete(d, f), deja: true });
          motif = String(motif || '').trim().slice(0, 300);
          if (!motif) throw Erreur('REASON_REQUIRED', 'Indiquez pourquoi cette facture est annulée.');
          var paye = payeDe({ paiements: f.paiements || [] });
          if (paye > 0) {
            throw Erreur('INVOICE_HAS_PAYMENTS', 'La facture ' + f.numero + ' a reçu ' + montantTexte(paye) +
                         ' $ : annulez d’abord ses paiements, un par un, avec leur motif.');
          }
          var avant = f.statut;
          Object.assign(f, { statut: 'annulee', payee_le: null, annulee_le: maintenant(), annulee_par: moi.id,
                             motif_annulation: motif });
          journaliser(d, moi, 'facture.annulation', 'facture', f.id, { statut: avant }, { statut: 'annulee', motif: motif });
          noterEvenementDemo(d, 'FACTURE_ANNULEE', f, null, { numero: f.numero, motif: motif });
          ecrireDonnees(d, 'factures');
          return plusTard({ facture: factureComplete(d, f), deja: false });
        } catch (e) { return rejeter(e); }
      },

      regrouperFactures: function (ids, cle) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'invoices.create');
          exiger(d, 'invoices.cancel');
          if (cle) {
            var existante = (d.factures || []).filter(function (f) { return f.cle_idempotence === cle; })[0];
            if (existante) {
              return plusTard({
                facture: factureComplete(d, existante),
                annulees: (d.factures || []).filter(function (f) { return f.remplacee_par === existante.id; })
                  .map(function (f) { return f.numero; }).sort(),
                deja: true
              });
            }
          }
          var uniques = (ids || []).filter(function (i, k, t) { return i && t.indexOf(i) === k; }).sort();
          if (uniques.length < 2) throw Erreur('INVALID_INPUT', 'Choisissez au moins deux factures à regrouper.');
          if (uniques.length > 50) throw Erreur('INVALID_INPUT', 'Au plus 50 factures par regroupement.');
          var choisies = uniques.map(function (i) { return (d.factures || []).filter(function (f) { return f.id === i; })[0]; });
          if (choisies.some(function (f) { return !f; })) {
            throw Erreur('INVOICE_NOT_FOUND', 'Une des factures choisies n’existe plus.');
          }
          var client = choisies[0].client_id, colis = [], echeance = null, numeros = [];
          choisies.forEach(function (f) {
            if (f.client_id !== client) {
              throw Erreur('INVOICE_CLIENT_MISMATCH',
                           'Les factures choisies appartiennent à plusieurs clients : on ne regroupe que celles d’un seul.');
            }
            var refus = refusRegroupement(f);
            if (refus) throw refus;
            (f.facture_lignes || []).forEach(function (l) { colis.push(trouverColisDemo(d, l.colis_id)); });
            if (f.echeance_le && (!echeance || f.echeance_le < echeance)) echeance = f.echeance_le;
            numeros.push(f.numero);
          });
          if (colis.some(function (c) { return !c; })) throw Erreur('SHIPMENT_NOT_FOUND', 'Un colis choisi n’existe plus.');
          var motif = 'Regroupement des factures ' + numeros.join(', ');
          choisies.forEach(function (f) {
            Object.assign(f, { statut: 'annulee', annulee_le: maintenant(), annulee_par: moi.id, motif_annulation: motif });
            noterEvenementDemo(d, 'FACTURE_ANNULEE', f, null, { numero: f.numero, motif: motif });
          });
          var montant = arrondi(colis.reduce(function (s, c) { return s + prixColis(c); }, 0) + FRAIS_SERVICE);
          var n = nouvelleFacture(d, moi, {
            client_id: client, montant_usd: montant, frais_service_usd: FRAIS_SERVICE, echeance_le: echeance,
            cle_idempotence: cle || null
          }, colis.sort(function (a, b) { return new Date(a.recu_le) - new Date(b.recu_le); }));
          choisies.forEach(function (f) { f.remplacee_par = n.id; });
          journaliser(d, moi, 'facture.regroupement', 'facture', n.id, { factures: numeros },
                      { numero: n.numero, montant_usd: n.montant_usd });
          ecrireDonnees(d, 'factures');
          return plusTard({ facture: factureComplete(d, n), annulees: numeros, deja: false });
        } catch (e) { return rejeter(e); }
      },

      calculerFacture: function (colisIds) {
        var d = lireDonnees();
        try { exiger(d, 'invoices.view'); } catch (e) { return echec(e.code); }
        var colis = (colisIds || []).map(function (i) { return trouverColisDemo(d, i); }).filter(Boolean)
          .sort(function (a, b) { return new Date(a.recu_le) - new Date(b.recu_le); });
        var sousTotal = arrondi(colis.reduce(function (s, c) { return s + prixColis(c); }, 0));
        var frais = colis.length ? FRAIS_SERVICE : 0;
        return plusTard({
          lignes: colis.map(function (c) {
            return { colis_id: c.id, numero: c.numero, description: c.description, poids_lb: c.poids_lb,
                     tarif_lb_usd: tarifDe(c), prix_usd: prixColis(c) };
          }),
          sous_total: sousTotal, frais_service: frais, total: arrondi(sousTotal + frais)
        });
      },

      resumeFacturation: function () {
        var d = lireDonnees();
        try { exiger(d, 'reports.view'); } catch (e) { return echec(e.code); }
        var r = { a_encaisser: 0, ouvertes: 0, partielles: 0, en_retard: 0, montant_en_retard: 0, encaisse_mois: 0 };
        var mois = aujourdhui().slice(0, 7);
        (d.factures || []).forEach(function (f) {
          (f.paiements || []).forEach(function (p) {
            if (!p.annule_le && new Date(new Date(p.paye_le).getTime() - 4 * 36e5).toISOString().slice(0, 7) === mois) {
              r.encaisse_mois = arrondi(r.encaisse_mois + p.montant_usd);
            }
          });
          if (f.statut === 'annulee') return;
          var c = factureComplete(d, f);
          r.a_encaisser = arrondi(r.a_encaisser + c.solde_usd);
          if (c.solde_usd > 0) r.ouvertes++;
          if (c.solde_usd > 0 && c.paye_usd > 0) r.partielles++;
          if (c.etat_paiement === 'en_retard') {
            r.en_retard++;
            r.montant_en_retard = arrondi(r.montant_en_retard + c.solde_usd);
          }
        });
        return plusTard(r);
      },

      // Le même rapport que rapport_anomalies_facturation, sur les données du navigateur
      anomaliesFacturation: function () {
        var d = lireDonnees();
        try { exiger(d, 'reports.view'); } catch (e) { return echec(e.code); }
        var sortie = [];
        function signaler(type, gravite, f, detail) {
          sortie.push({ type: type, gravite: gravite, facture_id: f ? f.id : null, numero: f ? f.numero : null,
                        detail: detail });
        }
        var factures = d.factures || [];
        factures.forEach(function (f) {
          var lignes = f.facture_lignes || [];
          var avecColis = lignes.some(function (l) { return l.colis_id; });
          var paye = payeDe({ paiements: f.paiements || [] });
          lignes.forEach(function (l) {
            var c = l.colis_id ? trouverColisDemo(d, l.colis_id) : null;
            if (!l.colis_id) {
              signaler('ligne_sans_colis', 'info', f, 'La ligne « ' + l.libelle + ' » (' + montantTexte(l.montant_usd) +
                       ' $) n’a plus de colis.');
              return;
            }
            if (!c) return;
            if (c.client_id !== f.client_id) signaler('client_different', 'erreur', f, 'Le colis ' + c.numero + ' appartient à un autre client.');
            if (f.statut === 'annulee') return;
            var autres = factures.filter(function (x) {
              return x.id !== f.id && x.statut !== 'annulee' &&
                (x.facture_lignes || []).some(function (m) { return m.colis_id === l.colis_id; });
            });
            if (autres.length) {
              signaler('colis_facture_deux_fois', 'erreur', f, 'Le colis ' + c.numero + ' est aussi sur la facture ' +
                       autres.map(function (x) { return x.numero; }).join(', ') + '.');
            }
            if (c.prix_usd != null && arrondi(c.prix_usd) !== arrondi(l.montant_usd)) {
              signaler('prix_colis_change', 'info', f, 'Le colis ' + c.numero + ' vaut aujourd’hui ' + montantTexte(c.prix_usd) +
                       ' $ ; la facture garde ' + montantTexte(l.montant_usd) + ' $.');
            }
          });
          var totalLignes = arrondi(lignes.reduce(function (s, l) { return s + l.montant_usd; }, 0));
          if (f.statut !== 'annulee' && avecColis && arrondi(totalLignes + f.frais_service_usd) !== arrondi(f.montant_usd)) {
            signaler('total_incoherent', 'erreur', f, 'Total ' + montantTexte(f.montant_usd) + ' $ ; lignes ' +
                     montantTexte(totalLignes) + ' $ + frais ' + montantTexte(f.frais_service_usd) + ' $.');
          }
          if (paye > f.montant_usd || f.montant_paye_usd > f.montant_usd) {
            signaler('paye_depasse_total', 'erreur', f, 'Payé ' + montantTexte(paye) + ' $ pour un total de ' +
                     montantTexte(f.montant_usd) + ' $.');
          }
          if (arrondi(f.montant_paye_usd) !== paye) {
            signaler('paye_different_paiements', 'erreur', f, 'La facture indique ' + montantTexte(f.montant_paye_usd) +
                     ' $ payés, ses paiements font ' + montantTexte(paye) + ' $.');
          }
          if ((f.statut === 'payee' && paye < f.montant_usd) || (f.statut === 'a_payer' && f.montant_usd > 0 && paye >= f.montant_usd)) {
            signaler('statut_incoherent', 'attention', f, f.statut === 'payee'
              ? 'Marquée payée, mais il reste ' + montantTexte(f.montant_usd - paye) + ' $ à payer.'
              : 'Marquée à payer, mais entièrement payée.');
          }
          if (f.statut === 'annulee' && paye > 0) {
            signaler('paiement_sur_facture_annulee', 'attention', f, montantTexte(paye) +
                     ' $ encaissés sur une facture annulée : à rembourser ou à reporter.');
          }
          if (f.statut !== 'annulee' && avecColis && !f.frais_service_usd && f.cree_le >= '2026-09-22T04:00:00.000Z') {
            signaler('frais_absents', 'info', f, 'Facture de colis sans frais de service.');
          }
        });
        d.colis.forEach(function (c) {
          if (c.client_id && !factureActiveDu(d, c.id)) {
            sortie.push({ type: 'colis_sans_facture', gravite: 'info', facture_id: null, numero: c.numero,
                          detail: 'Le colis ' + c.numero + ' n’est sur aucune facture active.' });
          }
        });
        var rang = { erreur: 0, attention: 1, info: 2 };
        sortie.sort(function (a, b) {
          return rang[a.gravite] - rang[b.gravite] || (a.type < b.type ? -1 : a.type > b.type ? 1 : 0) ||
                 String(a.numero).localeCompare(String(b.numero));
        });
        return plusTard(sortie);
      },

      // vue_generale : une période → ce que le rôle a le droit de voir
      vueGenerale: function (o) {
        o = o || {};
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.view');
          var jours = joursSansMouvement(o.jours);
          var p = bornesPeriode(o.periode, o.debut, o.fin);
          var serie = joursEntre(p.debut, p.fin);
          function dans(iso) { var j = jourSD(iso); return j >= p.debut && j <= p.fin; }
          function parJour(liste, cle, valeur) {
            var t = {};
            liste.forEach(function (x) { t[x.jour] = arrondi((t[x.jour] || 0) + (valeur ? valeur(x) : 1)); });
            return t;
          }

          // Les colis : le stock maintenant, les reçus et livrés de la période
          var statuts = {};
          STATUTS.forEach(function (st) { statuts[st] = 0; });
          d.colis.forEach(function (c) { statuts[c.statut] = (statuts[c.statut] || 0) + 1; });
          var recus = d.colis.filter(function (c) { return dans(c.recu_le); });
          var livraisons = {};
          d.historique.forEach(function (h) {
            if (h.statut !== 'livre' || h.statut_precedent === 'livre' || !dans(h.cree_le) || corrigeDemo(d, h)) return;
            var j = jourSD(h.cree_le);
            if (!livraisons[h.colis_id] || j < livraisons[h.colis_id]) livraisons[h.colis_id] = j;
          });
          var limite = Date.now() - jours * 864e5;
          var immobiles = d.colis.filter(function (c) {
            if (c.statut === 'livre') return false;
            var dernier = dernierEvenementDemo(d, c.id);
            return new Date(dernier ? dernier.cree_le : c.recu_le).getTime() < limite;
          }).length;
          var parRecu = parJour(recus.map(function (c) { return { jour: jourSD(c.recu_le) }; }));
          var parLivre = parJour(Object.keys(livraisons).map(function (k) { return { jour: livraisons[k] }; }));
          var colis = {
            total: d.colis.length,
            actifs: d.colis.length - statuts.livre,
            statuts: statuts,
            action_requise: statuts.incident,
            sans_mouvement: immobiles,
            recus_periode: recus.length,
            poids_periode: arrondi(recus.reduce(function (t, c) { return t + (Number(c.poids_lb) || 0); }, 0)),
            livres_periode: Object.keys(livraisons).length,
            par_jour: serie.map(function (j) { return { jour: j, recus: parRecu[j] || 0, livres: parLivre[j] || 0 }; })
          };
          var r = {
            periode: { code: p.code, debut: p.debut, fin: p.fin, jours: serie.length, fuseau: 'America/Santo_Domingo' },
            jours_sans_mouvement: jours,
            genere_le: maintenant(),
            colis: colis
          };

          if (peutCompte(moi, 'clients.view')) {
            var clients = d.comptes.filter(function (c) { return c.role === 'client'; });
            var idsClients = clients.map(function (c) { return c.id; });
            var actifs = {};
            d.colis.forEach(function (c) {
              if (c.statut !== 'livre' && idsClients.indexOf(c.client_id) >= 0) actifs[c.client_id] = true;
            });
            r.clients = {
              total: clients.length,
              nouveaux_periode: clients.filter(function (c) { return dans(c.cree_le); }).length,
              avec_colis_en_cours: Object.keys(actifs).length
            };
          }

          var facturation = null;
          if (peutCompte(moi, 'reports.view')) {
            var f = { emises_periode: 0, facture_periode: 0, paye_sur_periode: 0, solde_sur_periode: 0, annulees_periode: 0,
                      encaisse_periode: 0, paiements_periode: 0, a_encaisser: 0, ouvertes: 0, montant_en_retard: 0,
                      clients_avec_solde: 0, etats: { a_payer: 0, partielle: 0, en_retard: 0, payee: 0, annulee: 0 } };
            var avecSolde = {}, emissions = [], encaissements = [];
            (d.factures || []).forEach(function (x) {
              var c = factureComplete(d, x);
              f.etats[c.etat_paiement] += 1;
              if (x.statut !== 'annulee' && dans(x.cree_le)) {
                f.emises_periode++;
                f.facture_periode = arrondi(f.facture_periode + x.montant_usd);
                f.paye_sur_periode = arrondi(f.paye_sur_periode + c.paye_usd);
                f.solde_sur_periode = arrondi(f.solde_sur_periode + c.solde_usd);
                emissions.push({ jour: jourSD(x.cree_le), montant: x.montant_usd });
              }
              if (x.statut === 'annulee' && dans(x.cree_le)) f.annulees_periode++;
              f.a_encaisser = arrondi(f.a_encaisser + c.solde_usd);
              if (c.solde_usd > 0) { f.ouvertes++; avecSolde[x.client_id] = true; }
              if (c.etat_paiement === 'en_retard') f.montant_en_retard = arrondi(f.montant_en_retard + c.solde_usd);
              paiementsValides(x).forEach(function (pa) {
                if (dans(pa.paye_le)) encaissements.push({ jour: jourSD(pa.paye_le), montant: pa.montant_usd });
              });
            });
            f.encaisse_periode = arrondi(encaissements.reduce(function (t, x) { return t + x.montant; }, 0));
            f.paiements_periode = encaissements.length;
            f.clients_avec_solde = Object.keys(avecSolde).length;
            var parFacture = parJour(emissions, null, function (x) { return x.montant; });
            var parEncaisse = parJour(encaissements, null, function (x) { return x.montant; });
            f.par_jour = serie.map(function (j) { return { jour: j, facture: parFacture[j] || 0, encaisse: parEncaisse[j] || 0 }; });
            facturation = f;
            r.facturation = f;
          }

          if (peutCompte(moi, 'shipments.view_history')) {
            var tous = d.historique.filter(function (h) { return (h.metadonnees || {}).source === 'scanner'; });
            var scans = tous.filter(function (h) { return dans(h.cree_le); });
            var dernier = tous.slice().sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le) || b.id - a.id; })[0];
            var parEmploye = {}, parOperation = {};
            scans.forEach(function (h) {
              var k = h.auteur_id || '';
              parEmploye[k] = (parEmploye[k] || 0) + 1;
              parOperation[h.type_evenement] = (parOperation[h.type_evenement] || 0) + 1;
            });
            var parScan = parJour(scans.map(function (h) { return { jour: jourSD(h.cree_le) }; }));
            r.scanner = {
              aujourdhui: tous.filter(function (h) { return jourSD(h.cree_le) === aujourdhui(); }).length,
              periode: scans.length,
              echecs_suivis: false,
              dernier: dernier ? Object.assign(evenementJson(d, dernier), { numero: (trouverColisDemo(d, dernier.colis_id) || {}).numero || null })
                : null,
              par_employe: Object.keys(parEmploye).map(function (k) {
                var cl = d.comptes.filter(function (c) { return c.id === k; })[0];
                return { auteur_id: k || null, nom: cl ? (cl.nom_complet || cl.email) : 'Compte supprimé',
                         role: cl ? cl.role : null, nombre: parEmploye[k] };
              }).sort(function (a, b) { return b.nombre - a.nombre || String(a.nom).localeCompare(String(b.nom)); }),
              par_operation: Object.keys(parOperation).map(function (k) {
                return { type: k, libelle: TYPES_EVENEMENT[k] ? TYPES_EVENEMENT[k].libelle : k, nombre: parOperation[k] };
              }).sort(function (a, b) { return b.nombre - a.nombre || (a.type < b.type ? -1 : 1); }),
              par_jour: serie.map(function (j) { return { jour: j, nombre: parScan[j] || 0 }; })
            };
            r.activite = d.historique.slice().sort(function (a, b) {
              return new Date(b.cree_le) - new Date(a.cree_le) || b.id - a.id;
            }).slice(0, 12).map(function (h) {
              var c = trouverColisDemo(d, h.colis_id) || {};
              var cl = d.comptes.filter(function (x) { return x.id === c.client_id; })[0];
              return Object.assign(evenementJson(d, h), {
                numero: c.numero || null, client: cl ? cl.code : null,
                libelle: TYPES_EVENEMENT[h.type_evenement] ? TYPES_EVENEMENT[h.type_evenement].libelle : null,
                source: (h.metadonnees || {}).source || ''
              });
            });
          }

          if (peutCompte(moi, 'payments.view')) {
            var tousPaiements = [];
            (d.factures || []).forEach(function (x) {
              paiementsValides(x).forEach(function (pa) { tousPaiements.push({ p: pa, f: x }); });
            });
            r.paiements_recents = tousPaiements.sort(function (a, b) {
              return new Date(b.p.paye_le) - new Date(a.p.paye_le) || new Date(b.p.cree_le) - new Date(a.p.cree_le);
            }).slice(0, 8).map(function (x) {
              var cl = d.comptes.filter(function (c) { return c.id === x.p.client_id; })[0];
              return { id: x.p.id, montant_usd: x.p.montant_usd, moyen: x.p.moyen, paye_le: x.p.paye_le,
                       facture_id: x.f.id, facture: x.f.numero,
                       client: { code: cl ? cl.code : null, nom_complet: cl ? cl.nom_complet : null } };
            });
          }

          // Les alertes : les mêmes règles, les mêmes phrases que la base
          var alertes = [];
          if (colis.action_requise > 0) {
            alertes.push({ code: 'action_requise', gravite: 'critique', nombre: colis.action_requise,
                           message: colis.action_requise + ' colis en « action requise » : le client ou l’équipe doit agir.' });
          }
          if (colis.sans_mouvement > 0) {
            alertes.push({ code: 'sans_mouvement', gravite: 'attention', nombre: colis.sans_mouvement,
                           message: colis.sans_mouvement + ' colis en cours sans aucun événement depuis ' + jours + ' jours ou plus.' });
          }
          if (facturation && facturation.etats.en_retard > 0) {
            alertes.push({ code: 'factures_en_retard', gravite: 'attention', nombre: facturation.etats.en_retard,
                           message: facturation.etats.en_retard + ' facture(s) échue(s) non soldée(s) : ' +
                                    montantTexte(facturation.montant_en_retard).replace('.', ',') + ' $ en retard.' });
          }
          if (peutCompte(moi, 'invoices.view')) {
            var sansFacture = d.colis.filter(function (c) { return c.client_id && !factureActiveDu(d, c.id); }).length;
            if (sansFacture > 0) {
              alertes.push({ code: 'colis_sans_facture', gravite: 'info', nombre: sansFacture,
                             message: sansFacture + ' colis sur aucune facture active.' });
            }
          }
          r.alertes = alertes;
          return plusTard(r);
        } catch (e) { return rejeter(e); }
      },

      // colis_a_traiter : action requise, ou sans mouvement depuis N jours
      colisATraiter: function (liste, o) {
        o = o || {};
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.view');
          var l = String(liste || '').trim().toLowerCase();
          if (l !== 'action_requise' && l !== 'sans_mouvement') {
            throw Erreur('INVALID_INPUT', 'Liste inconnue : ' + l.slice(0, 30) + '.');
          }
          var jours = joursSansMouvement(o.jours);
          var parPage = trancheDemo(o.parPage, 25, 100), decalage = Math.max(0, (o.page || 0) * parPage);
          var historique = peutCompte(moi, 'shipments.view_history');
          var limite = Date.now() - jours * 864e5;
          var choisis = d.colis.filter(function (c) {
            return l === 'action_requise' ? c.statut === 'incident' : c.statut !== 'livre';
          }).map(function (c) {
            var dernier = dernierEvenementDemo(d, c.id);
            var action = null;
            if (l === 'action_requise') {
              historiqueDe(d, c.id).forEach(function (h) {
                if (h.statut === 'incident' && !corrigeDemo(d, h) && (!action || h.id > action.id)) action = h;
              });
            }
            var mouvement = dernier ? dernier.cree_le : c.recu_le;
            return { c: c, dernier: dernier, action: action, mouvement: mouvement, depuis: action ? action.cree_le : mouvement };
          }).filter(function (x) {
            return l === 'action_requise' || new Date(x.mouvement).getTime() < limite;
          }).sort(function (a, b) {
            return new Date(a.depuis) - new Date(b.depuis) || (a.c.numero < b.c.numero ? -1 : 1);
          });
          return plusTard({
            liste: l, jours: jours, total: choisis.length,
            lignes: choisis.slice(decalage, decalage + parPage).map(function (x) {
              var c = x.c;
              return {
                id: c.id, numero: c.numero, statut: c.statut, lieu: c.lieu || '', note: c.note || '',
                description: c.description || '', destination: c.destination || '',
                pays_destination: c.pays_destination, poids_lb: c.poids_lb == null ? null : c.poids_lb,
                recu_le: c.recu_le, maj_le: c.maj_le, depuis: x.depuis, dernier_mouvement: x.mouvement,
                jours: Math.floor((Date.now() - new Date(x.depuis).getTime()) / 864e5),
                client: clientResumeDemo(d, c.client_id, true),
                dernier_evenement: historique && x.dernier ? evenementJson(d, x.dernier) : null,
                action: historique && x.action ? evenementJson(d, x.action) : null
              };
            })
          });
        } catch (e) { return rejeter(e); }
      },

      // recherche_rapide : mêmes critères que la base
      rechercheRapide: function (texte) {
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'shipments.view');
          var brut = String(texte || '').trim().slice(0, 200);
          var qr = /[?&]suivi=([A-Za-z0-9-]+)/.exec(brut);
          var ref = (qr ? qr[1] : brut).trim();
          var finances = peutCompte(moi, 'invoices.view');
          var voitClients = peutCompte(moi, 'clients.view');
          var historique = peutCompte(moi, 'shipments.view_history');
          var r = { texte: brut, reference: ref, colis: [] };
          if (voitClients) r.clients = [];
          if (finances) r.factures = [];
          if (ref.length < 2) return plusTard(r);
          var maj = ref.toUpperCase();
          var chiffres = ref.replace(/[^0-9]/g, '');
          var code = chiffres.length >= 4 && /^(gse)?[\s-]*[0-9]+$/i.test(ref) ? 'GSE-' + chiffres : null;
          var lettres = /[a-zÀ-ɏ]/i.test(ref);
          var mots = lettres ? ref.toLowerCase().split(/[^0-9a-zÀ-ɏ]+/).filter(Boolean) : [];

          r.colis = d.colis.map(function (c) {
            var exact = c.numero === maj || (c.suivi_transporteur && (c.suivi_transporteur === ref || c.suivi_transporteur === maj));
            var trouve = exact || String(c.numero || '').indexOf(maj) === 0 ||
                         (code && String(c.numero || '').indexOf(code + '-') === 0);
            return trouve ? { c: c, exact: !!exact } : null;
          }).filter(Boolean).sort(function (a, b) {
            return (b.exact - a.exact) || (new Date(b.c.maj_le) - new Date(a.c.maj_le));
          }).slice(0, 8).map(function (x) {
            var c = x.c;
            var dernier = historique ? dernierEvenementDemo(d, c.id) : null;
            return {
              id: c.id, numero: c.numero, suivi_transporteur: c.suivi_transporteur || '', description: c.description || '',
              statut: c.statut, lieu: c.lieu || '', destination: c.destination || '', pays_destination: c.pays_destination,
              service: c.service, poids_lb: c.poids_lb == null ? null : c.poids_lb, recu_le: c.recu_le, maj_le: c.maj_le,
              exact: x.exact, prix_usd: finances ? (c.prix_usd == null ? null : c.prix_usd) : null,
              client: clientResumeDemo(d, c.client_id, true),
              dernier_evenement: dernier ? evenementJson(d, dernier) : null,
              facture: finances ? factureResumeDemo(d, c.id) : null
            };
          });

          if (voitClients) {
            r.clients = d.comptes.filter(function (cl) {
              if (cl.role !== 'client') return false;
              if (code && cl.code === code) return true;
              if (mots.length) {
                var siens = String(cl.nom_complet || '').toLowerCase().split(/[^0-9a-zÀ-ɏ]+/).filter(Boolean);
                if (mots.every(function (m) { return siens.some(function (x) { return x.indexOf(m) === 0; }); })) return true;
              }
              var tel = String(cl.telephone || '').replace(/[^0-9]/g, '');
              if (chiffres.length >= 4 && !lettres && tel.length >= chiffres.length &&
                  tel.slice(tel.length - chiffres.length) === chiffres) return true;
              return ref.length >= 3 && !/\s/.test(ref) && String(cl.email || '').toLowerCase().indexOf(ref.toLowerCase()) === 0;
            }).sort(function (a, b) {
              return ((b.code === code) - (a.code === code)) || String(a.nom_complet).localeCompare(String(b.nom_complet));
            }).slice(0, 8).map(function (cl) {
              var solde = 0;
              (d.factures || []).forEach(function (x) {
                if (x.client_id === cl.id && x.statut !== 'annulee') solde = arrondi(solde + factureComplete(d, x).solde_usd);
              });
              return {
                id: cl.id, code: cl.code, nom_complet: cl.nom_complet, telephone: cl.telephone || '', email: cl.email,
                ville: cl.ville || '', pays: cl.pays || '',
                colis_en_cours: d.colis.filter(function (c) { return c.client_id === cl.id && c.statut !== 'livre'; }).length,
                solde_usd: finances ? solde : null
              };
            });
          }

          if (finances) {
            r.factures = !chiffres ? [] : (d.factures || []).filter(function (x) {
              return x.numero === maj || String(x.numero || '').indexOf(maj) === 0;
            }).sort(function (a, b) {
              return ((b.numero === maj) - (a.numero === maj)) || (new Date(b.cree_le) - new Date(a.cree_le));
            }).slice(0, 8).map(function (x) {
              var c = factureComplete(d, x);
              var cl = d.comptes.filter(function (y) { return y.id === x.client_id; })[0];
              return { id: x.id, numero: x.numero, cree_le: x.cree_le, montant_usd: x.montant_usd, paye_usd: c.paye_usd,
                       solde_usd: c.solde_usd, etat: c.etat_paiement,
                       client: { code: cl ? cl.code : null, nom_complet: cl ? cl.nom_complet : null } };
            });
          }
          return plusTard(r);
        } catch (e) { return rejeter(e); }
      },

      // clients_soldes : une page de clients, triée et filtrée comme la base le fait
      clientsSoldes: function (o) {
        o = o || {};
        var d = lireDonnees();
        try {
          var moi = exiger(d, 'clients.view');
          var tri = String(o.tri || 'recent').toLowerCase(), filtre = String(o.filtre || 'tous').toLowerCase();
          if (['recent', 'nom', 'solde', 'activite', 'colis'].indexOf(tri) < 0) {
            throw Erreur('INVALID_INPUT', 'Tri inconnu : ' + tri.slice(0, 30) + '.');
          }
          if (['tous', 'avec_solde', 'avec_colis'].indexOf(filtre) < 0) {
            throw Erreur('INVALID_INPUT', 'Filtre inconnu : ' + filtre.slice(0, 30) + '.');
          }
          var finances = peutCompte(moi, 'invoices.view');
          if (!finances && (tri === 'solde' || filtre === 'avec_solde')) exiger(d, 'invoices.view');
          var parPage = trancheDemo(o.parPage, 50, 100), decalage = Math.max(0, (o.page || 0) * parPage);
          var t = nettoyer(o.recherche);
          var lignes = d.comptes.filter(function (c) {
            return c.role === 'client' && (!t || contient([c.code, c.nom_complet, c.telephone, c.email, c.ville, c.region], t));
          }).map(function (cl) {
            var e = { id: cl.id, code: cl.code, nom_complet: cl.nom_complet, telephone: cl.telephone || '', email: cl.email,
                      ville: cl.ville || '', region: cl.region || '', pays: cl.pays || '', cree_le: cl.cree_le,
                      colis_en_cours: 0, colis_total: 0, poids_en_cours: 0, derniere_activite: null, statuts: {},
                      facture_usd: 0, paye_usd: 0, solde_usd: 0, factures_ouvertes: 0 };
            d.colis.forEach(function (c) {
              if (c.client_id !== cl.id) return;
              e.colis_total++;
              if (!e.derniere_activite || new Date(c.maj_le) > new Date(e.derniere_activite)) e.derniere_activite = c.maj_le;
              if (c.statut === 'livre') return;
              e.colis_en_cours++;
              e.poids_en_cours = arrondi(e.poids_en_cours + (Number(c.poids_lb) || 0));
              e.statuts[c.statut] = (e.statuts[c.statut] || 0) + 1;
            });
            (d.factures || []).forEach(function (x) {
              if (x.client_id !== cl.id || x.statut === 'annulee') return;
              var c = factureComplete(d, x);
              e.facture_usd = arrondi(e.facture_usd + x.montant_usd);
              e.paye_usd = arrondi(e.paye_usd + c.paye_usd);
              e.solde_usd = arrondi(e.solde_usd + c.solde_usd);
              if (c.solde_usd > 0) e.factures_ouvertes++;
            });
            return e;
          }).filter(function (e) {
            return filtre === 'tous' || (filtre === 'avec_solde' && e.solde_usd > 0) ||
                   (filtre === 'avec_colis' && e.colis_en_cours > 0);
          });
          function date(x) { return x ? new Date(x).getTime() : -Infinity; }
          lignes.sort(function (a, b) {
            var k = 0;
            if (tri === 'solde') k = b.solde_usd - a.solde_usd;
            else if (tri === 'colis') k = b.colis_en_cours - a.colis_en_cours;
            else if (tri === 'activite') k = date(b.derniere_activite) - date(a.derniere_activite);
            else if (tri === 'nom') k = String(a.nom_complet || '').toLowerCase() < String(b.nom_complet || '').toLowerCase() ? -1
              : (String(a.nom_complet || '').toLowerCase() > String(b.nom_complet || '').toLowerCase() ? 1 : 0);
            return k || (date(b.cree_le) - date(a.cree_le)) || (a.id < b.id ? -1 : 1);
          });
          return plusTard({
            total: lignes.length, finances: finances,
            lignes: lignes.slice(decalage, decalage + parPage).map(function (e) {
              if (!finances) e.facture_usd = e.paye_usd = e.solde_usd = e.factures_ouvertes = null;
              return e;
            })
          });
        } catch (e) { return rejeter(e); }
      },

      // analytics_* : module = synthese, serie, operations, clients, finances,
      // routes, scanner ou qualite ; o = { periode, debut, fin, granularite, tri, page, parPage }
      analytics: function (module, o) {
        o = o || {};
        var d = lireDonnees();
        try {
          exiger(d, 'reports.view');
          if (MODULES_ANALYTICS.indexOf(module) < 0) throw Erreur('INVALID_INPUT', 'Module inconnu : ' + module + '.');
          var r = analyticsDemo(d, module, o);
          if (module !== 'qualite') return plusTard(r);
          // Le rapport de facturation de la Phase 5, repris par type (anomaliesFacturation)
          return demoAPI.admin.anomaliesFacturation().then(function (liste) {
            var par = {};
            liste.forEach(function (a) {
              var k = a.type + '|' + a.gravite;
              (par[k] = par[k] || { type: a.type, gravite: a.gravite, nombre: 0 }).nombre++;
            });
            var rang = { erreur: 0, attention: 1, info: 2 };
            r.facturation = Object.keys(par).map(function (k) { return par[k]; }).sort(function (x, y) {
              return rang[x.gravite] - rang[y.gravite] || y.nombre - x.nombre || (x.type < y.type ? -1 : 1);
            });
            return r;
          });
        } catch (e) { return rejeter(e); }
      },

      // Clients et colis d'exemple, pour découvrir le tableau de bord
      exemples: function () {
        var d = lireDonnees();
        try { exiger(d, 'settings.manage'); } catch (e) { return echec(e.code); }
        var jour = 864e5, t0 = Date.now();
        function date(joursAvant, heures) { return new Date(t0 - joursAvant * jour + (heures || 0) * 36e5).toISOString(); }
        var modeles = [
          { nom: 'Marie-Ange Dorvil', email: 'marie-ange@exemple.com', pays: 'HT', region: 'Ouest', ville: 'Pétion-Ville',
            adresse: 'Rue Grégoire #14', tel: '+509 3712 4580' },
          { nom: 'Jean-Robert Pierre', email: 'jean-robert@exemple.com', pays: 'HT', region: 'Nord', ville: 'Cap-Haïtien',
            adresse: 'Rue 15 B, Carénage', tel: '+509 4420 1187' },
          { nom: 'Carolina Méndez', email: 'carolina@exemple.com', pays: 'DO', region: 'Santiago', ville: 'Santiago de los Caballeros',
            adresse: 'Calle del Sol 58', tel: '+1 809 555 0147' }
        ];
        var ids = modeles.map(function (m) {
          var existant = trouverCompte(d, m.email);
          if (existant) return existant.id;
          var c = { id: identifiant(), email: m.email, mdp: empreinte('demo1234'), role: 'client', code: nouveauCode(d.comptes),
                    nom_complet: m.nom, pays: m.pays, region: m.region, ville: m.ville, adresse: m.adresse, telephone: m.tel,
                    langue: 'fr', cree_le: date(20) };
          d.comptes.push(c);
          return c.id;
        });
        var parcours = [
          { client: 0, desc: 'Chaussures Nike — 2 paires', exp: 'Amazon', suivi: 'TBA304918577000', poids: 4.2, service: 'aerien', etapes: [['recu', 6, 'Miami (Medley), FL'], ['emballe', 5, 'Miami (Medley), FL'], ['embarque', 4, 'Miami → Port-au-Prince'], ['distribution', 2, 'Port-au-Prince'], ['succursale', 1, 'Agence de Pétion-Ville'], ['disponible', 0, 'Agence de Pétion-Ville', 'Retrait possible du lundi au samedi, de 8 h à 18 h.']] },
          { client: 0, desc: 'Téléphone Samsung Galaxy A55', exp: 'Walmart', suivi: '9400111899223344556677', poids: 1.1, service: 'aerien', etapes: [['recu', 1, 'Miami (Medley), FL']] },
          { client: 0, desc: 'Vêtements', exp: 'SHEIN', suivi: 'GFUS01072196252801', poids: 2.6, service: 'aerien', etapes: [['recu', 16, 'Miami (Medley), FL'], ['embarque', 14, 'Miami → Port-au-Prince'], ['distribution', 12, 'Port-au-Prince'], ['succursale', 11, 'Agence de Pétion-Ville'], ['disponible', 11, 'Agence de Pétion-Ville'], ['livre', 10, 'Pétion-Ville', 'Remis en main propre.']] },
          { client: 1, desc: 'Pièces auto (amortisseurs)', exp: 'RockAuto', suivi: '1Z999AA10123456784', poids: 18, service: 'maritime', etapes: [['recu', 9, 'Miami (Medley), FL'], ['embarque', 5, 'Port de Miami → Cap-Haïtien', 'Départ du navire prévu vendredi.']] },
          { client: 1, desc: 'Ordinateur portable HP', exp: 'Amazon', suivi: 'TBA305112233000', poids: 5.4, service: 'aerien', etapes: [['recu', 3, 'Miami (Medley), FL'], ['embarque', 2, 'Miami → Cap-Haïtien'], ['incident', 1, 'Cap-Haïtien', 'Facture d\'achat demandée par la douane : envoyez-la-nous sur WhatsApp.']] },
          { client: 2, desc: 'Complément alimentaire (6 flacons)', exp: 'iHerb', suivi: 'TBA306778899000', poids: 3, service: 'aerien', etapes: [['recu', 4, 'Miami (Medley), FL'], ['embarque', 3, 'Miami → Santo Domingo'], ['distribution', 1, 'Santo Domingo']] },
          { client: 2, desc: 'Téléviseur 55 pouces', exp: 'Best Buy', suivi: '', poids: 38, service: 'maritime', etapes: [['recu', 12, 'Miami (Medley), FL'], ['embarque', 8, 'Port de Miami → Caucedo'], ['distribution', 4, 'Caucedo'], ['succursale', 0, 'Santiago de los Caballeros', 'Retrait possible dès aujourd\'hui.']] }
        ];
        parcours.forEach(function (p) {
          var client = d.comptes.filter(function (c) { return c.id === ids[p.client]; })[0];
          d.seqColis += 1;
          var c = {
            id: identifiant(), numero: 'GSE-' + d.seqColis + '-' + client.pays, client_id: client.id,
            suivi_transporteur: p.suivi, expediteur: p.exp, description: p.desc, poids_lb: p.poids, service: p.service,
            pays_destination: client.pays, destination: client.ville, statut: 'recu', lieu: '', note: ''
          };
          p.etapes.forEach(function (e) {
            c.statut = e[0];
            c.lieu = e[2];
            c.note = e[3] || '';
            c.maj_le = date(e[1], -2);
            historiser(d, c, c.maj_le);
          });
          c.cree_le = c.recu_le = date(p.etapes[0][1], -2);
          c.tarif_lb_usd = TARIF_LB_DEFAUT;
          c.prix_usd = prixTransport(c.poids_lb, c.tarif_lb_usd);
          d.colis.push(c);
          // Chaque colis repart avec sa facture, comme en ligne. Le colis livré
          // est payé ; l'ordinateur l'est à moitié ; les pièces auto sont en
          // retard de paiement.
          var f = facturerColisDemo(d, null, c).facture;
          var fa = (d.factures || []).filter(function (x) { return x.id === f.id; })[0];
          fa.cree_le = c.cree_le;
          if (p.etapes[p.etapes.length - 1][0] === 'livre') {
            ajouterPaiementDemo(d, null, fa, { montant_usd: fa.montant_usd, moyen: 'moncash', reference: 'MC-48213',
                                               paye_le: date(10) }, 'saisie', null);
          } else if (p.suivi === 'TBA305112233000') {
            ajouterPaiementDemo(d, null, fa, { montant_usd: 20, moyen: 'especes', paye_le: date(2) }, 'saisie', null);
          } else if (p.suivi === '1Z999AA10123456784') {
            fa.echeance_le = date(2).slice(0, 10);
          }
        });
        ecrireDonnees(d);
        return plusTard(true);
      },

      effacerDemo: function () {
        stockage('effacer', CLE_DONNEES);
        stockage('effacer', CLE_RECUP);
        stockage('effacer', CLE_SESSION);
        prevenir('colis');
        return plusTard(true);
      }
    }
  };

  /* ======================================================================
     Espace fermé (site en ligne sans configuration)
     ====================================================================== */
  function ferme() { return Promise.reject(Erreur('ferme')); }
  var offAPI = {
    session: function () { return Promise.resolve(null); },
    profil: function () { return Promise.resolve(null); },
    inscrire: ferme, connecter: ferme, deconnecter: function () { return Promise.resolve(true); },
    surSessionPerdue: function () { return function () {}; },
    envoyerLienMotDePasse: ferme, attendreRecuperation: function () { return Promise.resolve(false); },
    changerMotDePasse: ferme, modifierProfil: ferme, mesColis: ferme, mesFactures: ferme, monResume: ferme,
    mesNotifications: ferme, notificationsNonLues: ferme, marquerNotificationsLues: ferme,
    mesPreferencesNotifications: ferme, reglerPreferenceNotification: ferme,
    surveiller: function () { return function () {}; },
    suivre: ferme, estAdmin: function () { return Promise.resolve(false); },
    permissions: function () { return Promise.resolve({ role: null, equipe: false, permissions: [] }); },
    admin: {}
  };

  /* ======================================================================
     Outils d'affichage partagés (suivi de l'accueil, Mon compte, tableau de bord)
     ====================================================================== */
  var textes = null;
  var LOCALES = { fr: 'fr-FR', en: 'en-US', es: 'es-DO', ht: 'fr-FR' };
  var MOIS_HT = ['janvye', 'fevriye', 'mas', 'avril', 'me', 'jen', 'jiyè', 'out', 'septanm', 'oktòb', 'novanm', 'desanm'];
  var ETAPE = { recu: 1, emballe: 2, embarque: 3, distribution: 4, succursale: 5, disponible: 6, livre: 7 };

  // Textes de la page (balise <template data-textes>), traduits avec elle
  function texte(cle, valeurs) {
    if (!textes) {
      textes = {};
      var modele = document.querySelector('template[data-textes]');
      if (modele) {
        Array.prototype.forEach.call(modele.content.querySelectorAll('[data-t]'), function (el) {
          textes[el.getAttribute('data-t')] = el.textContent.trim();
        });
      }
    }
    var t = textes[cle] || '';
    Object.keys(valeurs || {}).forEach(function (k) { t = t.split('{' + k + '}').join(valeurs[k]); });
    return t;
  }

  function deuxChiffres(n) { return (n < 10 ? '0' : '') + n; }

  function date(iso, avecHeure) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    var heure = avecHeure ? deuxChiffres(d.getHours()) + ':' + deuxChiffres(d.getMinutes()) : '';
    if (LANGUE === 'ht') return d.getDate() + ' ' + MOIS_HT[d.getMonth()] + ' ' + d.getFullYear() + (heure ? ', ' + heure : '');
    var o = { day: 'numeric', month: 'short', year: 'numeric' };
    if (avecHeure) { o.hour = '2-digit'; o.minute = '2-digit'; }
    try { return new Intl.DateTimeFormat(LOCALES[LANGUE] || 'fr-FR', o).format(d); } catch (e) { return d.toLocaleString(); }
  }

  function nombre(n) {
    try { return new Intl.NumberFormat(LOCALES[LANGUE] || 'fr-FR', { maximumFractionDigits: 1 }).format(n); }
    catch (e) { return String(n); }
  }

  // Les montants sont en dollars des États-Unis, écrits selon la langue de la
  // page : « 45,00 $US » en français, « $45.00 » en anglais.
  function argent(n) {
    var v = Number(n) || 0;
    try {
      return new Intl.NumberFormat(LOCALES[LANGUE] || 'fr-FR',
                                   { style: 'currency', currency: 'USD' }).format(v);
    } catch (e) {
      return v.toFixed(2) + ' USD';
    }
  }

  // Étape du parcours (1 à 5) ; un incident garde l'étape précédente
  function etapeDe(statut, historique) {
    if (ETAPE[statut]) return ETAPE[statut];
    var h = (historique || []).slice().reverse();
    for (var i = 0; i < h.length; i++) if (ETAPE[h[i].statut]) return ETAPE[h[i].statut];
    return 1;
  }

  function remplirEtapes(liste, statut, historique) {
    var n = etapeDe(statut, historique);
    var total = liste.children.length;
    // Sur téléphone, les libellés sont masqués : l'étape en cours s'affiche sous les points
    liste.setAttribute('data-etape', texte('etape-sur', { n: n, total: total }) + ' · ' + texte('etape-' + n));
    Array.prototype.forEach.call(liste.children, function (li, i) {
      li.classList.toggle('is-fait', i < n);
      li.classList.toggle('is-actuel', i === n - 1);
      if (i === n - 1) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current');
    });
    liste.classList.toggle('is-incident', statut === 'incident');
  }

  // Historique, du plus récent au plus ancien
  function remplirHistorique(liste, historique, options) {
    options = options || {};
    var libelle = options.libelle || function (s) { return texte('statut-' + s); };
    liste.textContent = '';
    (historique || []).slice().reverse().forEach(function (h) {
      var li = document.createElement('li');
      var s = document.createElement('span');
      s.className = 'gs-chrono__statut';
      s.textContent = libelle(h.statut, h);
      var m = document.createElement('span');
      m.className = 'gs-chrono__meta';
      m.textContent = [date(h.cree_le, true), h.lieu].filter(Boolean).join(' · ');
      li.appendChild(s);
      li.appendChild(m);
      if (options.notes && h.note) {
        var p = document.createElement('p');
        p.className = 'gs-chrono__note';
        p.textContent = h.note;
        li.appendChild(p);
      }
      liste.appendChild(li);
    });
  }

  function copier(t) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(t).catch(function () { return copierAncien(t); });
    }
    return copierAncien(t);
  }

  function copierAncien(t) {
    return new Promise(function (ok, ko) {
      var zone = document.createElement('textarea');
      zone.value = t;
      zone.setAttribute('readonly', '');
      zone.style.position = 'fixed';
      zone.style.opacity = '0';
      document.body.appendChild(zone);
      zone.select();
      var reussi = false;
      try { reussi = document.execCommand('copy'); } catch (e) { reussi = false; }
      zone.remove();
      if (reussi) ok(); else ko(new Error('copie'));
    });
  }

  var api = MODE === 'supabase' ? supabaseAPI : (MODE === 'demo' ? demoAPI : offAPI);
  api.mode = MODE;
  api.statuts = STATUTS;
  api.langue = LANGUE;
  api.normaliserCode = normaliserCode;
  api.outils = {
    texte: texte, date: date, nombre: nombre, argent: argent, etapeDe: etapeDe,
    remplirEtapes: remplirEtapes, remplirHistorique: remplirHistorique, copier: copier,
    prixColis: prixColis, totauxFacture: totauxFacture, tarifDe: tarifDe, arrondi: arrondi,
    etatFacture: etatFacture, soldeDe: soldeDe, payeDe: payeDe
  };

  // Gelés : une page qui écrirait « API.tarifs.fraisService = 0 » n'obtiendrait
  // rien. Le tarif à la livre n'est qu'une valeur de départ, remplaçable colis
  // par colis dans le tableau de bord ; les frais de service ne le sont jamais.
  api.tarifs = Object.freeze({ parLivre: TARIF_LB_DEFAUT, fraisService: FRAIS_SERVICE });
  // La matrice des statuts, en lecture seule. Le tableau de bord demande
  // plutôt à la base (admin.statutsPossibles) : c'est elle qui décide.
  api.regles = Object.freeze({
    transitions: TRANSITIONS, transitionPermise: transitionPermise, statutPrecedent: statutPrecedent,
    prixTransport: prixTransport, typesEvenement: TYPES_EVENEMENT, natureTransition: natureTransition,
    typePourStatut: typePourStatut, validerOperation: validerOperation,
    libellesStatut: Object.freeze(LIBELLES), operationsScanner: Object.freeze(OPERATIONS_SCANNER.slice()),
    moyensPaiement: Object.freeze(MOYENS_PAIEMENT.slice()),
    permissionsDesRoles: Object.freeze(PERMISSIONS_DES_ROLES), rolesEquipe: Object.freeze(ROLES_EQUIPE.slice()),
    // Copie des règles et textes de notification (supabase-notifications.sql) : libellés
    // du tableau de bord, et comparaison avec la base (essai-notifications.py)
    notifications: Object.freeze({ regles: JSON.parse(JSON.stringify(REGLES_NOTIFICATIONS)),
                                   textes: JSON.parse(JSON.stringify(TEXTES_NOTIFICATIONS)),
                                   canaux: CANAUX_NOTIFICATIONS.slice() })
  });
  window.GoshipAPI = api;
})();
