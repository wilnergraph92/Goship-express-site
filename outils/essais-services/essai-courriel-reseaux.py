# -*- coding: utf-8 -*-
"""Éprouve les icônes des réseaux sociaux dans le pied des e-mails (outils/supabase-courriel-reseaux.sql).

Même base jetable, mêmes rôles SQL et même fausse pg_net que essai-services.py, avec toute la
chaîne de outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on envoie un e-mail
« Colis reçu » (pied d'avant), puis on installe le fichier DEUX fois. Ensuite :
  A. le pied porte « Suivez-nous » et quatre icônes cliquables (Facebook, Instagram, TikTok, WhatsApp),
     entre les boutons des boutiques et la phrase « Vous recevez ce message… », dans les quatre langues ;
  B. les icônes sont les images du site (assets/img/email/*.png) lues à l'adresse de site_url ;
     sans site_url, les quatre noms s'écrivent en liens de texte ;
  C. les quatre fichiers PNG existent, sont carrés et transparents aux coins ;
  D. rien d'autre ne bouge : le tableau du colis, les boutiques, l'absence d'adresse et de numéro ;
  E. rien n'est ouvert aux comptes ni aux visiteurs.

Depuis la racine du site :

    python3 outils/essais-services/essai-courriel-reseaux.py
"""
import importlib.util
import json
import os
import struct
import sys
import zlib

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
NOUVEAU = 'supabase-courriel-reseaux.sql'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
RESEAUX = (('Facebook', 'facebook', 'https://www.facebook.com/goshipexpress'),
           ('Instagram', 'instagram', 'https://www.instagram.com/goshipexpressllc'),
           ('TikTok', 'tiktok', 'https://www.tiktok.com/@goshipexpress.net'),
           ('WhatsApp', 'whatsapp', 'https://wa.me/18495386262'))
SITE = 'https://goshipexpress.net'


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def un(db, texte, compte=None):
    """La dernière ligne de la réponse."""
    sortie = db.comme(compte, texte) if compte not in (None, 'sql') else db.sql(texte)
    lignes = [l for l in sortie.splitlines() if l.strip()]
    return lignes[-1].strip() if lignes else ''


