-- =============================================================================
-- Goship Express — Les rapports (onglet « Rapport » du tableau de bord, 28/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une table (les rapports enregistrés), trois index et des fonctions. Il ne
-- supprime rien, ne change aucune donnée ni aucune règle existante, et peut être
-- relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-production.sql. Il demande les permissions reports.create, reports.edit
-- et reports.delete, ajoutées le même jour à supabase.sql : sans elles, il s'arrête
-- dès la première ligne et dit quoi relancer.
--
-- Un rapport enregistré n'est qu'une DÉFINITION : un nom, une période (des dates
-- de Santo Domingo, arrêtées à l'enregistrement), des filtres et les parties à
-- inclure. Ses chiffres et ses lignes se lisent dans les tables à chaque
-- ouverture (rapport_donnees), avec les définitions d'Analytics : le facturé d'un
-- rapport est celui d'Analytics pour les mêmes jours. Rien n'est recopié, rien
-- n'est recalculé à la main. Supprimer un rapport n'efface que sa ligne dans
-- « rapports » : aucune table n'en dépend, aucune donnée de colis, de facture ou
-- de paiement ne le suit.
--
-- L'activité d'un rapport vient du journal d'audit qui existe déjà (journal_audit,
-- supabase-services.sql) : création, modification, statut et suppression des
-- colis, clients et factures, paiements et annulations, rôles, rapports. Aucun
-- second journal. Une ligne n'y paraît que si le compte peut voir ce dont elle
-- parle (colis : shipments.view_history ; facture : invoices.view ; paiement :
-- payments.view ; client : clients.view, et users.view pour un changement de
-- rôle ; rapport : reports.view) ; audit_logs.view voit tout. Ce que la base ne
-- note pas (une suppression d'avant le journal, un scan refusé) n'y est pas.
--
-- Permissions (supabase.sql, permissions_du_role) :
--   reports.view    lire les rapports, leurs chiffres, les imprimer, en faire un
--                   PDF (administrateur, gérant) ; imprimer et exporter se font
--                   dans le navigateur, sur ce que reports.view a déjà lu
--   reports.create  enregistrer un rapport (administrateur, gérant)
--   reports.edit    modifier un rapport enregistré (administrateur)
--   reports.delete  supprimer un rapport enregistré (administrateur)
-- Un employé, un client ou un visiteur est refusé par chaque fonction.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. la table des rapports et ses index
--    3. les aides (période, filtres, parties, noms)
--    4. le journal des rapports (déclencheur)
--    5. les rapports : créer, modifier, supprimer, lister
--    6. les données d'un rapport (rapport_donnees)
--    7. droits et contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null
     or to_regprocedure('public.paye_usd(public.factures)') is null
     or to_regprocedure('public.creances_au(timestamptz)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
  if not ('reports.delete' = any (public.permissions_du_role('admin'))) then
    raise exception 'Permissions des rapports absentes : relancez outils/supabase.sql, puis toute la chaîne dans l''ordre (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. La table des rapports -------------------------------------------------------------
--   periode   aujourdhui, journalier, hebdomadaire, mensuel, trimestriel, annuel,
--             personnalise ; debut et fin en sont les jours (Santo Domingo, inclus)
--   filtres   { statut_colis : attente | transit | disponible | livre | incident,
--               etat_facture : payee | impayee | annulee | supprimee } (clé absente = tous)
--   sections  colis, evenements, factures, paiements, clients, activite, finances
create table if not exists public.rapports (
  id            uuid primary key default gen_random_uuid(),
  nom           text not null check (length(trim(nom)) between 1 and 120),
  type          text not null check (type in ('complet', 'colis', 'factures', 'paiements', 'clients',
                                              'evenements', 'activite')),
  periode       text not null check (periode in ('aujourdhui', 'journalier', 'hebdomadaire', 'mensuel',
                                                 'trimestriel', 'annuel', 'personnalise')),
  debut         date not null,
  fin           date not null,
  filtres       jsonb not null default '{}'::jsonb,
  sections      text[] not null,
  cree_par      uuid,
  role_createur text not null default '',
  cree_le       timestamptz not null default now(),
  modifie_le    timestamptz,
  modifie_par   uuid,
  constraint rapports_dates_check check (fin >= debut)
);

comment on table public.rapports is
  'Les rapports enregistrés (onglet Rapport) : leur définition seulement. Leurs chiffres se lisent dans les tables à chaque ouverture (rapport_donnees).';

create index if not exists rapports_creation_idx on public.rapports (cree_le desc);
-- Les suppressions (factures, colis) d'une période, lues dans le journal
create index if not exists journal_audit_action_idx on public.journal_audit (action, cree_le);
-- Tous les paiements d'une période, annulés compris (paiements_date_idx ne garde que
-- les valides)
create index if not exists paiements_paye_le_idx on public.paiements (paye_le);

-- Aucune lecture ni écriture directe : tout passe par les fonctions ci-dessous,
-- qui vérifient les permissions.
alter table public.rapports enable row level security;
revoke all on public.rapports from public, anon, authenticated;
grant select, insert, update, delete on public.rapports to service_role;


-- 3. Les aides -----------------------------------------------------------------------

-- Une date reçue en texte (AAAA-MM-JJ) → la date, ou une erreur lisible
create or replace function public.rapport_date(p_texte text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
begin
  if nullif(trim(coalesce(p_texte, '')), '') is null then
    return null;
  end if;
  if p_texte !~ '^\d{4}-\d{2}-\d{2}$' then
    perform public.erreur_metier('INVALID_PERIOD', 'Date illisible : ' || left(p_texte, 20) || '.');
  end if;
  return p_texte::date;
exception when datetime_field_overflow or invalid_datetime_format then
  perform public.erreur_metier('INVALID_PERIOD', 'Date impossible : ' || left(p_texte, 20) || '.');
  return null;
end;
$$;

-- Le type de période et sa date de référence → les jours du rapport (inclus)
--   aujourdhui     aujourd'hui à Santo Domingo
--   journalier     le jour choisi (debut)
--   hebdomadaire   la semaine, du lundi au dimanche, qui contient debut
--   mensuel        le mois de debut ; trimestriel son trimestre ; annuel son année
--   personnalise   de debut à fin, trois ans au plus
-- Sans date de référence : aujourd'hui.
create or replace function public.rapport_bornes(p_periode text, p_debut date default null, p_fin date default null)
returns table (debut date, fin date)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_ref date := coalesce(p_debut, public.aujourdhui());
begin
  case coalesce(p_periode, '')
    when 'aujourdhui' then
      return query select public.aujourdhui(), public.aujourdhui();
    when 'journalier' then
      return query select v_ref, v_ref;
    when 'hebdomadaire' then
      return query select date_trunc('week', v_ref)::date, date_trunc('week', v_ref)::date + 6;
    when 'mensuel' then
      return query select date_trunc('month', v_ref)::date,
                          (date_trunc('month', v_ref) + interval '1 month - 1 day')::date;
    when 'trimestriel' then
      return query select date_trunc('quarter', v_ref)::date,
                          (date_trunc('quarter', v_ref) + interval '3 months - 1 day')::date;
    when 'annuel' then
      return query select date_trunc('year', v_ref)::date,
                          (date_trunc('year', v_ref) + interval '1 year - 1 day')::date;
    when 'personnalise' then
      if p_debut is null or p_fin is null then
        perform public.erreur_metier('INVALID_PERIOD', 'Choisissez une date de début et une date de fin.');
      end if;
      if p_debut > p_fin then
        perform public.erreur_metier('INVALID_PERIOD', 'La date de début doit être antérieure à la date de fin.');
      end if;
      if p_fin - p_debut > 1095 then
        perform public.erreur_metier('INVALID_PERIOD', 'Une période de trois ans au plus.');
      end if;
      return query select p_debut, p_fin;
    else
      perform public.erreur_metier('INVALID_PERIOD', 'Période inconnue : ' || left(coalesce(p_periode, ''), 30) || '.');
  end case;
end;
$$;

-- Les filtres reçus → les mêmes, vérifiés (une clé vide est absente)
create or replace function public.rapport_filtres(p_filtres jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  k text;
  v text;
  r jsonb := '{}'::jsonb;
begin
  if p_filtres is null or p_filtres = 'null'::jsonb then
    return r;
  end if;
  if jsonb_typeof(p_filtres) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Les filtres forment un objet.');
  end if;
  for k in select jsonb_object_keys(p_filtres) loop
    if k not in ('statut_colis', 'etat_facture') then
      perform public.erreur_metier('INVALID_INPUT', 'Filtre inconnu : ' || left(k, 20) || '.');
    end if;
    if jsonb_typeof(p_filtres -> k) not in ('string', 'null') then
      perform public.erreur_metier('INVALID_INPUT', 'Le filtre « ' || k || ' » est un texte.');
    end if;
    v := nullif(lower(trim(coalesce(p_filtres ->> k, ''))), '');
    continue when v is null;
    if k = 'statut_colis' and v not in ('attente', 'transit', 'disponible', 'livre', 'incident') then
      perform public.erreur_metier('INVALID_INPUT', 'Statut de colis inconnu : ' || left(v, 20) || '.');
    elsif k = 'etat_facture' and v not in ('payee', 'impayee', 'annulee', 'supprimee') then
      perform public.erreur_metier('INVALID_INPUT', 'État de facture inconnu : ' || left(v, 20) || '.');
    end if;
    r := r || jsonb_build_object(k, v);
  end loop;
  return r;
end;
$$;

-- Un groupe de statuts (filtre « Statut du colis ») → les statuts de la base.
-- Un colis n'a pas de statut « annulé » : il se supprime, et le journal le note.
create or replace function public.rapport_statuts(p_groupe text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_groupe
           when 'attente' then array['recu', 'emballe']
           when 'transit' then array['embarque', 'distribution', 'succursale']
           when 'disponible' then array['disponible']
           when 'livre' then array['livre']
           when 'incident' then array['incident']
         end
$$;

-- Les parties d'un rapport : celles reçues (vérifiées, dans l'ordre du rapport), ou
-- celles de son type.
create or replace function public.rapport_sections(p_sections jsonb, p_type text)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_toutes text[] := array['finances', 'colis', 'evenements', 'factures', 'paiements', 'clients', 'activite'];
  v_recues text[];
  s text;
begin
  if p_sections is null or p_sections = 'null'::jsonb or p_sections = '[]'::jsonb then
    return case p_type
             when 'complet' then v_toutes
             when 'colis' then array['colis', 'evenements']
             when 'factures' then array['finances', 'factures']
             when 'paiements' then array['finances', 'paiements']
             when 'clients' then array['clients']
             when 'evenements' then array['evenements']
             when 'activite' then array['activite']
             else v_toutes
           end;
  end if;
  if jsonb_typeof(p_sections) <> 'array' then
    perform public.erreur_metier('INVALID_INPUT', 'Les données à inclure forment une liste.');
  end if;
  select array_agg(distinct x) into v_recues from jsonb_array_elements_text(p_sections) x;
  foreach s in array v_recues loop
    if not (s = any (v_toutes)) then
      perform public.erreur_metier('INVALID_INPUT', 'Donnée inconnue : ' || left(s, 20) || '.');
    end if;
  end loop;
  return array(select t from unnest(v_toutes) with ordinality u(t, n) where t = any (v_recues) order by n);
end;
$$;

-- Le nom d'un compte, pour « créé par » et « utilisateur » : son nom, sinon son
-- adresse. Vide pour le SQL Editor (aucun compte).
create or replace function public.nom_compte(p_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce((select coalesce(nullif(c.nom_complet, ''), c.email) from public.clients c where c.id = p_id), '')
$$;

-- Ce que le journal garde d'un rapport
create or replace function public.resume_rapport(r public.rapports)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('nom', r.nom, 'type', r.type, 'periode', r.periode, 'debut', r.debut, 'fin', r.fin,
                            'filtres', r.filtres, 'sections', to_jsonb(r.sections),
                            'cree_par', r.cree_par, 'role_createur', r.role_createur, 'cree_le', r.cree_le)
$$;

-- Un rapport tel que la page le lit. Statut : « en_cours » tant que sa période
-- n'est pas finie (ses chiffres peuvent encore bouger), « clos » ensuite.
create or replace function public.rapport_json(r public.rapports)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'nom', r.nom, 'type', r.type, 'periode', r.periode, 'debut', r.debut, 'fin', r.fin,
    'filtres', r.filtres, 'sections', to_jsonb(r.sections),
    'cree_par', r.cree_par, 'cree_par_nom', public.nom_compte(r.cree_par), 'role_createur', r.role_createur,
    'cree_le', r.cree_le, 'modifie_le', r.modifie_le, 'modifie_par_nom', nullif(public.nom_compte(r.modifie_par), ''),
    'statut', case when r.fin >= public.aujourdhui() then 'en_cours' else 'clos' end)
$$;

-- Un entier facultatif d'un objet reçu, borné
create or replace function public.entier_json(p jsonb, p_cle text, p_defaut integer, p_min integer, p_max integer)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p -> p_cle is null or p -> p_cle = 'null'::jsonb then
    return p_defaut;
  end if;
  if jsonb_typeof(p -> p_cle) <> 'number' or (p ->> p_cle) !~ '^\d+$' then
    perform public.erreur_metier('INVALID_INPUT', '« ' || p_cle || ' » est un nombre entier.');
  end if;
  return least(greatest((p ->> p_cle)::integer, p_min), p_max);
end;
$$;


-- 4. Le journal des rapports ----------------------------------------------------------
-- Même journal que les colis, les clients et les factures : qui a créé, modifié ou
-- supprimé quel rapport, avec l'avant et l'après. Une suppression y garde tout le
-- rapport.
create or replace function public.journaliser_rapport()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb;
begin
  if tg_op = 'INSERT' then
    perform public.auditer('rapport.creation', 'rapport', new.id::text, null, public.resume_rapport(new));
  elsif tg_op = 'UPDATE' then
    d := public.difference(public.resume_rapport(old), public.resume_rapport(new));
    if d -> 'apres' = '{}'::jsonb then
      return null;
    end if;
    perform public.auditer('rapport.modification', 'rapport', new.id::text, d -> 'avant', d -> 'apres');
  else
    perform public.auditer('rapport.suppression', 'rapport', old.id::text, public.resume_rapport(old), null);
  end if;
  return null;
end;
$$;

drop trigger if exists journaliser_rapport on public.rapports;
create trigger journaliser_rapport
  after insert or update or delete on public.rapports
  for each row execute function public.journaliser_rapport();


-- 5. Les rapports : créer, modifier, supprimer, lister ---------------------------------

-- Ce que la page envoie → une ligne prête (nom, type, période, filtres, parties)
create or replace function public.rapport_valider(p jsonb)
returns public.rapports
language plpgsql
stable
set search_path = ''
as $$
declare
  r public.rapports;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Rapport illisible.');
  end if;
  r.nom := trim(coalesce(p ->> 'nom', ''));
  if length(r.nom) = 0 or length(r.nom) > 120 then
    perform public.erreur_metier('INVALID_INPUT', 'Donnez un nom au rapport (120 caractères au plus).');
  end if;
  r.type := coalesce(nullif(p ->> 'type', ''), 'complet');
  if r.type not in ('complet', 'colis', 'factures', 'paiements', 'clients', 'evenements', 'activite') then
    perform public.erreur_metier('INVALID_INPUT', 'Type de rapport inconnu : ' || left(r.type, 20) || '.');
  end if;
  r.periode := coalesce(p ->> 'periode', '');
  select b.debut, b.fin into r.debut, r.fin
  from public.rapport_bornes(r.periode, public.rapport_date(p ->> 'debut'), public.rapport_date(p ->> 'fin')) b;
  r.filtres := public.rapport_filtres(p -> 'filtres');
  r.sections := public.rapport_sections(p -> 'sections', r.type);
  return r;
end;
$$;

create or replace function public.creer_rapport(p_rapport jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.rapports;
begin
  perform public.exiger_permission('reports.create');
  v := public.rapport_valider(p_rapport);
  insert into public.rapports (nom, type, periode, debut, fin, filtres, sections, cree_par, role_createur)
  values (v.nom, v.type, v.periode, v.debut, v.fin, v.filtres, v.sections, auth.uid(),
          coalesce((select c.role from public.clients c where c.id = auth.uid()), ''))
  returning * into v;
  return public.rapport_json(v);
end;
$$;

create or replace function public.modifier_rapport(p_id uuid, p_rapport jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.rapports;
begin
  perform public.exiger_permission('reports.edit');
  v := public.rapport_valider(p_rapport);
  update public.rapports r
     set nom = v.nom, type = v.type, periode = v.periode, debut = v.debut, fin = v.fin,
         filtres = v.filtres, sections = v.sections, modifie_le = now(), modifie_par = auth.uid()
   where r.id = p_id
  returning * into v;
  if v.id is null then
    perform public.erreur_metier('NOT_FOUND', 'Ce rapport n''existe plus.');
  end if;
  return public.rapport_json(v);
end;
$$;

-- Supprime le rapport enregistré, et rien d'autre : aucune table ne dépend de
-- « rapports ». Le journal garde le rapport supprimé.
create or replace function public.supprimer_rapport(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform public.exiger_permission('reports.delete');
  delete from public.rapports where id = p_id returning id into v_id;
  if v_id is null then
    perform public.erreur_metier('NOT_FOUND', 'Ce rapport n''existe plus.');
  end if;
  return jsonb_build_object('id', v_id, 'supprime', true);
end;
$$;

-- Les rapports enregistrés, les plus récents d'abord (recherche sur le nom)
create or replace function public.liste_rapports(p_recherche text default null, p_limite integer default 50,
                                                 p_decalage integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_texte text := nullif(lower(trim(coalesce(p_recherche, ''))), '');
begin
  perform public.exiger_permission('reports.view');
  return jsonb_build_object(
    'total', (select count(*) from public.rapports r
              where v_texte is null or strpos(lower(r.nom), v_texte) > 0),
    'lignes', coalesce((
      select jsonb_agg(public.rapport_json(x) order by x.cree_le desc, x.id)
      from (select * from public.rapports r
            where v_texte is null or strpos(lower(r.nom), v_texte) > 0
            order by r.cree_le desc, r.id
            limit least(greatest(coalesce(p_limite, 50), 1), 200)
            offset greatest(coalesce(p_decalage, 0), 0)) x), '[]'::jsonb));
end;
$$;


-- 6. Les données d'un rapport -----------------------------------------------------------
-- Reçoit la définition (celle d'un rapport enregistré, ou celle des filtres de la
-- page) : { periode, debut, fin, filtres, sections, limite, decalage, section }.
-- Rend la période, les statistiques (toujours calculées par la base, jamais en
-- additionnant des lignes dans la page) et, pour chaque partie, son total et une
-- page de lignes (limite : 50 par défaut, 2 000 au plus). « section » ne demande
-- qu'une page de plus d'une seule partie, sans les statistiques.
--
-- Définitions (celles d'Analytics, analytics_mesures) :
--   colis       reçus à Miami pendant la période (recu_le), leur statut actuel ;
--               supprimés : colis.suppression du journal pendant la période
--   évènements  étapes des colis écrites pendant la période (colis_historique),
--               corrections comprises, marquées
--   factures    émises pendant la période ; « payée » / « impayée » selon l'état
--               de paiement d'aujourd'hui ; annulées à part, jamais dans le
--               facturé ; supprimées : facture.suppression du journal pendant la
--               période (le numéro et le montant qu'elle avait), jamais actives
--   paiements   reçus pendant la période (paye_le), annulés compris et marqués ;
--               encaissé : les seuls valides
--   clients     ceux qui se sont inscrits, ont reçu un colis, une facture ou payé
--               pendant la période
--   activité    journal d'audit de la période, ce que le compte peut voir
create or replace function public.rapport_donnees(p_parametres jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p jsonb := coalesce(p_parametres, '{}'::jsonb);
  v_d1 date;
  v_d2 date;
  t1 timestamptz;
  t2 timestamptz;
  v_filtres jsonb;
  v_statuts text[];
  v_etat text;
  v_sections text[];
  v_seule text;
  v_limite integer;
  v_decalage integer;
  -- Ce que le compte peut lire dans le journal
  v_tout boolean := public.peut('audit_logs.view');
  v_j_colis boolean := v_tout or public.peut('shipments.view_history');
  v_j_factures boolean := v_tout or public.peut('invoices.view');
  v_j_paiements boolean := v_tout or public.peut('payments.view');
  v_j_clients boolean := v_tout or public.peut('clients.view');
  v_j_roles boolean := v_tout or public.peut('users.view');
  r jsonb;
  s jsonb := '{}'::jsonb;
begin
  perform public.exiger_permission('reports.view');
  if jsonb_typeof(p) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Paramètres du rapport illisibles.');
  end if;
  select b.debut, b.fin into v_d1, v_d2
  from public.rapport_bornes(coalesce(p ->> 'periode', 'personnalise'), public.rapport_date(p ->> 'debut'),
                             public.rapport_date(p ->> 'fin')) b;
  t1 := v_d1::timestamp at time zone 'America/Santo_Domingo';
  t2 := (v_d2 + 1)::timestamp at time zone 'America/Santo_Domingo';
  v_filtres := public.rapport_filtres(p -> 'filtres');
  v_statuts := public.rapport_statuts(v_filtres ->> 'statut_colis');
  v_etat := v_filtres ->> 'etat_facture';
  v_sections := public.rapport_sections(p -> 'sections', coalesce(nullif(p ->> 'type', ''), 'complet'));
  v_limite := public.entier_json(p, 'limite', 50, 1, 2000);
  v_decalage := public.entier_json(p, 'decalage', 0, 0, 1000000);
  v_seule := nullif(p ->> 'section', '');
  if v_seule is not null and not (v_seule = any (v_sections)) then
    perform public.erreur_metier('INVALID_INPUT', 'Cette donnée n''est pas dans le rapport : ' || left(v_seule, 20) || '.');
  end if;

  r := jsonb_build_object(
    'periode', jsonb_build_object('debut', v_d1, 'fin', v_d2, 'jours', v_d2 - v_d1 + 1,
                                  'fuseau', 'America/Santo_Domingo',
                                  'en_cours', v_d2 >= public.aujourdhui()),
    'filtres', v_filtres,
    'sections', to_jsonb(v_sections),
    'genere_le', now(),
    'genere_par', public.nom_compte(auth.uid()),
    'limite', v_limite,
    'decalage', v_decalage);

  -- Les statistiques ------------------------------------------------------------
  if v_seule is null then
    r := r || jsonb_build_object('statistiques', jsonb_build_object(
      'colis', (
        select jsonb_build_object(
          'total', count(*),
          'attente', count(*) filter (where c.statut in ('recu', 'emballe')),
          'transit', count(*) filter (where c.statut in ('embarque', 'distribution', 'succursale')),
          'disponible', count(*) filter (where c.statut = 'disponible'),
          'livre', count(*) filter (where c.statut = 'livre'),
          'incident', count(*) filter (where c.statut = 'incident'),
          'poids', coalesce(sum(c.poids_lb), 0),
          'valeur', coalesce(sum(c.prix_usd), 0),
          'supprimes', (select count(*) from public.journal_audit j
                        where j.action = 'colis.suppression' and j.cree_le >= t1 and j.cree_le < t2
                          and (v_statuts is null or (j.avant ->> 'statut') = any (v_statuts))))
        from public.colis c
        where c.recu_le >= t1 and c.recu_le < t2 and (v_statuts is null or c.statut = any (v_statuts))),
      'evenements', (
        select jsonb_build_object(
          'total', count(*),
          'corrections', count(*) filter (where h.type_evenement = 'CORRECTION'),
          'livraisons', count(*) filter (where h.statut = 'livre' and h.statut_precedent is distinct from 'livre'))
        from public.colis_historique h join public.colis c on c.id = h.colis_id
        where h.cree_le >= t1 and h.cree_le < t2 and (v_statuts is null or c.statut = any (v_statuts))),
      'factures', (
        with f as (
          select f.statut, f.montant_usd, f.remplacee_par, public.etat_paiement(f) as etat,
                 public.paye_usd(f) as paye, public.solde_usd(f) as solde
          from public.factures f
          where f.cree_le >= t1 and f.cree_le < t2
        ), g as (
          select * from f
          where v_etat is null
             or (v_etat = 'payee' and f.etat = 'payee')
             or (v_etat = 'impayee' and f.etat in ('a_payer', 'partielle', 'en_retard'))
             or (v_etat = 'annulee' and f.statut = 'annulee')
        ), sup as (
          select count(*) as n, coalesce(sum(nullif(j.avant ->> 'montant_usd', '')::numeric), 0) as montant
          from public.journal_audit j
          where j.action = 'facture.suppression' and j.cree_le >= t1 and j.cree_le < t2
            and (v_etat is null or v_etat = 'supprimee')
        )
        select jsonb_build_object(
          'total', count(*),
          'payees', count(*) filter (where g.etat = 'payee'),
          'impayees', count(*) filter (where g.etat in ('a_payer', 'partielle', 'en_retard')),
          'partielles', count(*) filter (where g.etat = 'partielle'),
          'en_retard', count(*) filter (where g.etat = 'en_retard'),
          'annulees', count(*) filter (where g.statut = 'annulee'),
          'regroupees', count(*) filter (where g.statut = 'annulee' and g.remplacee_par is not null),
          'supprimees', (select n from sup),
          'montant_facture', coalesce(sum(g.montant_usd) filter (where g.statut <> 'annulee'), 0),
          'montant_paye', coalesce(sum(g.paye) filter (where g.statut <> 'annulee'), 0),
          'montant_impaye', coalesce(sum(g.solde) filter (where g.statut <> 'annulee'), 0),
          'montant_annule', coalesce(sum(g.montant_usd) filter (where g.statut = 'annulee'), 0),
          'montant_supprime', (select montant from sup))
        from g),
      'paiements', (
        select jsonb_build_object(
          'nombre', count(*) filter (where pa.annule_le is null),
          'encaisse', coalesce(sum(pa.montant_usd) filter (where pa.annule_le is null), 0),
          'annules', count(*) filter (where pa.annule_le is not null),
          'montant_annule', coalesce(sum(pa.montant_usd) filter (where pa.annule_le is not null), 0),
          'par_moyen', coalesce((
            select jsonb_agg(jsonb_build_object('moyen', m.moyen, 'nombre', m.n, 'montant', m.montant)
                             order by m.montant desc, m.moyen)
            from (select x.moyen, count(*) as n, sum(x.montant_usd) as montant
                  from public.paiements x
                  where x.annule_le is null and x.paye_le >= t1 and x.paye_le < t2
                  group by x.moyen) m), '[]'::jsonb),
          -- Ce qui restait dû à la fin de la période (ou maintenant, si elle n'est pas finie)
          'creances_fin', public.creances_au(least(t2, now())))
        from public.paiements pa
        where pa.paye_le >= t1 and pa.paye_le < t2),
      'clients', jsonb_build_object(
        'nouveaux', (select count(*) from public.clients c
                     where c.role = 'client' and c.cree_le >= t1 and c.cree_le < t2),
        'actifs', (select count(*) from public.clients c
                   where c.role = 'client'
                     and (exists (select 1 from public.colis x where x.client_id = c.id
                                    and x.recu_le >= t1 and x.recu_le < t2)
                          or exists (select 1 from public.factures x where x.client_id = c.id
                                       and x.cree_le >= t1 and x.cree_le < t2)
                          or exists (select 1 from public.paiements x where x.client_id = c.id
                                       and x.paye_le >= t1 and x.paye_le < t2)))),
      'activite', (
        select jsonb_build_object(
          'total', count(*),
          'suppressions', count(*) filter (where j.action like '%.suppression'),
          'par_entite', coalesce((select jsonb_object_agg(e.entite, e.n)
                                  from (select j2.entite, count(*) as n from public.journal_audit j2
                                        where j2.cree_le >= t1 and j2.cree_le < t2
                                          and (v_tout
                                               or (j2.entite = 'colis' and v_j_colis)
                                               or (j2.entite = 'facture' and v_j_factures)
                                               or (j2.entite = 'paiement' and v_j_paiements)
                                               or (j2.entite = 'client' and v_j_roles
                                                   and j2.action in ('client.role', 'utilisateur.role'))
                                               or (j2.entite = 'client' and v_j_clients
                                                   and j2.action not in ('client.role', 'utilisateur.role'))
                                               or j2.entite = 'rapport')
                                        group by j2.entite) e), '{}'::jsonb))
        from public.journal_audit j
        where j.cree_le >= t1 and j.cree_le < t2
          and (v_tout
               or (j.entite = 'colis' and v_j_colis)
               or (j.entite = 'facture' and v_j_factures)
               or (j.entite = 'paiement' and v_j_paiements)
               or (j.entite = 'client' and v_j_roles and j.action in ('client.role', 'utilisateur.role'))
               or (j.entite = 'client' and v_j_clients and j.action not in ('client.role', 'utilisateur.role'))
               or j.entite = 'rapport'))));
  end if;

  -- Les colis -------------------------------------------------------------------------
  if 'colis' = any (v_sections) and (v_seule is null or v_seule = 'colis') then
    s := s || jsonb_build_object('colis', jsonb_build_object(
      'total', (select count(*) from public.colis c
                where c.recu_le >= t1 and c.recu_le < t2 and (v_statuts is null or c.statut = any (v_statuts))),
      'lignes', coalesce((
        select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
        from (select row_number() over (order by c.recu_le, c.numero) as ordre,
                     c.id, c.numero, c.recu_le, cl.code as client_code, cl.nom_complet as client_nom,
                     c.expediteur, c.description, c.poids_lb, c.prix_usd, c.service, c.pays_destination,
                     c.destination, c.statut,
                     (select max(h.cree_le) from public.colis_historique h
                      where h.colis_id = c.id and h.statut = 'livre' and h.statut_precedent is distinct from 'livre'
                        and not exists (select 1 from public.colis_historique k where k.corrige_id = h.id)) as livre_le,
                     (select nullif(public.nom_compte(j.auteur_id), '') from public.journal_audit j
                      where j.entite = 'colis' and j.entite_id = c.id::text and j.action = 'colis.creation'
                      order by j.cree_le limit 1) as cree_par
              from public.colis c left join public.clients cl on cl.id = c.client_id
              where c.recu_le >= t1 and c.recu_le < t2 and (v_statuts is null or c.statut = any (v_statuts))
              order by c.recu_le, c.numero
              limit v_limite offset v_decalage) x), '[]'::jsonb)));
  end if;

  -- Les étapes des colis (événements) ---------------------------------------------------
  if 'evenements' = any (v_sections) and (v_seule is null or v_seule = 'evenements') then
    s := s || jsonb_build_object('evenements', jsonb_build_object(
      'total', (select count(*) from public.colis_historique h join public.colis c on c.id = h.colis_id
                where h.cree_le >= t1 and h.cree_le < t2 and (v_statuts is null or c.statut = any (v_statuts))),
      'lignes', coalesce((
        select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
        from (select row_number() over (order by h.cree_le, h.id) as ordre,
                     h.id, h.cree_le, c.numero, h.type_evenement, h.statut_precedent, h.statut, h.lieu, h.note,
                     nullif(public.nom_compte(h.auteur_id), '') as auteur, h.auteur_role, h.visibilite,
                     h.corrige_id, coalesce(h.metadonnees ->> 'source', '') as source,
                     exists (select 1 from public.colis_historique k where k.corrige_id = h.id) as annule
              from public.colis_historique h join public.colis c on c.id = h.colis_id
              where h.cree_le >= t1 and h.cree_le < t2 and (v_statuts is null or c.statut = any (v_statuts))
              order by h.cree_le, h.id
              limit v_limite offset v_decalage) x), '[]'::jsonb)));
  end if;

  -- Les factures (et celles supprimées pendant la période) --------------------------------
  if 'factures' = any (v_sections) and (v_seule is null or v_seule = 'factures') then
    s := s || jsonb_build_object('factures', (
      with f as (
        select f.*, public.etat_paiement(f) as etat, public.paye_usd(f) as paye, public.solde_usd(f) as solde
        from public.factures f
        where f.cree_le >= t1 and f.cree_le < t2
      ), g as (
        select * from f
        where v_etat is null
           or (v_etat = 'payee' and f.etat = 'payee')
           or (v_etat = 'impayee' and f.etat in ('a_payer', 'partielle', 'en_retard'))
           or (v_etat = 'annulee' and f.statut = 'annulee')
      )
      select jsonb_build_object(
        'total', (select count(*) from g),
        'lignes', coalesce((
          select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
          from (select row_number() over (order by g.cree_le, g.numero) as ordre,
                       g.id, g.numero, g.cree_le, cl.code as client_code, cl.nom_complet as client_nom,
                       g.montant_usd, g.frais_service_usd, g.paye, g.solde, g.etat, g.statut, g.moyen,
                       g.echeance_le, g.annulee_le, g.motif_annulation,
                       (select n.numero from public.factures n where n.id = g.remplacee_par) as remplacee_par,
                       (select nullif(public.nom_compte(j.auteur_id), '') from public.journal_audit j
                        where j.entite = 'facture' and j.entite_id = g.id::text and j.action = 'facture.creation'
                        order by j.cree_le limit 1) as cree_par
                from g left join public.clients cl on cl.id = g.client_id
                order by g.cree_le, g.numero
                limit v_limite offset v_decalage) x), '[]'::jsonb),
        'supprimees', jsonb_build_object(
          'total', (select count(*) from public.journal_audit j
                    where j.action = 'facture.suppression' and j.cree_le >= t1 and j.cree_le < t2
                      and (v_etat is null or v_etat = 'supprimee')),
          'lignes', coalesce((
            select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
            from (select row_number() over (order by j.cree_le, j.id) as ordre,
                         j.cree_le as supprimee_le, j.avant ->> 'numero' as numero,
                         nullif(j.avant ->> 'montant_usd', '')::numeric as montant_usd,
                         j.avant ->> 'statut' as statut, nullif(public.nom_compte(j.auteur_id), '') as auteur
                  from public.journal_audit j
                  where j.action = 'facture.suppression' and j.cree_le >= t1 and j.cree_le < t2
                    and (v_etat is null or v_etat = 'supprimee')
                  order by j.cree_le, j.id
                  limit v_limite) x), '[]'::jsonb)))
    ));
  end if;

  -- Les paiements ------------------------------------------------------------------------
  if 'paiements' = any (v_sections) and (v_seule is null or v_seule = 'paiements') then
    s := s || jsonb_build_object('paiements', jsonb_build_object(
      'total', (select count(*) from public.paiements pa where pa.paye_le >= t1 and pa.paye_le < t2),
      'lignes', coalesce((
        select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
        from (select row_number() over (order by pa.paye_le, pa.id) as ordre,
                     pa.id, pa.paye_le, pa.facture_id, f.numero as facture_numero, cl.code as client_code,
                     cl.nom_complet as client_nom, pa.montant_usd, pa.moyen, pa.reference, pa.origine,
                     pa.annule_le, pa.motif_annulation, nullif(public.nom_compte(pa.cree_par), '') as saisi_par
              from public.paiements pa
              left join public.factures f on f.id = pa.facture_id
              left join public.clients cl on cl.id = pa.client_id
              where pa.paye_le >= t1 and pa.paye_le < t2
              order by pa.paye_le, pa.id
              limit v_limite offset v_decalage) x), '[]'::jsonb)));
  end if;

  -- Les clients ---------------------------------------------------------------------------
  if 'clients' = any (v_sections) and (v_seule is null or v_seule = 'clients') then
    s := s || jsonb_build_object('clients', (
      with c as (
        select c.*,
               (select count(*) from public.colis x where x.client_id = c.id
                  and x.recu_le >= t1 and x.recu_le < t2) as colis,
               (select coalesce(sum(x.montant_usd), 0) from public.factures x where x.client_id = c.id
                  and x.statut <> 'annulee' and x.cree_le >= t1 and x.cree_le < t2) as facture,
               (select coalesce(sum(x.montant_usd), 0) from public.paiements x where x.client_id = c.id
                  and x.annule_le is null and x.paye_le >= t1 and x.paye_le < t2) as paye
        from public.clients c
        where c.role = 'client'
          and ((c.cree_le >= t1 and c.cree_le < t2)
               or exists (select 1 from public.colis x where x.client_id = c.id and x.recu_le >= t1 and x.recu_le < t2)
               or exists (select 1 from public.factures x where x.client_id = c.id and x.cree_le >= t1 and x.cree_le < t2)
               or exists (select 1 from public.paiements x where x.client_id = c.id and x.paye_le >= t1 and x.paye_le < t2))
      )
      select jsonb_build_object(
        'total', (select count(*) from c),
        'lignes', coalesce((
          select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
          from (select row_number() over (order by lower(c.nom_complet), c.code) as ordre,
                       c.id, c.code, c.nom_complet as nom, c.pays, c.ville, c.cree_le,
                       (c.cree_le >= t1 and c.cree_le < t2) as nouveau, c.colis, c.facture, c.paye,
                       (select coalesce(sum(public.solde_usd(f)), 0) from public.factures f
                        where f.client_id = c.id) as solde
                from c
                order by lower(c.nom_complet), c.code
                limit v_limite offset v_decalage) x), '[]'::jsonb))));
  end if;

  -- L'activité (journal d'audit) -------------------------------------------------------------
  if 'activite' = any (v_sections) and (v_seule is null or v_seule = 'activite') then
    s := s || jsonb_build_object('activite', (
      with j as (
        select j.* from public.journal_audit j
        where j.cree_le >= t1 and j.cree_le < t2
          and (v_tout
               or (j.entite = 'colis' and v_j_colis)
               or (j.entite = 'facture' and v_j_factures)
               or (j.entite = 'paiement' and v_j_paiements)
               or (j.entite = 'client' and v_j_roles and j.action in ('client.role', 'utilisateur.role'))
               or (j.entite = 'client' and v_j_clients and j.action not in ('client.role', 'utilisateur.role'))
               or j.entite = 'rapport')
      )
      select jsonb_build_object(
        'total', (select count(*) from j),
        'lignes', coalesce((
          select jsonb_agg(to_jsonb(x) - 'ordre' order by x.ordre)
          from (select row_number() over (order by j.cree_le, j.id) as ordre,
                       j.id, j.cree_le, nullif(public.nom_compte(j.auteur_id), '') as auteur,
                       (select c.role from public.clients c where c.id = j.auteur_id) as auteur_role,
                       j.action, j.entite, j.entite_id,
                       coalesce(
                         case j.entite
                           when 'colis' then coalesce(j.apres ->> 'numero', j.avant ->> 'numero',
                                                      (select c.numero from public.colis c where c.id::text = j.entite_id))
                           when 'facture' then coalesce(j.apres ->> 'numero', j.avant ->> 'numero',
                                                        (select f.numero from public.factures f where f.id::text = j.entite_id))
                           when 'paiement' then (select f.numero from public.paiements pa
                                                 join public.factures f on f.id = pa.facture_id
                                                 where pa.id::text = j.entite_id)
                           when 'client' then coalesce((select c.code from public.clients c where c.id::text = j.entite_id),
                                                       j.avant ->> 'code', j.apres ->> 'code')
                           when 'rapport' then coalesce(j.apres ->> 'nom', j.avant ->> 'nom',
                                                        (select r.nom from public.rapports r where r.id::text = j.entite_id))
                         end, '') as reference,
                       j.avant, j.apres
                from j
                order by j.cree_le, j.id
                limit v_limite offset v_decalage) x), '[]'::jsonb))));
  end if;

  return r || jsonb_build_object('donnees', s);
end;
$$;


-- 7. Droits et contrôle ----------------------------------------------------------------
-- Les aides ne s'appellent pas seules ; les cinq fonctions des pages vérifient
-- chacune leur permission.
revoke execute on function public.rapport_date(text) from public, anon, authenticated;
revoke execute on function public.rapport_bornes(text, date, date) from public, anon, authenticated;
revoke execute on function public.rapport_filtres(jsonb) from public, anon, authenticated;
revoke execute on function public.rapport_statuts(text) from public, anon, authenticated;
revoke execute on function public.rapport_sections(jsonb, text) from public, anon, authenticated;
revoke execute on function public.nom_compte(uuid) from public, anon, authenticated;
revoke execute on function public.resume_rapport(public.rapports) from public, anon, authenticated;
revoke execute on function public.rapport_json(public.rapports) from public, anon, authenticated;
revoke execute on function public.entier_json(jsonb, text, integer, integer, integer) from public, anon, authenticated;
revoke execute on function public.rapport_valider(jsonb) from public, anon, authenticated;
revoke execute on function public.journaliser_rapport() from public, anon, authenticated;

revoke execute on function public.creer_rapport(jsonb) from public, anon;
revoke execute on function public.modifier_rapport(uuid, jsonb) from public, anon;
revoke execute on function public.supprimer_rapport(uuid) from public, anon;
revoke execute on function public.liste_rapports(text, integer, integer) from public, anon;
revoke execute on function public.rapport_donnees(jsonb) from public, anon;
grant execute on function public.creer_rapport(jsonb) to authenticated;
grant execute on function public.modifier_rapport(uuid, jsonb) to authenticated;
grant execute on function public.supprimer_rapport(uuid) to authenticated;
grant execute on function public.liste_rapports(text, integer, integer) to authenticated;
grant execute on function public.rapport_donnees(jsonb) to authenticated;


-- Contrôle : rapports_sur_5 = 5 ; ouvertes_aux_visiteurs = 0 ; table_fermee = true
-- (ni lecture ni écriture directe pour les comptes du site) ; journal = true.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('creer_rapport', 'modifier_rapport', 'supprimer_rapport', 'liste_rapports',
                            'rapport_donnees'))                                                   as rapports_sur_5,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and (p.proname like '%rapport%')
          and has_function_privilege('anon', p.oid, 'execute'))                                  as ouvertes_aux_visiteurs,
       (not has_table_privilege('authenticated', 'public.rapports', 'select')
        and not has_table_privilege('authenticated', 'public.rapports', 'insert')
        and not has_table_privilege('anon', 'public.rapports', 'select'))                        as table_fermee,
       (select count(*) = 1 from pg_trigger where tgname = 'journaliser_rapport')                as journal;
