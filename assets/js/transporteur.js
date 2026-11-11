/* ==========================================================================
   Goship Express — le transporteur d'un suivi de vendeur
   --------------------------------------------------------------------------
   GoshipTransporteur(numero) → { code, nom } ou null.

   On ne nomme un transporteur que lorsque le numéro le prouve : une forme qui
   n'appartient qu'à lui ET, quand elle en a une, une clé de contrôle juste.
   Un numéro de 12 ou 15 chiffres peut être FedEx, mais aussi bien autre
   chose : il ne reçoit pas de nom. Mieux vaut « non déterminé » qu'un nom
   faux sous les yeux de l'employé — il ne servirait qu'à tromper. Aucune
   requête : rien n'est vérifié chez le transporteur.

   Fichier à part, et non dans scan-parser.js : ce dernier est copié à
   l'identique dans l'application mobile (goship-express-app, lib/scan-parser.js),
   dont les essais vérifient que les deux copies sont les mêmes. Le tableau de
   bord seul se sert de ce fichier (onglet Pré-alertes, poste de scan, fiche du
   colis) ; l'application n'en a pas besoin.
   ========================================================================== */
(function () {
  'use strict';

  // UPS : 1Z, puis 15 signes, puis la clé. Une lettre compte (code − 63) mod 10
  // (A = 2 … I = 0 … Z = 7) ; les rangs pairs comptent double.
  function cleUps(n) {
    var somme = 0;
    for (var i = 2; i < 17; i++) {
      var c = n.charCodeAt(i);
      var v = c <= 57 ? c - 48 : (c - 63) % 10;
      somme += (i % 2 === 1) ? 2 * v : v;
    }
    return (10 - somme % 10) % 10 === Number(n.charAt(17));
  }

  // USPS, code-barres IMpb (20 à 22 chiffres, « 94… », « 92… ») : clé modulo 10,
  // poids 3 puis 1 en partant de la droite.
  function cleImpb(n) {
    var somme = 0, poids = 3;
    for (var i = n.length - 2; i >= 0; i--) {
      somme += Number(n.charAt(i)) * poids;
      poids = poids === 3 ? 1 : 3;
    }
    return (10 - somme % 10) % 10 === Number(n.charAt(n.length - 1));
  }

  // Numéro postal international (norme S10 de l'UPU) : 2 lettres, 8 chiffres,
  // la clé, le pays. Le pays US est celui de l'USPS.
  function cleS10(n) {
    var poids = [8, 6, 4, 2, 3, 5, 9, 7], somme = 0;
    for (var i = 0; i < 8; i++) somme += Number(n.charAt(2 + i)) * poids[i];
    var cle = 11 - somme % 11;
    if (cle === 10) cle = 0;
    if (cle === 11) cle = 5;
    return cle === Number(n.charAt(10));
  }

  // Le numéro (majuscules ou non, espaces ou non) → { code, nom } ou null quand il ne prouve rien
  function transporteur(numero) {
    var n = String(numero == null ? '' : numero).toUpperCase().replace(/\s+/g, '');
    // Amazon Logistics : « TBA » et 12 chiffres, une forme qu'aucun autre n'emploie
    if (/^TBA\d{12}$/.test(n)) return { code: 'amazon', nom: 'Amazon Logistics' };
    if (/^1Z[0-9A-Z]{16}$/.test(n) && cleUps(n)) return { code: 'ups', nom: 'UPS' };
    if (/^9[1-5]\d{18,20}$/.test(n) && cleImpb(n)) return { code: 'usps', nom: 'USPS' };
    if (/^[A-Z]{2}\d{9}US$/.test(n) && cleS10(n)) return { code: 'usps', nom: 'USPS' };
    return null;
  }

  window.GoshipTransporteur = transporteur;
})();