def png(chemin):
    """(largeur, hauteur, type de couleur, octet alpha du pixel (0, 0)) d'un PNG RGBA 8 bits."""
    d = open(chemin, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'pas un PNG : %s' % chemin
    larg, haut, prof, couleur = struct.unpack('>IIBB', d[16:26])
    idat, i = b'', 8
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i + 8])
        if t == b'IDAT':
            idat += d[i + 8:i + 8 + n]
        i += 12 + n
    brut = zlib.decompress(idat)
    return larg, haut, couleur, brut[1 + 3] if prof == 8 and couleur == 6 else None


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print("A0. Installation : la chaîne, un e-mail à l'ancien pied, puis le fichier deux fois")
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    db.sql("select public.definir_reglage('email_fournisseur', 'brevo'); select public.definir_reglage('email_cle_api', 'cle-essai');"
           "select public.definir_reglage('email_expediteur', 'essai@exemple.com');"
           "select public.definir_reglage('site_url', '%s');" % SITE)
    compteur = [0]

    def colis(client, **k):
        compteur[0] += 1
        r = jsonq(db, ADMIN, "select public.creer_colis(%s, null, true);" % js(dict(
            {'client_id': client, 'description': 'Tablette Samsung', 'poids_lb': 3.1, 'service': 'aerien', 'expediteur': 'AMAZON',
             'suivi_transporteur': 'RSX%05d' % compteur[0], 'pays_destination': 'DO', 'destination': 'Santo Domingo',
             'lieu': 'Miami'}, **k)))
        return r['colis']['id']

    mail = lambda cid: un(db, "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' like "
                              "'%%' || (select numero from colis where id = '%s') || '%%' order by id desc limit 1;" % cid)
    db.sql("update clients set langue = 'fr' where id = '%s'; update clients set langue = 'en' where id = '%s';" % (MARIE, JEAN))
    avant = colis(MARIE)
    db.sql("select public.traiter_notifications();")
    html_avant = mail(avant)
    verifier("avant le fichier : le pied n'a pas de réseaux", ['Suivez-nous' in html_avant, 'facebook.com' in html_avant], [False, False])
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('le contrôle du fichier : 2 fonctions, fermées, gabarit à jour',
             un(db, "select (select count(*) from pg_proc where proname in ('courriel_reseaux_textes', 'courriel_reseaux'))::text || '|' || "
                    "(select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false) "
                    "from pg_proc p where p.proname in ('courriel_reseaux_textes', 'courriel_reseaux', 'courriel_gabarit'))::text || '|' || "
                    "(position('courriel_reseaux' in pg_get_functiondef('public.courriel_gabarit(text, text, text, text, text, text, text)'::regprocedure)) > 0)::text;"),
             '2|false|true')

    print('\nA. Le pied porte les quatre icônes, entre les boutiques et la phrase finale')
    c1 = colis(MARIE)
    c2 = colis(JEAN)
    db.sql("select public.traiter_notifications();")
    h = mail(c1)
    verifier('« Suivez-nous » (français)', 'Suivez-nous' in h, True)
    for nom, fichier, url in RESEAUX:
        verifier('%s : un lien vers le compte' % nom, 'href="%s"' % url in h, True)
        verifier('%s : l\'image du site, à l\'adresse de site_url' % nom, 'src="%s/assets/img/email/%s.png"' % (SITE, fichier) in h, True)
        verifier('%s : un texte alternatif' % nom, 'alt="%s"' % nom in h, True)
    verifier('quatre icônes, de 36 px', (h.count('/assets/img/email/'), h.count('width="36" height="36"')), (4, 4))
    verifier("l'ordre : les boutiques, puis « Suivez-nous », puis la phrase « Vous recevez ce message »",
             h.index('Téléchargez') < h.index('Suivez-nous') < h.index('facebook.com') < h.index('whatsapp.png') < h.index('Vous recevez ce message'), True)
    verifier("le numéro de WhatsApp n'est écrit nulle part (seul le lien y mène)", ['849 538-6262' in h, '(849)' in h], [False, False])
    verifier("toujours pas d'adresse de Medley", '8140 NW 74th Ave' in h, False)
    he = mail(c2)
    verifier('anglais : « Follow us »', ['Follow us' in he, 'Suivez-nous' in he], [True, False])
    for langue, titre in (('es', 'Síganos'), ('ht', 'Swiv nou'), ('fr', 'Suivez-nous'), ('zz', 'Suivez-nous')):
        verifier('courriel_reseaux(%s) : « %s »' % (langue, titre), titre in un(db, "select public.courriel_reseaux('%s');" % langue), True)

    print("\nB. Sans adresse de site officielle, les noms en liens de texte")
    for valeur, titre in (('', 'site_url vide'), ('-', 'site_url illisible'), ('http://goshipexpress.net', 'site_url en http'),
                          ("https://x.com\"><script>", 'site_url piégé')):
        db.sql("select public.definir_reglage('site_url', '%s');" % valeur.replace("'", "''"))
        r = un(db, "select public.courriel_reseaux('fr');")
        verifier('%s : aucune image' % titre, '<img' in r, False)
        verifier('%s : les quatre noms en liens' % titre,
                 [('>%s</a>' % nom in r and 'href="%s"' % url in r) for nom, _, url in RESEAUX], [True] * 4)
    db.sql("select public.definir_reglage('site_url', 'https://goshipexpress.net/sous-dossier/');")
    verifier("site_url avec un dossier : l'image suit", 'src="https://goshipexpress.net/sous-dossier/assets/img/email/facebook.png"' in un(db, "select public.courriel_reseaux('fr');"), True)
    db.sql("select public.definir_reglage('site_url', '%s');" % SITE)

    print('\nC. Les quatre images existent')
    for nom, fichier, _ in RESEAUX:
        chemin = os.path.join(RACINE, 'assets', 'img', 'email', fichier + '.png')
        verifier('%s.png existe' % fichier, os.path.exists(chemin), True)
        larg, haut, couleur, alpha = png(chemin)
        verifier('%s.png : carré, RGBA, coin transparent (cercle)' % fichier, (larg == haut, larg >= 72, couleur, alpha), (True, True, 6, 0))

    print('\nD. Le reste du pied ne bouge pas')
    verifier("le tableau du colis est toujours là", ['N° de colis' in h, 'Tablette Samsung' in h], [True, True])
    verifier("les boutiques : Google Play en lien, App Store « Bientôt sur »", ['https://play.google.com' in h, 'Bientôt sur' in h], [True, True])
    verifier("la phrase « Vous recevez ce message… » reste", 'Vous recevez ce message car vous avez un compte client Goship Express' in h, True)
    verifier("la coquille reste un tableau HTML valide (autant de <table> que de </table>)", h.count('<table'), h.count('</table>'))
    verifier("un autre e-mail de la base (courriel_gabarit appelé seul) a aussi les réseaux",
             'Suivez-nous' in un(db, "select public.courriel_gabarit('fr', 'Essai', 'Bonjour', '<p>Corps</p>', '', '', 'Pied');"), True)

    print('\nE. Les droits')
    for nom, requete in (('courriel_reseaux', "select public.courriel_reseaux('fr');"),
                         ('courriel_reseaux_textes', "select public.courriel_reseaux_textes();"),
                         ('courriel_gabarit', "select public.courriel_gabarit('fr', 'a', 'b', 'c', 'd', 'e', 'f');")):
        for qui, compte in (('un visiteur', None), ('un client', MARIE), ('un employé', EMPLOYE), ('un administrateur', ADMIN)):
            verifier('%s ne peut pas appeler %s' % (qui, nom), db.erreur(compte, requete)[:17], 'permission denied')

    # APERCU=/dossier : écrit l'e-mail rendu (HTML) pour le regarder dans un navigateur
    if os.environ.get('APERCU'):
        os.makedirs(os.environ['APERCU'], exist_ok=True)
        for nom, contenu in (('recu-fr', h), ('recu-en', he)):
            open(os.path.join(os.environ['APERCU'], nom + '.html'), 'w', encoding='utf-8').write(contenu)

    echecs = [r for r in S.RESULTATS if not r]
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), len(S.RESULTATS) - len(echecs)))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
