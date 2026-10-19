# -*- coding: utf-8 -*-
"""Éprouve le lieu de réception d'un colis (outils/supabase-lieu-reception.sql).

Même base jetable, mêmes rôles SQL et même fausse pg_net que essai-services.py, avec toute la
chaîne de outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on crée des colis
« à l'ancienne » (lieu par défaut), puis on installe le fichier DEUX fois. Ensuite :
  A. creer_colis refuse un colis sans lieu de réception (LOCATION_REQUIRED), n'en crée aucun,
     garde le lieu tel qu'écrit (sans espaces autour), et rend le colis déjà créé à une requête répétée ;
  B. le lieu en toutes lettres : « Miami (Medley), FL » se lit « Miami », avec la préposition de
     la langue (à, en, aux, in, nan) ;
  C. l'e-mail « Colis reçu » le dit : sujet, titre, phrase et statut, dans les quatre langues ;
  D. c'est le lieu de la RÉCEPTION, pas celui de l'étape suivante ; un colis dont l'événement n'a
     pas de lieu garde l'ancienne phrase ; « Colis disponible » ne change pas ;
  E. rien n'est ouvert aux comptes ni aux visiteurs.

Depuis la racine du site :

    python3 outils/essais-services/essai-lieu-reception.py
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
NOUVEAU = 'supabase-lieu-reception.sql'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]


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

    print("A0. Installation : la chaîne, des colis à l'ancienne, puis le fichier deux fois")
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    db.sql("select public.definir_reglage('email_fournisseur', 'brevo'); select public.definir_reglage('email_cle_api', 'cle-essai');"
           "select public.definir_reglage('email_expediteur', 'essai@exemple.com');"
           "select public.definir_reglage('site_url', 'https://goshipexpress.net');")

    compteur = [0]

    def donnees(client, **k):
        compteur[0] += 1
        return dict({'client_id': client, 'description': 'Tablette Samsung', 'poids_lb': 3.1, 'service': 'aerien',
                     'expediteur': 'AMAZON', 'suivi_transporteur': 'TRK%05d' % compteur[0],
                     'pays_destination': 'DO', 'destination': 'Santo Domingo'}, **k)

    def colis(client, cle=None, **k):
        r = jsonq(db, ADMIN, "select public.creer_colis(%s, %s, true);" % (js(donnees(client, **k)), "'%s'" % cle if cle else 'null'))
        return r['colis']['id'] if 'colis' in r else r['id']

    def refus(client, **k):
        return db.erreur(ADMIN, "select public.creer_colis(%s, null, true);" % js(donnees(client, **k)))

    # À l'ancienne : sans lieu, la base écrivait Miami en silence
    ancien = colis(MARIE, description="Colis d'avant la mise à jour")
    verifier("avant le fichier : un colis sans lieu est rangé à Miami en silence (c'est ce qu'on corrige)",
             un(db, "select lieu from colis where id = '%s';" % ancien), 'Miami (Medley), FL')
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('le contrôle du fichier : 3 fonctions, creer_colis exige le lieu, expedier_envoi à jour, rien d\'ouvert',
             un(db, "select (select count(*) from pg_proc where proname in ('lieu_reception_court', 'lieu_reception_phrase', 'courriel_lieu_textes'))::text || '|' || "
                    "(position('LOCATION_REQUIRED' in pg_get_functiondef('public.creer_colis(jsonb, text, boolean)'::regprocedure)) > 0)::text || '|' || "
                    "(position('historique_id' in pg_get_functiondef('public.expedier_envoi(public.notification_envois)'::regprocedure)) > 0)::text || '|' || "
                    "(select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false) from pg_proc p "
                    "where p.proname in ('lieu_reception_court', 'lieu_reception_phrase', 'courriel_lieu_textes', 'courriel_colis', 'expedier_envoi'))::text;"),
             '3|true|true|false')
    verifier("un seul courriel_colis (l'ancienne signature est remplacée, pas doublée)",
             un(db, "select count(*) from pg_proc where proname = 'courriel_colis';"), '1')

    print('\nA. Le lieu de réception est obligatoire')
    avant = un(db, 'select count(*) from colis;')
    verifier('sans lieu : refusé (LOCATION_REQUIRED)', refus(MARIE)[:17], 'LOCATION_REQUIRED')
    verifier('lieu vide : refusé', refus(MARIE, lieu='')[:17], 'LOCATION_REQUIRED')
    verifier('lieu fait d\'espaces : refusé', refus(MARIE, lieu='   ')[:17], 'LOCATION_REQUIRED')
    verifier('lieu null : refusé', refus(MARIE, lieu=None)[:17], 'LOCATION_REQUIRED')
    verifier('lieu de 81 signes : refusé (INVALID_INPUT)', refus(MARIE, lieu='x' * 81)[:13], 'INVALID_INPUT')
    verifier('aucun colis n\'a été créé par ces refus', un(db, 'select count(*) from colis;'), avant)
    verifier("le message dit quoi faire", db.erreur(ADMIN, "select public.creer_colis(%s, null, true);" % js(donnees(MARIE)))[:17], 'LOCATION_REQUIRED')
    verifier("un employé non plus : sans lieu, refusé",
             db.erreur(EMPLOYE, "select public.creer_colis(%s, null, true);" % js(donnees(MARIE)))[:17], 'LOCATION_REQUIRED')

    c = colis(MARIE, lieu='  Port-au-Prince  ')
    verifier('le lieu est gardé tel qu\'écrit, sans les espaces autour', un(db, "select lieu from colis where id = '%s';" % c), 'Port-au-Prince')
    verifier('… et c\'est aussi le lieu de l\'événement de réception',
             un(db, "select lieu from colis_historique where colis_id = '%s' order by id limit 1;" % c), 'Port-au-Prince')
    verifier('le lieu n\'est plus jamais « Miami (Medley), FL » par défaut',
             un(db, "select count(*) from colis where id <> '%s' and lieu = 'Miami (Medley), FL';" % ancien), '0')

    # Requête répétée (double clic) : le colis déjà créé revient, même si la requête n'a pas de lieu
    d1 = donnees(JEAN, lieu='Santo Domingo')
    r1 = jsonq(db, ADMIN, "select public.creer_colis(%s, 'cle-lieu-1', true);" % js(d1))
    d1.pop('lieu')
    r2 = jsonq(db, ADMIN, "select public.creer_colis(%s, 'cle-lieu-1', true);" % js(d1))
    verifier('requête répétée : le même colis, signalé « déjà »', [r2['colis']['id'] == r1['colis']['id'], r2['deja']], [True, True])
    verifier('… et un seul colis pour cette clé', un(db, "select count(*) from colis where cle_idempotence = 'cle-lieu-1';"), '1')

    print('\nB. Le lieu en toutes lettres')
    court = lambda lieu: un(db, "select public.lieu_reception_court('%s');" % lieu.replace("'", "''"))
    for lieu, attendu in (('Miami (Medley), FL', 'Miami'), ('Port de Miami', 'Miami'), ('miami', 'Miami'), ('Port-au-Prince', 'Port-au-Prince'),
                          ('Santo Domingo', 'Santo Domingo'), ('Pétion-Ville (agence), HT', 'Pétion-Ville'), ('  Cap-Haïtien ', 'Cap-Haïtien')):
        verifier('lieu_reception_court(%r)' % lieu, court(lieu), attendu)
    verifier('lieu_reception_court(vide, null)', [court(''), un(db, "select coalesce(public.lieu_reception_court(null), 'x');")], ['', ''])
    phrase = lambda lieu, langue: un(db, "select public.lieu_reception_phrase('%s', '%s');" % (lieu.replace("'", "''"), langue))
    for lieu, langue, attendu in (('Miami (Medley), FL', 'fr', 'à Miami'), ('Port-au-Prince', 'fr', 'à Port-au-Prince'),
                                  ('Les Cayes', 'fr', 'aux Cayes'), ('Le Cap', 'fr', 'au Cap'),
                                  ('République dominicaine', 'fr', 'en République dominicaine'), ('Haïti', 'fr', 'en Haïti'),
                                  ('USA', 'fr', 'aux États-Unis'),
                                  ('Miami', 'en', 'in Miami'), ('Dominican Republic', 'en', 'in the Dominican Republic'), ('Haiti', 'en', 'in Haiti'),
                                  ('Miami', 'es', 'en Miami'), ('República Dominicana', 'es', 'en República Dominicana'), ('Haití', 'es', 'en Haití'),
                                  ('Miami', 'ht', 'nan Miami'), ('Republique dominicaine', 'ht', 'nan Repiblik Dominikèn'), ('Haïti', 'ht', 'an Ayiti'),
                                  ('Miami', 'zz', 'à Miami')):
        verifier('%s (%s)' % (lieu, langue), phrase(lieu, langue), attendu)
    verifier('aucun lieu : aucune phrase', phrase('', 'fr'), '')

    print('\nC. L\'e-mail « Colis reçu » dit où le colis a été reçu')
    db.sql("update clients set langue = 'fr' where id = '%s'; update clients set langue = 'en' where id = '%s';" % (MARIE, JEAN))
    ids = {}
    for nom, client, lieu in (('miami', MARIE, 'Miami (Medley), FL'), ('port', MARIE, 'Port-au-Prince'), ('rd', MARIE, 'République dominicaine'),
                              ('cayes', MARIE, 'Les Cayes'), ('en', JEAN, 'Miami (Medley), FL'), ('en-rd', JEAN, 'Santo Domingo')):
        ids[nom] = colis(client, lieu=lieu)
    db.sql("select public.traiter_notifications();")
    numero = lambda nom: un(db, "select numero from colis where id = '%s';" % ids[nom])
    sujet = lambda nom: un(db, "select body ->> 'subject' from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%' order by id desc limit 1;" % numero(nom))
    html = lambda nom: un(db, "select body ->> 'htmlContent' from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%' order by id desc limit 1;" % numero(nom))
    verifier('« Colis reçu à Miami » (le sujet)', sujet('miami'), 'Colis reçu à Miami — %s' % numero('miami'))
    verifier('« Colis reçu à Port-au-Prince » (le sujet)', sujet('port'), 'Colis reçu à Port-au-Prince — %s' % numero('port'))
    verifier('« Colis reçu en République dominicaine » (le sujet)', sujet('rd'), 'Colis reçu en République dominicaine — %s' % numero('rd'))
    verifier('« Colis reçu aux Cayes » (le sujet)', sujet('cayes'), 'Colis reçu aux Cayes — %s' % numero('cayes'))
    for nom, lieu_phrase in (('miami', 'à Miami'), ('port', 'à Port-au-Prince'), ('rd', 'en République dominicaine')):
        h = html(nom)
        verifier('%s : le titre de l\'e-mail' % nom, 'Colis reçu %s' % lieu_phrase in h, True)
        verifier('%s : la phrase d\'ouverture' % nom, 'Nous avons bien reçu votre colis %s. En voici les détails :' % lieu_phrase in h, True)
        verifier('%s : la ligne « Statut »' % nom, 'Reçu %s' % lieu_phrase in h, True)
        verifier('%s : plus de « notre entrepôt de Miami » en dur' % nom, 'entrepôt de Miami' in h, False)
        verifier('%s : la version texte aussi' % nom,
                 un(db, "select position('Statut : Reçu %s' in body ->> 'textContent') > 0 from net.envois where url like '%%brevo%%' "
                        "and body ->> 'subject' like '%%%s%%' order by id desc limit 1;" % (lieu_phrase, numero(nom))), 't')
    verifier('le tableau des détails est toujours là (numéro, contenu)', [numero('port') in html('port'), 'Tablette Samsung' in html('port')], [True, True])
    verifier('anglais : « Package received in Miami » (sujet)', sujet('en'), 'Package received in Miami — %s' % numero('en'))
    verifier('anglais : phrase et statut',
             ['We have received your package in Miami. Here are the details:' in html('en'), 'Received in Miami' in html('en')], [True, True])
    verifier('anglais : Santo Domingo', sujet('en-rd'), 'Package received in Santo Domingo — %s' % numero('en-rd'))
    for langue, attendu in (('es', 'Paquete recibido en Port-au-Prince'), ('ht', 'Koli resevwa nan Port-au-Prince')):
        titre = un(db, "select public.courriel_colis('shipment_received', '%s', '%s', 'GSE-1') ->> 'titre';" % (langue, ids['port']))
        verifier('%s : titre « %s »' % (langue, attendu), titre, attendu)
    verifier("un lieu piégé est échappé dans l'e-mail",
             un(db, "select position('&lt;b&gt;' in public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-1') ->> 'html') > 0;" % colis(MARIE, lieu='<b>Dépôt</b>')), 't')

    print('\nD. Le lieu de la réception, pas celui de l\'étape suivante')
    c2 = colis(MARIE, lieu='Miami')
    jsonq(db, ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], 'emballe', 'Santo Domingo');" % c2)
    verifier('le colis est maintenant à Santo Domingo', un(db, "select lieu from colis where id = '%s';" % c2), 'Santo Domingo')
    db.sql("select public.traiter_notifications();")
    ids['c2'] = c2
    verifier('… mais l\'e-mail « Colis reçu » part avec le lieu de la réception (Miami)', sujet('c2'), 'Colis reçu à Miami — %s' % numero('c2'))
    # Sans événement donné : le premier événement du colis
    verifier('sans événement donné : le lieu du premier événement',
             un(db, "select public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-1') ->> 'titre';" % c2), 'Colis reçu à Miami')
    # Un colis dont l'événement n'a pas de lieu : l'ancienne phrase, l'ancien titre
    sans = colis(MARIE, lieu='Miami')
    db.sql("set session_replication_role = replica; update colis_historique set lieu = '' where colis_id = '%s'; set session_replication_role = origin;" % sans)
    verifier("un événement sans lieu : l'ancienne phrase (entrepôt de Miami)",
             un(db, "select position('à notre entrepôt de Miami' in public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-1') ->> 'html') > 0;" % sans), 't')
    verifier("… et pas de titre imposé (le titre habituel du message reste)",
             un(db, "select coalesce(public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-1') ->> 'titre', 'aucun');" % sans), 'aucun')
    # « Colis disponible » ne change pas
    for statut, lieu in (('embarque', 'Miami'), ('distribution', 'Santo Domingo'), ('succursale', 'Santo Domingo'), ('disponible', 'Santo Domingo')):
        jsonq(db, ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], '%s', '%s');" % (c2, statut, lieu))
    db.sql("select public.traiter_notifications();")
    dispo = un(db, "select body ->> 'subject' from net.envois where url like '%%brevo%%' and body ->> 'subject' like '%%%s%%' and body ->> 'subject' like 'Colis disponible%%' limit 1;" % numero('c2'))
    verifier('« Colis disponible » : le sujet est inchangé', dispo, 'Colis disponible — %s' % numero('c2'))
    verifier('… et la phrase donne l\'agence',
             'Votre colis est disponible dans notre agence de Santo Domingo.' in un(db, "select body ->> 'htmlContent' from net.envois where body ->> 'subject' = '%s';" % dispo), True)
    verifier('les autres messages (facture, expédié) n\'ont pas de titre imposé',
             [un(db, "select public.courriel_colis('invoice_created', 'fr', '%s', 'GSE-1') is null;" % c2),
              un(db, "select public.courriel_colis('shipment_shipped', 'fr', '%s', 'GSE-1') is null;" % c2)], ['t', 't'])
    verifier('jamais « envoyé » ni « livré » sans la réponse du fournisseur',
             un(db, "select string_agg(distinct e.statut, ',') from notification_envois e join notifications n on n.id = e.notification_id where n.colis_id = '%s' and e.canal = 'email';" % ids['miami']), 'envoi')

    print('\nE. Les droits')
    for nom, requete in (('lieu_reception_court', "select public.lieu_reception_court('Miami');"),
                         ('lieu_reception_phrase', "select public.lieu_reception_phrase('Miami', 'fr');"),
                         ('courriel_lieu_textes', "select public.courriel_lieu_textes();"),
                         ('courriel_colis', "select public.courriel_colis('shipment_received', 'fr', '%s', 'GSE-1');" % c2)):
        for qui, compte in (('un visiteur', None), ('un client', MARIE), ('un employé', EMPLOYE), ('un administrateur', ADMIN)):
            verifier('%s ne peut pas appeler %s' % (qui, nom), db.erreur(compte, requete)[:17], 'permission denied')
    verifier("expedier_envoi reste fermée à tous", db.erreur(ADMIN, "select public.expedier_envoi(null::public.notification_envois);")[:17], 'permission denied')
    verifier("un visiteur ne peut pas enregistrer un colis", db.erreur(None, "select public.creer_colis(%s, null, true);" % js(donnees(MARIE, lieu='Miami')))[:17], 'permission denied')
    verifier("un client ne peut pas enregistrer un colis (même avec un lieu)",
             db.erreur(MARIE, "select public.creer_colis(%s, null, true);" % js(donnees(MARIE, lieu='Miami')))[:17], 'PERMISSION_DENIED')

    # APERCU=/dossier : écrit les e-mails rendus (HTML) pour les regarder dans un navigateur
    if os.environ.get('APERCU'):
        os.makedirs(os.environ['APERCU'], exist_ok=True)
        for nom in ('miami', 'port', 'rd', 'en'):
            open(os.path.join(os.environ['APERCU'], 'recu-%s.html' % nom), 'w', encoding='utf-8').write(html(nom))

    echecs = [r for r in S.RESULTATS if not r]
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), len(S.RESULTATS) - len(echecs)))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
