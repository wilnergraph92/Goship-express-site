# -*- coding: utf-8 -*-
"""L'équipe modifie ou supprime une pré-alerte (outils/supabase-prealertes-equipe.sql).

Base jetable et fausse pg_net, comme les autres bancs : 17TRACK n'est jamais appelé.

  A. installation par-dessus une base en service, sans changer une donnée ;
  B. modifier : les champs changent, le numéro est remis en forme, le journal garde avant, après
     et motif ; rien de changé = rien d'écrit ; le statut ne bouge pas ;
  C. les refus : mêmes contrôles qu'à la création, pré-alerte reçue, inconnue, client, visiteur ;
  D. un numéro changé : l'ancien suivi du transporteur est détaché, le nouveau ouvert si le suivi
     automatique est allumé (et seulement alors) ;
  E. supprimer : administrateur seul, motif obligatoire, jamais une pré-alerte reçue ; le journal
     garde la copie complète ;
  F. les accès directs : l'équipe ne modifie ni n'efface plus la table sans passer par les
     fonctions ; le client garde les siens (application mobile) ;
  G. aucun colis, aucun historique, aucun statut de colis n'a bougé.

    python3 outils/essais-services/essai-prealertes-equipe.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_moteur', os.path.join(ICI, 'essai-moteur-suivi.py'))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)
S = M.S

ADMIN, MARIE, JEAN, EMPLOYE, GERANT = S.ADMIN, M.MARIE, M.JEAN, M.EMPLOYE, M.GERANT
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un
CHAINE = M.CHAINE
NOUVEAU = 'supabase-prealertes-equipe.sql'


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def prealerte(db, client, magasin, description, suivi=''):
    return jsonq(db, client, "select public.creer_prealerte(gen_random_uuid(), %s, %s, %s, null, 'aerien');"
                 % (q(magasin), q(description), q(suivi)))


def modifier(db, compte, ident, champs, motif=None):
    return jsonq(db, compte, "select public.modifier_prealerte('%s', %s::jsonb, %s);"
                 % (ident, q(json.dumps(champs)), q(motif) if motif is not None else 'null'))


def erreur_modif(db, compte, ident, champs, motif=None):
    return db.erreur(compte, "select public.modifier_prealerte('%s', %s::jsonb, %s);"
                     % (ident, q(json.dumps(champs)), q(motif) if motif is not None else 'null'))


def ligne(db, ident):
    return un(db, "select coalesce((select magasin || '|' || description || '|' || suivi_transporteur || '|' || "
                  "coalesce(valeur_usd::text, '-') || '|' || service || '|' || statut from prealertes where id = '%s'), 'absente');"
              % ident)


def journal(db, action):
    sortie = un(db, "select coalesce((select json_build_object('auteur', auteur_id, 'avant', avant, 'apres', apres, "
                    "'motif', motif)::text from journal_audit where action = '%s' order by id desc limit 1), 'null');" % action)
    return json.loads(sortie)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-battement.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-battement.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
                            (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Pierre')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000","langue":"fr"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    p1 = prealerte(db, MARIE, 'Shein', 'Robe rouge', '1Z999AA10123456784')['id']
    p2 = prealerte(db, MARIE, 'Temu', 'Écouteurs', 'TBA312345678901')['id']
    p3 = prealerte(db, MARIE, 'Nike', 'Chaussures', 'SWX000000000000303')['id']
    pj = prealerte(db, JEAN, 'Ebay', 'Montre', '')['id']
    # Le colis de Nike arrive chez Marie : sa pré-alerte passe à « reçue » toute seule
    creer(db, ADMIN, {'client_id': MARIE, 'description': 'Chaussures', 'poids_lb': 2, 'service': 'aerien',
                      'pays_destination': 'HT', 'destination': 'Pétion-Ville', 'lieu': 'Miami (Medley), FL',
                      'suivi_transporteur': 'SWX000000000000303'})
    verifier('avant la migration : 4 pré-alertes, dont une reçue',
             un(db, "select count(*) || ':' || count(*) filter (where statut = 'recu') from prealertes;"), '4:1')
    HIST = "select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from colis_historique h;"
    COLIS = "select md5(string_agg(id || statut || coalesce(suivi_transporteur, ''), ',' order by id)) from colis;"
    hist_avant, colis_avant = un(db, HIST), un(db, COLIS)
    photo = M.empreintes(db)
    for _ in range(3):
        sortie = db.fichier(M.chemin(NOUVEAU))
    verifier('le fichier s\'installe trois fois de suite', 'oui', 'oui')
    verifier('contrôle : 2 fonctions | fermées aux visiteurs | aucune règle d\'équipe en direct',
             [l for l in sortie.splitlines() if '|' in l][-1].replace(' ', ''), '2|f|0')
    verifier('aucune table n\'a changé', M.empreintes(db), photo)

    print('\nB. Modifier une pré-alerte en attente')
    r = modifier(db, EMPLOYE, p1, {'magasin': ' Shein US ', 'suivi_transporteur': '1z999aa1 0123456791',
                                   'valeur_usd': '42.5', 'service': 'maritime'}, 'Numéro corrigé par la cliente au téléphone')
    verifier('l\'employée modifie : magasin, numéro remis en forme, valeur, mode',
             (r['magasin'], r['suivi_transporteur'], r['valeur_usd'], r['service'], r['statut'], r['deja']),
             ('Shein US', '1Z999AA10123456791', 42.5, 'maritime', 'attente', False))
    verifier('… et la base garde exactement cela', ligne(db, p1), 'Shein US|Robe rouge|1Z999AA10123456791|42.50|maritime|attente')
    j = journal(db, 'prealerte.modification')
    verifier('journal : qui, avant et après des seuls champs changés, motif',
             (j['auteur'], sorted(j['avant']), j['apres']['suivi_transporteur'], j['avant']['magasin'], j['motif']),
             (EMPLOYE, ['magasin', 'service', 'suivi_transporteur', 'valeur_usd'], '1Z999AA10123456791', 'Shein',
              'Numéro corrigé par la cliente au téléphone'))
    n_journal = un(db, "select count(*) from journal_audit where action = 'prealerte.modification';")
    r = modifier(db, GERANT, p1, {'magasin': 'Shein US'})
    verifier('rien de changé : « déjà », rien d\'écrit au journal',
             (r['deja'], un(db, "select count(*) from journal_audit where action = 'prealerte.modification';")), (True, n_journal))
    r = modifier(db, ADMIN, p1, {'valeur_usd': None})
    verifier('valeur effacée (null), sans motif : permis', (r['valeur_usd'], r['deja']), (None, False))

    print('\nC. Les refus')
    verifier('magasin vide', erreur_modif(db, EMPLOYE, p1, {'magasin': '  '}), 'PREALERT_STORE_REQUIRED')
    verifier('contenu vide', erreur_modif(db, EMPLOYE, p1, {'description': ''}), 'PREALERT_DESCRIPTION_REQUIRED')
    verifier('numéro illisible', erreur_modif(db, EMPLOYE, p1, {'suivi_transporteur': 'AB#12'}), 'INVALID_TRACKING')
    verifier('valeur négative', erreur_modif(db, EMPLOYE, p1, {'valeur_usd': -1}), 'INVALID_VALUE')
    verifier('valeur qui n\'est pas un nombre', erreur_modif(db, EMPLOYE, p1, {'valeur_usd': 'beaucoup'}), 'INVALID_VALUE')
    verifier('mode inconnu', erreur_modif(db, EMPLOYE, p1, {'service': 'bateau'}), 'INVALID_SERVICE')
    verifier('numéro d\'une autre pré-alerte en attente du même client',
             erreur_modif(db, EMPLOYE, p1, {'suivi_transporteur': 'TBA312345678901'}), 'PREALERT_DUPLICATE')
    verifier('numéro d\'un colis déjà arrivé chez ce client',
             erreur_modif(db, EMPLOYE, p1, {'suivi_transporteur': 'SWX000000000000303'}), 'PREALERT_ALREADY_RECEIVED')
    verifier('le même numéro chez un AUTRE client : permis (deux clients, deux achats)',
             modifier(db, EMPLOYE, pj, {'suivi_transporteur': 'TBA312345678901'})['suivi_transporteur'], 'TBA312345678901')
    verifier('pré-alerte reçue : ne se modifie plus', erreur_modif(db, ADMIN, p3, {'magasin': 'Nike US'}), 'PREALERT_NOT_PENDING')
    verifier('pré-alerte inconnue', erreur_modif(db, ADMIN, '00000000-0000-0000-0000-000000000000', {'magasin': 'X'}),
             'PREALERT_NOT_FOUND')
    verifier('la cliente elle-même ne passe pas par là', erreur_modif(db, MARIE, p1, {'magasin': 'X'}), 'PERMISSION_DENIED')
    verifier('un visiteur non plus', db.erreur(None, "select public.modifier_prealerte('%s', '{}'::jsonb, null);" % p1),
             'permission denied for function modifier_prealerte')
    verifier('aucun refus n\'a rien écrit', ligne(db, p1), 'Shein US|Robe rouge|1Z999AA10123456791|-|maritime|attente')

    print('\nD. Un numéro changé et le suivi du transporteur')
    # Le suivi automatique des pré-alertes allumé (en essai), comme en production depuis le 16/11
    db.sql("select public.definir_reglage('suivi_17track_cle', 'cle-essai-17track');")
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"conformite\": \"PENDING_VERIFICATION\", "
                     "\"essai\": true, \"plafond_essai\": 30, \"marge_quota\": 20, \"suivre_prealertes\": true, "
                     "\"plafond_mensuel\": 30}');")
    p4 = prealerte(db, MARIE, 'Zara', 'Veste', 'GFUS01000000000301')['id']
    ancien = un(db, "select suivi_externe_id from prealertes where id = '%s';" % p4)
    verifier('une nouvelle pré-alerte est suivie (déclencheur existant)', ancien != '', True)
    modifier(db, EMPLOYE, p4, {'suivi_transporteur': 'GFUS01000000000302'})
    nouveau = un(db, "select s.numero from prealertes p join suivis_externes s on s.id = p.suivi_externe_id "
                     "where p.id = '%s';" % p4)
    verifier('numéro changé : la pré-alerte suit le nouveau numéro', nouveau, 'GFUS01000000000302')
    verifier('… l\'ancien suivi existe toujours (aucune donnée effacée), sans cette pré-alerte',
             un(db, "select count(*) from suivis_externes where id = '%s';" % ancien) + ':' +
             un(db, "select count(*) from prealertes where suivi_externe_id = '%s';" % ancien), '1:0')
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"suivre_prealertes\": false}');")
    modifier(db, EMPLOYE, p4, {'suivi_transporteur': 'GFUS01000000000303'})
    verifier('interrupteur éteint : détachée, aucun suivi ouvert',
             (un(db, "select coalesce(suivi_externe_id::text, 'aucun') from prealertes where id = '%s';" % p4),
              un(db, "select count(*) from suivis_externes where numero = 'GFUS01000000000303';")), ('aucun', '0'))
    modifier(db, EMPLOYE, p4, {'magasin': 'Zara Home'})
    verifier('un autre champ changé ne touche pas au suivi', un(db, "select coalesce(suivi_externe_id::text, 'aucun') "
             "from prealertes where id = '%s';" % p4), 'aucun')

    print('\nE. Supprimer une pré-alerte')
    verifier('l\'employée : refusé (shipments.delete)',
             db.erreur(EMPLOYE, "select public.supprimer_prealerte('%s', 'Doublon annoncé deux fois');" % p2), 'PERMISSION_DENIED')
    verifier('le gérant : refusé',
             db.erreur(GERANT, "select public.supprimer_prealerte('%s', 'Doublon annoncé deux fois');" % p2), 'PERMISSION_DENIED')
    verifier('la cliente : refusé (elle supprime les siennes depuis l\'application)',
             db.erreur(MARIE, "select public.supprimer_prealerte('%s', 'Doublon annoncé deux fois');" % p2), 'PERMISSION_DENIED')
    verifier('motif trop court', db.erreur(ADMIN, "select public.supprimer_prealerte('%s', 'non');" % p2), 'REASON_REQUIRED')
    verifier('pré-alerte reçue : refusé, avec le numéro du colis',
             db.erreur(ADMIN, "select public.supprimer_prealerte('%s', 'Pour voir ce qui arrive');" % p3), 'PREALERT_RECEIVED')
    avant = un(db, "select to_jsonb(p)::text from prealertes p where id = '%s';" % p2)
    r = jsonq(db, ADMIN, "select public.supprimer_prealerte('%s', 'Doublon : la cliente l''a annoncée deux fois');" % p2)
    verifier('l\'administrateur supprime', (r['supprimee'], ligne(db, p2)), (True, 'absente'))
    j = journal(db, 'prealerte.suppression')
    verifier('journal : copie complète de la pré-alerte, motif, auteur',
             (j['avant'] == json.loads(avant), j['apres'], j['motif'], j['auteur']),
             (True, None, 'Doublon : la cliente l\'a annoncée deux fois', ADMIN))
    verifier('une seconde fois : introuvable',
             db.erreur(ADMIN, "select public.supprimer_prealerte('%s', 'Doublon encore');" % p2), 'PREALERT_NOT_FOUND')

    print('\nF. Les accès directs à la table')
    verifier('l\'employée ne modifie plus en direct (0 ligne)',
             un(db, "select 1;") and db.comme(EMPLOYE, "with u as (update prealertes set magasin = 'Pirate' where id = '%s' "
                                                        "returning 1) select count(*) from u;" % p1).splitlines()[-1], '0')
    verifier('l\'administrateur n\'efface plus en direct (0 ligne)',
             db.comme(ADMIN, "with u as (delete from prealertes where id = '%s' returning 1) select count(*) from u;"
                      % p1).splitlines()[-1], '0')
    verifier('la cliente modifie toujours la sienne en direct (application installée)',
             db.comme(MARIE, "with u as (update prealertes set description = 'Robe rouge, taille M' where id = '%s' "
                             "returning 1) select count(*) from u;" % p1).splitlines()[-1], '1')
    verifier('… mais pas celle d\'un autre client',
             db.comme(MARIE, "with u as (update prealertes set magasin = 'X' where id = '%s' returning 1) "
                             "select count(*) from u;" % pj).splitlines()[-1], '0')
    verifier('… et supprime toujours la sienne en direct',
             db.comme(MARIE, "with u as (delete from prealertes where id = '%s' returning 1) select count(*) from u;"
                      % p4).splitlines()[-1], '1')
    verifier('l\'équipe lit toujours toutes les pré-alertes', un(db, "select count(*) from prealertes;"),
             db.comme(EMPLOYE, "select count(*) from prealertes;").splitlines()[-1])

    print('\nG. Les colis n\'ont pas bougé')
    verifier('l\'historique des colis est intact', un(db, HIST), hist_avant)
    verifier('les colis et leurs statuts aussi', un(db, COLIS), colis_avant)

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
