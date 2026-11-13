-- =============================================================================
-- Goship Express — la supervision du suivi externe (Phase 6 du suivi universel, 13/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE trois fonctions (deux lectures pour l'équipe, une commande pour
-- l'administrateur) et un index. Il ne change aucune table, aucune donnée, aucune
-- permission, aucune fonction existante, et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-alertes-suivi.sql.
--
-- Pourquoi : l'équipe ne voyait rien du suivi externe, tout se lisait en SQL. Dossier de
-- la Phase 6 validé par le CEO le 13/11/2026 (les cinq décisions comme recommandé) :
--    1. un onglet « Suivi transporteurs » du tableau de bord (admin.html#suivi), sous
--       tracking.view (administrateur, gérant, employé) ;
--    2. l'administrateur seul (tracking.manage) arrête ou reprend le moteur et change le
--       plafond mensuel, avec un motif, journalisé ;
--    3. « à surveiller » : livré par le transporteur depuis plus de 3 jours sans réception
--       à Miami ; aucune nouvelle depuis 30 jours ;
--    4. « suivre ce numéro » à la main : l'administrateur seul, par demander_suivi_externe
--       (existante, inchangée), après une confirmation qui montre le quota restant ;
--    5. même méthode que les phases précédentes.
--
-- Ce que ce fichier NE fait PAS : aucun statut de colis ne change, aucun événement de colis
-- n'est créé, rien n'est rapproché tout seul. « Livré » par le transporteur n'est jamais
-- « reçu ». Les cas qui ne se rapprochent pas tout seuls sont MONTRÉS ; l'employé décide,
-- par les chemins existants (poste de scan, creer_colis, rapprocher_prealerte).
--
-- Les noms et codes des clients ne sortent que pour un compte qui a clients.view (les trois
-- rôles de l'équipe l'ont) ; un client n'a jamais tracking.view : il n'ouvre rien d'ici.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. index
--    3. supervision_suivi(filtres, page) : santé, compteurs, à surveiller, liste
--    4. fiche_suivi_externe(suivi) : un suivi, ses événements, son journal, ses achats
--    5. piloter_suivi_externe(code, action, motif, valeur) : arrêter, reprendre, plafond
--    6. droits
--    7. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.etat_alertes_suivi()') is null
     or to_regprocedure('public.sante_suivi_externe()') is null
     or to_regprocedure('public.regler_fournisseur_suivi(text, jsonb)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-alertes-suivi.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Index ------------------------------------------------------------------------
-- Les achats d'un suivi (fiche, liste, « à surveiller ») : la pré-alerte ne connaissait
-- son suivi que par une clé étrangère sans index.
create index if not exists prealertes_suivi_externe_idx
  on public.prealertes (suivi_externe_id) where suivi_externe_id is not null;


-- 3. La supervision ----------------------------------------------------------------
-- Une seule lecture pour l'onglet : la santé du moteur (les fonctions de la Phase 3 et de
-- la Phase 5, telles quelles), les cas à surveiller et la liste des suivis, page par page
-- (50 lignes). Rien n'est compté dans la page.
--
-- p_filtres (tous facultatifs ; une valeur inconnue est ignorée) :
--    recherche     numéro, magasin, contenu, code ou nom du client
--    etat          en_attente, actif, arrete, erreur
--    statut        l'un des douze statuts normalisés, ou AUCUN (pas encore de statut)
--    transporteur  le code d'un transporteur (ups, usps, amazon…)
--    suivi         en_cours (pas de fin_motif) ou termine
--
-- Les raisons « à surveiller », dans l'ordre où elles sont montrées :
--    LIVRE_NON_RECU   le transporteur a livré il y a plus de 3 jours, l'achat attend toujours
--    AUTRE_CLIENT     un colis reçu porte ce numéro, mais chez un autre client
--    INCIDENT         exception, tentative échouée, retour
--    NUMERO_REFUSE    le transporteur ne reconnaît pas le numéro
--    SILENCE          aucune nouvelle depuis 30 jours
-- Un achat n'a qu'une de ces raisons (la première qui vaut), plus AUTRE_CLIENT s'il y a lieu.
create or replace function public.supervision_suivi(p_filtres jsonb default '{}'::jsonb, p_page integer default 1)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_par_page constant integer := 50;
  c_livre_jours constant integer := 3;
  c_silence_jours constant integer := 30;
  v_noms boolean;
  v_f jsonb := coalesce(p_filtres, '{}'::jsonb);
  v_recherche text;
  v_compact text;
  v_etat text;
  v_statut text;
  v_transporteur text;
  v_suivi text;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_total integer;
  v_surveiller jsonb;
  v_liste jsonb;
begin
  perform public.exiger_permission('tracking.view');
  v_noms := public.peut('clients.view');

  v_recherche := nullif(lower(btrim(left(coalesce(v_f ->> 'recherche', ''), 80))), '');
  v_compact := nullif(regexp_replace(upper(coalesce(v_recherche, '')), '[^A-Z0-9]', '', 'g'), '');
  v_etat := case when v_f ->> 'etat' in ('en_attente', 'actif', 'arrete', 'erreur') then v_f ->> 'etat' end;
  v_statut := case when v_f ->> 'statut' in ('AUCUN', 'PENDING', 'INFO_RECEIVED', 'IN_TRANSIT', 'CUSTOMS',
                                             'OUT_FOR_DELIVERY', 'AVAILABLE_FOR_PICKUP', 'DELIVERED',
                                             'FAILED_ATTEMPT', 'EXCEPTION', 'RETURNED', 'EXPIRED', 'NOT_FOUND')
                   then v_f ->> 'statut' end;
  v_transporteur := case when v_f ->> 'transporteur' ~ '^[a-z0-9_-]{2,40}$' then v_f ->> 'transporteur' end;
  v_suivi := case when v_f ->> 'suivi' in ('en_cours', 'termine') then v_f ->> 'suivi' end;

  -- Les cas à surveiller : des achats EN ATTENTE (une pré-alerte reçue ou annulée n'a plus
  -- rien à surveiller), 200 au plus, les plus anciens d'abord dans chaque raison (puis dans
  -- l'ordre où les achats ont été annoncés)
  with cas as (
    select 'LIVRE_NON_RECU' as raison, 1 as rang, p.id as prealerte_id, p.cree_le as annonce_le,
           s.id as suivi_id, null::uuid as colis_id,
           coalesce(s.livre_vu_le, s.dernier_evenement_le, s.maj_le) as depuis
      from public.prealertes p join public.suivis_externes s on s.id = p.suivi_externe_id
     where p.statut = 'attente' and s.statut = 'DELIVERED'
       and coalesce(s.livre_vu_le, s.dernier_evenement_le, s.maj_le) < now() - make_interval(days => c_livre_jours)
    union all
    select 'AUTRE_CLIENT', 2, p.id, p.cree_le, p.suivi_externe_id, c.id, c.cree_le
      from public.prealertes p
      join public.colis c on c.suivi_transporteur = public.normaliser_numero_suivi(p.suivi_transporteur)
     where p.statut = 'attente' and btrim(p.suivi_transporteur) <> ''
       and c.client_id is distinct from p.client_id
    union all
    select 'INCIDENT', 3, p.id, p.cree_le, s.id, null, coalesce(s.dernier_evenement_le, s.maj_le)
      from public.prealertes p join public.suivis_externes s on s.id = p.suivi_externe_id
     where p.statut = 'attente' and s.statut in ('EXCEPTION', 'FAILED_ATTEMPT', 'RETURNED')
    union all
    select 'NUMERO_REFUSE', 4, p.id, p.cree_le, s.id, null, s.maj_le
      from public.prealertes p join public.suivis_externes s on s.id = p.suivi_externe_id
     where p.statut = 'attente' and s.code_resultat = 'INVALID_TRACKING'
       and s.statut is distinct from 'DELIVERED' and s.statut is distinct from 'EXCEPTION'
       and s.statut is distinct from 'FAILED_ATTEMPT' and s.statut is distinct from 'RETURNED'
    union all
    select 'SILENCE', 5, p.id, p.cree_le, s.id, null, coalesce(s.dernier_evenement_le, s.inscrit_le, s.cree_le)
      from public.prealertes p join public.suivis_externes s on s.id = p.suivi_externe_id
     where p.statut = 'attente' and s.statut is distinct from 'DELIVERED'
       and s.statut is distinct from 'EXCEPTION' and s.statut is distinct from 'FAILED_ATTEMPT'
       and s.statut is distinct from 'RETURNED' and s.code_resultat is distinct from 'INVALID_TRACKING'
       and coalesce(s.dernier_evenement_le, s.inscrit_le, s.cree_le) < now() - make_interval(days => c_silence_jours)
  ), choisis as (
    select * from cas order by rang, depuis, annonce_le, prealerte_id limit 200
  )
  select jsonb_build_object(
           'compteurs', (select jsonb_build_object(
                            'total', count(*),
                            'LIVRE_NON_RECU', count(*) filter (where raison = 'LIVRE_NON_RECU'),
                            'AUTRE_CLIENT', count(*) filter (where raison = 'AUTRE_CLIENT'),
                            'INCIDENT', count(*) filter (where raison = 'INCIDENT'),
                            'NUMERO_REFUSE', count(*) filter (where raison = 'NUMERO_REFUSE'),
                            'SILENCE', count(*) filter (where raison = 'SILENCE')) from cas),
           'cas', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'raison', x.raison,
                      'depuis', x.depuis,
                      'achat', jsonb_build_object('id', p.id, 'magasin', p.magasin, 'description', p.description,
                                                  'numero_suivi', p.suivi_transporteur, 'cree_le', p.cree_le,
                                                  'client', case when v_noms then jsonb_build_object(
                                                    'id', cl.id, 'code', cl.code, 'nom', cl.nom_complet) end),
                      'suivi', case when s.id is not null then jsonb_build_object(
                                 'id', s.id, 'numero', s.numero, 'transporteur', s.transporteur,
                                 'transporteur_nom', (select t.nom from public.transporteurs_connus() t where t.code = s.transporteur),
                                 'statut', s.statut, 'code_resultat', s.code_resultat, 'dernier_lieu', s.dernier_lieu,
                                 'dernier_evenement_le', s.dernier_evenement_le) end,
                      'colis', case when co.id is not null then jsonb_build_object(
                                 'id', co.id, 'numero', co.numero, 'statut', co.statut, 'cree_le', co.cree_le,
                                 'client', case when v_noms then jsonb_build_object(
                                   'id', cc.id, 'code', cc.code, 'nom', cc.nom_complet) end) end)
                    order by x.rang, x.depuis, x.annonce_le, x.prealerte_id)
               from choisis x
               join public.prealertes p on p.id = x.prealerte_id
               left join public.clients cl on cl.id = p.client_id
               left join public.suivis_externes s on s.id = x.suivi_id
               left join public.colis co on co.id = x.colis_id
               left join public.clients cc on cc.id = co.client_id), '[]'::jsonb))
    into v_surveiller;

  -- La liste des suivis, filtrée, 50 par page, les plus récents d'abord
  with filtres as (
    select s.id, s.cree_le
      from public.suivis_externes s
     where (v_etat is null or s.etat = v_etat)
       and (v_statut is null or (v_statut = 'AUCUN' and s.statut is null) or s.statut = v_statut)
       and (v_transporteur is null or s.transporteur = v_transporteur)
       and (v_suivi is null or (v_suivi = 'en_cours') = (s.fin_motif is null))
       and (v_recherche is null
            or (v_compact is not null and s.numero like '%' || v_compact || '%')
            or exists (select 1 from public.prealertes p
                        left join public.clients cl on cl.id = p.client_id
                        where p.suivi_externe_id = s.id
                          and (lower(p.magasin) like '%' || v_recherche || '%'
                               or lower(p.description) like '%' || v_recherche || '%'
                               or (v_noms and (lower(coalesce(cl.code, '')) like '%' || v_recherche || '%'
                                               or lower(cl.nom_complet) like '%' || v_recherche || '%')))))
  ), page as (
    select * from filtres order by cree_le desc, id
     offset (v_page - 1) * c_par_page limit c_par_page
  )
  select (select count(*) from filtres),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'numero', s.numero, 'transporteur', s.transporteur,
           'transporteur_nom', (select t.nom from public.transporteurs_connus() t where t.code = s.transporteur),
           'fournisseur', s.fournisseur, 'etat', s.etat, 'etape', s.etape, 'statut', s.statut,
           'code_resultat', s.code_resultat, 'derniere_erreur', s.derniere_erreur,
           'dernier_lieu', s.dernier_lieu, 'dernier_evenement_le', s.dernier_evenement_le,
           'origine', s.origine, 'fin_motif', s.fin_motif, 'inscrit_le', s.inscrit_le, 'cree_le', s.cree_le,
           'evenements', (select count(*) from public.suivis_externes_evenements e where e.suivi_id = s.id),
           'achats', (select count(*) from public.prealertes p where p.suivi_externe_id = s.id),
           'clients', case when v_noms then (
              select coalesce(jsonb_agg(distinct cl.code) filter (where cl.code is not null), '[]'::jsonb)
                from public.prealertes p join public.clients cl on cl.id = p.client_id
               where p.suivi_externe_id = s.id) end,
           'colis', (select jsonb_build_object('id', c.id, 'numero', c.numero, 'statut', c.statut)
                       from public.colis c where c.suivi_transporteur = s.numero limit 1))
         order by i.cree_le desc, i.id), '[]'::jsonb)
    into v_total, v_liste
    from page i
    join public.suivis_externes s on s.id = i.id;

  return jsonb_build_object(
    'sante', public.sante_suivi_externe(),
    'fournisseurs', public.etat_fournisseurs_suivi(),
    'alertes', public.etat_alertes_suivi(),
    'seuils', jsonb_build_object('livre_jours', c_livre_jours, 'silence_jours', c_silence_jours),
    'a_surveiller', v_surveiller,
    'suivis', v_liste,
    'total', v_total,
    'page', v_page,
    'pages', greatest(ceil(v_total::numeric / c_par_page)::integer, 1),
    'noms', v_noms,
    'peut_piloter', public.peut('tracking.manage'));
