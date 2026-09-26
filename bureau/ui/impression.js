/* La fenêtre « Imprimer » : aperçu, imprimante, exemplaires. Un succès ne s'affiche
   que si l'imprimante a accepté le document ; un refus se dit, et « Réessayer » relance. */
(function () {
  'use strict';
  var I = window.Impression;
  var $ = function (s) { return document.querySelector(s); };
  var choix = $('[data-imprimante]'), copies = $('[data-copies]'), etat = $('[data-etat]');
  var boutonImprimer = $('[data-imprimer]'), boutonPdf = $('[data-pdf]');

  function dire(texte, erreur) {
    etat.hidden = !texte;
    etat.textContent = texte || '';
    etat.classList.toggle('message--erreur', !!erreur);
  }
  function occupe(oui) { boutonPdf.disabled = oui; boutonImprimer.disabled = oui || choix.disabled; }

  I.preparer().then(function (p) {
    document.title = 'Imprimer — ' + p.titre;
    $('[data-titre]').textContent = p.titre;
    $('[data-format]').textContent = p.format;
    if (!p.imprimantes.length) {
      choix.appendChild(new Option('Aucune imprimante installée', ''));
      choix.disabled = true;
      boutonImprimer.disabled = true;
      dire('Aucune imprimante n’est installée sur cet ordinateur. Vous pouvez enregistrer le document en PDF.', true);
    }
    p.imprimantes.forEach(function (x) {
      var o = new Option(x.libelle + (x.defaut ? ' (par défaut)' : ''), x.nom);
      o.selected = p.choix ? x.nom === p.choix : x.defaut;
      choix.appendChild(o);
    });
    choix.focus();
  }).catch(function () { dire('Impossible de lister les imprimantes de cet ordinateur.', true); });

  I.apercu().then(function (octets) {
    var url = URL.createObjectURL(new Blob([octets], { type: 'application/pdf' }));
    var cadre = $('[data-apercu]');
    cadre.src = url + '#toolbar=0&navpanes=0';
    cadre.hidden = false;
    $('[data-attente]').hidden = true;
  }).catch(function () {
    $('[data-attente]').textContent = 'Aperçu impossible : le document n’a pas pu être préparé.';
  });

  $('[data-form]').addEventListener('submit', function (e) {
    e.preventDefault();
    if (!choix.value) { dire('Choisissez une imprimante.', true); return; }
    occupe(true);
    dire('Envoi à l’imprimante…');
    I.imprimer(choix.value, copies.value).then(function (r) {
      occupe(false);
      if (r.ok) { dire('Document envoyé à l’imprimante.'); setTimeout(I.fermer, 700); return; }
      // Les raisons que donne Chromium, en anglais : on les traduit quand on les connaît
      var raison = { cancelled: 'impression annulée', 'Print job canceled': 'impression annulée',
                     'Invalid deviceName provided': 'imprimante introuvable',
                     'Print job failed': 'l’imprimante a refusé le document' }[r.raison] || r.raison || 'raison inconnue';
      dire('Impression échouée : ' + raison + '. Vérifiez que l’imprimante est allumée, connectée et approvisionnée, puis « Réessayer ».', true);
      boutonImprimer.textContent = 'Réessayer';
    }).catch(function () {
      occupe(false);
      dire('Impression échouée : l’application n’a pas pu joindre l’imprimante.', true);
      boutonImprimer.textContent = 'Réessayer';
    });
  });
  boutonPdf.addEventListener('click', function () {
    occupe(true);
    I.pdf().then(function (r) {
      occupe(false);
      if (r.ok) dire('PDF enregistré.');
    }).catch(function () { occupe(false); dire('Le PDF n’a pas pu être enregistré.', true); });
  });
  $('[data-fermer]').addEventListener('click', function () { I.fermer(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') I.fermer(); });
})();
