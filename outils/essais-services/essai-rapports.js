/* ==========================================================================
   Goship Express — les rapports du mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-rapports.py :
   permissions des quatre rôles, périodes, refus, un mois de données contrôlé
   (colis par statut, factures payées, impayées, annulées, regroupées,
   supprimées, paiement annulé), filtres, pages de lignes, journal, et qu'une
   suppression de rapport ne touche à aucune autre donnée.

     node outils/essais-services/essai-rapports.js             les cas
     node outils/essais-services/essai-rapports.js --formes    la forme (clés)
          des réponses, pour essai-rapports.py
     node outils/essais-services/essai-rapports.js --bornes    les jours de
          chaque période, pour essai-rapports.py
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

var memoire = {};
global.window = { GOSHIP_CONFIG: {}, addEventListener: function () {} };
global.location = { protocol: 'file:', hostname: '', href: 'file:///site/admin.html', hash: '', search: '',
                    pathname: '/site/admin.html' };
global.document = { currentScript: null, documentElement: { lang: 'fr' }, querySelector: function () { return null; } };
global.localStorage = {
  getItem: function (k) { return Object.prototype.hasOwnProperty.call(memoire, k) ? memoire[k] : null; },
  setItem: function (k, v) { memoire[k] = String(v); },
  removeItem: function (k) { delete memoire[k]; }
};
global.history = { replaceState: function () {} };
global.setTimeout = function (f) { return setImmediate(f); };
new Function(fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'api.js'), 'utf8'))();
var API = global.window.GoshipAPI;
var A = API.admin;
var CLE = 'gse-demo-donnees';
var MARS = { periode: 'personnalise', debut: '2026-03-01', fin: '2026-03-31' };
// Les périodes comparées à rapport_bornes de la base (essai-rapports.py)
var BORNES = [['journalier', '2026-03-17'], ['hebdomadaire', '2026-03-18'], ['hebdomadaire', '2026-03-22'],
              ['hebdomadaire', '2026-01-01'], ['mensuel', '2028-02-10'], ['mensuel', '2026-12-31'],
              ['trimestriel', '2026-08-10'], ['trimestriel', '2026-01-01'], ['trimestriel', '2026-12-31'],
              ['annuel', '2026-06-01'], ['personnalise', '2026-09-01', '2026-09-30'], ['aujourdhui'], ['mensuel']];

var mode = process.argv[2] || '';
if (mode) console.log = function () {};
var resultats = [];
function verifier(titre, obtenu, attendu) {
  var bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  var montre = JSON.stringify(obtenu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + (titre + ' '.repeat(62)).slice(0, 62) + ' ' +
              (montre && montre.length > 60 ? montre.slice(0, 57) + '…' : montre));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}
function code(p) { return p.then(function () { return 'aucune'; }, function (e) { return e.code; }); }
function message(p) { return p.then(function () { return 'aucune'; }, function (e) { return e.code + ' ' + e.detail; }); }
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo',
               client: 'marie-ange@exemple.com' };
function comme(qui) { return API.deconnecter().then(function () { return API.connecter(EQUIPE[qui], 'demo1234'); }); }
function donnees() { return JSON.parse(memoire[CLE]); }
function retoucher(f) {
  var d = donnees();
  f(d);
  memoire[CLE] = JSON.stringify(d);
}
function sd(texte) { return new Date(texte.replace(' ', 'T') + ':00-04:00').toISOString(); }
function cles(v, chemin) {
  chemin = chemin || '';
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    var sortie = [];
    Object.keys(v).sort().forEach(function (k) {
      sortie.push(chemin + k);
      sortie = sortie.concat(cles(v[k], chemin + k + '.'));
    });
    return sortie;
  }
  if (Array.isArray(v) && v.length) return cles(v[0], chemin + '[].');
  return [];
}

// Un mois de mars posé à la minute près, le même que essai-rapports.py (en plus petit)
function poserMars(d) {
  var marie = d.comptes.filter(function (c) { return c.email === EQUIPE.client; })[0];
  var jean = d.comptes.filter(function (c) { return c.role === 'client' && c.id !== marie.id; })[0];
  var admin = d.comptes.filter(function (c) { return c.role === 'admin'; })[0];
  marie.cree_le = sd('2026-03-02 09:00');
  var n = 0;
  function colis(id, reception, statuts, client) {
    var c = { id: id, numero: 'GSE-R' + (++n), client_id: client.id, statut: statuts[statuts.length - 1] || 'recu',
              recu_le: sd(reception), poids_lb: 2, prix_usd: 20, service: 'aerien', pays_destination: 'HT',
              destination: 'Jacmel', expediteur: 'Amazon', description: 'Essai', cree_le: sd(reception), maj_le: sd(reception) };
    d.colis.push(c);
    var avant = null;
    ['recu'].concat(statuts).forEach(function (s, i) {
      d.historique.push({ id: 9000 + n * 10 + i, colis_id: id, statut: s, statut_precedent: avant, type_evenement: null,
                          cree_le: new Date(new Date(c.recu_le).getTime() + i * 6e4).toISOString(), auteur_id: admin.id,
                          lieu: 'Miami', note: '', visibilite: 'publique', corrige_id: null, metadonnees: {} });
      avant = s;
    });
    d.journal.push({ id: d.journal.length + 1, auteur_id: admin.id, action: 'colis.creation', entite: 'colis', entite_id: id,
                     avant: null, apres: { numero: c.numero }, cree_le: c.recu_le });
    return c;
  }
  d.journal = d.journal || [];
  colis('r1', '2026-03-01 00:00', [], marie);
  colis('r2', '2026-03-03 10:00', ['emballe'], marie);
  colis('r3', '2026-03-31 23:59', [], marie);
  colis('r4', '2026-03-07 10:00', ['emballe', 'embarque', 'distribution', 'succursale', 'disponible', 'livre'], jean);
  colis('r5', '2026-03-08 10:00', ['incident'], marie);
  colis('r6', '2026-04-01 00:00', [], marie);
  colis('r7', '2026-02-28 23:59', [], marie);
  d.journal.push({ id: d.journal.length + 1, auteur_id: admin.id, action: 'colis.suppression', entite: 'colis', entite_id: 'parti',
                   avant: { numero: 'GSE-PARTI', statut: 'recu' }, apres: null, cree_le: sd('2026-03-10 10:00') });
  function paiement(id, montant, moyen, quand, annule) {
    return { id: id, montant_usd: montant, moyen: moyen, reference: '', paye_le: sd(quand), note: '', origine: 'saisie',
             cree_par: admin.id, cree_le: sd(quand), annule_le: annule ? sd(annule) : null, annule_par: null,
             motif_annulation: annule ? 'Saisi par erreur' : '' };
  }
  function facture(id, client, montant, quand, champs, paiements) {
    var f = Object.assign({ id: id, numero: '2026-03-' + id, client_id: client.id, montant_usd: montant, frais_service_usd: 10,
                            statut: 'a_payer', cree_le: sd(quand), echeance_le: null, annulee_le: null, remplacee_par: null,
                            motif_annulation: '', moyen: '', facture_lignes: [], paiements: [] }, champs || {});
    (paiements || []).forEach(function (p) { p.facture_id = id; p.client_id = client.id; f.paiements.push(p); });
    d.factures = (d.factures || []).concat([f]);
  }
  facture('f1', marie, 100, '2026-03-04 09:00', null, [paiement('p1', 100, 'especes', '2026-03-05 10:00')]);
  facture('f2', jean, 80, '2026-03-05 09:00', null, [paiement('p2', 30, 'moncash', '2026-03-06 10:00')]);
  facture('f3', marie, 50, '2026-03-06 09:00', null, [paiement('p3', 10, 'especes', '2026-03-07 10:00', '2026-03-07 11:00')]);
  facture('f4', jean, 40, '2026-03-07 09:00', { statut: 'annulee', annulee_le: sd('2026-03-07 10:00'), motif_annulation: 'Doublon' });
  facture('f5', marie, 20, '2026-03-08 09:00', { statut: 'annulee', annulee_le: sd('2026-03-20 09:00'), remplacee_par: 'f7' });
  facture('f7', marie, 30, '2026-03-20 09:00');
  facture('f9', jean, 999, '2026-04-02 09:00');
  d.journal.push({ id: d.journal.length + 1, auteur_id: admin.id, action: 'facture.suppression', entite: 'facture', entite_id: 'f8',
                   avant: { numero: '2026-03-0008', montant_usd: 60, statut: 'a_payer' }, apres: null, cree_le: sd('2026-03-25 10:00') });
  d.journal.push({ id: d.journal.length + 1, auteur_id: admin.id, action: 'notification.regle', entite: 'notification', entite_id: 'x',
                   avant: null, apres: null, cree_le: sd('2026-03-26 10:00') });
}

function lesCas() {
  var brut = null;
  return comme('admin').then(function () { return A.exemples(); }).then(function () {
    retoucher(poserMars);

    console.log('A. Les permissions (mêmes refus que la base)');
    return Promise.all([code(A.donneesRapport(MARS)), code(A.rapports()), code(A.creerRapport(Object.assign({ nom: 'Admin' }, MARS)))]);
  }).then(function (r) {
    verifier('administrateur : lire, lister, créer', r, ['aucune', 'aucune', 'aucune']);
    return comme('gerant');
  }).then(function () {
    return A.creerRapport(Object.assign({ nom: 'Du gérant', type: 'factures' }, MARS));
  }).then(function (rg) {
    verifier('gérant : créé par lui, rôle gérant, factures + finances',
             [rg.cree_par_nom !== '', rg.role_createur, rg.sections], [true, 'gerant', ['finances', 'factures']]);
    return Promise.all([code(A.donneesRapport(MARS)), code(A.rapports()),
                        code(A.modifierRapport(rg.id, Object.assign({ nom: 'x' }, MARS))), code(A.supprimerRapport(rg.id))]);
  }).then(function (r) {
    verifier('gérant : lire et lister ; modifier et supprimer refusés', r, ['aucune', 'aucune', 'non-autorise', 'non-autorise']);
    return comme('employe');
  }).then(function () {
    return Promise.all([code(A.donneesRapport(MARS)), code(A.rapports()), code(A.creerRapport(Object.assign({ nom: 'x' }, MARS)))]);
  }).then(function (r) {
    verifier('employée : tout refusé', r, ['non-autorise', 'non-autorise', 'non-autorise']);
    return comme('client');
  }).then(function () {
    return Promise.all([code(A.donneesRapport(MARS)), code(A.rapports())]);
  }).then(function (r) {
    verifier('client : tout refusé', r, ['non-autorise', 'non-autorise']);
    return comme('admin');
  }).then(function () {
    console.log('\nB. Les refus de période et d\'enregistrement');
    var cas = [
      [{ periode: 'personnalise', debut: '2026-09-30', fin: '2026-09-01' }, 'INVALID_PERIOD La date de début doit être antérieure à la date de fin.'],
      [{ periode: 'personnalise' }, 'INVALID_PERIOD Choisissez une date de début et une date de fin.'],
      [{ periode: 'personnalise', debut: '2020-01-01', fin: '2026-01-01' }, 'INVALID_PERIOD Une période de trois ans au plus.'],
      [{ periode: 'journalier', debut: '2026-02-30' }, 'INVALID_PERIOD Date impossible : 2026-02-30.'],
      [{ periode: 'journalier', debut: '17/03/2026' }, 'INVALID_PERIOD Date illisible : 17/03/2026.'],
      [{ periode: 'semestriel' }, 'INVALID_PERIOD Période inconnue : semestriel.']];
    return Promise.all(cas.map(function (c) { return message(A.donneesRapport(c[0])); })).then(function (r) {
      verifier('périodes refusées, mêmes phrases que la base', r, cas.map(function (c) { return c[1]; }));
      var refus = [{ nom: '  ' }, { nom: new Array(122).join('x') }, { type: 'secret' }, { filtres: { pays: 'HT' } },
                   { filtres: { statut_colis: 'annule' } }, { filtres: { etat_facture: 'perdue' } },
                   { sections: ['colis', 'salaires'] }];
      return Promise.all(refus.map(function (x) { return code(A.creerRapport(Object.assign({ nom: 'Essai' }, MARS, x))); }));
    });
  }).then(function (r) {
    verifier('enregistrements refusés : INVALID_INPUT ×7', r, ['INVALID_INPUT', 'INVALID_INPUT', 'INVALID_INPUT', 'INVALID_INPUT',
                                                              'INVALID_INPUT', 'INVALID_INPUT', 'INVALID_INPUT']);
    return A.creerRapport({ nom: 'Semaine', periode: 'hebdomadaire', debut: '2026-03-18',
                            filtres: { statut_colis: '', etat_facture: 'PAYEE' }, sections: ['activite', 'colis', 'colis'] });
  }).then(function (r) {
    verifier('hebdomadaire : lundi → dimanche ; filtres nettoyés ; parties dans l\'ordre',
             [r.debut, r.fin, r.filtres, r.sections, r.statut], ['2026-03-16', '2026-03-22', { etat_facture: 'payee' },
                                                                  ['colis', 'activite'], 'clos']);

    console.log('\nC. Un mois de données');
    return A.donneesRapport(Object.assign({ limite: 500 }, MARS));
  }).then(function (m) {
    brut = m;
    var c = m.statistiques.colis, f = m.statistiques.factures, p = m.statistiques.paiements;
    verifier('5 colis de mars : 3 en attente, 1 livré, 1 action requise, 1 supprimé',
             [c.total, c.attente, c.transit, c.livre, c.incident, c.supprimes], [5, 3, 0, 1, 1, 1]);
    verifier('les lignes : du 1er mars 0 h au 31 mars 23 h 59',
             [m.donnees.colis.lignes[0].numero, m.donnees.colis.lignes[4].numero], ['GSE-R1', 'GSE-R3']);
    verifier('colis livré : date de livraison et créé par',
             m.donnees.colis.lignes.filter(function (x) { return x.numero === 'GSE-R4'; }).map(function (x) {
               return [x.livre_le !== null, x.cree_par !== null];
             }), [[true, true]]);
    verifier('factures : 6, payée 1, impayées 3, annulées 2 (1 regroupée), supprimée 1',
             [f.total, f.payees, f.impayees, f.partielles, f.annulees, f.regroupees, f.supprimees], [6, 1, 3, 1, 2, 1, 1]);
    verifier('facturé 260 = payé 130 + impayé 130 ; annulé 60 ; supprimé 60',
             [f.montant_facture, f.montant_paye, f.montant_impaye, f.montant_annule, f.montant_supprime], [260, 130, 130, 60, 60]);
    verifier('paiements : 2 valides (130), 1 annulé (10)', [p.nombre, p.encaisse, p.annules, p.montant_annule], [2, 130, 1, 10]);
    verifier('par moyen : espèces 100, MonCash 30', p.par_moyen.map(function (x) { return [x.moyen, x.montant]; }),
             [['especes', 100], ['moncash', 30]]);
    verifier('supprimée : numéro et montant lus dans le journal',
             [m.donnees.factures.supprimees.total, m.donnees.factures.supprimees.lignes[0].montant_usd], [1, 60]);
    verifier('regroupée : « remplacée par » le numéro de la nouvelle',
             m.donnees.factures.lignes.filter(function (x) { return x.id === 'f5'; })[0].remplacee_par, '2026-03-f7');
    verifier('paiement annulé : dans les lignes, marqué', m.donnees.paiements.lignes.filter(function (x) { return x.annule_le; }).length, 1);
    verifier('clients : 1 nouveau, 2 actifs', [m.statistiques.clients.nouveaux, m.statistiques.clients.actifs], [1, 2]);
    verifier('activité : les suppressions à part', m.statistiques.activite.suppressions, 2);
    verifier('les étapes de mars : 13 (1 + 2 + 1 + 7 + 2), dont 1 livraison', [m.statistiques.evenements.total, m.statistiques.evenements.livraisons], [13, 1]);
    return comme('gerant').then(function () { return A.donneesRapport(Object.assign({ sections: ['activite'] }, MARS)); });
  }).then(function (g) {
    verifier('le gérant ne voit pas la ligne des réglages', brut.statistiques.activite.total - g.statistiques.activite.total, 1);
    return comme('admin').then(function () {
      return Promise.all([['payee', [1, 100]], ['impayee', [3, 160]], ['annulee', [2, 0]], ['supprimee', [0, 0]]].map(function (x) {
        return A.donneesRapport(Object.assign({ filtres: { etat_facture: x[0] } }, MARS)).then(function (r) {
          return [r.statistiques.factures.total, r.statistiques.factures.montant_facture];
        });
      }));
    });
  }).then(function (r) {
    verifier('filtres de facture : payée, impayée, annulée, supprimée', r, [[1, 100], [3, 160], [2, 0], [0, 0]]);
    return A.donneesRapport(Object.assign({ filtres: { statut_colis: 'attente' } }, MARS));
  }).then(function (r) {
    verifier('filtre « en attente » : 3 colis, et le supprimé (reçu)', [r.statistiques.colis.total, r.statistiques.colis.supprimes], [3, 1]);
    return Promise.all([A.donneesRapport(Object.assign({ sections: ['colis'], limite: 2, decalage: 2 }, MARS)),
                        A.donneesRapport(Object.assign({ section: 'factures', limite: 1 }, MARS)),
                        code(A.donneesRapport(Object.assign({ sections: ['colis'], section: 'factures' }, MARS))),
                        A.donneesRapport({ periode: 'journalier', debut: '2025-01-01' })]);
  }).then(function (r) {
    verifier('page : lignes 3 et 4, total entier', [r[0].donnees.colis.lignes.map(function (x) { return x.numero; }),
                                                    r[0].donnees.colis.total], [['GSE-R4', 'GSE-R5'], 5]);
    verifier('une seule partie : sans statistiques', ['statistiques' in r[1], Object.keys(r[1].donnees)], [false, ['factures']]);
    verifier('une partie hors du rapport : refusée', r[2], 'INVALID_INPUT');
    verifier('un jour sans rien : zéros', [r[3].statistiques.colis.total, r[3].statistiques.factures.montant_facture], [0, 0]);

    console.log('\nD. Modifier, supprimer : le journal, et rien d\'autre');
    return A.creerRapport(Object.assign({ nom: 'Rapport mensuel - Mars 2026' }, MARS));
  }).then(function (r) {
    return A.modifierRapport(r.id, { nom: 'Rapport trimestriel', periode: 'trimestriel', debut: '2026-02-01' }).then(function (m) {
      verifier('modifié : trimestre, modifié le posé, créé par gardé',
               [m.debut, m.fin, m.modifie_le !== null, m.cree_par_nom === r.cree_par_nom], ['2026-01-01', '2026-03-31', true, true]);
      var avant = donnees();
      return A.supprimerRapport(r.id).then(function (ok) {
        var apres = donnees();
        verifier('supprimé', [ok.supprime, apres.rapports.some(function (x) { return x.id === r.id; })], [true, false]);
        verifier('colis, factures, paiements, comptes, étapes : inchangés',
                 ['colis', 'factures', 'comptes', 'historique'].map(function (k) { return JSON.stringify(apres[k]) === JSON.stringify(avant[k]); }),
                 [true, true, true, true]);
        var j = apres.journal.filter(function (x) { return x.entite === 'rapport' && x.entite_id === r.id; })
          .map(function (x) { return x.action; });
        verifier('journal : création, modification, suppression', j, ['rapport.creation', 'rapport.modification', 'rapport.suppression']);
        return code(A.supprimerRapport(r.id));
      });
    });
  }).then(function (c) {
    verifier('supprimer deux fois : NOT_FOUND', c, 'NOT_FOUND');
    return A.rapports({ recherche: 'SEMAINE' });
  }).then(function (l) {
    verifier('liste : recherche sans casse', l.lignes.map(function (x) { return x.nom; }), ['Semaine']);
    var n = resultats.filter(Boolean).length;
    console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
    process.exitCode = n === resultats.length ? 0 : 1;
  });
}

function lesFormes() {
  return comme('admin').then(function () { return A.exemples(); }).then(function () {
    retoucher(poserMars);
    return A.creerRapport(Object.assign({ nom: 'Forme' }, MARS));
  }).then(function (r) {
    return Promise.all([r, A.rapports(), A.donneesRapport(Object.assign({ limite: 500 }, MARS))]);
  }).then(function (x) {
    process.stdout.write(JSON.stringify({ rapport: cles(x[0]), liste: cles(x[1]), donnees: cles(x[2]) }) + '\n');
  });
}

function lesBornes() {
  return comme('admin').then(function () {
    return Promise.all(BORNES.map(function (b) {
      return A.donneesRapport({ periode: b[0], debut: b[1] || null, fin: b[2] || null, sections: ['colis'], limite: 1 })
        .then(function (r) { return [b, r.periode.debut + ' ' + r.periode.fin]; });
    }));
  }).then(function (liste) { process.stdout.write(JSON.stringify(liste) + '\n'); });
}

(mode === '--formes' ? lesFormes() : mode === '--bornes' ? lesBornes() : lesCas()).catch(function (e) {
  process.stderr.write('ERREUR ' + (e && (e.stack || e.message || e.code)) + '\n');
  process.exitCode = 2;
});
