# -*- coding: utf-8 -*-
"""Éprouve le moteur d'événements (outils/supabase-evenements.sql).

Même base jetable et mêmes rôles que essai-services.py, dont il reprend les
outils. Deux temps :

  A. la MIGRATION : on installe la base telle qu'elle était avant la Phase 3
     (les fichiers de la dernière version publiée, lus dans Git), on y crée
     des colis et des factures, puis on installe la nouvelle version par-dessus
     et on vérifie que rien du passé n'a bougé ;
  B. le MOTEUR : transitions, événements sans changement de statut, correction,
     immuabilité, idempotence, concurrence, lecture de l'historique.

Depuis la racine du site :

    python3 outils/essais-services/essai-evenements.py

Voir LISEZ-MOI.md.
"""
import importlib.util
import json
import os
import subprocess
import sys
import threading
import time

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE, TRAVAIL = S.RACINE, S.TRAVAIL
ADMIN, ADMIN2, MARIE, JEAN = S.ADMIN, S.ADMIN2, S.MARIE, S.JEAN
verifier, jsonq, colis, creer, statut, un = S.verifier, S.jsonq, S.colis, S.creer, S.statut, S.un

# La version publiée avant la Phase 3 : c'est elle qui tourne aujourd'hui chez
# Supabase, et c'est par-dessus elle que la nouvelle s'installera.
AVANT = os.environ.get('GOSHIP_AVANT', '8e0e565')


def fichier_git(nom):
    texte = subprocess.run(['git', '-C', RACINE, 'show', '%s:outils/%s' % (AVANT, nom)],
                           capture_output=True, text=True, check=True).stdout
    chemin = os.path.join(TRAVAIL, 'avant-' + nom)
    open(chemin, 'w', encoding='utf-8').write(texte)
    return chemin


def op(db, compte, id_colis, type_, lieu=None, note=None, meta=None, cle=None, attendu=None, cible=None, motif=None,
       brut=False):
    def q(v):
        return 'null' if v is None else "'%s'" % str(v).replace("'", "''")
    texte = ("select public.executer_operation('%s', %s, %s, %s, %s, %s, %s, %s, %s);"
             % (id_colis, q(type_), q(lieu), q(note),
                "'%s'::jsonb" % json.dumps(meta).replace("'", "''") if meta is not None else "'{}'::jsonb",
                q(cle), q(attendu), q(cible), q(motif)))
    if brut:
        return texte
    return jsonq(db, compte, texte)


def erreur(db, compte, texte):
    return db.erreur(compte, texte)


