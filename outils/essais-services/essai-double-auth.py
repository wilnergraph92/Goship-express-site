# -*- coding: utf-8 -*-
"""La double authentification de l'équipe (outils/supabase-double-auth.sql, lot 1 du contrôle qualité).

Base jetable, comme les autres bancs ; auth.mfa_factors est une doublure de la table de Supabase
Auth (même colonnes utiles, même type énuméré pour le statut). Le jeton d'une session porte « aal »
comme chez Supabase : « aal1 » (mot de passe seul) ou « aal2 » (code donné).

  A. installation par-dessus une base en service : aucune donnée ne bouge, et tant que personne n'a
     inscrit d'appareil, chaque rôle garde exactement les mêmes permissions ;
  B. un administrateur qui a inscrit un appareil : sans le code, plus rien de l'équipe (permissions,
     lignes protégées par RLS, est_admin) ; avec le code, tout ; un appareil non vérifié ne compte pas ;
  C. une cliente qui aurait inscrit un appareil garde ses colis et ses factures (« :own ») ;
  D. ma_double_auth() et double_auth_equipe() : ce que la page lit, et qui peut le lire ;
  E. obligatoire : seul un administrateur qui a donné son code l'allume, avec un motif, journalisé ;
     un compte de l'équipe sans appareil perd alors l'équipe, un client rien ;
  F. le réglage est fermé, survit à une relance du fichier, et la chaîne officielle le connaît.

    python3 outils/essais-services/essai-double-auth.py
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

ADMIN, ADMIN2, MARIE, JEAN, EMPLOYE, GERANT = S.ADMIN, S.ADMIN2, M.MARIE, M.JEAN, M.EMPLOYE, M.GERANT
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un
CHAINE = M.CHAINE
NOUVEAU = 'supabase-double-auth.sql'

# Doublure de la table de Supabase Auth : le statut y est un type énuméré, pas du texte
DOUBLURE_MFA = """
do $d$ begin
  if to_regtype('auth.factor_status') is null then
    create type auth.factor_status as enum ('unverified', 'verified');
  end if;