end;
$$;


-- 4. La fiche d'un suivi -------------------------------------------------------------------
-- Ce qu'on en sait, sa chronologie (200 événements au plus, du plus récent au plus ancien),
-- le journal des appels au fournisseur (200 au plus : opération, résultat, codes, durée —
-- jamais la clé ni le contenu d'une requête, que la table ne garde pas), les achats qui le
-- portent et le colis arrivé. NULL pour un suivi inconnu. Le moteur ne rattache un appel à un
-- suivi que s'il ne portait que ce numéro : un appel groupé (plusieurs numéros d'un coup) ne
-- figure dans aucune fiche, seulement dans les erreurs de la santé.
create or replace function public.fiche_suivi_externe(p_suivi uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s public.suivis_externes;
  v_noms boolean;
begin
  perform public.exiger_permission('tracking.view');
  v_noms := public.peut('clients.view');
  select * into s from public.suivis_externes where id = p_suivi;
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'suivi', jsonb_build_object(
      'id', s.id, 'numero', s.numero, 'transporteur', s.transporteur,
      'transporteur_nom', (select t.nom from public.transporteurs_connus() t where t.code = s.transporteur),
      'transporteur_source', s.transporteur_source, 'fournisseur', s.fournisseur,
      'etat', s.etat, 'etape', s.etape, 'statut', s.statut, 'statut_original', s.statut_original,
      'sous_statut', s.sous_statut, 'code_resultat', s.code_resultat, 'derniere_erreur', s.derniere_erreur,
      'dernier_lieu', s.dernier_lieu, 'dernier_evenement_le', s.dernier_evenement_le,
      'livraison_estimee_le', s.livraison_estimee_le, 'livre_vu_le', s.livre_vu_le,
      'origine', s.origine, 'fin_motif', s.fin_motif, 'inscrit_le', s.inscrit_le,
      'derniere_synchro_le', s.derniere_synchro_le, 'prochaine_synchro_le', s.prochaine_synchro_le,
      'lectures', s.lectures, 'tentatives', s.tentatives, 'cree_le', s.cree_le),
    'evenements', coalesce((
      select jsonb_agg(jsonb_build_object('survenu_le', e.survenu_le, 'statut', e.statut,
                                          'statut_original', e.statut_original, 'description', e.description,
                                          'lieu', e.lieu, 'pays', e.pays)
                       order by e.survenu_le desc, e.id desc)
        from (select * from public.suivis_externes_evenements where suivi_id = s.id
               order by survenu_le desc, id desc limit 200) e), '[]'::jsonb),
    'journal', coalesce((
      select jsonb_agg(jsonb_build_object('operation', j.operation, 'resultat', j.resultat,
                                          'code_http', j.code_http, 'code_erreur', j.code_erreur,
                                          'duree_ms', j.duree_ms, 'cree_le', j.cree_le)
                       order by j.cree_le desc, j.id desc)
        from (select * from public.suivis_externes_journal where suivi_id = s.id
               order by cree_le desc, id desc limit 200) j), '[]'::jsonb),
    'achats', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'magasin', p.magasin, 'description', p.description,
                                          'statut', p.statut, 'cree_le', p.cree_le, 'colis_id', p.colis_id,
                                          'client', case when v_noms then jsonb_build_object(
                                            'id', cl.id, 'code', cl.code, 'nom', cl.nom_complet) end)
                       order by p.cree_le desc)
        from public.prealertes p left join public.clients cl on cl.id = p.client_id
       where p.suivi_externe_id = s.id), '[]'::jsonb),
    'colis', (select jsonb_build_object('id', c.id, 'numero', c.numero, 'statut', c.statut, 'cree_le', c.cree_le)
                from public.colis c where c.suivi_transporteur = s.numero limit 1),
    'noms', v_noms);
