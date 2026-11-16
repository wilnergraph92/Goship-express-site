# -*- coding: utf-8 -*-
"""Les index des clés étrangères (outils/supabase-index-cles.sql, lot confort du contrôle qualité).

Base jetable, comme les autres bancs :

  A. installation par-dessus une base en service, trois fois, sans changer une donnée ;
  B. les six index existent, sur les bonnes colonnes, et plus aucune clé étrangère du schéma public
     n'est sans index ;
  C. la chaîne officielle connaît le fichier.

    python3 outils/essais-services/essai-index-cles.py
"""
import importlib.util
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_moteur', os.path.join(ICI, 'essai-moteur-suivi.py'))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)
S = M.S

verifier, un = S.verifier, S.un
CHAINE = M.CHAINE
NOUVEAU = 'supabase-index-cles.sql'
SANS_INDEX = ("select count(*) from pg_constraint c where c.contype = 'f' and c.connamespace = 'public'::regnamespace "
              "and not exists (select 1 from pg_index i where i.indrelid = c.conrelid "
              "and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey);")


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-prealertes-equipe.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-prealertes-equipe.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
              values ('%s', 'equipe@goship.test', now(), '{"nom_complet":"Ada Admin","pays":"HT"}'::jsonb);""" % S.ADMIN)
    db.sql("select public.definir_admin('equipe@goship.test');")
    avant_cles = un(db, SANS_INDEX)
    verifier('avant : les six clés étrangères signalées par Supabase sont sans index', avant_cles, '6')
    photo = M.empreintes(db)
    for _ in range(3):
        sortie = db.fichier(M.chemin(NOUVEAU))
    verifier('le fichier s\'installe trois fois de suite', 'oui', 'oui')
    verifier('contrôle : 6 index | aucune clé sans index',
             [l for l in sortie.splitlines() if '|' in l][-1].replace(' ', ''), '6|0')
    verifier('aucune donnée n\'a changé', M.empreintes(db), photo)

    print('\nB. Les bons index, sur les bonnes colonnes')
    attendus = {
        'factures_remplacee_par_idx': 'factures(remplacee_par)',
        'prealertes_colis_idx': 'prealertes(colis_id)',
        'suivis_externes_fournisseur_idx': 'suivis_externes(fournisseur)',
        'suivis_externes_evenements_fournisseur_idx': 'suivis_externes_evenements(fournisseur)',
        'suivis_externes_journal_fournisseur_idx': 'suivis_externes_journal(fournisseur)',
        'suivis_externes_journal_suivi_idx': 'suivis_externes_journal(suivi_id)',
    }
    for nom, cible in sorted(attendus.items()):
        obtenu = un(db, "select c.relname || '(' || string_agg(a.attname, ',' order by k.n) || ')' "
                        "from pg_index i join pg_class x on x.oid = i.indexrelid join pg_class c on c.oid = i.indrelid "
                        "cross join lateral unnest(i.indkey::int2[]) with ordinality k(att, n) "
                        "join pg_attribute a on a.attrelid = c.oid and a.attnum = k.att "
                        "where x.relname = '%s' group by c.relname;" % nom)
        verifier(nom, obtenu, cible)
    verifier('plus aucune clé étrangère sans index', un(db, SANS_INDEX), '0')

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