end $d$;
create table if not exists auth.mfa_factors (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, friendly_name text,
  factor_type text not null default 'totp', status auth.factor_status not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
"""


def session(db, compte, texte, aal='aal1', echec_permis=False):
    """Comme le site, avec le niveau de la session dans le jeton (« aal1 » ou « aal2 »)."""
    entete = ('set role authenticated;\nset request.jwt.claims = \'{"sub":"%s","aal":"%s"}\';\n' % (compte, aal))
    return db._psql('authenticator', S.BASE, entete + texte, echec_permis)


def val(db, compte, texte, aal='aal1'):
    lignes = [l for l in session(db, compte, texte, aal).splitlines() if l.strip()]
    return lignes[-1].strip() if lignes else ''


def obj(db, compte, texte, aal='aal1'):
    return json.loads(val(db, compte, texte, aal))


def erreur(db, compte, texte, aal='aal1'):
    for ligne in session(db, compte, texte, aal, echec_permis=True).splitlines():
        if ligne.startswith('ERROR:'):
            return ligne.split(':', 1)[1].strip()
    return 'aucune'


def appareil(db, compte, statut='verified'):
    db.sql("insert into auth.mfa_factors (user_id, friendly_name, status) values ('%s', 'Téléphone', '%s');"
           % (compte, statut))


def matrice(db, comptes):
    """Chaque permission connue, pour chaque compte, sans code : « 1 » ou « 0 »."""
    toutes = db.sql("select string_agg(distinct p, ',' order by p) from clients c, "
                    "unnest(public.permissions_du_role(c.role)) p where p not like '%:own';").splitlines()[-1]
    sortie = []
    for compte in comptes:
        sortie.append(val(db, compte, "select string_agg(case when public.peut(p) then '1' else '0' end, '' order by p) "
                                      "from unnest(string_to_array('%s', ',')) p;" % toutes))
    return '|'.join(sortie)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    db.sql(DOUBLURE_MFA)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-supervision-suivi.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-supervision-suivi.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    comptes = ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (ADMIN2, 'equipe2@goship.test', 'Alix Admin'),
               (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
               (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'), (JEAN, 'jean@exemple.com', 'Jean Pierre'))
    for uid, email, nom in comptes:
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000","langue":"fr"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test'); select public.definir_admin('equipe2@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    base_colis = {'description': 'Robe', 'poids_lb': 2, 'service': 'aerien', 'pays_destination': 'HT',
                  'destination': 'Pétion-Ville', 'expediteur': 'Shein', 'lieu': 'Miami (Medley), FL'}
    creer(db, ADMIN, dict(base_colis, client_id=MARIE))
    creer(db, ADMIN, dict(base_colis, client_id=JEAN, description='Chaussures'))
    tous = [c[0] for c in comptes]
    matrice_avant = matrice(db, tous)
    photo = M.empreintes(db)
    for _ in range(3):
        sortie = db.fichier(M.chemin(NOUVEAU))
    verifier('le fichier s\'installe trois fois de suite', 'oui', 'oui')
    verifier('contrôle : 4 fonctions | pas obligatoire | fermées aux visiteurs | peut() vérifie',
             [l for l in sortie.splitlines() if '|' in l][-1].replace(' ', ''), '4|f|f|t')
    verifier('aucune table n\'a changé (hors le réglage, nouveau)', M.empreintes(db, sauf=('double_auth_reglage',)), photo)
    verifier('sans appareil inscrit : chaque rôle garde exactement ses permissions', matrice(db, tous), matrice_avant)
    verifier('… et avec un jeton qui ne dit rien de « aal » (anciennes sessions)',
             db.comme(ADMIN, "select public.peut('roles.manage');").splitlines()[-1], 't')

    print('\nB. Un administrateur qui a inscrit un appareil')
    appareil(db, ADMIN, 'unverified')
    verifier('un appareil pas encore vérifié ne change rien', val(db, ADMIN, "select public.peut('clients.view');"), 't')
    appareil(db, ADMIN)
    verifier('sans le code : plus aucune permission de l\'équipe',
             val(db, ADMIN, "select count(*) from unnest(public.permissions_du_role('admin')) p where public.peut(p);"), '0')
    verifier('sans le code : les colis protégés par la base sont invisibles', val(db, ADMIN, "select count(*) from colis;"), '0')
    verifier('sans le code : les clients aussi', val(db, ADMIN, "select count(*) from clients where id <> auth.uid();"), '0')
    verifier('sans le code : est_admin() répond non', val(db, ADMIN, "select public.est_admin();"), 'f')
    verifier('sans le code : changer un rôle est refusé',
             erreur(db, ADMIN, "select public.changer_role('employe@goship.test', 'gerant');"), 'PERMISSION_DENIED')
    verifier('avec le code (aal2) : toutes ses permissions',
             val(db, ADMIN, "select bool_and(public.peut(p)) from unnest(public.permissions_du_role('admin')) p "
                            "where p not like '%:own';", 'aal2'), 't')
    verifier('avec le code : les deux colis', val(db, ADMIN, "select count(*) from colis;", 'aal2'), '2')
    verifier('avec le code : est_admin() répond oui', val(db, ADMIN, "select public.est_admin();", 'aal2'), 't')
    verifier('l\'autre administrateur, sans appareil, n\'est pas touché',
             val(db, ADMIN2, "select count(*) from colis;"), '2')

    print('\nC. Une cliente qui aurait inscrit un appareil garde ses colis')
    appareil(db, MARIE)
    verifier('sans code : ses colis, et seulement les siens', val(db, MARIE, "select count(*) from colis;"), '1')
    verifier('sans code : ses factures', val(db, MARIE, "select count(*) from factures;"), '1')
    verifier('… et rien de l\'équipe, avec ou sans code', val(db, MARIE, "select public.peut('clients.view');", 'aal2'), 'f')

    print('\nD. Ce que la page lit')
    m = obj(db, ADMIN, "select public.ma_double_auth();")
    verifier('administrateur sans code : code demandé',
             (m['equipe'], m['active'], m['appareils'], m['session'], m['code_requis'], m['obligatoire']),
             (True, True, 1, 'aal1', True, False))
    m = obj(db, ADMIN, "select public.ma_double_auth();", 'aal2')
    verifier('administrateur avec code : rien à demander', (m['session'], m['code_requis']), ('aal2', False))
    m = obj(db, GERANT, "select public.ma_double_auth();")
    verifier('gérant sans appareil : rien à demander, à activer', (m['equipe'], m['active'], m['code_requis']),
             (True, False, False))
    m = obj(db, MARIE, "select public.ma_double_auth();")
    verifier('cliente : pas de l\'équipe, rien à demander', (m['equipe'], m['code_requis']), (False, False))
    e = obj(db, ADMIN, "select public.double_auth_equipe();", 'aal2')
    verifier('l\'équipe vue par l\'administrateur : 4 comptes, un seul protégé, aucun client',
             (len(e['comptes']), sum(1 for c in e['comptes'] if c['appareils'] > 0),
              any(c['id'] in (MARIE, JEAN) for c in e['comptes'])), (4, 1, False))
    verifier('… rien d\'autre qu\'un identifiant et un nombre',
             sorted({k for c in e['comptes'] for k in c}), ['appareils', 'id'])
    verifier('l\'administrateur sans son code ne la lit pas',
             erreur(db, ADMIN, "select public.double_auth_equipe();"), 'PERMISSION_DENIED')
    verifier('une cliente ne la lit pas', erreur(db, MARIE, "select public.double_auth_equipe();"), 'PERMISSION_DENIED')
    verifier('un visiteur n\'appelle aucune des deux',
             S.Base.erreur(db, None, "select public.ma_double_auth();"),
             'permission denied for function ma_double_auth')

    print('\nE. Obligatoire pour toute l\'équipe')
    verifier('sans le code : refusé (l\'administrateur protégé n\'a plus settings.manage)',
             erreur(db, ADMIN, "select public.regler_double_auth(true, 'Toute l''équipe');"), 'PERMISSION_DENIED')
    verifier('sans appareil (donc sans code possible) : refusé',
             erreur(db, ADMIN2, "select public.regler_double_auth(true, 'Toute l''équipe');"), 'MFA_REQUIRED')
    verifier('un gérant, même avec un code : refusé',
             erreur(db, GERANT, "select public.regler_double_auth(true, 'Toute l''équipe');", 'aal2'), 'PERMISSION_DENIED')
    verifier('motif trop court : refusé',
             erreur(db, ADMIN, "select public.regler_double_auth(true, 'ok');", 'aal2'), 'REASON_REQUIRED')
    r = obj(db, ADMIN, "select public.regler_double_auth(true, 'Toute l''équipe est équipée');", 'aal2')
    verifier('l\'administrateur avec son code l\'allume', (r['obligatoire'], r['deja']), (True, False))
    verifier('journalisé : qui, avant, après, motif',
             un(db, "select auteur_id || ' ' || (avant ->> 'obligatoire') || '→' || (apres ->> 'obligatoire') || ' ' || motif "
                    "from journal_audit where action = 'double_auth.reglage' order by id desc limit 1;"),
             '%s false→true Toute l\'équipe est équipée' % ADMIN)
    verifier('le gérant sans appareil n\'a plus l\'équipe', val(db, GERANT, "select count(*) from colis;"), '0')
    verifier('… et la page lui demande d\'en inscrire un',
             obj(db, GERANT, "select public.ma_double_auth();")['code_requis'], True)
    verifier('un jeton aal2 rend l\'équipe (après inscription et code)',
             val(db, GERANT, "select count(*) from colis;", 'aal2'), '2')
    verifier('un client n\'est pas touché', val(db, JEAN, "select count(*) from colis;"), '1')
    verifier('rallumer : rien de plus',
             obj(db, ADMIN, "select public.regler_double_auth(true, 'Encore une fois');", 'aal2')['deja'], True)

    print('\nF. Le réglage est fermé et survit à une relance')
    verifier('aucune lecture directe du réglage',
             erreur(db, ADMIN, "select * from double_auth_reglage;", 'aal2'), 'permission denied for table double_auth_reglage')
    verifier('aucune écriture directe',
             erreur(db, ADMIN, "update double_auth_reglage set obligatoire = false;", 'aal2'),
             'permission denied for table double_auth_reglage')
    verifier('session_double_auth_ok() n\'est ouverte à personne',
             erreur(db, ADMIN, "select public.session_double_auth_ok();", 'aal2'),
             'permission denied for function session_double_auth_ok')
    db.fichier(M.chemin(NOUVEAU))
    verifier('relancer le fichier ne l\'éteint pas', un(db, "select obligatoire from double_auth_reglage;"), 't')
    obj(db, ADMIN, "select public.regler_double_auth(false, 'Retour à l''activation volontaire');", 'aal2')
    verifier('l\'éteindre : le gérant sans appareil retrouve l\'équipe', val(db, GERANT, "select count(*) from colis;"), '2')
    db.sql("delete from auth.mfa_factors;")
    verifier('appareils supprimés (téléphone perdu, Supabase) : tout revient comme avant',
             matrice(db, tous), matrice_avant)

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
