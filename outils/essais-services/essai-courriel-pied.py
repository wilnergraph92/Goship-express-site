# -*- coding: utf-8 -*-
"""Éprouve le pied des e-mails et la fin des e-mails de facturation (outils/supabase-courriel-pied.sql).

Même base jetable, mêmes rôles SQL et même fausse pg_net que essai-services.py, avec toute la
chaîne de outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on crée un colis et une
facture (leurs messages attendent dans la file), puis on installe le fichier DEUX fois. Ensuite :
  A. les règles : plus d'e-mail pour une facture, un paiement, un retard ; le reste est intact ;
  B. l'e-mail d'une facture qui attendait est annulé, et une nouvelle facture ou un paiement n'en font plus ;
  C. le pied : plus d'adresse ni de téléphone, deux boutiques (Google Play avec son lien, App Store « bientôt ») ;
  D. les réglages des boutiques : un lien se pose, se retire, ne s'écrase pas, et seule une adresse https passe ;
  E. les quatre langues, et les droits.

Depuis la racine du site :

    python3 outils/essais-services/essai-courriel-pied.py
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
NOUVEAU = 'supabase-courriel-pied.sql'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
PLAY = 'https://play.google.com/store/apps/details?id=com.goshipexpress.app'
FACTURES = "('invoice_created', 'payment_received', 'invoice_overdue')"


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

    print("A0. Installation : la chaîne, une facture et un colis en file d'attente, puis le fichier deux fois")
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    db.sql("select public.definir_reglage('email_fournisseur', 'brevo'); select public.definir_reglage('email_cle_api', 'cle-essai');"
           "select public.definir_reglage('email_expediteur', 'essai@exemple.com');")

    colis = lambda client, **k: jsonq(db, ADMIN, "select public.creer_colis(%s, null, true);" % js(dict(
        {'client_id': client, 'description': 'Tablette Samsung', 'poids_lb': 3.1, 'service': 'aerien', 'expediteur': 'AMAZON',
         'suivi_transporteur': 'AVANT0001234', 'pays_destination': 'DO', 'destination': 'Santo Domingo'}, **k)))
    c1 = colis(MARIE)
    cid1 = c1['id'] if 'id' in c1 else c1['colis']['id']
    f1 = jsonq(db, ADMIN, "select public.facturer_colis('%s');" % cid1)['facture']
    verifier("avant le fichier : la facture a un e-mail en file d'attente",
             un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                    "where e.canal = 'email' and e.statut = 'attente' and n.type = 'invoice_created';"), '1')
    verifier("… et l'e-mail du colis aussi", un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                                                    "where e.canal = 'email' and e.statut = 'attente' and n.type = 'shipment_received';"), '1')
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('le contrôle du fichier : 2 fonctions, fermées, gabarit sans adresse, factures sans e-mail',
             un(db, "select (select count(*) from pg_proc where proname in ('courriel_boutiques_textes', 'courriel_boutiques'))::text || '|' || "
                    "(select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false) "
                    "from pg_proc p where p.proname in ('courriel_boutiques_textes', 'courriel_boutiques', 'courriel_gabarit'))::text || '|' || "
                    "(position('8140 NW' in pg_get_functiondef('public.courriel_gabarit(text, text, text, text, text, text, text)'::regprocedure)) = 0)::text || '|' || "
                    "(not exists (select 1 from notification_regles where type in %s and 'email' = any(canaux)))::text;" % FACTURES),
             '2|false|true|true')

    print('\nA. Les règles : plus d\'e-mail de facturation, le reste est intact')
    verifier("facture créée, paiement, retard : plus de canal e-mail, le téléphone reste",
             un(db, "select string_agg(type || ':' || array_to_string(canaux, '+'), ',' order by type) from notification_regles where type in %s;" % FACTURES),
             'invoice_created:push,invoice_overdue:push,payment_received:push')
    verifier("colis reçu, colis disponible, action requise : l'e-mail est gardé",
             un(db, "select string_agg(type, ',' order by type) from notification_regles where type in ('shipment_received', 'shipment_available', 'action_required') "
                    "and 'email' = any(canaux);"), 'action_required,shipment_available,shipment_received')
    verifier("facture payée : toujours le téléphone seul", un(db, "select array_to_string(canaux, '+') from notification_regles where type = 'invoice_paid';"), 'push')
    verifier("les règles restent actives (rien n'est éteint, seul l'e-mail est retiré)",
             un(db, "select count(*) from notification_regles where type in %s and actif;" % FACTURES), '3')

    print("\nB. L'e-mail d'une facture qui attendait est annulé ; plus aucun n'est créé")
    verifier("l'envoi en attente est « annulé » avec sa raison",
             un(db, "select e.statut || ':' || e.code_erreur from notification_envois e join notifications n on n.id = e.notification_id "
                    "where e.canal = 'email' and n.type = 'invoice_created' and n.facture_id = '%s';" % f1['id']), 'annule:REGLE_COUPEE')
    verifier("l'e-mail du colis, lui, attend toujours", un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                                                              "where e.canal = 'email' and e.statut = 'attente' and n.type = 'shipment_received';"), '1')
    c2 = colis(JEAN, suivi_transporteur='APRES0001234')
    cid2 = c2['id'] if 'id' in c2 else c2['colis']['id']
    f2 = jsonq(db, ADMIN, "select public.facturer_colis('%s');" % cid2)['facture']
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s, null);" % (f2['id'], js({'montant_usd': f2['montant_usd'], 'moyen': 'especes'})))
    # Un paiement qui solde la facture ne donne que « Facture payée » : deux notifications, pas trois
    verifier("une nouvelle facture et son paiement : les notifications existent (espace client), aucun envoi par e-mail",
             un(db, "select (select count(*) from notifications where type in ('invoice_created', 'payment_received', 'invoice_paid') and facture_id = '%s')::text || '|' || "
                    "(select count(*) from notification_envois e join notifications n on n.id = e.notification_id where e.canal = 'email' and n.facture_id = '%s' "
                    "and e.statut <> 'annule' and n.type in %s)::text || '|' || "
                    "(select count(*) from notification_envois e join notifications n on n.id = e.notification_id where e.canal = 'email' and n.facture_id = '%s' and n.type in %s)::text;"
                    % (f2['id'], f2['id'], FACTURES, f2['id'], FACTURES)), '2|0|0')
    verifier("le téléphone et l'espace client gardent le message de la facture",
             un(db, "select count(*) from notifications where type = 'invoice_created' and facture_id = '%s';" % f2['id']), '1')
    db.sql("select public.traiter_notifications();")
    verifier("aucun e-mail de facture n'a été remis au fournisseur", un(db, "select count(*) from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%facture%%' or body ->> 'subject' like '%%Facture%%' or body ->> 'subject' like '%%invoice%%';"), '0')

    print('\nC. Le pied : plus d\'adresse ni de téléphone, deux boutiques')
    numero1 = un(db, "select numero from colis where id = '%s';" % cid1)
    mail = lambda numero: un(db, "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%' order by id desc limit 1;" % numero)
    html1 = mail(numero1)
    verifier("l'e-mail du colis (parti après le fichier) a le tableau ET le nouveau pied", ('Package number' in html1 or 'N° de colis' in html1) and 'Téléchargez' in html1, True)
    for titre, texte, attendu in (("plus l'adresse de Medley", '8140 NW 74th Ave', False), ("plus le numéro WhatsApp", '849 538-6262', False),
                                  ("plus « WhatsApp » dans le pied", 'WhatsApp', False),
                                  ("le titre des boutiques", "Téléchargez l&#39;application Goship Express", True),
                                  ("Google Play est un lien vers la fiche de l'application", 'href="%s"' % PLAY, True),
                                  ("… avec « Disponible sur »", 'Disponible sur', True),
                                  ("App Store : « Bientôt sur », sans lien (aucune fiche n'existe)", 'Bientôt sur', True),
                                  ("… et il n'y a qu'un seul lien de boutique", 'apps.apple.com', False),
                                  ("la phrase « Vous recevez ce message… » reste", 'Vous recevez ce message car vous avez un compte client Goship Express', True)):
        verifier('pied : ' + titre, texte in html1, attendu)
    verifier("l'App Store n'est pas un lien tant qu'il n'a pas d'adresse (un <span>, pas un <a>)",
             html1.count('<a href="https://play.google.com') == 1 and html1.count('>App Store</span></span>') == 1, True)

    print('\nD. Les réglages des boutiques')
    pied = lambda langue='fr': un(db, "select public.courriel_boutiques('%s');" % langue)
    db.sql("select public.definir_reglage('store_ios_url', 'https://apps.apple.com/app/id1234567890');")
    p = pied()
    verifier("une adresse App Store posée : le bouton devient un lien", ['href="https://apps.apple.com/app/id1234567890"' in p, p.count('Disponible sur'), 'Bientôt' in p], [True, 2, False])
    db.sql("select public.definir_reglage('store_android_url', '-');")
    p = pied()
    verifier("Google Play retiré (« - ») : « Bientôt sur » et plus de lien", ['play.google.com' in p, p.count('Bientôt sur'), p.count('Disponible sur')], [False, 1, 1])
    for titre, valeur in (('javascript:', 'javascript:alert(1)'), ('http sans s', 'http://play.google.com/x'), ('un guillemet', 'https://x.com/"onmouseover=alert(1)'),
                          ('un espace', 'https://x.com/a b'), ('une balise', 'https://x.com/<script>'), ('vide', '')):
        db.sql("select public.definir_reglage('store_ios_url', '%s');" % valeur.replace("'", "''"))
        p = pied()
        verifier('adresse refusée (%s) : pas de lien, « Bientôt sur »' % titre, ['apps.apple.com' in p or 'javascript' in p or 'onmouseover' in p or '<script>' in p, p.count('Bientôt sur')], [False, 2])
    db.sql("select public.definir_reglage('store_android_url', 'https://play.google.com/store/apps/details?id=autre');")
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier("relancer le fichier n'écrase pas l'adresse posée par le propriétaire", un(db, "select public.lire_reglage('store_android_url');"),
             'https://play.google.com/store/apps/details?id=autre')
    verifier("une adresse avec ses paramètres (&) est échappée dans le lien",
             ('href="https://play.google.com/store/apps/details?id=autre"' in pied()), True)
    db.sql("select public.definir_reglage('store_ios_url', 'https://apps.apple.com/app/x?a=1&b=2');")
    verifier("… « & » devient « &amp; » dans le HTML", 'href="https://apps.apple.com/app/x?a=1&amp;b=2"' in pied(), True)

    print('\nE. Les quatre langues, la coquille partagée, les droits')
    db.sql("select public.definir_reglage('store_ios_url', 'https://apps.apple.com/app/id1');"
           "select public.definir_reglage('store_android_url', 'https://play.google.com/store/apps/details?id=com.goshipexpress.app');")
    for langue, titre, dispo in (('fr', "Téléchargez l'application Goship Express", 'Disponible sur'), ('en', 'Get the Goship Express app', 'Available on'),
                                 ('es', 'Descargue la app de Goship Express', 'Disponible en'), ('ht', 'Telechaje aplikasyon Goship Express la', 'Disponib sou'),
                                 ('zz', "Téléchargez l'application Goship Express", 'Disponible sur')):
        p = pied(langue)
        verifier('langue %s : titre et libellés' % langue, [titre.replace("'", '&#39;') in p, p.count(dispo)], [True, 2])
    g = un(db, "select public.courriel_gabarit('en', 'Sujet', 'Hello Ana,', '<p>Corps</p>', 'OPEN', 'https://goshipexpress.net/mon-compte.html', 'You receive this message because you have an account.');")
    verifier("la coquille partagée (bienvenue, facture, colis) : pas d'adresse, boutiques, bouton, pied",
             ['8140' in g, 'Get the Goship Express app' in g, 'OPEN' in g, 'You receive this message because you have an account.' in g], [False, True, True, True])
    for nom, requete in (('courriel_boutiques', "select public.courriel_boutiques('fr');"), ('courriel_boutiques_textes', "select public.courriel_boutiques_textes();"),
                         ('courriel_gabarit', "select public.courriel_gabarit('fr', 's', 'b', 'c', 'd', '', 'e');")):
        for qui, compte in (('un visiteur', None), ('un client', MARIE), ('un employé', EMPLOYE), ('un administrateur', ADMIN)):
            verifier('%s ne peut pas appeler %s' % (qui, nom), db.erreur(compte, requete)[:17], 'permission denied')

    # APERCU=/dossier : écrit l'e-mail rendu (HTML) pour le regarder dans un navigateur
    if os.environ.get('APERCU'):
        os.makedirs(os.environ['APERCU'], exist_ok=True)
        db.sql("select public.definir_reglage('store_ios_url', '');")
        open(os.path.join(os.environ['APERCU'], 'pied-bientot.html'), 'w', encoding='utf-8').write(mail(numero1))
        db.sql("select public.definir_reglage('store_ios_url', 'https://apps.apple.com/app/id1');")
        open(os.path.join(os.environ['APERCU'], 'pied-deux-boutiques.html'), 'w', encoding='utf-8').write(
            un(db, "select public.courriel_gabarit('fr', 'Sujet', 'Bonjour Ana,', '<p style=\"margin:0;font-size:17px\">Corps de l''e-mail.</p>', 'OUVRIR MON ESPACE', 'https://goshipexpress.net/mon-compte.html', 'Vous recevez ce message car vous avez un compte client Goship Express.');"))

    echecs = [r for r in S.RESULTATS if not r]
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), len(S.RESULTATS) - len(echecs)))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