def gros(db, texte):
    """Une requête trop longue pour la ligne de commande : passée par un fichier."""
    chemin = os.path.join(TRAVAIL, 'requete.sql')
    open(chemin, 'w', encoding='utf-8').write(texte)
    r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE, '-v', 'ON_ERROR_STOP=1',
                        '-X', '-q', '-t', '-A', '-f', chemin], capture_output=True, text=True, check=True)
    return r.stdout.strip()


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    base = {'client_id': MARIE, 'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien',
            'pays_destination': 'HT', 'destination': 'Pétion-Ville'}

    print('A. Migration depuis la version publiée (%s)' % AVANT)
    for nom in ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql'):
        db.fichier(fichier_git(nom))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Équipe'), (ADMIN2, 'equipe2@goship.test', 'Équipe 2'),
                            (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'), (JEAN, 'jean@exemple.com', 'Jean')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test'); select public.definir_admin('equipe2@goship.test');")
    ancien = creer(db, ADMIN, dict(base, description='Ancien colis', suivi_transporteur='ANCIEN-1'))
    vieux = ancien['colis']['id']
    jsonq(db, ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], 'embarque', 'Miami', 'En route');" % vieux)
    avant_hist = un(db, "select string_agg(id || ':' || statut || ':' || lieu || ':' || note || ':' || cree_le, '|' "
                        "order by id) from colis_historique where colis_id = '%s';" % vieux)
    avant_fact = un(db, "select string_agg(numero || ':' || montant_usd || ':' || frais_service_usd, '|' order by numero) "
                        "from factures;")
    avant_prix = un(db, "select string_agg(numero || ':' || prix_usd, '|' order by numero) from colis;")

    for nom in ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql'):
        db.fichier(os.path.join(RACINE, 'outils', nom))
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-evenements.sql'))
    controle = un(db, open(os.path.join(RACINE, 'outils', 'supabase-evenements.sql'), encoding='utf-8').read()
                  .split('-- Contrôle ---')[1].split('\n', 1)[1])
    verifier('nouvelle version installée par-dessus, relancée : contrôle', controle, '8|3|8|2')
    verifier('les événements passés sont intacts, au caractère près',
             un(db, "select string_agg(id || ':' || statut || ':' || lieu || ':' || note || ':' || cree_le, '|' "
                    "order by id) from colis_historique where colis_id = '%s';" % vieux), avant_hist)
    verifier('aucun faux événement inventé : les anciens restent sans type',
             un(db, "select count(*) filter (where type_evenement is null) || '/' || count(*) "
                    "from colis_historique where colis_id = '%s';" % vieux), '2/2')
    verifier('les factures n\'ont pas bougé', un(db, "select string_agg(numero || ':' || montant_usd || ':' || "
                                                     "frais_service_usd, '|' order by numero) from factures;"), avant_fact)
    verifier('les prix des colis non plus', un(db, "select string_agg(numero || ':' || prix_usd, '|' order by numero) "
                                                   "from colis;"), avant_prix)
    pub = jsonq(db, None, "select public.suivre_colis('ANCIEN-1');")
    verifier('suivi public d\'un ancien colis : ses deux étapes', [h['statut'] for h in pub['historique']],
             ['recu', 'embarque'])
    r = op(db, ADMIN, vieux, 'COLIS_ARRIVE', lieu='Port-au-Prince')
    verifier('un ancien colis continue sa route par le moteur', (r['evenement']['statut_precedent'], r['colis']['statut']),
             ('embarque', 'distribution'))

    print('\nB1. Transition valide, transition refusée')
    c = creer(db, ADMIN, dict(base, suivi_transporteur='TBA-EVT'))['colis']['id']
    h = jsonq(db, ADMIN, "select public.historique_colis('%s');" % c)
    verifier('création : un événement COLIS_RECU, sans statut précédent, par l\'équipe',
             (len(h), h[0]['type_evenement'], h[0]['statut_precedent'], h[0]['statut'], h[0]['auteur_id']),
             (1, 'COLIS_RECU', None, 'recu', ADMIN))
    verifier('Reçu → Livré : refusé', erreur(db, ADMIN, op(db, ADMIN, c, 'COLIS_LIVRE', brut=True)),
             'INVALID_STATUS_TRANSITION')
    r = op(db, ADMIN, c, 'COLIS_EXPEDIE', lieu='Miami', note='Vol du soir', meta={'conteneur': 'GSE-2026-09'})
    verifier('Reçu → Expédié : l\'événement et le statut ensemble',
             (r['evenement']['type_evenement'], r['evenement']['statut_precedent'], r['evenement']['statut'],
              r['colis']['statut'], r['change_statut']),
             ('COLIS_EXPEDIE', 'recu', 'embarque', 'embarque', True))
    verifier('l\'auteur est le compte connecté, avec son rôle', (r['evenement']['auteur_id'], r['evenement']['auteur_role']),
             (ADMIN, 'admin'))
    verifier('le lieu et les précisions sont gardés',
             (r['evenement']['lieu'], r['evenement']['metadonnees']), ('Miami', {'conteneur': 'GSE-2026-09'}))
    verifier('l\'heure est celle de la base (moins de 5 s)',
             un(db, "select (now() - cree_le < interval '5 seconds') from colis_historique where id = %s;"
                % r['evenement']['id']), 't')

    print('\nB2. Événement sans changement de statut')
    d = creer(db, ADMIN, dict(base, description='Inspecté'))['colis']['id']
    r = op(db, ADMIN, d, 'COLIS_INSPECTE', note='Carton abîmé, contenu intact')
    verifier('Inspecté : événement écrit, statut inchangé',
             (r['evenement']['type_evenement'], r['colis']['statut'], r['change_statut'], r['evenement']['visibilite']),
             ('COLIS_INSPECTE', 'recu', False, 'interne'))
    verifier('il garde le lieu du colis faute d\'en donner un', r['evenement']['lieu'], 'Miami (Medley), FL')
    for t in ('COLIS_CONSOLIDE', 'COLIS_CHARGE'):
        verifier('%s : statut inchangé' % t, op(db, ADMIN, d, t, lieu='Quai 2')['colis']['statut'], 'recu')
    verifier('le client ne voit pas les opérations internes',
             db.comme(MARIE, "select count(*) from colis_historique where colis_id = '%s';" % d), '1')
    verifier('le suivi public non plus', len(jsonq(db, None, "select public.suivre_colis('%s');"
                                                   % un(db, "select numero from colis where id = '%s';" % d))
                                             ['historique']), 1)
    verifier('l\'équipe voit tout', len(jsonq(db, ADMIN, "select public.historique_colis('%s');" % d)), 4)
    op(db, ADMIN, d, 'COLIS_EXPEDIE', lieu='Miami')
    verifier('Inspecté après le départ : refusé', erreur(db, ADMIN, op(db, ADMIN, d, 'COLIS_INSPECTE', brut=True)),
             'INVALID_STATUS_TRANSITION')
    ops = jsonq(db, ADMIN, "select public.operations_possibles('%s');" % c)
    verifier('opérations possibles sur un colis expédié',
             sorted(o['type'] for o in ops['operations']),
             ['ACTION_REQUISE', 'COLIS_ARRIVE', 'COLIS_DISPONIBLE', 'COLIS_TRANSFERE', 'CORRECTION', 'MISE_A_JOUR'])

    print('\nB3. Action requise')
    verifier('Expédié → Action requise', op(db, ADMIN, c, 'ACTION_REQUISE', lieu='Douane',
                                          meta={'raison': 'document_manquant'})['colis']['statut'], 'incident')
    verifier('Action requise → Livré : refusé', erreur(db, ADMIN, op(db, ADMIN, c, 'COLIS_LIVRE', brut=True)),
             'INVALID_STATUS_TRANSITION')
    r = op(db, ADMIN, c, 'ACTION_RESOLUE', lieu='Douane')
    verifier('Action résolue → retour à Expédié', (r['evenement']['statut_precedent'], r['colis']['statut']),
             ('incident', 'embarque'))
    op(db, ADMIN, c, 'ACTION_REQUISE')
    verifier('Action résolue vers une étape suivante (Centre de distribution)',
             op(db, ADMIN, c, 'ACTION_RESOLUE', cible='distribution', lieu='Port-au-Prince')['colis']['statut'],
             'distribution')
    verifier('mais pas n\'importe où', erreur(db, ADMIN, op(db, ADMIN, c, 'ACTION_REQUISE', brut=True) +
                                              op(db, ADMIN, c, 'ACTION_RESOLUE', cible='livre', brut=True)),
             'INVALID_STATUS_TRANSITION')

    verifier('refus dans une même requête : tout est annulé, le colis n\'a pas bougé',
             un(db, "select statut from colis where id = '%s';" % c), 'distribution')

    print('\nB4. Livraison et statut final')
    verifier('Disponible sans agence : refusé', erreur(db, ADMIN, op(db, ADMIN, c, 'COLIS_DISPONIBLE', brut=True)),
             'LOCATION_REQUIRED')
    op(db, ADMIN, c, 'COLIS_DISPONIBLE', lieu='Agence de Pétion-Ville')
    r = op(db, ADMIN, c, 'COLIS_LIVRE', lieu='Pétion-Ville', meta={'destinataire': 'Marie-Ange', 'methode': 'retrait'})
    livre_id = r['evenement']['id']
    verifier('Disponible → Livré', (r['evenement']['statut_precedent'], r['colis']['statut']), ('disponible', 'livre'))
    for t, cible in (('COLIS_EXPEDIE', None), ('ACTION_REQUISE', None), ('COLIS_DISPONIBLE', None),
                     ('ACTION_RESOLUE', 'disponible')):
        verifier('Livré → %s : refusé' % t, erreur(db, ADMIN, op(db, ADMIN, c, t, lieu='X', cible=cible, brut=True)),
                 'INVALID_STATUS_TRANSITION')
    verifier('UPDATE direct du statut, même par l\'équipe : refusé',
             erreur(db, ADMIN, "update colis set statut = 'disponible' where id = '%s';" % c), 'INVALID_STATUS_TRANSITION')
    verifier('ni même depuis le SQL Editor', erreur(db, 'sql', "update colis set statut = 'disponible' where id = '%s';" % c),
             'INVALID_STATUS_TRANSITION')
    verifier('Correction sans motif : refusée', erreur(db, ADMIN, op(db, ADMIN, c, 'CORRECTION', brut=True)),
             'INVALID_EVENT_DATA')
    r = op(db, ADMIN, c, 'CORRECTION', motif='Livré par erreur : le client n\'est pas venu')
    verifier('Correction avec motif : Livré → Disponible', (r['evenement']['statut_precedent'], r['colis']['statut'],
                                                          r['evenement']['corrige_id']), ('livre', 'disponible', livre_id))
    verifier('la livraison erronée n\'est ni modifiée ni effacée',
             un(db, "select type_evenement || ':' || statut from colis_historique where id = %s;" % livre_id),
             'COLIS_LIVRE:livre')
    verifier('mais le client et le public ne la voient plus',
             (db.comme(MARIE, "select count(*) from colis_historique where id = %s;" % livre_id),
              'livre' in [h['statut'] for h in jsonq(db, None, "select public.suivre_colis('TBA-EVT');")['historique']]),
             ('0', False))
    verifier('la correction est au journal d\'audit, avec son motif',
             un(db, "select apres ->> 'motif' from journal_audit where action = 'colis.correction' "
                    "and entite_id = '%s';" % c), 'Livré par erreur : le client n\'est pas venu')
    verifier('et l\'équipe voit l\'événement corrigé marqué comme tel',
             [e['corrige'] for e in jsonq(db, ADMIN, "select public.historique_colis('%s');" % c)
              if e['id'] == livre_id], [True])
    verifier('un client ne peut pas corriger',
             erreur(db, MARIE, op(db, MARIE, c, 'CORRECTION', motif='x', brut=True)), 'PERMISSION_DENIED')

    print('\nB5. Un événement est un fait')
    verifier('UPDATE d\'un événement : refusé (même au SQL Editor)',
             erreur(db, 'sql', "update colis_historique set note = 'réécrit' where id = %s;" % livre_id), 'EVENT_IMMUTABLE')
    verifier('DELETE d\'un événement : refusé', erreur(db, 'sql', "delete from colis_historique where id = %s;" % livre_id),
             'EVENT_IMMUTABLE')
    verifier('le client ne peut ni écrire, ni modifier, ni effacer',
             [erreur(db, MARIE, q).startswith('permission denied') for q in (
                 "insert into colis_historique (colis_id, statut) values ('%s', 'livre');" % c,
                 "update colis_historique set note = 'x' where colis_id = '%s';" % c,
                 "delete from colis_historique where colis_id = '%s';" % c)], [True, True, True])
    verifier('ni fabriquer un événement par le moteur',
             erreur(db, MARIE, op(db, MARIE, c, 'COLIS_LIVRE', brut=True)), 'PERMISSION_DENIED')
    z = creer(db, ADMIN, dict(base, description='À supprimer'), facturer=False)['colis']['id']
    op(db, ADMIN, z, 'COLIS_INSPECTE')
    db.comme(ADMIN, "delete from colis where id = '%s';" % z)
    verifier('supprimer un colis emporte bien son historique',
             un(db, "select count(*) from colis_historique where colis_id = '%s';" % z), '0')

    print('\nB6. Données refusées')
    cas = [('type inconnu', dict(type_='COLIS_TELEPORTE'), 'EVENT_TYPE_INVALID'),
           ('précisions qui ne sont pas un objet', dict(type_='COLIS_EMBALLE', meta=[1, 2]), 'INVALID_EVENT_DATA'),
           ('un mot de passe dans les précisions', dict(type_='COLIS_EMBALLE', meta={'mot_de_passe': 'x'}),
            'INVALID_EVENT_DATA'),
           ('un jeton caché plus bas', dict(type_='COLIS_EMBALLE', meta={'scan': {'api_token': 'x'}}),
            'INVALID_EVENT_DATA'),
           ('lieu de plus de 80 caractères', dict(type_='COLIS_EMBALLE', lieu='x' * 81), 'INVALID_LOCATION'),
           ('cible incohérente avec l\'événement', dict(type_='COLIS_EMBALLE', cible='livre'), 'INVALID_EVENT_DATA')]
    e = creer(db, ADMIN, dict(base, description='Refus'), facturer=False)['colis']['id']
    for titre, kw, code in cas:
        verifier(titre, erreur(db, ADMIN, op(db, ADMIN, e, brut=True, **kw)), code)
    verifier('colis inconnu', erreur(db, ADMIN, op(db, ADMIN, '99999999-9999-9999-9999-999999999999', 'COLIS_EMBALLE',
                                                     brut=True)), 'SHIPMENT_NOT_FOUND')
    verifier('aucun événement écrit par ces refus', un(db, "select count(*) from colis_historique where colis_id = '%s';" % e),
             '1')

    print('\nB7. Double scan, idempotence, conflits')
    f = creer(db, ADMIN, dict(base, description='Scan', suivi_transporteur='SCAN-42'), facturer=False)['colis']['id']
    r1 = op(db, ADMIN, f, 'COLIS_EXPEDIE', lieu='Miami')
    r2 = op(db, ADMIN, f, 'COLIS_EXPEDIE', lieu='Miami')
    verifier('scanné deux fois « Expédié » : le second rend le premier', (r2['deja'], r2['evenement']['id']),
             (True, r1['evenement']['id']))
    g = creer(db, ADMIN, dict(base, description='Inspecté deux fois'), facturer=False)['colis']['id']
    i1 = op(db, ADMIN, g, 'COLIS_INSPECTE')
    verifier('inspecté deux fois de suite : un seul événement', op(db, ADMIN, g, 'COLIS_INSPECTE')['deja'], True)
    k1 = op(db, ADMIN, g, 'COLIS_EMBALLE', cle='scan-session-abc123')
    k2 = op(db, ADMIN, g, 'COLIS_EMBALLE', cle='scan-session-abc123')
    verifier('même clé : même événement', (k2['deja'], k2['evenement']['id']), (True, k1['evenement']['id']))
    verifier('même clé pour une autre opération : refusé',
             erreur(db, ADMIN, op(db, ADMIN, g, 'COLIS_EXPEDIE', cle='scan-session-abc123', brut=True)),
             'DUPLICATE_OPERATION')
    verifier('statut attendu dépassé par une autre opération : conflit',
             erreur(db, ADMIN, op(db, ADMIN, g, 'ACTION_REQUISE', attendu='recu', brut=True)), 'STATUS_CONFLICT')
    verifier('statut attendu dépassé par la même opération : déjà faite',
             op(db, ADMIN, g, 'COLIS_EMBALLE', attendu='recu')['deja'], True)
    op(db, ADMIN, f, 'MISE_A_JOUR', lieu='Miami, quai 3')
    verifier('« Expédié » redemandé après autre chose : déjà à ce statut',
             erreur(db, ADMIN, op(db, ADMIN, f, 'COLIS_EXPEDIE', brut=True)), 'STATUS_ALREADY_SET')
    r = jsonq(db, ADMIN, "select public.executer_operation_par_reference('scan-42', 'COLIS_ARRIVE', 'Port-au-Prince');")
    verifier('par le numéro scanné (suivi vendeur, en minuscules)', r['colis']['statut'], 'distribution')
    verifier('numéro scanné inconnu',
             erreur(db, ADMIN, "select public.executer_operation_par_reference('INCONNU-1', 'COLIS_ARRIVE');"),
             'SHIPMENT_NOT_FOUND')
    lot = [creer(db, ADMIN, dict(base, description='Lot %d' % n), facturer=False)['colis']['id'] for n in range(3)]
    s1 = statut(db, ADMIN, lot, 'embarque', 'Miami', attendus={x: 'recu' for x in lot}, cle='lot-9')
    s2 = statut(db, ADMIN, lot, 'embarque', 'Miami', attendus={x: 'recu' for x in lot}, cle='lot-9')
    verifier('lot renvoyé avec la même clé : rien de refait', ((s1['modifies'], len(s1['evenements'])),
                                                               (s2['modifies'], s2['inchanges'])), ((3, 3), (0, 3)))

    print('\nB8. Concurrence')
    sorties = {}

    def lancer(nom, compte, texte, pause=0):
        time.sleep(pause)
        sorties[nom] = db.comme(compte, texte, echec_permis=True)

    def ensemble(a, b):
        t1 = threading.Thread(target=lancer, args=a)
        t2 = threading.Thread(target=lancer, args=b + (0.3,))
        t1.start(); t2.start(); t1.join(); t2.join()

    x = creer(db, ADMIN, dict(base, description='Course 1'), facturer=False)['colis']['id']
    lent = 'begin; %s select pg_sleep(1); commit;'
    ensemble(('A', ADMIN, lent % op(db, ADMIN, x, 'COLIS_EXPEDIE', lieu='Miami', attendu='recu', brut=True)),
             ('B', ADMIN2, op(db, ADMIN2, x, 'COLIS_EXPEDIE', lieu='Miami', attendu='recu', brut=True)))
    verifier('A et B : Reçu → Expédié en même temps → B reçoit l\'opération de A',
             ('"deja": true' in sorties['B'], un(db, "select count(*) from colis_historique where colis_id = '%s' "
                                                     "and type_evenement = 'COLIS_EXPEDIE';" % x)), (True, '1'))
    y = creer(db, ADMIN, dict(base, description='Course 2'), facturer=False)['colis']['id']
    ensemble(('A', ADMIN, lent % op(db, ADMIN, y, 'COLIS_EXPEDIE', lieu='Miami', attendu='recu', brut=True)),
             ('B', ADMIN2, op(db, ADMIN2, y, 'ACTION_REQUISE', lieu='Miami', attendu='recu', brut=True)))
    verifier('A Expédié, B Action requise en même temps → B en conflit',
             ('STATUS_CONFLICT' in sorties['B'], un(db, "select statut from colis where id = '%s';" % y)),
             (True, 'embarque'))
    verifier('historique cohérent : chaque événement part du statut laissé par le précédent',
             un(db, """select count(*) from (select statut_precedent,
                                                   lag(statut) over (partition by colis_id order by id) avant
                                            from colis_historique where colis_id in ('%s', '%s')) s
                       where statut_precedent is distinct from avant;""" % (x, y)), '0')
    w = creer(db, ADMIN, dict(base, description='Course 3'), facturer=False)['colis']['id']
    meme = op(db, ADMIN, w, 'COLIS_EXPEDIE', lieu='Miami', cle='http-retry-7', brut=True)
    ensemble(('A', ADMIN, lent % meme), ('B', ADMIN, meme))
    verifier('même requête HTTP envoyée deux fois en même temps : un seul événement',
             un(db, "select count(*) from colis_historique where cle_idempotence = 'http-retry-7';"), '1')
    verifier('et renvoyée après coup (retry réseau) : toujours un seul',
             (op(db, ADMIN, w, 'COLIS_EXPEDIE', lieu='Miami', cle='http-retry-7')['deja'],
              un(db, "select count(*) from colis_historique where colis_id = '%s';" % w)), (True, '2'))

    print('\nB9. Historique complet d\'un colis')
    n = creer(db, ADMIN, dict(base, description='Parcours complet', suivi_transporteur='PARCOURS-1'))
    nid = n['colis']['id']
    op(db, ADMIN, nid, 'COLIS_EXPEDIE', lieu='Miami')
    op(db, ADMIN2, nid, 'COLIS_DISPONIBLE', lieu='Agence de Pétion-Ville')
    op(db, ADMIN, nid, 'COLIS_LIVRE', lieu='Pétion-Ville')
    h = jsonq(db, ADMIN, "select public.historique_colis('%s');" % nid)
    verifier('exactement les quatre événements attendus, dans l\'ordre',
             [(e['type_evenement'], e['statut_precedent'], e['statut']) for e in h],
             [('COLIS_RECU', None, 'recu'), ('COLIS_EXPEDIE', 'recu', 'embarque'),
              ('COLIS_DISPONIBLE', 'embarque', 'disponible'), ('COLIS_LIVRE', 'disponible', 'livre')])
    verifier('chacun avec son auteur réel', [e['auteur_id'] for e in h], [ADMIN, ADMIN, ADMIN2, ADMIN])
    verifier('chacun avec son heure, croissante', all(h[k]['cree_le'] and h[k]['cree_le'] <= h[k + 1]['cree_le']
                                                      for k in range(1, 3)), True)
    verifier('deux lectures, la même histoire',
             jsonq(db, ADMIN, "select public.historique_colis('%s');" % nid) == h, True)
    verifier('le dernier événement', jsonq(db, ADMIN, "select public.dernier_evenement('%s');" % nid)['type_evenement'],
             'COLIS_LIVRE')
    client = jsonq(db, MARIE, "select public.historique_colis('%s');" % nid)
    verifier('le client lit son historique, sans auteur ni précisions',
             (len(client), any('auteur_id' in e or 'metadonnees' in e for e in client)), (4, False))
    verifier('mais pas celui d\'un autre', erreur(db, JEAN, "select public.historique_colis('%s');" % nid),
             'PERMISSION_DENIED')
    rech = jsonq(db, ADMIN, "select public.rechercher_evenements('COLIS_LIVRE', now() - interval '1 hour', null, null, 10, 0);")
    verifier('recherche par type et par date (équipe)', (rech['total'] >= 2, all(e['type_evenement'] == 'COLIS_LIVRE'
                                                                                for e in rech['lignes'])), (True, True))
    verifier('refusée à un client', erreur(db, MARIE, "select public.rechercher_evenements();"), 'PERMISSION_DENIED')
    pub = jsonq(db, None, "select public.suivre_colis('PARCOURS-1');")
    verifier('suivi public : statut, étapes, sans note ni précisions ni auteur',
             ([x['statut'] for x in pub['historique']], [k for k in ('note', 'metadonnees', 'auteur') if k in json.dumps(pub)]),
             (['recu', 'embarque', 'disponible', 'livre'], []))
    verifier('les statuts n\'ont pas touché à la facture',
             un(db, "select f.montant_usd from factures f join facture_lignes l on l.facture_id = f.id "
                    "where l.colis_id = '%s';" % nid), '30.00')
    verifier('changer de statut est journalisé (colis.statut)',
             un(db, "select count(*) from journal_audit where action = 'colis.statut' and entite_id = '%s';" % nid), '3')

    print('\nB10. Sécurité des fonctions')
    verifier('RLS toujours active partout',
             un(db, "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' "
                    "and not relrowsecurity;"), '0')
    verifier('toute fonction « security definer » a un search_path fixé',
             un(db, "select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosecdef "
                    "and (proconfig is null or not exists (select 1 from unnest(proconfig) c "
                    "where c like 'search_path=%'));"), '0')
    verifier('un visiteur n\'appelle pas le moteur',
             un(db, "select has_function_privilege('anon', 'public.executer_operation(uuid, text, text, text, jsonb, "
                    "text, text, text, text)', 'execute');"), 'f')

    print('\nB11. Les mêmes règles dans le navigateur (mode démonstration)')
    demo = lambda mode, entree: json.loads(subprocess.run(
        ['node', os.path.join(ICI, 'essai-demo.js'), mode], input=json.dumps(entree),
        capture_output=True, text=True, check=True).stdout)
    catalogue_js = demo('--catalogue', None)
    verifier('catalogue des événements : api.js = base',
             catalogue_js == jsonq(db, 'sql', 'select public.types_evenement();'), True)
    statuts = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-demo.js'), '--regles'],
                                        capture_output=True, text=True).stdout)['statuts']
    triplets = [(de, vers, p) for de in statuts for vers in statuts for p in [None] + statuts if p != de]
    valeurs = ','.join("(%d,'%s','%s',%s)" % (k, de, vers, "'%s'" % p if p else 'null::text')
                       for k, (de, vers, p) in enumerate(triplets))
    sql = gros(db, "select string_agg(coalesce(public.nature_transition(de, vers, p), '-') || '/' || "
                 "coalesce(public.type_pour_statut(de, vers, p), '-'), ',' order by k) "
                 "from (values %s) v(k, de, vers, p);" % valeurs).split(',')
    js = demo('--nature', triplets)
    ecarts = [triplets[k] for k in range(len(triplets)) if sql[k] != js[k]]
    verifier('%d cas nature/type de transition : même réponse' % len(triplets), ecarts, [])
    types = sorted(catalogue_js)
    quad = [(a, p, t, cible) for a in statuts for p in [None] + statuts if p != a for t in types
            for cible in [None, 'embarque', 'disponible']]
    valeurs = ','.join("(%d,'%s',%s,'%s',%s)" % (k, a, "'%s'" % p if p else 'null::text', t,
                                                 "'%s'" % c if c else 'null::text')
                       for k, (a, p, t, c) in enumerate(quad))
    sql = gros(db, "select string_agg(coalesce(v ->> 'code', 'ok') || '/' || coalesce(v ->> 'cible', '-'), ',' order by k) "
                 "from (select k, public.valider_operation(a, p, t, c) v from (values %s) x(k, a, p, t, c)) s;"
                 % valeurs).split(',')
    js = demo('--operations', quad)
    ecarts = [quad[k] for k in range(len(quad)) if sql[k] != js[k]]
    verifier('%d validations d\'opération : même réponse' % len(quad), ecarts[:3], [])

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    return 0 if all(S.RESULTATS) else 1


if __name__ == '__main__':
    sys.exit(main())
