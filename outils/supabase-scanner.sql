-- =============================================================================
-- Goship Express — le scanner (Phase 4, 26/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce
-- fichier n'ajoute que deux fonctions de lecture et d'orchestration, ne
-- touche à aucune table ni à aucune donnée, et peut être relancé autant de
-- fois qu'on veut.
--
-- Ordre d'installation : supabase.sql, supabase-facturation.sql,
-- supabase-services.sql, supabase-evenements.sql, puis ce fichier.
--
-- Le scanner n'est pas un système à part : c'est une porte d'entrée de plus
-- vers le moteur de la Phase 3. Rien ici ne décide d'une transition, ne
-- calcule un statut ni n'écrit un événement : tout passe par
-- executer_operation (supabase-evenements.sql), qui verrouille le colis,
-- valide, écrit l'événement et change le statut dans une seule transaction.
-- Ce fichier ne fait que deux choses pour que le poste de scan aille vite :
--
--   scanner_colis      un code lu → tout ce qu'il faut afficher, en UNE
--                      requête : le colis, son client, son dernier événement,
--                      sa livraison ou son action requise, son historique et
--                      les opérations permises maintenant.
--   scanner_operation  un code lu + une opération → le moteur, puis la fiche
--                      à jour, toujours en une requête.
--
-- La recherche passe par les index uniques du numéro (colis_numero_key) et du
-- suivi vendeur (colis_suivi_unique_idx) : un colis sur cent mille se trouve
-- aussi vite qu'un sur dix.
-- =============================================================================


-- Les opérations proposées au poste de scan. La réception (COLIS_RECU) n'en
-- fait pas partie : un colis naît par le formulaire d'enregistrement, avec
-- son client et son poids, jamais par un scan. La correction et la mise à
-- jour non plus : ce sont des gestes administratifs, faits depuis la fiche du
-- colis, avec leur motif.
create or replace function public.operations_du_scanner()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['COLIS_INSPECTE', 'COLIS_EMBALLE', 'COLIS_CONSOLIDE', 'COLIS_CHARGE', 'COLIS_EXPEDIE',
               'COLIS_ARRIVE', 'COLIS_TRANSFERE', 'COLIS_DISPONIBLE', 'COLIS_LIVRE', 'ACTION_REQUISE',
               'ACTION_RESOLUE']
$$;

-- Ce que le poste de scan affiche d'un colis. Pas d'adresse ni de téléphone :
-- le nom, le code et la ville suffisent à reconnaître un colis. Le prix n'y
-- figure que pour qui a le droit de voir les factures.
create or replace function public.fiche_scanner(p_colis uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.colis;
  cl public.clients;
  v_precedent text;
  v_livraison bigint;
  v_action bigint;
begin
  select * into c from public.colis where id = p_colis;
  if not found then
    return null;
  end if;
  select * into cl from public.clients where id = c.client_id;
  v_precedent := public.statut_precedent(c.id, c.statut);

  -- La livraison et l'action requise en cours : le dernier événement de ce
  -- type qu'aucune correction n'a annulé
  if c.statut = 'livre' then
    select max(h.id) into v_livraison from public.colis_historique h
     where h.colis_id = c.id and h.statut = 'livre' and not public.evenement_corrige(h.id);
  elsif c.statut = 'incident' then
    select max(h.id) into v_action from public.colis_historique h
     where h.colis_id = c.id and h.statut = 'incident' and not public.evenement_corrige(h.id);
  end if;

  return jsonb_build_object(
    'colis', jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'suivi_transporteur', c.suivi_transporteur,
      'description', c.description, 'expediteur', c.expediteur, 'poids_lb', c.poids_lb,
      'service', c.service, 'pays_destination', c.pays_destination, 'destination', c.destination,
      'statut', c.statut, 'lieu', c.lieu, 'note', c.note, 'recu_le', c.recu_le, 'maj_le', c.maj_le,
      'prix_usd', case when public.peut('invoices.view') then c.prix_usd end),
    'client', case when cl.id is null then null else jsonb_build_object(
      'code', cl.code, 'nom_complet', cl.nom_complet, 'ville', cl.ville, 'pays', cl.pays) end,
    'origine', 'Miami (Medley), FL',
    'precedent', v_precedent,
    'dernier_evenement', public.evenement_json((select max(id) from public.colis_historique where colis_id = c.id)),
    'livraison', case when v_livraison is not null then public.evenement_json(v_livraison) end,
    'action_requise', case when v_action is not null then public.evenement_json(v_action) end,
    'operations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'type', k, 'libelle', public.types_evenement() -> k ->> 'libelle',
               'statut', v ->> 'cible', 'change_statut', (v ->> 'cible') is distinct from c.statut,
               'lieu_requis', (public.types_evenement() -> k ->> 'lieu_requis')::boolean)
             order by array_position(public.operations_du_scanner(), k))
      from unnest(public.operations_du_scanner()) k,
           lateral (select public.valider_operation(c.statut, v_precedent, k, null) as v) x
      where v ->> 'code' is null and public.peut(public.types_evenement() -> k ->> 'permission')), '[]'::jsonb),
    'historique', coalesce((select jsonb_agg(public.evenement_json(h.id) order by h.id)
                            from public.colis_historique h where h.colis_id = c.id), '[]'::jsonb));