end;
$$;


-- 5. Piloter le moteur ---------------------------------------------------------------------
-- L'administrateur seul (tracking.manage, vérifié par regler_fournisseur_suivi elle-même),
-- avec un motif d'au moins 5 caractères, gardé dans le journal d'audit :
--    arreter   le fournisseur en service s'arrête (actif et essai éteints) ;
--    reprendre il revient en service : actif s'il est VERIFIED, sinon en essai s'il est en
--              cours de vérification — regler_fournisseur_suivi refuse le reste ;
--    plafond   le plafond mensuel des pré-alertes suivies (p_valeur, 1 à 100 000).
-- Rien d'autre n'est réglable ici : conformité, quota d'essai, transporteurs exclus restent
-- des décisions écrites, passées en SQL.
create or replace function public.piloter_suivi_externe(p_code text, p_action text, p_motif text,
                                                        p_valeur integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.fournisseurs_suivi;
  v_champs jsonb;
begin
  perform public.exiger_permission('tracking.manage');
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Indiquez un motif (5 caractères au moins).');
  end if;
  select * into f from public.fournisseurs_suivi where code = p_code;
  if not found then
    perform public.erreur_metier('PROVIDER_UNKNOWN', 'Fournisseur de suivi inconnu.');
  end if;
  if p_action = 'arreter' then
    if not (f.actif or f.essai) then
      perform public.erreur_metier('PROVIDER_STOPPED', 'Ce fournisseur est déjà arrêté.');
    end if;
    v_champs := jsonb_build_object('actif', false, 'essai', false);
  elsif p_action = 'reprendre' then
    if f.actif or f.essai then
      perform public.erreur_metier('PROVIDER_IN_SERVICE', 'Ce fournisseur est déjà en service.');
    end if;
    v_champs := case when f.conformite = 'VERIFIED' then jsonb_build_object('actif', true)
                     else jsonb_build_object('essai', true) end;
  elsif p_action = 'plafond' then
    if p_valeur is null or p_valeur < 1 or p_valeur > 100000 then
      perform public.erreur_metier('INVALID_CAP', 'Le plafond mensuel va de 1 à 100 000.');
    end if;
    v_champs := jsonb_build_object('plafond_mensuel', p_valeur);
  else
    perform public.erreur_metier('INVALID_ACTION', 'Action inconnue.');
  end if;
  perform set_config('goship.motif', left(btrim(p_motif), 300), true);
  return public.regler_fournisseur_suivi(p_code, v_champs);
end;
$$;


-- 6. Droits --------------------------------------------------------------------------
revoke execute on function public.supervision_suivi(jsonb, integer) from public, anon;
revoke execute on function public.fiche_suivi_externe(uuid) from public, anon;
revoke execute on function public.piloter_suivi_externe(text, text, text, integer) from public, anon;
grant execute on function public.supervision_suivi(jsonb, integer) to authenticated;
grant execute on function public.fiche_suivi_externe(uuid) to authenticated;
grant execute on function public.piloter_suivi_externe(text, text, text, integer) to authenticated;


-- 7. Contrôle ------------------------------------------------------------------------
-- fonctions : 3 ; index : 1 ; ouvertes_aux_visiteurs : false
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('supervision_suivi', 'fiche_suivi_externe', 'piloter_suivi_externe')) as fonctions,
       (select count(*) from pg_indexes where schemaname = 'public'
           and indexname = 'prealertes_suivi_externe_idx') as index,
       (has_function_privilege('anon', 'public.supervision_suivi(jsonb, integer)', 'execute')
        or has_function_privilege('anon', 'public.fiche_suivi_externe(uuid)', 'execute')
        or has_function_privilege('anon', 'public.piloter_suivi_externe(text, text, text, integer)', 'execute'))
         as ouvertes_aux_visiteurs;
