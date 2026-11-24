-- CANDIDATE LOCALE — adaptateurs de réponses et retours transactionnels.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Réutilise notification_envois, le sender historique, P-07 et les tables P-08.
-- Aucun canal n'est activé et aucune fonction Edge/provider n'est appelée ici.

begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.notification_envois') is null
     or pg_catalog.to_regclass('public.communication_evenements_fournisseur') is null
     or pg_catalog.to_regclass('public.communication_evenements_traitement') is null
     or pg_catalog.to_regprocedure('public.communication_autoriser_sortie(text,text)') is null
     or pg_catalog.to_regprocedure('public.lire_reglage(text)') is null
     or pg_catalog.to_regprocedure('extensions.hmac(text,text,text)') is null then
    raise exception 'COMMUNICATION_CHANNEL_ADAPTER_DEPENDENCY_MISSING';
  end if;
end
$garde$;

-- Les réponses du fournisseur sont réduites à une classification et à un identifiant
-- technique. Aucun message d'erreur libre n'est conservé ni retourné.
create or replace function public.communication_normaliser_reponse_canal(
  p_canal text, p_code_http integer, p_contenu text, p_erreur text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $fonction$
declare
  v_json jsonb;
  v_ticket jsonb;
  v_id text;
  v_code text;
  v_code_fournisseur text;
  v_classe text := 'incertain';
begin
  if p_canal is null or p_canal not in ('push', 'email', 'whatsapp') then
    return jsonb_build_object('classe', 'definitif', 'code', 'CANAL_INVALIDE');
  end if;
  if p_erreur is not null or p_code_http is null then
    return jsonb_build_object('classe', 'incertain', 'code', 'RESULTAT_INCERTAIN');
  end if;

  begin
    v_json := p_contenu::jsonb;
  exception when others then
    v_json := null;
  end;

  if p_code_http = 429 then
    return jsonb_build_object('classe', 'temporaire', 'code', 'LIMITE_DEBIT');
  elsif p_code_http in (408, 425) or p_code_http >= 500 then
    -- Après un délai ou une panne, le fournisseur peut avoir accepté le message.
    return jsonb_build_object('classe', 'incertain', 'code', 'RESULTAT_INCERTAIN');
  elsif p_code_http between 200 and 299 then
    if p_canal = 'push' then
      v_ticket := coalesce(v_json -> 'data' -> 0, v_json -> 'data');
      if v_ticket ->> 'status' = 'ok' then
        v_id := v_ticket ->> 'id';
      elsif v_ticket ->> 'status' = 'error' then
        v_code_fournisseur := v_ticket -> 'details' ->> 'error';
        if v_code_fournisseur = 'MessageRateExceeded' then
          return jsonb_build_object('classe', 'temporaire', 'code', 'LIMITE_DEBIT');
        elsif v_code_fournisseur = 'DeviceNotRegistered' then
          -- Code officiel conservé : la supervision de supabase-notifications.sql
          -- compte les « DeviceNotRegistered » des dernières 24 h, et
          -- lire_reponse_envoi oublie l'appareil (correction du 23/11/2026).
          return jsonb_build_object('classe', 'definitif', 'code', 'DeviceNotRegistered');
        else
          return jsonb_build_object('classe', 'refuse', 'code', 'REFUS_FOURNISSEUR');
        end if;
      end if;
    elsif p_canal = 'whatsapp' then
      v_id := v_json -> 'messages' -> 0 ->> 'id';
      v_code_fournisseur := v_json -> 'error' ->> 'code';
    else
      -- Brevo retourne messageId ; Resend retourne id.
      v_id := coalesce(v_json ->> 'messageId', v_json ->> 'id');
    end if;

    if nullif(btrim(v_id), '') is not null and length(v_id) <= 200 then
      return jsonb_build_object('classe', 'accepte', 'message_id', v_id);
    end if;
    if v_json ? 'error' then
      return jsonb_build_object('classe', 'refuse', 'code', 'REFUS_FOURNISSEUR');
    end if;
    return jsonb_build_object('classe', 'incertain', 'code', 'REPONSE_INCOMPLETE');
  elsif p_code_http between 400 and 499 then
    if p_canal = 'whatsapp' then
      v_code_fournisseur := v_json -> 'error' ->> 'code';
      if v_code_fournisseur in ('4', '17', '80008', '130429', '131056') then
        return jsonb_build_object('classe', 'temporaire', 'code', 'LIMITE_DEBIT');
      end if;
    end if;
    v_code := 'HTTP_' || p_code_http::text;
    v_classe := case when p_code_http in (401, 403, 404, 422) then 'definitif' else 'refuse' end;
    return jsonb_build_object('classe', v_classe, 'code', v_code);
  end if;
  return jsonb_build_object('classe', 'incertain', 'code', 'REPONSE_INCONNUE');
end;
$fonction$;

create or replace function public.communication_adresse_courriel_valide(p_email text)
returns boolean
language sql
immutable
set search_path = ''
as $fonction$
  select coalesce(length(p_email) <= 254
    and p_email ~ '^[^@[:space:]]+@[^@[:space:].]+(\.[^@[:space:].]+)+$', false)
$fonction$;

-- Garde de format sans journaliser l'adresse, puis conservation intégrale de P-07.
create or replace function public.expedier_envoi(p_envoi public.notification_envois)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_email text;
  v_raison text;
begin
  if p_envoi.canal = 'email' then
    select c.email into v_email
      from public.notifications n
      join public.clients c on c.id = n.client_id
     where n.id = p_envoi.notification_id;
    if not found or not public.communication_adresse_courriel_valide(v_email) then
      raise exception 'SANS_DESTINATAIRE';
    end if;
  end if;

  if not public.communication_sortie_autorisee('envoi', p_envoi.canal) then
    v_raison := public.communication_autoriser_sortie('envoi', p_envoi.canal);
  end if;
  if v_raison is not null then
    raise exception 'COMMUNICATION_OUTPUT_BLOCKED'
      using errcode = '55000', detail = v_raison;
  end if;
  if not public.communication_sortie_autorisee('envoi', p_envoi.canal) then
    raise exception 'COMMUNICATION_GATE_REQUIRED' using errcode = '55000';
  end if;
  perform pg_catalog.set_config('goship.sortie_autorisee', '', true);
  perform pg_catalog.set_config('goship.sortie_consommee', pg_catalog.txid_current()::text, true);
  return public.communication_expedier_envoi_sans_porte(p_envoi);
end;
$fonction$;
revoke all on function public.communication_adresse_courriel_valide(text)
  from public, anon, authenticated, service_role;
revoke all on function public.expedier_envoi(public.notification_envois)
  from public, anon, authenticated, service_role;

-- Réception normalisée P-08 : le code Edge doit d'abord authentifier la requête
-- fournisseur (Meta raw-body HMAC, Brevo auth déclarée, Resend Svix), puis signer
-- cette enveloppe avec le secret partagé. Ce RPC n'est ouvert qu'au rôle dédié.
-- Le corps original et les coordonnées du destinataire ne sont jamais persistés.
create or replace function public.communication_recevoir_statut_transactionnel(
  p_fournisseur text, p_charge text, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $fonction$
declare
  v_cle text;
  v_charge jsonb;
  v_type text;
  v_id text;
  v_message_id text;
  v_survenu timestamptz;
  v_code text;
  v_evenement bigint;
begin
  if p_fournisseur is null or p_fournisseur not in ('meta', 'brevo', 'resend')
     or p_charge is null or length(p_charge) > 20000
     or coalesce(p_signature, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false);
  end if;

  begin
    v_charge := p_charge::jsonb;
    v_survenu := nullif(v_charge ->> 'survenu_le', '')::timestamptz;
  exception when others then
    return jsonb_build_object('ok', false, 'format', true);
  end;

  v_type := v_charge ->> 'type';
  v_id := v_charge ->> 'id';
  v_message_id := v_charge ->> 'message_id';
  v_code := v_charge ->> 'code';
  if jsonb_typeof(v_charge) <> 'object'
     or coalesce(v_id, '') !~ '^[A-Za-z0-9:_./-]{1,200}$'
     or coalesce(v_message_id, '') = '' or length(v_message_id) > 200
     or coalesce(v_type, '') not in ('sent', 'delivered', 'read', 'failed', 'hard_bounce', 'blocked')
     or (v_code is not null and v_code !~ '^[A-Za-z0-9_-]{1,60}$') then
    return jsonb_build_object('ok', false, 'format', true);
  end if;
  if (p_fournisseur = 'meta' and v_type not in ('sent', 'delivered', 'read', 'failed'))
     or (p_fournisseur in ('brevo', 'resend') and v_type not in
         ('sent', 'delivered', 'failed', 'hard_bounce', 'blocked')) then
    return jsonb_build_object('ok', false, 'format', true);
  end if;
  if v_survenu is null or v_survenu > now() + interval '5 minutes' then
    return jsonb_build_object('ok', false, 'format', true);
  end if;

  v_cle := public.lire_reglage('communication_cle_webhook');
  if coalesce(v_cle, '') = ''
     or p_signature <> encode(extensions.hmac(p_fournisseur || ':' || p_charge, v_cle, 'sha256'), 'hex') then
    return jsonb_build_object('ok', false);
  end if;

  perform set_config('synchronous_commit', 'on', true);
  insert into public.communication_evenements_fournisseur
    (fournisseur, evenement_id, type, message_id, code, survenu_le)
  values (p_fournisseur, v_id, v_type, left(v_message_id, 200), left(v_code, 60), v_survenu)
  on conflict (fournisseur, evenement_id) do nothing
  returning id into v_evenement;
  if v_evenement is null then
    return jsonb_build_object('ok', true, 'rejeu', true);
  end if;

  insert into public.communication_evenements_traitement
    (evenement_id, etat, priorite, classe)
  values (v_evenement, 'a_traiter', 2, 'autre');
  return jsonb_build_object('ok', true, 'enregistre', true, 'traite', false);
end;
$fonction$;

do $role$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'communication_webhook') then
    create role communication_webhook nologin noinherit;
  end if;
end
$role$;
grant usage on schema public to communication_webhook;
revoke all on function public.communication_recevoir_statut_transactionnel(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.communication_recevoir_statut_transactionnel(text, text, text)
  to communication_webhook;

create index if not exists communication_evenements_message_idx
  on public.communication_evenements_fournisseur (fournisseur, message_id)
  where message_id is not null;

create or replace function public.communication_traiter_evenements_transactionnels(p_limite integer default 50)
returns integer
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  t public.communication_evenements_traitement;
  ev public.communication_evenements_fournisseur;
  e public.notification_envois;
  v_id bigint;
  v_nombre integer := 0;
  v_candidats integer;
  v_resultat text;
begin
  for t in
    select q.*
      from public.communication_evenements_traitement q
      join public.communication_evenements_fournisseur x on x.id = q.evenement_id
     where q.etat = 'a_traiter' and q.prochain_essai_le <= now()
       and x.type in ('sent', 'delivered', 'read', 'failed', 'hard_bounce', 'blocked')
       and exists (
         select 1 from public.notification_envois n
          where n.fournisseur = x.fournisseur and n.message_id = x.message_id
            and ((x.fournisseur = 'meta' and n.canal = 'whatsapp')
              or (x.fournisseur in ('brevo', 'resend') and n.canal = 'email'))
       )
     order by q.priorite, q.evenement_id
     limit least(greatest(coalesce(p_limite, 50), 1), 200)
     for update of q skip locked
  loop
    select * into ev from public.communication_evenements_fournisseur x where x.id = t.evenement_id;
    select count(*), min(n.id) into v_candidats, v_id
      from public.notification_envois n
     where n.fournisseur = ev.fournisseur and n.message_id = ev.message_id
       and ((ev.fournisseur = 'meta' and n.canal = 'whatsapp')
         or (ev.fournisseur in ('brevo', 'resend') and n.canal = 'email'));

    if v_candidats = 0 then
      update public.communication_evenements_traitement
         set tentatives = tentatives + 1,
             etat = case when tentatives + 1 >= 5 then 'echec' else 'a_traiter' end,
             prochain_essai_le = now() + interval '1 minute',
             dernier_code = 'NOREF',
             resultat = case when tentatives + 1 >= 5 then 'A_REVOIR' else 'ATTENTE_RAPPROCHEMENT' end
       where evenement_id = t.evenement_id;
      v_nombre := v_nombre + 1;
      continue;
    elsif v_candidats > 1 then
      update public.communication_evenements_traitement
         set etat = 'echec', dernier_code = 'AMBIG', resultat = 'CORRELATION_AMBIGUE'
       where evenement_id = t.evenement_id;
      v_nombre := v_nombre + 1;
      continue;
    end if;

    select * into e from public.notification_envois n where n.id = v_id for update;
    if not found then
      continue;
    end if;

    v_resultat := 'STATUT_ANTERIEUR_CONSERVE';
    if ev.type = 'sent' and e.statut in ('envoi', 'incertain') then
      update public.notification_envois
         set statut = 'envoye', envoye_le = coalesce(envoye_le, ev.survenu_le),
             code_erreur = null, erreur = null, maj_le = now()
       where id = e.id;
      v_resultat := 'ACCEPTE_FOURNISSEUR';
    elsif ev.type in ('delivered', 'read') and e.statut in ('envoi', 'envoye', 'incertain') then
      update public.notification_envois
         set statut = 'livre', envoye_le = coalesce(envoye_le, ev.survenu_le),
             livre_le = coalesce(livre_le, ev.survenu_le),
             code_erreur = null, erreur = null, maj_le = now()
       where id = e.id;
      v_resultat := 'LIVRAISON_FOURNISSEUR';
    elsif ev.type in ('failed', 'hard_bounce', 'blocked') and e.statut in ('envoi', 'envoye', 'incertain') then
      update public.notification_envois
         set statut = 'echec', code_erreur = coalesce(ev.code, upper(ev.type)),
             erreur = null, maj_le = now()
       where id = e.id;
      v_resultat := 'ECHEC_FOURNISSEUR';
    end if;

    update public.communication_evenements_traitement
       set etat = 'traite', traite_le = clock_timestamp(), resultat = v_resultat,
           cible_empreinte = null, code_confirmation = null
     where evenement_id = t.evenement_id;
    v_nombre := v_nombre + 1;
  end loop;
  return v_nombre;
end;
$fonction$;

revoke all on function public.communication_traiter_evenements_transactionnels(integer)
  from public, anon, authenticated, service_role;

-- Le travailleur de 004 (ou de la chaîne officielle) devient la fonction intérieure, et
-- traiter_notifications l'enveloppe pour traiter aussi les retours transactionnels.
-- Correction du 23/11/2026 (étape C11, trouvée par le rejeu de la chaîne sur une base
-- restaurée) : quand la chaîne est rejouée, 004 réécrit traiter_notifications ; c'est
-- alors CETTE version, la plus récente, qui doit devenir la fonction intérieure. L'ancien
-- code gardait la fonction intérieure du premier passage : une correction ultérieure du
-- travailleur ne prenait jamais effet sur une base existante. L'enveloppe se reconnaît à
-- son appel de la fonction intérieure.
do $worker$
declare
  v_travailleur regprocedure := pg_catalog.to_regprocedure('public.traiter_notifications(integer)');
begin
  if v_travailleur is not null
     and pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid = v_travailleur),
                           'communication_traiter_notifications_sans_callbacks') = 0 then
    execute 'drop function if exists public.communication_traiter_notifications_sans_callbacks(integer)';
    execute 'alter function public.traiter_notifications(integer) '
            'rename to communication_traiter_notifications_sans_callbacks';
  elsif pg_catalog.to_regprocedure('public.communication_traiter_notifications_sans_callbacks(integer)') is null then
    raise exception 'COMMUNICATION_NOTIFICATION_WORKER_UNAVAILABLE';
  end if;
