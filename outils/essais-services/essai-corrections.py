# -*- coding: utf-8 -*-
"""Éprouve les corrections du tableau de bord du 12/10/2026 (outils/supabase-corrections.sql).

Même base jetable et mêmes rôles SQL que essai-services.py, avec toute la chaîne de
outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on y laisse des
données à l'ancienne (un colis sans ville, un colis sans poids ni prix, des factures),
puis on installe le fichier deux fois : rien de tout cela ne doit bouger. Ensuite :
  1. le prix fixé à la main : poids facultatif, jamais de poids à zéro, prix gardé tel
     quel, facture juste ; le prix calculé exige toujours un poids ;
  2. les notifications : la base crée les envois avec le colis, l'équipe les lit
     (admin, gérant, employé), un client non ; l'ancien envoi direct est fermé, ce qui
     donnait « permission refusée » ; aucun doublon de colis ni de message ;
  3. l'historique des modifications : motif, avant / après, auteur, dans la même
     transaction ; rien au journal pour une modification refusée ; le journal ne se
     modifie ni ne s'efface ; lisible par l'administrateur seul ; factures payées :
     paiements intacts, montant jamais sous le payé, facture datée « rectifiée » ;
  4. la destination : pays et ville obligatoires, ancien colis sans ville modifiable,
     adresse de livraison distincte et absente du suivi public, date d'enregistrement
     qui ne bouge pas.

Depuis la racine du site :

    python3 outils/essais-services/essai-corrections.py
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
ADMIN, GERANT, EMPLOYE, MARIE, JEAN = A.ADMIN, A.GERANT, A.EMPLOYE, A.MARIE, A.JEAN
verifier, jsonq, un = S.verifier, S.jsonq, S.un
REFUS = 'PERMISSION_DENIED'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
FICHIER = 'supabase-corrections.sql'


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def champs_colis(**k):
    c = {'client_id': MARIE, 'description': 'Colis', 'poids_lb': 4, 'service': 'aerien',
         'pays_destination': 'HT', 'destination': 'Jacmel'}
    c.update(k)
    return {x: v for x, v in c.items() if v is not ...}


def creer(db, compte=ADMIN, cle=None, **k):
    return jsonq(db, compte, "select public.creer_colis(%s, %s, true);" % (js(champs_colis(**k)), q(cle)))


def creer_brut(**k):
    return "select public.creer_colis(%s, null, true);" % js(champs_colis(**k))


def modifier(db, ident, champs, compte=ADMIN, brut=False):
    texte = "select public.modifier_colis('%s', %s);" % (ident, js(champs))
    return texte if brut else jsonq(db, compte, texte)


def mod_facture(db, ident, champs, motif=None, compte=ADMIN, brut=False):
    texte = "select public.modifier_facture('%s', %s, %s);" % (ident, js(champs), q(motif))
    return texte if brut else jsonq(db, compte, texte)


def historique(db, compte=ADMIN, brut=False, **o):
    texte = ("select public.historique_modifications(%s, %s, %s, %s, %s, %s, %s);"
             % (q(o.get('debut')), q(o.get('fin')), q(o.get('recherche', '')), q(o.get('auteur')),
                q(o.get('entite', '')), o.get('page', 0), o.get('par_page', 50)))
    return texte if brut else jsonq(db, compte, texte)


def code(db, compte, texte):
    return db.erreur(compte, texte)


def nb_journal(db):
    return un(db, "select count(*) from journal_audit;")


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation : la chaîne, des données à l\'ancienne, puis ce fichier deux fois')
    for f in CHAINE[:CHAINE.index(FICHIER)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    ancien = creer(db, description='Ancien sans ville')['colis']
    sans_poids = creer(db, description='Ancien sans poids')['colis']
    libre_avant = jsonq(db, ADMIN, "select public.creer_facture('%s', '{}'::uuid[], %s, null);"
                        % (JEAN, js({'montant_usd': 25})))['facture']
    # Des lignes d'avant les règles d'aujourd'hui : posées sans déclencheurs, comme une reprise
    db.sql("alter table colis disable trigger user;"
           "update colis set destination = '' where id = '%s';"
           "update colis set poids_lb = null, prix_usd = null where id = '%s';"
           "alter table colis enable trigger user;" % (ancien['id'], sans_poids['id']))
    photo = ("select string_agg(numero || ':' || coalesce(poids_lb::text, '-') || ':' || destination || ':' || "
             "coalesce(prix_usd::text, '-') || ':' || statut, ',' order by numero) || '|' || "
             "(select string_agg(numero || ':' || montant_usd || ':' || statut, ',' order by numero) from factures) "
             "from colis;")
    avant = un(db, photo)
    journal_avant = nb_journal(db)
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, FICHIER))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('colis et factures d\'avant : pas un caractère, pas un centime de changé', un(db, photo), avant)
    verifier('… et aucune ligne de journal écrite par l\'installation', nb_journal(db), journal_avant)
    verifier('les nouvelles colonnes sont vides pour les anciennes lignes',
             un(db, "select (select count(*) from colis where adresse_livraison <> '') || '|' || "
                    "(select count(*) from factures where rectifiee_le is not null) || '|' || "
                    "(select count(*) from journal_audit where motif <> '');"), '0|0|0')
    verifier('contrôle de fin de fichier : 3 | 2 | faux | 2',
             un(db, "select (select count(*) from information_schema.columns where table_schema = 'public' "
                    "and (table_name, column_name) in (('colis', 'adresse_livraison'), ('factures', 'rectifiee_le'), "
                    "('journal_audit', 'motif'))) || '|' || (select count(*) from pg_proc p join pg_namespace n "
                    "on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('modifier_facture', "
                    "'historique_modifications')) || '|' || (select coalesce(bool_or(has_function_privilege('anon', "
                    "p.oid, 'execute')), false) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where "
                    "n.nspname = 'public' and p.proname in ('modifier_facture', 'historique_modifications', "
                    "'auditer')) || '|' || (select count(*) from pg_trigger where tgrelid = "
                    "'public.journal_audit'::regclass and tgname in ('journal_immuable', 'journal_immuable_vider'));"),
             '3|2|false|2')

    print('\n1. Le prix fixé à la main')
    r = creer(db, poids_lb=4, description='Calculé')
    verifier('prix calculé, poids 4 lb : 4 × 5 = 20 $, facture 20 $',
             (r['colis']['prix_usd'], r['colis']['poids_lb'], r['facture']['montant_usd']), (20, 4, 20))
    verifier('prix calculé sans poids : refusé (INVALID_WEIGHT)', code(db, ADMIN, creer_brut(poids_lb=None)), 'INVALID_WEIGHT')
    verifier('prix calculé, poids vide (« ») : refusé', code(db, ADMIN, creer_brut(poids_lb='')), 'INVALID_WEIGHT')
    verifier('poids 0 : refusé, même au prix fixé', code(db, ADMIN, creer_brut(poids_lb=0, prix_fixe_usd=30)),
             'INVALID_WEIGHT')
    verifier('poids négatif : refusé', code(db, ADMIN, creer_brut(poids_lb=-2)), 'INVALID_WEIGHT')
    verifier('poids absurde (20 000 lb) : refusé, même au prix fixé',
             code(db, ADMIN, creer_brut(poids_lb=20000, prix_fixe_usd=30)), 'INVALID_WEIGHT')
    m1 = creer(db, poids_lb=3, prix_fixe_usd='35,50', description='Forfait avec poids')
    verifier('prix fixé + poids 3 lb : prix 35,50 $ tel quel, poids gardé, aucun tarif',
             (m1['colis']['prix_usd'], m1['colis']['prix_fixe_usd'], m1['colis']['poids_lb'], m1['colis']['tarif_lb_usd']),
             (35.5, 35.5, 3, None))
    m2 = creer(db, poids_lb=None, prix_fixe_usd=40, description='Forfait sans poids')
    verifier('prix fixé SANS poids : enregistré, poids vide (jamais 0), prix 40 $',
             (m2['colis']['poids_lb'], m2['colis']['prix_usd'], m2['colis']['statut']), (None, 40, 'recu'))
    verifier('… en base aussi : poids null, prix 40', un(db, "select coalesce(poids_lb::text, 'null') || ' ' || prix_usd "
                                                          "from colis where id = '%s';" % m2['colis']['id']), 'null 40.00')
    verifier('… sa facture : 40 $, une ligne sans poids, aucun frais',
             (m2['facture']['montant_usd'], [l['poids_lb'] for l in m2['facture']['facture_lignes']],
              m2['facture']['frais_service_usd']), (40, [None], 0))
    verifier('prix fixé sans poids par une employée : refusé (geste de facturation)',
             code(db, EMPLOYE, creer_brut(poids_lb=None, prix_fixe_usd=40)), REFUS)
    verifier('le client le voit dans ses factures : 40 $',
             [f['montant_usd'] for f in jsonq(db, MARIE, "select public.mes_factures();") if f['numero'] == m2['facture']['numero']],
             [40])
    verifier('… et dans son suivi public : le colis existe, sans erreur',
             (jsonq(db, None, "select public.suivre_colis('%s');" % m2['colis']['numero']) or {}).get('numero'),
             m2['colis']['numero'])
    verifier('quitter le prix fixé sans poids : refusé (le prix se calculerait à 0 $)',
             code(db, ADMIN, modifier(db, m2['colis']['id'], {'prix_fixe_usd': None}, brut=True)), 'INVALID_WEIGHT')
    retour = modifier(db, m2['colis']['id'], {'prix_fixe_usd': None, 'poids_lb': 6})
    verifier('… avec un poids (6 lb) : prix recalculé, 30 $', (retour['prix_usd'], retour['tarif_lb_usd']), (30, 5))
    verifier('… la facture déjà émise garde ses 40 $', un(db, "select montant_usd from factures where id = '%s';"
                                                         % m2['facture']['id']), '40.00')
    mod = modifier(db, sans_poids['id'], {'description': 'Ancien sans poids, renommé'})
    verifier('ancien colis sans poids ni prix : modifiable, rien d\'inventé', (mod['poids_lb'], mod['prix_usd']), (None, None))
    verifier('… mais changer son tarif demande un poids',
             code(db, ADMIN, modifier(db, sans_poids['id'], {'tarif_lb_usd': 6}, brut=True)), 'INVALID_WEIGHT')
    verifier('effacer le poids d\'un colis au prix calculé : refusé',
             code(db, ADMIN, modifier(db, r['colis']['id'], {'poids_lb': None}, brut=True)), 'INVALID_WEIGHT')

    print('\n2. Les notifications après l\'enregistrement')
    n1 = creer(db, description='À prévenir', cle='notif-1')
    envois = jsonq(db, ADMIN, "select public.envois_colis('%s');" % n1['colis']['id'])
    verifier('la base a créé « Colis reçu » avec le colis : un envoi par canal',
             sorted((e['type'], e['canal']) for e in envois),
             [('shipment_received', 'email'), ('shipment_received', 'push'), ('shipment_received', 'whatsapp')])
    verifier('rien de configuré ici : non envoyés, avec la raison (pas un refus de droits)',
             sorted((e['canal'], e['statut'], e['code_erreur']) for e in envois),
             [('email', 'annule', 'NON_CONFIGURE'), ('push', 'annule', 'SANS_APPAREIL'),
              ('whatsapp', 'annule', 'NON_CONFIGURE')])
    for nom, compte in (('administrateur', ADMIN), ('gérant', GERANT), ('employée', EMPLOYE)):
        verifier('%s : lit les envois du colis' % nom,
                 code(db, compte, "select public.envois_colis('%s');" % n1['colis']['id']), 'aucune')
    verifier('client : ne lit pas les envois de l\'équipe',
             code(db, MARIE, "select public.envois_colis('%s');" % n1['colis']['id']), REFUS)
    verifier('visiteur : refusé', 'permission denied' in code(db, None, "select public.envois_colis('%s');"
                                                               % n1['colis']['id']), True)
    ancienne = ("select public.envoyer_email_client('%s', 'recu', 'Sujet', '<p>x</p>', 'x');" % n1['colis']['id'])
    verifier('la cause : l\'ancien envoi direct est fermé, même à l\'administrateur',
             'permission denied for function envoyer_email_client' in code(db, ADMIN, ancienne), True)
    verifier('… pareil pour WhatsApp', 'permission denied for function envoyer_whatsapp_client' in code(
        db, ADMIN, "select public.envoyer_whatsapp_client('%s', 'recu', 'colis_recu', 'fr', '[]'::jsonb);"
        % n1['colis']['id']), True)
    deux = creer(db, description='À prévenir', cle='notif-1')
    verifier('même demande renvoyée (après un message raté) : le même colis, rien en double',
             (deux['deja'], deux['colis']['id'] == n1['colis']['id'],
              un(db, "select count(*) from colis where cle_idempotence = 'notif-1';"),
              un(db, "select count(*) from notifications where colis_id = '%s' and type = 'shipment_received';"
                 % n1['colis']['id'])), (True, True, '1', '1'))
    db.sql("select public.definir_reglage('email_cle_api', 'cle-essai'); "
           "select public.definir_reglage('email_expediteur', 'colis@goship.test');")
    n2 = creer(db, description='E-mail configuré')
    e2 = [e for e in jsonq(db, ADMIN, "select public.envois_colis('%s');" % n2['colis']['id']) if e['canal'] == 'email']
    verifier('e-mail configuré : l\'envoi attend le travailleur (« en file »), jamais « envoyé » d\'office',
             [(e['statut'], e['code_erreur']) for e in e2], [('attente', None)])
    db.sql("select public.definir_reglage('email_cle_api', ''); select public.definir_reglage('email_expediteur', '');")

    print('\n3. L\'historique des modifications')
    c3 = creer(db, description='Chaussures', poids_lb=4)['colis']
    db.comme(ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], 'emballe', 'Miami', '', null, null, null);"
             % c3['id'])
    etapes = un(db, "select count(*) from colis_historique where colis_id = '%s';" % c3['id'])
    n_avant = nb_journal(db)
    verifier('modification refusée (poids 0) : rien au journal',
             (code(db, ADMIN, modifier(db, c3['id'], {'poids_lb': 0, 'motif': 'essai'}, brut=True)), nb_journal(db)),
             ('INVALID_WEIGHT', n_avant))
    m3 = modifier(db, c3['id'], {'poids_lb': 5, 'destination': 'Léogâne', 'motif': 'Pesée refaite au dépôt'})
    verifier('colis en cours modifié : nouveau poids, nouveau prix, nouvelle ville',
             (m3['poids_lb'], m3['prix_usd'], m3['destination']), (5, 25, 'Léogâne'))
    verifier('… son statut et ses étapes n\'ont pas bougé',
             (m3['statut'], un(db, "select count(*) from colis_historique where colis_id = '%s';" % c3['id'])),
             ('emballe', etapes))
    j = jsonq(db, 'sql', "select to_jsonb(j) from journal_audit j where entite = 'colis' and entite_id = '%s' "
                         "and action = 'colis.modification' order by id desc limit 1;" % c3['id'])
    verifier('journal : avant / après, auteur, motif',
             (j['avant']['poids_lb'], j['apres']['poids_lb'], j['avant']['destination'], j['apres']['destination'],
              j['auteur_id'], j['motif']), (4, 5, 'Jacmel', 'Léogâne', ADMIN, 'Pesée refaite au dépôt'))
    verifier('le client lit son colis tel qu\'il est maintenant',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select poids_lb || ' ' || destination from colis where id = '%s';" % (MARIE, c3['id'])),
             '5.00 Léogâne')
    verifier('… et ne lit rien du journal', db.comme(MARIE, "select count(*) from journal_audit;").splitlines()[-1], '0')
    verifier('la date d\'enregistrement ne bouge pas', un(db, "select cree_le = '%s'::timestamptz from colis where id = '%s';"
                                                          % (c3['cree_le'], c3['id'])), 't')

    libre = jsonq(db, ADMIN, "select public.creer_facture('%s', '{}'::uuid[], %s, null);"
                  % (JEAN, js({'montant_usd': 50})))['facture']
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s, null);" % (libre['id'], js({'montant_usd': 20, 'moyen': 'especes'})))
    verifier('corriger un montant sans motif : refusé (REASON_REQUIRED)',
             code(db, ADMIN, mod_facture(db, libre['id'], {'montant_usd': 45}, brut=True)), 'REASON_REQUIRED')
    verifier('… motif trop court : refusé', code(db, ADMIN, mod_facture(db, libre['id'], {'montant_usd': 45}, 'ok', brut=True)),
             'REASON_REQUIRED')
    verifier('… sous le payé (20 $) : refusé, même avec un motif',
             code(db, ADMIN, mod_facture(db, libre['id'], {'montant_usd': 10}, 'Remise exceptionnelle', brut=True)),
             'INVALID_AMOUNT')
    f3 = mod_facture(db, libre['id'], {'montant_usd': 45}, 'Remise accordée au client')
    verifier('avec un motif : 45 $, payé 20 $ intact, reste 25 $, un seul paiement',
             (f3['montant_usd'], f3['paye_usd'], f3['solde_usd'], len(f3['paiements'])), (45, 20, 25, 1))
    verifier('… la facture est datée « rectifiée »', f3['rectifiee_le'] is not None, True)
    jf = jsonq(db, 'sql', "select to_jsonb(j) from journal_audit j where entite = 'facture' and entite_id = '%s' "
                          "order by id desc limit 1;" % libre['id'])
    verifier('journal : 50 → 45, motif, action « modification »',
             (jf['avant']['montant_usd'], jf['apres']['montant_usd'], jf['motif'], jf['action']),
             (50, 45, 'Remise accordée au client', 'facture.modification'))
    f4 = mod_facture(db, libre['id'], {'note': 'Merci', 'echeance_le': '2026-11-01'})
    verifier('note et échéance : sans motif, et gardées au journal maintenant',
             (f4['note'], f4['echeance_le'], sorted(jsonq(db, 'sql', "select apres from journal_audit where entite = "
                                                          "'facture' and entite_id = '%s' order by id desc limit 1;"
                                                          % libre['id']).keys())),
             ('Merci', '2026-11-01', ['echeance_le', 'note']))
    verifier('le montant ne change pas sans le demander : rectifiée reste à la même date',
             f4['rectifiee_le'], f3['rectifiee_le'])
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s, null);" % (libre['id'], js({'montant_usd': 25, 'moyen': 'especes'})))
    f5 = mod_facture(db, libre['id'], {'montant_usd': 55}, 'Oubli d\'un article sur la facture')
    verifier('facture payée, montant corrigé à la hausse : à payer 10 $, paiements intacts',
             (f5['statut'], f5['paye_usd'], f5['solde_usd'], len(f5['paiements'])), ('a_payer', 45, 10, 2))
    verifier('une facture de colis garde son total', code(db, ADMIN, mod_facture(
        db, r['facture']['id'], {'montant_usd': 5}, 'Geste commercial', brut=True)), 'INVOICE_LOCKED')
    verifier('un lien de paiement qui n\'est pas https : refusé', code(db, ADMIN, mod_facture(
        db, libre['id'], {'lien_paiement': 'http://exemple.com'}, brut=True)), 'INVALID_INPUT')
    a3 = creer(db, description='À annuler')['facture']
    jsonq(db, ADMIN, "select public.annuler_facture('%s', 'Mauvais client');" % a3['id'])
    verifier('une facture annulée ne se modifie plus',
             code(db, ADMIN, mod_facture(db, a3['id'], {'note': 'x'}, brut=True)), 'INVOICE_LOCKED')
    for nom, compte, attendu in (('employée', EMPLOYE, REFUS), ('client', MARIE, REFUS)):
        verifier('modifier_facture : %s refusé' % nom,
                 code(db, compte, mod_facture(db, libre['id'], {'note': 'x'}, brut=True)), attendu)

    h = historique(db, recherche=c3['numero'])
    verifier('historique : par numéro de colis, ses seules lignes (création, statut, modification)',
             (set(l['reference'] for l in h['lignes']), sorted(set(l['action'] for l in h['lignes']))),
             ({c3['numero']}, ['colis.creation', 'colis.modification', 'colis.statut']))
    ligne = [l for l in h['lignes'] if l['action'] == 'colis.modification'][0]
    verifier('… avec l\'auteur, son rôle et le motif',
             (ligne['auteur'], ligne['role_auteur'], ligne['motif']), ('Ada Admin', 'admin', 'Pesée refaite au dépôt'))
    hf = historique(db, recherche=libre['numero'].lower(), entite='facture')
    verifier('par numéro de facture (minuscules), objet « facture » : ses lignes seulement',
             set(l['reference'] for l in hf['lignes']), {libre['numero']})
    verifier('par administrateur : le gérant n\'a rien modifié', historique(db, auteur=GERANT)['total'], 0)
    verifier('par période : rien en 2020', historique(db, debut='2020-01-01T00:00:00-04:00',
                                                      fin='2020-02-01T00:00:00-04:00')['total'], 0)
    tout = historique(db, par_page=3)
    verifier('pagination : 3 lignes par page, le total compte tout',
             (len(tout['lignes']), tout['total'] > 3), (3, True))
    verifier('la liste des auteurs pour le filtre', [a['nom'] for a in tout['auteurs']], ['Ada Admin'])
    verifier('un « % » dans la recherche ne vaut pas « tout »', historique(db, recherche='%')['total'], 0)
    for nom, compte in (('gérant', GERANT), ('employée', EMPLOYE), ('client', MARIE)):
        verifier('historique : %s refusé, même en appelant la fonction' % nom,
                 code(db, compte, historique(db, brut=True)), REFUS)
    verifier('historique : visiteur refusé', 'permission denied' in code(db, None, historique(db, brut=True)), True)
    verifier('le journal ne se modifie pas, même depuis le SQL Editor',
             code(db, 'sql', "update journal_audit set motif = 'x' where id = (select min(id) from journal_audit);"),
             'AUDIT_LOG_LOCKED')
    verifier('… ne s\'efface pas', code(db, 'sql', "delete from journal_audit;"), 'AUDIT_LOG_LOCKED')
    verifier('… ne se vide pas', code(db, 'sql', "truncate journal_audit;"), 'AUDIT_LOG_LOCKED')
    verifier('… et un compte connecté n\'y écrit rien',
             'permission denied' in code(db, ADMIN, "delete from journal_audit;"), True)

    print('\n4. La destination et l\'étiquette')
    verifier('nouveau colis sans ville : refusé (CITY_REQUIRED)', code(db, ADMIN, creer_brut(destination='')), 'CITY_REQUIRED')
    verifier('… ville faite d\'espaces : refusée', code(db, ADMIN, creer_brut(destination='   ')), 'CITY_REQUIRED')
    verifier('… ville absente du tout : refusée', code(db, ADMIN, creer_brut(destination=...)), 'CITY_REQUIRED')
    verifier('pays inconnu : refusé', code(db, ADMIN, creer_brut(pays_destination='FR')), 'INVALID_DESTINATION')
    mod = modifier(db, ancien['id'], {'description': 'Ancien, renommé'})
    verifier('ancien colis sans ville : modifiable sans lui en inventer une', mod['destination'], '')
    verifier('… mais changer son pays demande une ville',
             code(db, ADMIN, modifier(db, ancien['id'], {'pays_destination': 'DO'}, brut=True)), 'CITY_REQUIRED')
    mod = modifier(db, ancien['id'], {'pays_destination': 'DO', 'destination': 'Santiago de los Caballeros',
                                       'motif': 'Destination corrigée'})
    verifier('… pays et ville ensemble : acceptés', (mod['pays_destination'], mod['destination']),
             ('DO', 'Santiago de los Caballeros'))
    longue = 'Rue Lamarre, 12, ' + 'x' * 200
    c4 = creer(db, description='Livré à domicile', destination='  Pétion-Ville ',
               adresse_livraison='  ' + longue)['colis']
    verifier('ville et adresse de livraison nettoyées, l\'adresse bornée à 160 caractères',
             (c4['destination'], len(c4['adresse_livraison']), c4['adresse_livraison'][:16]),
             ('Pétion-Ville', 160, 'Rue Lamarre, 12,'))
    verifier('l\'adresse de livraison n\'est pas celle du profil du client',
             c4['adresse_livraison'] != (c4.get('adresse_client') or ''), True)
    suivi = jsonq(db, None, "select public.suivre_colis('%s');" % c4['numero'])
    verifier('le suivi public ne montre ni l\'adresse de livraison ni celle du client',
             [k for k in ('adresse_livraison', 'adresse_client', 'telephone_client') if k in json.dumps(suivi)], [])
    m4 = modifier(db, c4['id'], {'adresse_livraison': 'Delmas 33, impasse Rosier', 'motif': 'Nouvelle adresse'})
    verifier('adresse modifiée : la nouvelle, et l\'ancienne au journal',
             (m4['adresse_livraison'],
              jsonq(db, 'sql', "select avant from journal_audit where entite = 'colis' and entite_id = '%s' "
                               "order by id desc limit 1;" % c4['id'])['adresse_livraison'][:16]),
             ('Delmas 33, impasse Rosier', 'Rue Lamarre, 12,'))
    verifier('la date d\'enregistrement reste celle de la création',
             m4['cree_le'] == c4['cree_le'] and m4['maj_le'] != c4['maj_le'], True)

    ok = sum(1 for r in S.RESULTATS if r)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), ok))
    sys.exit(0 if ok == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