end;
$$;

-- ShipmentLookup : le code lu (numéro GSE ou suivi du vendeur, déjà extrait
-- d'un lien par la page) → la fiche, ou null si aucun colis ne le porte. Un
-- code introuvable n'est pas une erreur : c'est une réponse, que le poste
-- affiche sans rien écrire (aucun colis, donc aucun événement).
create or replace function public.scanner_colis(p_reference text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(trim(coalesce(p_reference, '')));
  v_id uuid;
begin
  perform public.exiger_permission('shipments.scan');
  if length(v_ref) < 4 or length(v_ref) > 60 then
    perform public.erreur_metier('INVALID_SCAN_FORMAT', 'Code illisible : ' || left(coalesce(p_reference, ''), 60) || '.');
  end if;
  select id into v_id from public.colis where numero = v_ref;
  if v_id is null then
    select id into v_id from public.colis where suivi_transporteur = v_ref and suivi_transporteur <> ''
     order by maj_le desc limit 1;
  end if;
  if v_id is null then
    raise log 'goship scan introuvable compte=%', coalesce(auth.uid()::text, 'aucun');
    return null;
  end if;
  return public.fiche_scanner(v_id);
end;
$$;

-- ScanOperation : le code lu et l'opération choisie → executer_operation →
-- la fiche à jour. Une seule requête pour le mode rapide (scan, scan, scan…).
--
-- p_statut_attendu : le statut que le poste affichait (mode normal). En mode
-- rapide, la page ne connaît pas le statut avant le scan : elle l'omet, et le
-- moteur valide la transition sur le statut réel, verrou posé.
-- p_cle : une clé par scan. Renvoyée après une coupure réseau, elle rend le
-- résultat déjà enregistré au lieu d'écrire un second événement.
--
-- Réponse : { code, message, resultat (celui du moteur), fiche }.
--   code « OK »                       l'événement vient d'être écrit
--   code « ALREADY_IN_TARGET_STATE »  l'opération était déjà faite (double
--                                     scan, deux postes, retry) : rien de neuf
create or replace function public.scanner_operation(p_reference text, p_type text, p_lieu text default null,
                                                    p_note text default null, p_metadonnees jsonb default '{}',
                                                    p_cle text default null, p_statut_attendu text default null,
                                                    p_cible text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text := upper(trim(coalesce(p_type, '')));
  v_ref text := upper(trim(coalesce(p_reference, '')));
  v_id uuid;
  r jsonb;
begin
  perform public.exiger_permission('shipments.scan');
  if not (v_type = any (public.operations_du_scanner())) then
    perform public.erreur_metier('EVENT_TYPE_INVALID',
      'Opération impossible depuis le scanner : ' || coalesce(p_type, '(vide)') || '.');
  end if;
  if length(v_ref) < 4 or length(v_ref) > 60 then
    perform public.erreur_metier('INVALID_SCAN_FORMAT', 'Code illisible : ' || left(coalesce(p_reference, ''), 60) || '.');
  end if;
  select id into v_id from public.colis where numero = v_ref;
  if v_id is null then
    select id into v_id from public.colis where suivi_transporteur = v_ref and suivi_transporteur <> ''
     order by maj_le desc limit 1;
  end if;
  if v_id is null then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis ne porte le numéro ' || v_ref || '.');
  end if;

  r := public.executer_operation(v_id, v_type, p_lieu, p_note,
                                 coalesce(p_metadonnees, '{}'::jsonb) || jsonb_build_object('source', 'scanner'),
                                 p_cle, p_statut_attendu, p_cible, null);

  return jsonb_build_object(
    'code', case when (r ->> 'deja')::boolean then 'ALREADY_IN_TARGET_STATE' else 'OK' end,
    'message', case when (r ->> 'deja')::boolean
                    then 'Déjà fait : ' || (public.types_evenement() -> v_type ->> 'libelle')
                    else public.types_evenement() -> v_type ->> 'libelle' end,
    'resultat', r,
    'fiche', public.fiche_scanner(v_id));
end;
$$;


-- Droits ------------------------------------------------------------------------
revoke execute on function public.fiche_scanner(uuid) from public, anon, authenticated;
revoke execute on function public.operations_du_scanner() from public, anon;
revoke execute on function public.scanner_colis(text) from public, anon;
revoke execute on function public.scanner_operation(text, text, text, text, jsonb, text, text, text) from public, anon;
grant execute on function public.operations_du_scanner() to authenticated;
grant execute on function public.scanner_colis(text) to authenticated;
grant execute on function public.scanner_operation(text, text, text, text, jsonb, text, text, text) to authenticated;


-- Contrôle ---------------------------------------------------------------------
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('operations_du_scanner', 'fiche_scanner', 'scanner_colis', 'scanner_operation'))
                                                                                            as scanner_sur_4,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'executer_operation')                    as moteur_present;