end
$worker$;
-- Fonction intérieure : appelée seulement par l'enveloppe (security definer).
revoke all on function public.communication_traiter_notifications_sans_callbacks(integer)
  from public, anon, authenticated, service_role;

create or replace function public.traiter_notifications(p_lot integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_resultat jsonb;
  v_callbacks integer;
begin
  v_resultat := public.communication_traiter_notifications_sans_callbacks(p_lot);
  v_callbacks := public.communication_traiter_evenements_transactionnels(coalesce(p_lot, 50));
  return coalesce(v_resultat, '{}'::jsonb)
      || jsonb_build_object('retours_transactionnels', v_callbacks);
end;
$fonction$;
revoke execute on function public.traiter_notifications(integer) from public, anon, authenticated;
grant execute on function public.traiter_notifications(integer) to service_role;

commit;

revoke all on function public.communication_normaliser_reponse_canal(text, integer, text, text)
  from public, anon, authenticated, service_role;

create or replace function public.lire_reponse_envoi(
  p_envoi public.notification_envois, p_code integer, p_contenu text, p_erreur text)
returns void
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_resultat jsonb;
  v_classe text;
  v_code text;
  v_id text;
  v_max integer := (select tentatives_max from public.notification_moteur);
begin
  v_resultat := public.communication_normaliser_reponse_canal(
    p_envoi.canal, p_code, p_contenu, p_erreur);
  v_classe := v_resultat ->> 'classe';
  v_code := coalesce(v_resultat ->> 'code', '');
  v_id := v_resultat ->> 'message_id';

  -- Décision K (CEO, 23/11/2026) : une notification transactionnelle dont le
  -- résultat est incertain parce que le fournisseur a répondu 408, 425 ou 5xx,
  -- parce que le réseau a échoué ou parce qu'il est resté silencieux est
  -- réessayée comme dans le moteur officiel (30 s, 2 min, puis abandon au
  -- maximum de tentatives). Un « colis disponible » reçu deux fois gêne peu ; un
  -- message perdu est un défaut de service. Restent « incertain », sans reprise :
  -- une réponse 2xx sans identifiant de message (le fournisseur l'a sans doute
  -- accepté) et les codes de confirmation WhatsApp (un second code invaliderait
  -- le premier). Les codes reprennent ceux du moteur officiel : HTTP_<code> ou
  -- RESEAU, puis ABANDON_<code>.
  -- Une ligne marketing (candidate 012) n'est jamais réessayée après un résultat
  -- incertain : un message promotionnel reçu deux fois est une gêne, pas un service.
  if v_classe = 'incertain' and v_code = 'RESULTAT_INCERTAIN'
     and (pg_catalog.to_jsonb(p_envoi) ->> 'communication_confirmation_demande_id') is null
     and (pg_catalog.to_jsonb(p_envoi) ->> 'communication_campagne_destinataire_id') is null then
    v_classe := 'temporaire';
    v_code := case when p_erreur is null and p_code is not null
                   then 'HTTP_' || p_code::text else 'RESEAU' end;
  end if;

  if v_classe = 'accepte' then
    update public.notification_envois
       set statut = case when statut in ('livre', 'echec', 'annule') then statut else 'envoye' end,
           message_id = coalesce(message_id, left(v_id, 200)),
           envoye_le = coalesce(envoye_le, now()),
           code_erreur = case when statut in ('livre', 'echec', 'annule') then code_erreur else null end,
           erreur = null, verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  elsif v_classe = 'temporaire' and p_envoi.tentative < v_max then
    update public.notification_envois
       set statut = case when statut in ('livre', 'echec', 'annule') then statut else 'attente' end,
           code_erreur = case when statut in ('livre', 'echec', 'annule') then code_erreur else v_code end,
           erreur = null, verrouille_le = null,
           prochain_essai_le = now() + case p_envoi.tentative
             when 1 then interval '30 seconds' when 2 then interval '2 minutes'
             else interval '10 minutes' end,
           maj_le = now()
     where id = p_envoi.id;
  elsif v_classe = 'incertain' then
    update public.notification_envois
       set statut = case when statut in ('livre', 'echec', 'annule') then statut else 'incertain' end,
           code_erreur = case when statut in ('livre', 'echec', 'annule') then code_erreur else v_code end,
           erreur = null, verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  else
    -- Un échec temporaire au bout de ses tentatives est un abandon, comme dans le
    -- moteur officiel (ABANDON_HTTP_503, ABANDON_RESEAU, ABANDON_LIMITE_DEBIT).
    if v_classe = 'temporaire' then
      v_code := 'ABANDON_' || v_code;
    end if;
    update public.notification_envois
       set statut = case when statut in ('livre', 'echec', 'annule') then statut else 'echec' end,
           code_erreur = case when statut in ('livre', 'echec', 'annule') then code_erreur else v_code end,
           erreur = null, verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
    -- Comme le moteur officiel : un téléphone qu'Expo ne connaît plus est oublié,
    -- pour ne plus lui envoyer de push. Correction du 23/11/2026 (régression
    -- trouvée par essai-communication-non-regression.py).
    if p_envoi.canal = 'push' and v_code = 'DeviceNotRegistered' and p_envoi.appareil_id is not null then
      delete from public.appareils where id = p_envoi.appareil_id;
    end if;
  end if;
end;
$fonction$;
