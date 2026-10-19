# -*- coding: utf-8 -*-
"""Éprouve l'e-mail « Colis reçu » et « Colis disponible » (outils/supabase-courriel-colis.sql).

Même base jetable, mêmes rôles SQL et même fausse pg_net que essai-services.py, avec toute la
chaîne de outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on crée des colis
(qui préviennent déjà le client par la phrase seule), puis on installe le fichier DEUX fois. Ensuite :
  A. l'e-mail d'un colis reçu : la phrase, puis le tableau (statut, code, numéro, expéditeur,
     service, contenu, suivi masqué, poids), dans la langue du compte ;
  B. l'e-mail d'un colis disponible : l'agence dans la phrase, le statut qui change ;
  C. seulement ces deux messages : les autres étapes n'envoient pas d'e-mail, une facture garde sa phrase ;
  D. les valeurs de la base sont échappées, une valeur vide n'a pas de ligne, le suivi est masqué ;
  E. rien n'est ouvert aux comptes ni aux visiteurs, et un envoi n'est jamais « envoyé » sans réponse.

Depuis la racine du site :

    python3 outils/essais-services/essai-courriel-colis.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_analytics', os.path.join(ICI, 'essai-analytics.py'))
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
S = A.S

RACINE = S.RACINE
OUTILS = os.path.join(RACINE, 'outils')
ADMIN, MARIE, JEAN, EMPLOYE = A.ADMIN, A.MARIE, A.JEAN, A.EMPLOYE
verifier, jsonq = S.verifier, S.jsonq
REFUS = 'PERMISSION_DENIED'
NOUVEAU = 'supabase-courriel-colis.sql'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
SUIVI = '1Z999AA10123458995'


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def un(db, texte, compte=None):
    """La dernière ligne de la réponse."""
    sortie = db.comme(compte, texte) if compte not in (None, 'sql') else db.sql(texte)
    lignes = [l for l in sortie.splitlines() if l.strip()]
    return lignes[-1].strip() if lignes else ''


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print("A0. Installation : la chaîne, un colis reçu à l'ancienne, puis le fichier deux fois")
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    db.sql("select public.definir_reglage('email_fournisseur', 'brevo'); select public.definir_reglage('email_cle_api', 'cle-essai');"
           "select public.definir_reglage('email_expediteur', 'essai@exemple.com');"
           "select public.definir_reglage('site_url', 'https://goshipexpress.net');")

    colis = lambda client, **k: jsonq(db, ADMIN, "select public.creer_colis(%s, null, true);" % js(dict(
        {'client_id': client, 'description': 'Tablette Samsung', 'poids_lb': 3.1, 'service': 'aerien', 'expediteur': 'AMAZON',
         'suivi_transporteur': SUIVI, 'pays_destination': 'DO', 'destination': 'Santo Domingo'}, **k)))
    ancien = colis(MARIE, description='Colis d\'avant la mise à jour', suivi_transporteur='ANCIEN0001234')
    ancien_id = ancien['id'] if 'id' in ancien else ancien['colis']['id']
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('le contrôle du fichier : 3 fonctions, fermées, expedier_envoi à jour',
             un(db, "select (select count(*) from pg_proc where proname in ('courriel_colis_textes', 'suivi_masque', 'courriel_colis'))::text || '|' || "
                    "(select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false) "
                    "from pg_proc p where p.proname in ('courriel_colis_textes', 'suivi_masque', 'courriel_colis', 'expedier_envoi'))::text || '|' || "
                    "(position('courriel_colis' in pg_get_functiondef('public.expedier_envoi(public.notification_envois)'::regprocedure)) > 0)::text;"),
             '3|false|true')

    corps = lambda numero, champ: un(db, "select body ->> '%s' from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%' order by id desc limit 1;" % (champ, numero))
    contient = lambda numero, champ, texte: un(db, "select position('%s' in (select body ->> '%s' from net.envois where url like '%%brevo%%' "
                                                   "and body ->> 'subject' like '%%%s%%' order by id desc limit 1)) > 0;" % (texte.replace("'", "''"), champ, numero)) == 't'

    print('\nA. Colis reçu : la phrase, puis le tableau')
    db.sql("update clients set langue = 'fr' where id = '%s';" % MARIE)
    c = colis(MARIE)
    cid = c['id'] if 'id' in c else c['colis']['id']
    numero = un(db, "select numero from colis where id = '%s';" % cid)
    code_marie = un(db, "select code from clients where id = '%s';" % MARIE)
    db.sql("select public.traiter_notifications();")
    verifier("un e-mail est remis au fournisseur pour ce colis", un(db, "select count(*) from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%';" % numero), '1')
    verifier("sujet : le titre et le numéro", corps(numero, 'subject'), 'Colis reçu — %s' % numero)
    for titre, texte in (("la salutation par le prénom", 'Bonjour Marie-Ange,'),
                         ("la phrase d'origine, avec ses détails à suivre", 'Nous avons bien reçu votre colis à notre entrepôt de Miami. En voici les détails :'),
                         ("le statut", 'Reçu à Miami'), ("le code client", code_marie), ("le numéro du colis", numero),
                         ("l'expéditeur", 'AMAZON'), ("le service, en toutes lettres", 'Fret aérien'),
                         ("le contenu", 'Tablette Samsung'), ("le poids, avec la virgule française", '3,10 lb'),
                         ("le suivi du vendeur, masqué", '**************8995')):
        verifier('HTML : ' + titre, contient(numero, 'htmlContent', texte), True)
    verifier('le suivi du vendeur n\'est jamais écrit en entier (HTML)', contient(numero, 'htmlContent', SUIVI), False)
    verifier('… ni dans la version texte', contient(numero, 'textContent', SUIVI), False)
    verifier('le tableau est en tableau HTML (compatible avec les messageries)', contient(numero, 'htmlContent', '<table role="presentation" cellpadding="0" cellspacing="0" align="center"'), True)
    verifier('le bouton vers l\'espace client est là (site_url réglé)', contient(numero, 'htmlContent', 'https://goshipexpress.net/mon-compte.html'), True)
    verifier('version texte : « Libellé : valeur » (le français met l\'espace avant les deux-points)',
             [contient(numero, 'textContent', 'N° de colis : %s' % numero), contient(numero, 'textContent', 'Poids : 3,10 lb'),
              contient(numero, 'textContent', 'Statut : Reçu à Miami')], [True, True, True])
    verifier('jamais « envoyé » ni « livré » sans la réponse du fournisseur',
             un(db, "select string_agg(distinct e.statut, ',') from notification_envois e join notifications n on n.id = e.notification_id "
                    "where n.type = 'shipment_received' and n.colis_id = '%s' and e.canal = 'email';" % cid), 'envoi')

    print('\n   Un colis reçu avant le fichier : son e-mail est parti avec la phrase seule, rien n\'a été rejoué')
    verifier("aucun nouvel e-mail pour le colis d'avant", un(db, "select count(*) from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%';"
                                                                 % un(db, "select numero from colis where id = '%s';" % ancien_id)), '1')

    print('\nB. Colis disponible : l\'agence dans la phrase, le statut qui change')
    for statut, lieu in (('emballe', 'Miami'), ('embarque', 'Miami'), ('distribution', 'Santo Domingo'), ('succursale', 'Santo Domingo'), ('disponible', 'Santo Domingo')):
        jsonq(db, ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], '%s', '%s');" % (cid, statut, lieu))
    db.sql("select public.traiter_notifications();")
    sujet_dispo = un(db, "select body ->> 'subject' from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%' and body ->> 'subject' not like 'Colis reçu%%' order by id desc limit 1;" % numero)
    verifier('sujet : « Colis disponible »', sujet_dispo, 'Colis disponible — %s' % numero)
    for titre, texte in (("l'agence dans la phrase", 'Votre colis est disponible dans notre agence de Santo Domingo. Présentez votre code client pour le retirer.'),
                         ('le statut devient « Disponible en agence »', 'Disponible en agence'), ('… et ne dit plus « Reçu à Miami »', None),
                         ("le contenu est toujours là", 'Tablette Samsung')):
        sortie = un(db, "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' = '%s';" % sujet_dispo.replace("'", "''"))
        if texte is None:
            verifier('HTML : ' + titre, 'Reçu à Miami' in sortie, False)
        else:
            verifier('HTML : ' + titre, texte in sortie, True)

    print('\nC. Seulement « reçu » et « disponible »')
    verifier("les autres étapes de colis n'ont aucun e-mail (emballé, expédié, arrivé, transféré)",
             un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                    "where e.canal = 'email' and n.colis_id = '%s' and n.type not in ('shipment_received', 'shipment_available');" % cid), '0')
    verifier("l'e-mail part pour « reçu » et pour « disponible », et pour rien d'autre sur ce colis",
             un(db, "select string_agg(distinct n.type, ',' order by n.type) from notification_envois e join notifications n on n.id = e.notification_id "
                    "where e.canal = 'email' and n.colis_id = '%s';" % cid), 'shipment_available,shipment_received')
    verifier("un autre type de message ne reçoit pas de tableau (courriel_colis rend null)",
             [un(db, "select public.courriel_colis('invoice_created', 'fr', '%s', 'GSE-0001') is null;" % cid),
              un(db, "select public.courriel_colis('shipment_shipped', 'fr', '%s', 'GSE-0001') is null;" % cid),
              un(db, "select public.courriel_colis('shipment_received', 'fr', '00000000-0000-0000-0000-000000000000', 'GSE-0001') is null;")], ['t', 't', 't'])

    print('\nD. Une autre langue, des valeurs échappées, des lignes vides, le suivi masqué')
    db.sql("update clients set langue = 'en' where id = '%s';" % JEAN)
    c2 = colis(JEAN, description='<script>alert(1)</script> & "guillemets"', expediteur='', suivi_transporteur='', poids_lb=None, prix_fixe_usd=25, service='maritime')
    cid2 = c2['id'] if 'id' in c2 else c2['colis']['id']
    numero2 = un(db, "select numero from colis where id = '%s';" % cid2)
    db.sql("select public.traiter_notifications();")
    verifier('anglais : sujet', corps(numero2, 'subject'), 'Package received — %s' % numero2)
    for titre, texte, attendu in (("salutation", 'Hello Jean,', True),
                                  ("phrase", 'We have received your package at our Miami warehouse. Here are the details:', True),
                                  ("statut", 'Received in Miami', True), ("libellé du numéro", 'Package number', True),
                                  ("service en toutes lettres", 'Ocean freight', True),
                                  ("une description piégée est échappée (&lt;script&gt;)", '&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;guillemets&quot;', True),
                                  ("… et jamais écrite telle quelle", '<script>', False),
                                  ("sans expéditeur : pas de ligne « Sender »", 'Sender', False),
                                  ("sans suivi : pas de ligne « Seller tracking »", 'Seller tracking', False),
                                  ("sans poids : pas de ligne « Weight »", 'Weight', False)):
        verifier('HTML anglais : ' + titre, contient(numero2, 'htmlContent', texte), attendu)
    verifier('texte anglais : « Libellé: valeur » (sans espace avant les deux-points)', contient(numero2, 'textContent', 'Package number: %s' % numero2), True)
    verifier('le poids se met en forme selon la langue : 3.10 lb en anglais, 3,10 lb en français',
             [un(db, "select position('Weight: 3.10 lb' in public.courriel_colis('shipment_received', 'en', '%s', 'GSE-0001') ->> 'texte') > 0;" % cid),
              un(db, "select position('Poids : 3,10 lb' in public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-0001') ->> 'texte') > 0;" % cid)], ['t', 't'])
    verifier('espagnol et créole : les libellés existent',
             [un(db, "select position('Estatus' in public.courriel_colis('shipment_received', 'es', '%s', 'GSE-0001') ->> 'html') > 0;" % cid),
              un(db, "select position('Koli' in public.courriel_colis('shipment_available', 'ht', '%s', 'GSE-0001') ->> 'html') > 0;" % cid)], ['t', 't'])
    verifier('une langue inconnue retombe sur le français',
             un(db, "select position('Statut' in public.courriel_colis('shipment_received', 'zz', '%s', 'GSE-0001') ->> 'html') > 0;" % cid), 't')
    verifier('suivi_masque : vide, court, long',
             un(db, "select public.suivi_masque('') || '|' || public.suivi_masque('abc') || '|' || public.suivi_masque('12345') || '|' || public.suivi_masque('  %s  ') || '|' || coalesce(public.suivi_masque(null), 'x');" % SUIVI),
             '|***|*2345|**************8995|')

    print('\nE. Les droits')
    for nom, requete in (('courriel_colis', "select public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-1');" % cid),
                         ('suivi_masque', "select public.suivi_masque('12345');"),
                         ('courriel_colis_textes', "select public.courriel_colis_textes();")):
        for qui, compte in (('un visiteur', None), ('un client', MARIE), ('un employé', EMPLOYE), ('un administrateur', ADMIN)):
            verifier('%s ne peut pas appeler %s' % (qui, nom), db.erreur(compte, requete)[:17], 'permission denied')
    verifier("expedier_envoi reste fermée à tous", db.erreur(ADMIN, "select public.expedier_envoi(null::public.notification_envois);")[:17], 'permission denied')

    # APERCU=/dossier : écrit les e-mails rendus (HTML) pour les regarder dans un navigateur
    if os.environ.get('APERCU'):
        os.makedirs(os.environ['APERCU'], exist_ok=True)
        for nom, requete in (('recu-fr', "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' = 'Colis reçu — %s'" % numero),
                             ('disponible-fr', "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' = 'Colis disponible — %s'" % numero),
                             ('recu-en', "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' = 'Package received — %s'" % numero2)):
            open(os.path.join(os.environ['APERCU'], nom + '.html'), 'w', encoding='utf-8').write(un(db, requete + ' order by id desc limit 1;'))

    echecs = [r for r in S.RESULTATS if not r]
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), len(S.RESULTATS) - len(echecs)))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
