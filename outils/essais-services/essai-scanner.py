# -*- coding: utf-8 -*-
"""Éprouve le poste de scan côté base (outils/supabase-scanner.sql).

Même base jetable et mêmes rôles que essai-services.py. On installe les cinq
fichiers, puis on joue le poste de scan : un code lu, la fiche, l'opération,
le double scan, deux postes en même temps, une coupure réseau. Tout ce que le
poste affiche doit venir de la base, et tout ce qu'il fait passer par le
moteur d'événements.

Depuis la racine du site :

    python3 outils/essais-services/essai-scanner.py
"""
import importlib.util
import json
import os
import sys
import threading
import time

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

ADMIN, ADMIN2, MARIE, JEAN = S.ADMIN, S.ADMIN2, S.MARIE, S.JEAN
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un
FICHIERS = S.SCRIPTS + [os.path.join(S.RACINE, 'outils', 'supabase-scanner.sql')]


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def scan(db, compte, ref):
    return jsonq(db, compte, "select public.scanner_colis(%s);" % q(ref))


def operer(db, compte, ref, type_, lieu=None, note=None, cle=None, attendu=None, cible=None, brut=False):
    texte = ("select public.scanner_operation(%s, %s, %s, %s, '{}'::jsonb, %s, %s, %s);"
             % (q(ref), q(type_), q(lieu), q(note), q(cle), q(attendu), q(cible)))
    return texte if brut else jsonq(db, compte, texte)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    for f in FICHIERS + FICHIERS[::-1] + FICHIERS:
        db.fichier(f)
    verifier('les cinq fichiers s\'installent et se relancent dans le désordre', 'oui', 'oui')
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Jean Poste'), (ADMIN2, 'equipe2@goship.test', 'Rose Poste'),
                            (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'), (JEAN, 'jean@exemple.com', 'Jean')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "adresse":"12 rue Capois","telephone":"+509 3000 0000"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test'); select public.definir_admin('equipe2@goship.test');")
    base = {'client_id': MARIE, 'description': 'Chaussures Nike', 'poids_lb': 4.2, 'service': 'aerien',
            'pays_destination': 'HT', 'destination': 'Pétion-Ville', 'suivi_transporteur': 'TBA304918577000'}
    c = creer(db, ADMIN, base)['colis']
    num = c['numero']

    print('\n1. Un code lu → la fiche (ShipmentLookup)')
    f = scan(db, ADMIN, num)
    verifier('numéro GSE : colis trouvé', f['colis']['numero'], num)
    verifier('en minuscules et avec des espaces aussi', scan(db, ADMIN, '  ' + num.lower() + ' ')['colis']['id'], c['id'])
    verifier('par le suivi du vendeur (carton Amazon)', scan(db, ADMIN, 'tba304918577000')['colis']['id'], c['id'])
    verifier('code inconnu : pas une erreur, une réponse vide', scan(db, ADMIN, 'GSE-999999-HT'), None)
    verifier('code illisible : refusé sans chercher', db.erreur(ADMIN, "select public.scanner_colis('AB');"),
             'INVALID_SCAN_FORMAT')
    verifier('la fiche : ce qu\'il faut au poste',
             sorted(f.keys()), sorted(['colis', 'client', 'origine', 'precedent', 'dernier_evenement', 'livraison',
                                       'action_requise', 'operations', 'historique']))
    verifier('client : nom, code, ville — ni adresse ni téléphone',
             sorted(f['client'].keys()), ['code', 'nom_complet', 'pays', 'ville'])
    verifier('dernier événement : la réception, par le compte qui l\'a enregistré',
             (f['dernier_evenement']['type_evenement'], f['dernier_evenement']['auteur']), ('COLIS_RECU', 'Jean Poste'))
    verifier('opérations proposées à « Reçu » : celles que la base permet',
             [o['type'] for o in f['operations']],
             ['COLIS_INSPECTE', 'COLIS_EMBALLE', 'COLIS_CONSOLIDE', 'COLIS_CHARGE', 'COLIS_EXPEDIE', 'ACTION_REQUISE'])
    verifier('ni la réception (formulaire), ni la correction, ni la livraison',
             [t for t in ('COLIS_RECU', 'CORRECTION', 'MISE_A_JOUR', 'COLIS_LIVRE') if t in [o['type'] for o in f['operations']]],
             [])
    verifier('un client ne scanne pas', db.erreur(MARIE, "select public.scanner_colis('%s');" % num), 'PERMISSION_DENIED')
    verifier('un visiteur non plus',
             un(db, "select has_function_privilege('anon', 'public.scanner_colis(text)', 'execute');"), 'f')

    print('\n2. Scan → opération → événement → statut (ScanOperation)')
    r = operer(db, ADMIN, num, 'COLIS_EXPEDIE', lieu='Miami (Medley), FL', cle='scan-1', attendu='recu')
    e = r['resultat']['evenement']
    verifier('« Expédier » : fait', (r['code'], r['message']), ('OK', 'Expédié'))
    verifier('l\'événement : statut avant et après, auteur réel, lieu du poste',
             (e['type_evenement'], e['statut_precedent'], e['statut'], e['auteur'], e['lieu']),
             ('COLIS_EXPEDIE', 'recu', 'embarque', 'Jean Poste', 'Miami (Medley), FL'))
    verifier('marqué comme venu du scanner', e['metadonnees'], {'source': 'scanner'})
    verifier('la fiche renvoyée est déjà à jour',
             (r['fiche']['colis']['statut'], len(r['fiche']['historique']), r['fiche']['historique'][-1]['id']),
             ('embarque', 2, e['id']))
    verifier('en base : le statut et l\'événement, ensemble',
             un(db, "select c.statut || '/' || (select count(*) from colis_historique h where h.colis_id = c.id) "
                    "from colis c where c.id = '%s';" % c['id']), 'embarque/2')
    verifier('la facture n\'a pas bougé',
             un(db, "select f.montant_usd from factures f join facture_lignes l on l.facture_id = f.id "
                    "where l.colis_id = '%s';" % c['id']), '31.00')

    print('\n3. Double scan, retry, opérations refusées')
    r2 = operer(db, ADMIN, num, 'COLIS_EXPEDIE', lieu='Miami (Medley), FL', cle='scan-2')
    verifier('le même colis rescanné aussitôt : déjà fait, rien d\'écrit',
             (r2['code'], r2['resultat']['evenement']['id']), ('ALREADY_IN_TARGET_STATE', e['id']))
    r3 = operer(db, ADMIN, num, 'COLIS_EXPEDIE', lieu='Miami (Medley), FL', cle='scan-1', attendu='recu')
    verifier('la même requête renvoyée après une coupure : même événement',
             (r3['code'], r3['resultat']['evenement']['id']), ('ALREADY_IN_TARGET_STATE', e['id']))
    verifier('toujours deux événements en tout',
             un(db, "select count(*) from colis_historique where colis_id = '%s';" % c['id']), '2')
    for titre, type_, kw, code in (
            ('Livrer un colis embarqué', 'COLIS_LIVRE', {}, 'INVALID_STATUS_TRANSITION'),
            ('Inspecter après le départ', 'COLIS_INSPECTE', {}, 'INVALID_STATUS_TRANSITION'),
            ('Corriger depuis le scanner', 'CORRECTION', {}, 'EVENT_TYPE_INVALID'),
            ('Recevoir (créer) depuis le scanner', 'COLIS_RECU', {}, 'EVENT_TYPE_INVALID'),
            ('Disponible sans agence', 'COLIS_DISPONIBLE', {}, 'LOCATION_REQUIRED'),
            ('Statut affiché dépassé', 'ACTION_REQUISE', {'attendu': 'recu'}, 'STATUS_CONFLICT')):
        verifier(titre + ' : refusé', db.erreur(ADMIN, operer(db, ADMIN, num, type_, brut=True, **kw)), code)
    verifier('colis inconnu : refusé, aucun colis créé',
             (db.erreur(ADMIN, operer(db, ADMIN, 'GSE-999999-HT', 'COLIS_EXPEDIE', brut=True)),
              un(db, "select count(*) from colis;")), ('SHIPMENT_NOT_FOUND', '1'))
    verifier('un client ne fait pas d\'opération',
             db.erreur(MARIE, operer(db, MARIE, num, 'COLIS_ARRIVE', brut=True)), 'PERMISSION_DENIED')
    verifier('aucun événement de trop après ces refus',
             un(db, "select count(*) from colis_historique where colis_id = '%s';" % c['id']), '2')

    print('\n4. Colis en action requise, colis livré')
    r = operer(db, ADMIN, num, 'ACTION_REQUISE', lieu='Douane', note='Adresse à vérifier', attendu='embarque')
    f = r['fiche']
    verifier('action requise : sa raison est sur la fiche',
             (f['action_requise']['note'], f['action_requise']['lieu']), ('Adresse à vérifier', 'Douane'))
    verifier('on peut la résoudre depuis le scanner', 'ACTION_RESOLUE' in [o['type'] for o in f['operations']], True)
    r = operer(db, ADMIN, num, 'ACTION_RESOLUE', attendu='incident')
    verifier('résolue : le colis reprend son étape', r['fiche']['colis']['statut'], 'embarque')
    operer(db, ADMIN, num, 'COLIS_DISPONIBLE', lieu='Agence de Pétion-Ville', attendu='embarque')
    r = operer(db, ADMIN2, num, 'COLIS_LIVRE', lieu='Pétion-Ville', attendu='disponible')
    f = scan(db, ADMIN, num)
    verifier('colis livré : date, auteur et lieu de la livraison sur la fiche',
             (f['livraison']['auteur'], f['livraison']['lieu'], bool(f['livraison']['cree_le'])),
             ('Rose Poste', 'Pétion-Ville', True))
    verifier('et plus aucune opération proposée', f['operations'], [])
    verifier('le scanner ne peut plus rien sur lui',
             [db.erreur(ADMIN, operer(db, ADMIN, num, t, lieu='X', brut=True)) for t in ('COLIS_EXPEDIE', 'ACTION_REQUISE')],
             ['INVALID_STATUS_TRANSITION', 'INVALID_STATUS_TRANSITION'])
    r = operer(db, ADMIN, num, 'COLIS_LIVRE', lieu='Pétion-Ville')
    verifier('« Livrer » rescanné : déjà fait, rien d\'écrit', (r['code'], r['resultat']['evenement']['auteur']),
             ('ALREADY_IN_TARGET_STATE', 'Rose Poste'))

    print('\n5. Deux postes en même temps')
    sorties = {}

    def lancer(nom, compte, texte, pause=0):
        time.sleep(pause)
        sorties[nom] = db.comme(compte, texte, echec_permis=True)

    def ensemble(a, b):
        t1 = threading.Thread(target=lancer, args=a)
        t2 = threading.Thread(target=lancer, args=b + (0.3,))
        t1.start(); t2.start(); t1.join(); t2.join()

    lent = 'begin; %s select pg_sleep(1); commit;'
    x = creer(db, ADMIN, dict(base, description='Course', suivi_transporteur=''), facturer=False)['colis']['numero']
    ensemble(('A', ADMIN, lent % operer(db, ADMIN, x, 'COLIS_EXPEDIE', lieu='Miami', cle='a-1', brut=True)),
             ('B', ADMIN2, operer(db, ADMIN2, x, 'COLIS_EXPEDIE', lieu='Miami', cle='b-1', brut=True)))
    verifier('deux postes scannent « Expédier » : un seul événement, B l\'apprend',
             ('ALREADY_IN_TARGET_STATE' in sorties['B'],
              un(db, "select count(*) from colis_historique h join colis c on c.id = h.colis_id "
                     "where c.numero = '%s' and h.type_evenement = 'COLIS_EXPEDIE';" % x)), (True, '1'))
    y = creer(db, ADMIN, dict(base, description='Course 2', suivi_transporteur=''), facturer=False)['colis']['numero']
    ensemble(('A', ADMIN, lent % operer(db, ADMIN, y, 'COLIS_EXPEDIE', lieu='Miami', cle='a-2', attendu='recu', brut=True)),
             ('B', ADMIN2, operer(db, ADMIN2, y, 'ACTION_REQUISE', lieu='Miami', cle='b-2', attendu='recu', brut=True)))
    verifier('« Expédier » et « Action requise » au même instant : le second est en conflit',
             ('STATUS_CONFLICT' in sorties['B'], un(db, "select statut from colis where numero = '%s';" % y)),
             (True, 'embarque'))
    z = creer(db, ADMIN, dict(base, description='Double clic', suivi_transporteur=''), facturer=False)['colis']['numero']
    meme = operer(db, ADMIN, z, 'COLIS_EMBALLE', lieu='Miami', cle='clic-1', attendu='recu', brut=True)
    ensemble(('A', ADMIN, lent % meme), ('B', ADMIN, meme))
    verifier('double clic (même requête deux fois) : un seul événement',
             un(db, "select count(*) from colis_historique where cle_idempotence = 'clic-1';"), '1')
    verifier('aucun historique incohérent : chaque événement part du statut du précédent',
             un(db, """select count(*) from (select statut_precedent,
                                                   lag(statut) over (partition by colis_id order by id) avant
                                            from colis_historique) s
                       where statut_precedent is distinct from avant;"""), '0')

    print('\n6. Vitesse')
    # Par lots de 1 000 : chaque colis créé pose un verrou sur son suivi
    # vendeur (supabase-services.sql), et une seule transaction de 20 000
    # colis dépasserait la table des verrous. En vrai, un colis = une requête.
    for lot in range(20):
        db.sql("""insert into colis (client_id, description, poids_lb, suivi_transporteur)
                  select '%s', 'Volume ' || n, 2, 'VOL' || lpad(n::text, 9, '0')
                  from generate_series(%d, %d) n;""" % (MARIE, lot * 1000 + 1, lot * 1000 + 1000))
    db.sql('analyze colis; analyze colis_historique;')
    plan = db.sql("explain select id from colis where numero = 'GSE-15000-HT';")
    verifier('recherche par numéro : par l\'index, pas en lisant la table', 'Index' in plan and 'Seq Scan' not in plan, True)
    plan = db.sql("explain select id from colis where suivi_transporteur = 'VOL000015000' and suivi_transporteur <> '';")
    verifier('recherche par suivi vendeur : par l\'index aussi', 'Index' in plan and 'Seq Scan' not in plan, True)
    debut = time.time()
    for k in range(20):
        scan(db, ADMIN, 'VOL%09d' % (1000 + k * 900))
    duree = (time.time() - debut) / 20
    verifier('20 000 colis : une fiche en moins de 0,3 s (connexion comprise)', duree < 0.3, True)

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    return 0 if all(S.RESULTATS) else 1


if __name__ == '__main__':
    sys.exit(main())
