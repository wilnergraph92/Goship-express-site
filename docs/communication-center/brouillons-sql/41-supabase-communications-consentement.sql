-- =============================================================================
-- BROUILLON — CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- Version Phase 1.3.1 (18/11/2026) — garde à trois couches : voir l'en-tête de
-- 40-supabase-communications-fondation.sql (bloc DO, puis TOUT le contenu dans une chaîne inerte).
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.3.1) : ne pas exécuter.';
end;
$brouillon$;

select $brouillon_goship_non_executable$
-- ===== DÉBUT DU CONTENU INERTE : tout ce qui suit est du TEXTE jusqu'à la balise de fin =====
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.3.1) : ne pas exécuter.';
end;
$brouillon$;
-- Couche 4 (Phase 1.3.1, IR-22) : un outil qui découperait ce texte à chaque point-virgule, sans comprendre les
-- chaînes, et continuerait après les erreurs, exécuterait CETTE instruction en premier : elle
-- ferme sa propre connexion, et rien de ce qui suit ne peut s'exécuter dans cette session. Dans
-- tout client correct, elle est du texte, comme le reste.
select pg_catalog.pg_terminate_backend(pg_catalog.pg_backend_pid());

-- =============================================================================
-- Goship Express — Centre de communication : le consentement, les changements de contact,
-- l'équipe et l'administration. À la suite de 40-…-fondation.
--
--   1. Le client : voir l'état de SON consentement, pour SON contact (masqué), dans la langue
--      du texte affiché ; demander ; retirer. Par défaut : AUCUN consentement (décision D-I).
--   2. La confirmation par le contact lui-même (revue 1.1, C2) : un lien signé pour l'e-mail
--      (ici) ; un message envoyé depuis le numéro pour WhatsApp (43, retours des fournisseurs).
--   3. Le changement de contact ou la suppression du compte : INVALIDATION, jamais un retrait
--      (revue 1.1, H7). Déclencheur qui ne bloque jamais l'écriture du client et qui garde ses
--      erreurs (revue 1.1, M13).
--   4. L'équipe : lire l'historique ; noter un RETRAIT demandé ; ajouter une suppression.
--   5. L'administrateur : textes, réglages, quota Brevo, identité légale et adresse postale
--      (après décision du CEO), limite WhatsApp, tarifs, indicatifs, liste d'essai, levée d'une
--      suppression, conservation, demandes de purge.
-- Toutes les écritures de consentement prennent le verrou « consentement:<client>:<canal> »
-- (revue 1.1, H6). Toute écriture de l'équipe va au journal d'audit avec son motif.
-- =============================================================================


-- 1. Le client ------------------------------------------------------------------------------

-- Les mots de confirmation WhatsApp, par langue. À VALIDER (juriste et Meta) avant toute
-- activation ; ils ne sont jamais présentés comme définitifs.
create or replace function public.communication_mots_confirmation()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('fr', jsonb_build_array('OUI'), 'en', jsonb_build_array('YES'),
                            'es', jsonb_build_array('SI', 'SÍ'), 'ht', jsonb_build_array('WI'))
$$;

-- Ce que « Mon compte » affiche. p_langue est OBLIGATOIRE : c'est la langue de l'écran, et le
-- texte renvoyé est celui de CETTE langue, sans repli silencieux sur une autre (revue 1.1, M1).
-- Pas de texte attesté dans cette langue pour ce canal : recueil_ouvert = false.
create or replace function public.mes_consentements_communication(p_langue text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_resultat jsonb := '[]'::jsonb;
  v_canal text;
  v_cible text;
  t public.communication_textes_consentement;
  r public.communication_reglages;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Réservé à l''espace client.');
  end if;
  if p_langue is null or p_langue not in ('fr', 'en', 'es', 'ht') then
    perform public.erreur_metier('INVALID_LANGUAGE', 'Langue d''affichage manquante ou inconnue.');
  end if;
  select * into r from public.communication_reglages;
  foreach v_canal in array array['email', 'whatsapp'] loop
    v_cible := public.communication_cible(v_moi, v_canal);
    select * into t from public.communication_textes_consentement x
     where x.canal = v_canal and x.langue = p_langue and x.statut = 'atteste_juridique'
     order by x.atteste_le desc limit 1;
    v_resultat := v_resultat || jsonb_build_array(
      public.communication_etat_consentement(v_moi, v_canal) || jsonb_build_object(
        'canal', v_canal,
        'contact_masque', public.communication_masque(v_canal, v_cible),   -- le contact EXACT concerné
        'joignable', v_cible is not null,
        'recueil_ouvert', t.version is not null and v_cible is not null
                          and (v_canal = 'email' or r.whatsapp_numero_affiche is not null),
        'version', t.version, 'langue_texte', t.langue, 'texte', t.texte,
        'numero_a_ecrire', case when v_canal = 'whatsapp' then r.whatsapp_numero_affiche end,
        'mots_confirmation', case when v_canal = 'whatsapp' then public.communication_mots_confirmation() -> p_langue end));
  end loop;
  return jsonb_build_object('canaux', v_resultat);
end;
$$;

-- Demander : le client coche la case. Exige la version ET la langue EXACTES du texte affiché ;
-- crée l'étape « demande » (EN ATTENTE) et le jeton ou le code de confirmation. Rien n'est
-- actif avant la confirmation par le contact lui-même. Limites : changements_consentement_jour
-- et demandes_confirmation_jour par canal et par 24 h (revue 1.1, M14).
create or replace function public.demander_consentement_communication(p_canal text, p_version text, p_langue text,
                                                                     p_source text default 'compte_web')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'                 -- D5 (P-03) : au-delà, erreur (jamais d'attente sans fin)
as $$
declare
  v_moi uuid := auth.uid();
  r public.communication_reglages;
  t public.communication_textes_consentement;
  v_cible text;
  v_empreinte text;
  v_id bigint;
  v_code text;
  v_essai integer;
  v_tirage integer;
  v_place boolean;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Réservé à l''espace client.');
  end if;
  if p_canal not in ('email', 'whatsapp') or p_source not in ('compte_web', 'application') then
    perform public.erreur_metier('INVALID_INPUT', 'Canal ou origine inconnus.');
  end if;
  perform public.communication_verrou('consentement:' || v_moi || ':' || p_canal);
  select * into r from public.communication_reglages;

  if (select count(*) from public.communication_consentements
       where client_id = v_moi and canal = p_canal and source in ('compte_web', 'application')
         and cree_le > now() - interval '24 hours') >= r.changements_consentement_jour
     or (select count(*) from public.communication_confirmations
          where client_id = v_moi and canal = p_canal and cree_le > now() - interval '24 hours') >= r.demandes_confirmation_jour then
    perform public.erreur_metier('TOO_MANY_CHANGES', 'Trop de changements aujourd''hui : réessayez demain.');
  end if;
  -- D5 (D1) : pas deux demandes du même compte en moins d'une minute (double clic, robot)
  if exists (select 1 from public.communication_confirmations
              where client_id = v_moi and canal = p_canal and cree_le > clock_timestamp() - interval '1 minute') then
    perform public.erreur_metier('TOO_MANY_CHANGES', 'Une demande vient d''être envoyée : attendez une minute.');
  end if;

  select * into t from public.communication_textes_consentement
   where version = p_version and canal = p_canal and langue = p_langue and statut = 'atteste_juridique';
  if not found then
    perform public.erreur_metier('CONSENT_TEXT_INVALID', 'Ce texte n''est plus en vigueur : rechargez la page.');
  end if;
  v_cible := public.communication_cible(v_moi, p_canal);
  v_empreinte := public.communication_empreinte(p_canal, v_cible);
  if v_cible is null then
    perform public.erreur_metier('NO_TARGET', 'Ajoutez d''abord votre adresse e-mail ou votre numéro WhatsApp à votre profil.');
  end if;
  if v_empreinte is null then
    perform public.erreur_metier('NOT_AVAILABLE', 'Service momentanément indisponible.');   -- poivre absent : échec fermé
  end if;
  if p_canal = 'whatsapp' and r.whatsapp_numero_affiche is null then
    perform public.erreur_metier('NOT_AVAILABLE', 'L''inscription WhatsApp n''est pas encore ouverte.');
  end if;
  -- D5 (D1, N-02) : demandes répétées vers un même NUMÉRO ou une même adresse, tous comptes
  -- confondus (plusieurs comptes peuvent partager un contact) : même plafond que par compte
  if (select count(*) from public.communication_confirmations
       where canal = p_canal and cible_empreinte = v_empreinte
         and cree_le > now() - interval '24 hours') >= r.demandes_confirmation_jour then
    perform public.erreur_metier('TOO_MANY_CHANGES', 'Trop de demandes pour ce contact aujourd''hui : réessayez demain.');
  end if;
  if (public.communication_etat_consentement(v_moi, p_canal) ->> 'actif')::boolean then
    return public.mes_consentements_communication(p_langue);       -- déjà confirmé pour ce contact
  end if;

  -- Une seule demande en cours par canal : les précédentes sont annulées
  update public.communication_confirmations set annule_le = clock_timestamp()
   where client_id = v_moi and canal = p_canal and utilise_le is null and annule_le is null;

  insert into public.communication_consentements (client_id, canal, action, source, texte_version, texte_empreinte,
                                                  langue, cible_empreinte, contexte, auteur_id)
  values (v_moi, p_canal, 'demande', p_source, t.version, t.empreinte, t.langue, v_empreinte,
          jsonb_build_object('source', p_source), v_moi)
  returning id into v_id;

  if p_canal = 'email' then
    insert into public.communication_confirmations (consentement_id, client_id, canal, cible_empreinte, code, expire_le)
    values (v_id, v_moi, p_canal, v_empreinte, null, clock_timestamp() + make_interval(hours => r.confirmation_validite_h));
  else
    -- D5 (D1, N-02) : code de 6 CHIFFRES tiré par un générateur cryptographique, sans biais
    -- (tirage rejeté au-delà de 16 000 000), DIFFÉRENT de tout code encore ouvert pour ce même
    -- numéro : l'index unique communication_confirmations_code_numero_idx le garantit en base,
    -- même si deux comptes du numéro demandent en même temps (ils ne partagent pas N3) — un
    -- conflit fait simplement tirer un autre code. Il ne suffit jamais seul : le message doit
    -- AUSSI venir du numéro dont l'empreinte est celle de la demande (43 §7). Expire vite.
    for v_essai in 1..20 loop
      v_tirage := ('x' || encode(extensions.gen_random_bytes(3), 'hex'))::bit(24)::integer;
      continue when v_tirage >= 16000000;
      v_code := lpad((v_tirage % 1000000)::text, 6, '0');
      begin
        insert into public.communication_confirmations (consentement_id, client_id, canal, cible_empreinte, code, expire_le)
        values (v_id, v_moi, p_canal, v_empreinte, v_code,
                clock_timestamp() + make_interval(mins => r.confirmation_code_validite_min));
        v_place := true;
        exit;
      exception when unique_violation then
        v_code := null;                                          -- code déjà ouvert pour ce numéro : on retire
      end;
    end loop;
    if not coalesce(v_place, false) then
      perform public.erreur_metier('NOT_AVAILABLE', 'Service momentanément indisponible : réessayez.');
    end if;
  end if;
  -- E-mail : l'envoi du lien est mis en file par 43 (communication_demander_envoi_confirmation),
  -- jamais par une page, et seulement si confirmations_actives et email_actif sont allumés.
  if p_canal = 'email' then
    perform public.communication_demander_envoi_confirmation(v_id);
  end if;
  return public.mes_consentements_communication(p_langue)
         || jsonb_build_object('code_whatsapp', v_code);
end;
$$;

-- Confirmer par le lien de l'e-mail. Ouverte sans connexion : le lien peut être ouvert sur un
-- autre appareil. La page desinscription/confirmation n'appelle cette fonction qu'au CLIC sur
-- un bouton (jamais au chargement : les robots de messagerie ouvrent les liens). Jeton : 43
-- caractères base64url, gardé seulement par son SHA-256, à usage unique, avec une date
-- d'expiration, et refusé si le contact du client a changé depuis la demande.
create or replace function public.confirmer_consentement_communication(p_jeton text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'                 -- D5 (P-03) : au-delà, erreur (jamais d'attente sans fin)
as $$
declare
  f public.communication_confirmations;
  k public.communication_consentements;
begin
  if coalesce(p_jeton, '') !~ '^[A-Za-z0-9_-]{43}$' then
    return jsonb_build_object('ok', false);                      -- contrôle bon marché avant toute lecture
  end if;
  -- Ordre des verrous (Phase 1.3, C2) : la ligne est d'abord LUE sans verrou, puis N3 (le
  -- consentement), puis la ligne est verrouillée et RELUE. Avant 1.3, la ligne était verrouillée
  -- AVANT N3, quand demander_consentement_communication prend N3 AVANT d'annuler les lignes :
  -- deux onglets du même client (demander d'un côté, confirmer de l'autre) pouvaient s'attendre.
  select * into f from public.communication_confirmations
   where jeton_empreinte = encode(extensions.digest(p_jeton, 'sha256'), 'hex');
  if not found or f.utilise_le is not null or f.annule_le is not null or f.expire_le < now() then
    return jsonb_build_object('ok', false);
  end if;
  perform public.communication_verrou('consentement:' || f.client_id || ':' || f.canal);
  select * into f from public.communication_confirmations
   where id = f.id and utilise_le is null and annule_le is null and expire_le > now() for update;
  if not found then
    return jsonb_build_object('ok', false);
  end if;
  -- Le contact n'a pas changé, et la demande est toujours la dernière étape (pas de retrait depuis)
  if public.communication_empreinte(f.canal, public.communication_cible(f.client_id, f.canal)) is distinct from f.cible_empreinte
     or (public.communication_etat_consentement(f.client_id, f.canal) ->> 'etat') <> 'en_attente' then
    update public.communication_confirmations set annule_le = clock_timestamp() where id = f.id;
    return jsonb_build_object('ok', false);
  end if;
  select * into k from public.communication_consentements where id = f.consentement_id;
  update public.communication_confirmations set utilise_le = clock_timestamp() where id = f.id;
  insert into public.communication_consentements (client_id, canal, action, source, texte_version, texte_empreinte,
                                                  langue, cible_empreinte)
  values (f.client_id, f.canal, 'confirme', 'lien_confirmation', k.texte_version, k.texte_empreinte, k.langue, f.cible_empreinte);
  -- Une nouvelle inscription confirmée par le client lève SES désinscriptions de ce contact
  -- (jamais une plainte, un rebond ou une suppression manuelle) — règle à valider par le juriste.
  update public.communication_suppressions
     set leve_le = clock_timestamp(), motif_levee = 'Nouvelle inscription confirmée par le contact'
   where canal = f.canal and cible_empreinte = f.cible_empreinte and leve_le is null
     and raison in ('desinscription', 'stop');
  return jsonb_build_object('ok', true, 'canal', f.canal);
end;
$$;

-- Retirer : toujours permis, jamais limité, effet immédiat.
create or replace function public.retirer_mon_consentement_communication(p_canal text, p_source text default 'compte_web')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'                 -- D5 (P-03) : au-delà, erreur (jamais d'attente sans fin)
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client') then
    perform public.erreur_metier('PERMISSION_DENIED', 'Réservé à l''espace client.');
  end if;
  if p_canal not in ('email', 'whatsapp') or p_source not in ('compte_web', 'application') then
    perform public.erreur_metier('INVALID_INPUT', 'Canal ou origine inconnus.');
  end if;
  perform public.communication_verrou('consentement:' || v_moi || ':' || p_canal);
  update public.communication_confirmations set annule_le = clock_timestamp()
   where client_id = v_moi and canal = p_canal and utilise_le is null and annule_le is null;
  if (public.communication_etat_consentement(v_moi, p_canal) ->> 'etat') in ('en_attente', 'confirme') then
    insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte, auteur_id)
    values (v_moi, p_canal, 'retire', p_source,
            public.communication_empreinte(p_canal, public.communication_cible(v_moi, p_canal)), v_moi);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- 2. Changement de contact et suppression du compte (revue 1.1, H7, M13) ------------------------
-- Un changement d'e-mail, de téléphone ou de pays (le pays change l'indicatif) INVALIDE le
-- consentement du canal concerné : ligne « invalide » avec l'empreinte de l'ANCIEN contact,
-- jamais « retire ». Le nouveau contact n'hérite de rien (l'état actif exige l'empreinte
-- actuelle). Les confirmations en cours sont annulées. Suppression du compte : invalidation
-- des deux canaux. Ne bloque JAMAIS l'écriture du client (Google, profil, suppression du
-- compte) ; une erreur est GARDÉE dans communication_erreurs.
create or replace function public.communication_suivre_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
-- Phase 1.3.1 (revue indépendante IR-05, IR-07, IR-16) : TROIS blocs indépendants. Avant, un
-- seul bloc attrapait tout : une erreur dans la demande de purge (par exemple 43 pas encore
-- appliqué) annulait AUSSI les invalidations de consentement — et un contact repris plus tard
-- aurait retrouvé un ancien accord. Le journal ne garde que le code d'erreur (jamais sqlerrm,
-- qui peut recopier une valeur).
declare
  v_canal text;
  v_ancienne text;
  v_change boolean;
  v_etat text;
  v_empreintes text[];
begin
  -- 1. Invalidation, canal par canal (chacun dans son propre bloc)
  foreach v_canal in array array['email', 'whatsapp'] loop
    begin
      v_change := (new.supprime_le is not null and old.supprime_le is null)
               or (v_canal = 'email' and public.communication_normaliser('email', new.email)
                                         is distinct from public.communication_normaliser('email', old.email))
               or (v_canal = 'whatsapp' and public.telephone_international(new.telephone, new.pays)
                                            is distinct from public.telephone_international(old.telephone, old.pays));
      if v_change and exists (select 1 from public.communication_consentements k
                               where k.client_id = new.id and k.canal = v_canal) then
        -- D5 (RF-10, P-03) : sur le chemin EXISTANT des clients (profil, Google, suppression du
        -- compte), on n'attend jamais N3. S'il est pris, l'invalidation s'écrit quand même, sans
        -- lui : un consentement ne vaut de toute façon que pour le contact ACTUEL (40,
        -- communication_etat_consentement), donc rien ne peut partir vers le nouveau contact.
        if not pg_try_advisory_xact_lock(hashtextextended('goship-communication:consentement:' || new.id || ':' || v_canal, 0)) then
          insert into public.communication_erreurs (source, code, detail)
          values ('communication_suivre_client:sans_verrou', 'N3_OCCUPE', v_canal);
        end if;
        v_ancienne := public.communication_empreinte(v_canal,
                        case v_canal when 'email' then old.email
                                     else public.telephone_international(old.telephone, old.pays) end);
        insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte, auteur_id)
        values (new.id, v_canal, 'invalide',
                case when new.supprime_le is not null and old.supprime_le is null then 'suppression_compte'
                     else 'changement_contact' end,
                v_ancienne, auth.uid());
        update public.communication_confirmations set annule_le = clock_timestamp()
         where client_id = new.id and canal = v_canal and utilise_le is null and annule_le is null;
      end if;
    exception when others then
      get stacked diagnostics v_etat = returned_sqlstate;
      begin
        insert into public.communication_erreurs (source, code, detail)
        values ('communication_suivre_client:invalidation', v_etat, v_canal);
      exception when others then null;
      end;
    end;
  end loop;

  -- 2. Un fuseau déclaré devient caduc si le pays ou la région change (1.3, C6)
  begin
    if new.pays is distinct from old.pays or new.region is distinct from old.region then
      delete from public.communication_fuseaux_clients where client_id = new.id;
    end if;
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    begin
      insert into public.communication_erreurs (source, code) values ('communication_suivre_client:fuseau', v_etat);
    exception when others then null;
    end;
  end;

  -- 3. Suppression du compte : demande d'effacement ouverte d'office (demandeur = la personne ;
  --    un AUTRE compte l'approuve). Dès qu'UNE table du Centre cite la personne. Les empreintes
  --    de ses contacts sont prises dans old.* : supprimer_mon_compte vide l'e-mail et le
  --    téléphone dans le même UPDATE, après quoi on ne pourrait plus retrouver ses fenêtres
  --    WhatsApp ni ses suppressions (IR-07).
  begin
    if new.supprime_le is not null and old.supprime_le is null
       and (exists (select 1 from public.communication_consentements k where k.client_id = new.id)
            or exists (select 1 from public.communication_confirmations f where f.client_id = new.id)
            or exists (select 1 from public.communication_fuseaux_clients z where z.client_id = new.id)
            or exists (select 1 from public.communication_destinataires_essai t where t.client_id = new.id)
            or exists (select 1 from public.communication_suppressions s where s.client_id = new.id)
            or exists (select 1 from public.communication_destinataires dd where dd.client_id = new.id)
            or exists (select 1 from public.communication_envois e where e.client_id = new.id))
       and not exists (select 1 from public.communication_demandes_purge d
                        where d.type = 'personne' and d.client_id = new.id and d.statut in ('demandee', 'approuvee')) then
      select coalesce(array_agg(x) filter (where x is not null), '{}') into v_empreintes
        from unnest(array[public.communication_empreinte('email', old.email),
                          public.communication_empreinte('whatsapp', public.telephone_international(old.telephone, old.pays))]) x;
      insert into public.communication_demandes_purge (type, client_id, motif, demandee_par, empreintes)
      values ('personne', new.id, 'Suppression du compte demandée par la personne', new.id, v_empreintes);
    end if;
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    begin
      insert into public.communication_erreurs (source, code) values ('communication_suivre_client:purge', v_etat);
    exception when others then null;
    end;
  end;
  -- Limite connue (IR-16) : une annulation par délai (statement_timeout, query_canceled) n'est
  -- pas attrapée par « when others » ; N3 n'est tenu par un travailleur que quelques
  -- millisecondes (lock_timeout 2 s), ce qui la rend improbable. Essai T-18.
  return new;
end;
$$;
drop trigger if exists communication_suivre_client on public.clients;
create trigger communication_suivre_client
  after update of email, telephone, pays, region, supprime_le on public.clients
  for each row execute function public.communication_suivre_client();


-- 3. L'équipe ------------------------------------------------------------------------------------
create or replace function public.consentements_client(p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.consents');
  return jsonb_build_object(
    'email', public.communication_etat_consentement(p_client, 'email'),
    'whatsapp', public.communication_etat_consentement(p_client, 'whatsapp'),
    'historique', coalesce((select jsonb_agg(jsonb_build_object(
        'canal', k.canal, 'action', k.action, 'source', k.source, 'version', k.texte_version,
        'langue', k.langue, 'le', k.cree_le, 'par_equipe', k.auteur_id is distinct from k.client_id,
        'motif', k.motif) order by k.cree_le desc, k.id desc)
      from public.communication_consentements k where k.client_id = p_client), '[]'::jsonb),
    'suppressions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'canal', s.canal, 'raison', s.raison, 'le', s.cree_le, 'levee_le', s.leve_le) order by s.cree_le desc)
      from public.communication_suppressions s where s.client_id = p_client), '[]'::jsonb));
end;
$$;

-- Le client demande, par téléphone ou au comptoir, à ne plus rien recevoir : l'équipe le note.
create or replace function public.retirer_consentement_client(p_client uuid, p_canal text, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'                 -- D5 (P-03) : au-delà, erreur (jamais d'attente sans fin)
as $$
begin
  perform public.exiger_permission('communications.consents');
  if p_canal not in ('email', 'whatsapp') then
    perform public.erreur_metier('INVALID_CHANNEL', 'Canal inconnu.');
  end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Dites qui a demandé le retrait, et comment (5 caractères au moins).');
  end if;
  perform public.communication_verrou('consentement:' || p_client || ':' || p_canal);
  update public.communication_confirmations set annule_le = clock_timestamp()
   where client_id = p_client and canal = p_canal and utilise_le is null and annule_le is null;
  insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte, auteur_id, motif)
  values (p_client, p_canal, 'retire', 'equipe_sur_demande',
          public.communication_empreinte(p_canal, public.communication_cible(p_client, p_canal)), auth.uid(), trim(p_motif));
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.consentement_retire', 'client', p_client::text, null, jsonb_build_object('canal', p_canal));
  return public.consentements_client(p_client);
end;
$$;

-- Suppression manuelle (revue 1.1, M4) : n'empêche que le commercial, jamais le transactionnel.
create or replace function public.ajouter_suppression_communication(p_client uuid, p_canal text, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empreinte text;
begin
  perform public.exiger_permission('communications.consents');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif d''au moins 5 caractères.');
  end if;
  v_empreinte := public.communication_empreinte(p_canal, public.communication_cible(p_client, p_canal));
  if v_empreinte is null then
    perform public.erreur_metier('NO_TARGET', 'Ce client n''a pas de contact sur ce canal.');
  end if;
  insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source, auteur_id, motif)
  values (p_canal, v_empreinte, p_client, 'manuel', 'equipe', auth.uid(), trim(p_motif))
  on conflict do nothing;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.suppression_manuelle', 'client', p_client::text, null, jsonb_build_object('canal', p_canal));
  return public.consentements_client(p_client);
end;
$$;


-- 4. L'administrateur --------------------------------------------------------------------------

-- 4.1 Les textes de consentement : brouillon, puis attestation (référence de l'avis juridique).
create or replace function public.ecrire_texte_consentement(p_version text, p_canal text, p_langue text, p_texte text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if exists (select 1 from public.communication_textes_consentement
              where version = p_version and canal = p_canal and langue = p_langue and statut <> 'brouillon') then
    perform public.erreur_metier('CONSENT_TEXT_LOCKED', 'Texte attesté ou retiré : créez une nouvelle version.');
  end if;
  insert into public.communication_textes_consentement (version, canal, langue, texte, empreinte)
  values (p_version, p_canal, p_langue, p_texte, encode(extensions.digest(p_texte, 'sha256'), 'hex'))
  on conflict (version, canal, langue) do update set texte = excluded.texte, empreinte = excluded.empreinte;
  perform public.auditer('communication.texte_consentement', 'communication_texte', p_version || ':' || p_canal || ':' || p_langue,
                         null, jsonb_build_object('empreinte', encode(extensions.digest(p_texte, 'sha256'), 'hex')));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.attester_texte_consentement(p_version text, p_canal text, p_langue text, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_reference, ''))) < 5 then
    perform public.erreur_metier('LEGAL_REFERENCE_REQUIRED', 'Notez la référence de l''avis du conseil juridique (nom, date).');
  end if;
  update public.communication_textes_consentement
     set statut = 'atteste_juridique', reference_juridique = trim(p_reference), atteste_par = auth.uid(), atteste_le = now()
   where version = p_version and canal = p_canal and langue = p_langue and statut = 'brouillon';
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Aucun brouillon à cette version.');
  end if;
  perform set_config('goship.motif', trim(p_reference), true);
  perform public.auditer('communication.texte_atteste', 'communication_texte', p_version || ':' || p_canal || ':' || p_langue,
                         null, jsonb_build_object('reference', trim(p_reference)));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.2 Les réglages ordinaires : liste blanche, motif, avant/après au journal. Les réglages
-- « BLOQUÉS » (quota Brevo, limite WhatsApp, identité et adresse) ont leurs propres fonctions,
-- qui exigent une preuve. Allumer un canal vérifie que ses préalables sont en place.
create or replace function public.regler_communications(p_champs jsonb, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_avant public.communication_reglages;
  v_apres public.communication_reglages;
  v_cle text;
  v_permis text[] := array['campagnes_actives', 'mode', 'email_actif', 'whatsapp_actif', 'confirmations_actives',
                           'plafond_jour_usd', 'plafond_jour_messages', 'lot_par_minute', 'delai_http_ms',
                           'heure_debut', 'heure_fin', 'frequence_max_jour', 'frequence_max_semaine',
                           'attente_transactionnel_max', 'seuil_croissance_pct', 'modele_meta_fraicheur_min',
                           'confirmation_validite_h', 'changements_consentement_jour', 'demandes_confirmation_jour',
                           'quatre_yeux', 'adresse_miami_validee',
                           'debit_max_minute', 'marge_fenetre_min', 'webhook_max_minute', 'brevo_quota_validite_jours'];
  -- L'arrêt d'urgence n'est PAS un réglage : table communication_arret, fonctions de §4.8.
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif d''au moins 5 caractères.');
  end if;
  for v_cle in select jsonb_object_keys(coalesce(p_champs, '{}'::jsonb)) loop
    if not v_cle = any (v_permis) then
      perform public.erreur_metier('INVALID_FIELD', 'Réglage inconnu ou protégé : ' || v_cle);
    end if;
  end loop;
  -- N0 EXCLUSIF (Phase 1.3, C1) : attend la fin des envois en cours, puis empêche tout nouvel
  -- envoi de lire les réglages avant ce COMMIT. 10 secondes au plus ; au-delà, refus : pour
  -- COUPER sans attendre, il y a l'arrêt d'urgence (arreter_communications).
  -- D5 (P-03) : 3 s, puis 2 s pour la ligne des réglages (jamais « 0 » = sans limite) ; total
  -- sous les 8 s du rôle authenticated (mesurés le 20/11/2026)
  perform set_config('lock_timeout', '3s', true);
  begin
    perform public.communication_verrou_interrupteurs(true);
  exception when lock_not_available then
    perform public.erreur_metier('BUSY', 'Des envois sont en cours : réessayez, ou utilisez l''arrêt d''urgence pour tout couper.');
  end;
  perform set_config('lock_timeout', '2s', true);
  select * into v_avant from public.communication_reglages for update;
  begin
    update public.communication_reglages set
      campagnes_actives = coalesce((p_champs ->> 'campagnes_actives')::boolean, campagnes_actives),
      mode = coalesce(p_champs ->> 'mode', mode),
      email_actif = coalesce((p_champs ->> 'email_actif')::boolean, email_actif),
      whatsapp_actif = coalesce((p_champs ->> 'whatsapp_actif')::boolean, whatsapp_actif),
      confirmations_actives = coalesce((p_champs ->> 'confirmations_actives')::boolean, confirmations_actives),
      plafond_jour_usd = coalesce((p_champs ->> 'plafond_jour_usd')::numeric, plafond_jour_usd),
      plafond_jour_messages = coalesce((p_champs ->> 'plafond_jour_messages')::integer, plafond_jour_messages),
      lot_par_minute = coalesce((p_champs ->> 'lot_par_minute')::integer, lot_par_minute),
      delai_http_ms = coalesce((p_champs ->> 'delai_http_ms')::integer, delai_http_ms),
      heure_debut = coalesce((p_champs ->> 'heure_debut')::integer, heure_debut),
      heure_fin = coalesce((p_champs ->> 'heure_fin')::integer, heure_fin),
      frequence_max_jour = coalesce((p_champs ->> 'frequence_max_jour')::integer, frequence_max_jour),
      frequence_max_semaine = coalesce((p_champs ->> 'frequence_max_semaine')::integer, frequence_max_semaine),
      attente_transactionnel_max = coalesce((p_champs ->> 'attente_transactionnel_max')::integer, attente_transactionnel_max),
      seuil_croissance_pct = coalesce((p_champs ->> 'seuil_croissance_pct')::integer, seuil_croissance_pct),
      modele_meta_fraicheur_min = coalesce((p_champs ->> 'modele_meta_fraicheur_min')::integer, modele_meta_fraicheur_min),
      confirmation_validite_h = coalesce((p_champs ->> 'confirmation_validite_h')::integer, confirmation_validite_h),
      changements_consentement_jour = coalesce((p_champs ->> 'changements_consentement_jour')::integer, changements_consentement_jour),
      demandes_confirmation_jour = coalesce((p_champs ->> 'demandes_confirmation_jour')::integer, demandes_confirmation_jour),
      quatre_yeux = coalesce((p_champs ->> 'quatre_yeux')::boolean, quatre_yeux),
      adresse_miami_validee = coalesce((p_champs ->> 'adresse_miami_validee')::boolean, adresse_miami_validee),
      debit_max_minute = coalesce((p_champs ->> 'debit_max_minute')::integer, debit_max_minute),
      marge_fenetre_min = coalesce((p_champs ->> 'marge_fenetre_min')::integer, marge_fenetre_min),
      webhook_max_minute = coalesce((p_champs ->> 'webhook_max_minute')::integer, webhook_max_minute),
      brevo_quota_validite_jours = coalesce((p_champs ->> 'brevo_quota_validite_jours')::integer, brevo_quota_validite_jours),
      maj_le = now(), maj_par = auth.uid()
    returning * into v_apres;
  exception when invalid_text_representation or check_violation or numeric_value_out_of_range then
    perform public.erreur_metier('INVALID_VALUE', 'Valeur refusée : vérifiez le type et les bornes du réglage.');
  end;

  -- Les préalables de chaque canal (échec fermé)
  if v_apres.email_actif and (v_apres.identite_legale is null or v_apres.adresse_postale is null) then
    perform public.erreur_metier('SENDER_IDENTITY_BLOCKED',
      'Identité légale et adresse postale non validées par le CEO (décision D-G) : l''e-mail commercial reste coupé.');
  end if;
  -- 1.3.1 (IR-11) : tant que le commercial PARTAGE le compte Brevo du transactionnel, une plainte
  -- ou un blocage sur un e-mail commercial peut atteindre les e-mails de colis, de facture et de
  -- connexion (comportement de Brevo rapporté, non éprouvé). L'e-mail commercial reste fermé
  -- jusqu'à la décision C4 du CEO (compte séparé).
  if v_apres.email_actif and v_apres.brevo_compte_partage
     and coalesce(public.lire_reglage('communication_email_fournisseur'), 'brevo') = 'brevo' then
    perform public.erreur_metier('SHARED_PROVIDER_ACCOUNT',
      'Le compte Brevo est partagé avec les e-mails de colis et de connexion : e-mail commercial fermé (décision C4).');
  end if;
  if v_apres.email_actif and (v_apres.brevo_quota_verifie_le is null
                               or coalesce(public.lire_reglage('communication_email_cle_api'), '') = ''
                               or coalesce(public.lire_reglage('communication_expediteur'), '') = '') then
    perform public.erreur_metier('EMAIL_IDENTITY_MISSING',
      'Compte et expéditeur commerciaux non configurés, ou quota Brevo non vérifié (décisions C4, D-C).');
  end if;
  if (v_apres.email_actif or v_apres.confirmations_actives)
     and coalesce(public.lire_reglage('communication_cle_desinscription'), '') = '' then
    perform public.erreur_metier('UNSUBSCRIBE_KEY_MISSING', 'Clé de signature des liens absente : aucun e-mail commercial.');
  end if;
  if v_apres.whatsapp_actif and (v_apres.whatsapp_destinataires_jour is null or v_apres.whatsapp_numero_affiche is null
                                  or coalesce(public.lire_reglage('communication_whatsapp_numero_id'), '') = '') then
    perform public.erreur_metier('WHATSAPP_BLOCKED',
      'Numéro commercial, ou limite quotidienne attribuée par Meta, non renseignés (décisions C4, H11).');
  end if;
  if (v_apres.email_actif or v_apres.whatsapp_actif or v_apres.confirmations_actives)
     and coalesce(public.lire_reglage('communication_poivre'), '') = '' then
    perform public.erreur_metier('PEPPER_MISSING', 'Poivre des empreintes absent : aucun envoi possible.');
  end if;

  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.reglages', 'communication_reglages', 'reglages', to_jsonb(v_avant), to_jsonb(v_apres));
  return to_jsonb(v_apres);
end;
$$;

-- 4.3 Les valeurs BLOQUÉES, chacune avec sa preuve, jamais inventées.
create or replace function public.verifier_quota_brevo(p_quota_24h integer, p_quota_30j integer, p_reserve integer,
                                                       p_compte_partage boolean, p_preuve text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_preuve, ''))) < 10 then
    perform public.erreur_metier('PROOF_REQUIRED', 'Dites où le quota a été lu (page Brevo, date, capture).');
  end if;
  perform set_config('lock_timeout', '3s', true);             -- D5 (P-03, RF-07) : jamais d'attente sans fin
  begin
    perform public.communication_verrou_interrupteurs(true);   -- N0 exclusif : réglage d'envoi (1.3, C1)
  exception when lock_not_available then
    perform public.erreur_metier('BUSY', 'Des envois sont en cours : réessayez dans quelques secondes.');
  end;
  perform set_config('lock_timeout', '2s', true);
  update public.communication_reglages
     set brevo_quota_24h = p_quota_24h, brevo_quota_30j = p_quota_30j, brevo_reserve_24h = p_reserve,
         brevo_compte_partage = p_compte_partage, brevo_quota_preuve = trim(p_preuve),
         brevo_quota_verifie_le = now(), brevo_quota_verifie_par = auth.uid(), maj_le = now(), maj_par = auth.uid();
  perform set_config('goship.motif', trim(p_preuve), true);
  perform public.auditer('communication.quota_brevo', 'communication_reglages', 'brevo', null,
                         jsonb_build_object('24h', p_quota_24h, '30j', p_quota_30j, 'reserve', p_reserve, 'partage', p_compte_partage));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.regler_whatsapp_commercial(p_numero_affiche text, p_destinataires_jour integer, p_preuve text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_preuve, ''))) < 10 then
    perform public.erreur_metier('PROOF_REQUIRED', 'Dites d''où viennent le numéro et la limite (décision du CEO, gestionnaire WhatsApp de Meta, date).');
  end if;
  perform set_config('lock_timeout', '3s', true);             -- D5 (P-03, RF-07) : jamais d'attente sans fin
  begin
    perform public.communication_verrou_interrupteurs(true);   -- N0 exclusif : réglage d'envoi (1.3, C1)
  exception when lock_not_available then
    perform public.erreur_metier('BUSY', 'Des envois sont en cours : réessayez dans quelques secondes.');
  end;
  perform set_config('lock_timeout', '2s', true);
  update public.communication_reglages
     set whatsapp_numero_affiche = p_numero_affiche, whatsapp_destinataires_jour = p_destinataires_jour,
         whatsapp_limite_preuve = trim(p_preuve), maj_le = now(), maj_par = auth.uid();
  perform set_config('goship.motif', trim(p_preuve), true);
  perform public.auditer('communication.whatsapp_commercial', 'communication_reglages', 'whatsapp', null,
                         jsonb_build_object('numero', p_numero_affiche, 'limite', p_destinataires_jour));
  return jsonb_build_object('ok', true);
end;
$$;

-- Identité légale et adresse postale de l'expéditeur (D-G) : posées par l'administrateur après
-- la décision ÉCRITE du CEO, dont la référence est le motif.
create or replace function public.valider_identite_expediteur(p_identite text, p_adresse text, p_decision_ceo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_decision_ceo, ''))) < 10 then
    perform public.erreur_metier('CEO_DECISION_REQUIRED', 'Référence de la décision écrite du CEO obligatoire.');
  end if;
  update public.communication_reglages
     set identite_legale = trim(p_identite), adresse_postale = trim(p_adresse),
         identite_validee_par = auth.uid(), identite_validee_le = now(), maj_le = now(), maj_par = auth.uid();
  perform set_config('goship.motif', trim(p_decision_ceo), true);
  perform public.auditer('communication.identite_expediteur', 'communication_reglages', 'identite', null,
                         jsonb_build_object('identite', trim(p_identite), 'adresse', trim(p_adresse)));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.4 Tarifs et indicatifs : seulement avec une preuve (grille officielle, confirmation de Meta).
create or replace function public.verifier_tarif_communication(p_fournisseur text, p_canal text, p_categorie text,
                                                               p_territoire text, p_prix_usd numeric, p_preuve text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_preuve, ''))) < 10 then
    perform public.erreur_metier('PROOF_REQUIRED', 'Dites où le prix a été lu (grille officielle, date).');
  end if;
  insert into public.communication_tarifs (fournisseur, canal, categorie, territoire, prix_usd, preuve, verifie_par)
  values (p_fournisseur, p_canal, p_categorie, p_territoire, p_prix_usd, trim(p_preuve), auth.uid())
  on conflict (fournisseur, canal, categorie, territoire) do update
    set prix_usd = excluded.prix_usd, preuve = excluded.preuve, verifie_par = excluded.verifie_par, verifie_le = now();
  perform public.auditer('communication.tarif', 'communication_tarif', p_fournisseur || ':' || p_canal || ':' || p_categorie || ':' || p_territoire,
                         null, jsonb_build_object('prix_usd', p_prix_usd, 'preuve', trim(p_preuve)));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.verifier_indicatif_communication(p_prefixe text, p_territoire text, p_autorise boolean, p_preuve text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_preuve, ''))) < 10 then
    perform public.erreur_metier('PROOF_REQUIRED', 'Preuve obligatoire (liste NANPA, confirmation écrite de Meta, date).');
  end if;
  -- 1.3.1 (IR-23) : dans le plan nord-américain (+1), un territoire se lit sur 4 chiffres au moins
  -- (1 + indicatif régional) : « 1 » ou « 18 » classeraient d'un coup Canada et Caraïbes en « US »
  -- Revue n° 2 (IR2-09) : y compris « NANP_AUTRE » autorisé (cela ouvrirait tout le +1 non classé)
  if p_prefixe like '1%' and length(p_prefixe) < 4 and (p_territoire <> 'NANP_AUTRE' or p_autorise) then
    perform public.erreur_metier('PREFIX_TOO_SHORT', 'Un indicatif +1 se classe sur 4 chiffres au moins (exemple : 1305).');
  end if;
  insert into public.communication_indicatifs (prefixe, territoire, autorise_marketing, verifie, preuve, verifie_par, verifie_le)
  values (p_prefixe, p_territoire, p_autorise, true, trim(p_preuve), auth.uid(), now())
  on conflict (prefixe) do update
    set territoire = excluded.territoire, autorise_marketing = excluded.autorise_marketing, verifie = true,
        preuve = excluded.preuve, verifie_par = excluded.verifie_par, verifie_le = excluded.verifie_le;
  perform public.auditer('communication.indicatif', 'communication_indicatif', p_prefixe, null,
                         jsonb_build_object('territoire', p_territoire, 'autorise', p_autorise, 'preuve', trim(p_preuve)));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.5 La liste d'essai : un compte de l'équipe, ou un client CONFIRMÉ sur ce canal.
create or replace function public.regler_destinataire_essai(p_client uuid, p_canal text, p_actif boolean, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.clients;
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif d''au moins 5 caractères.');
  end if;
  select * into c from public.clients where id = p_client;
  if not found or c.supprime_le is not null then
    perform public.erreur_metier('NOT_FOUND', 'Compte introuvable.');
  end if;
  if p_actif and c.role = 'client' and not public.communication_consentement_actuel(p_client, p_canal) then
    perform public.erreur_metier('CONSENT_REQUIRED', 'Un client n''entre sur la liste d''essai que s''il a lui-même confirmé son accord sur ce canal.');
  end if;
  insert into public.communication_destinataires_essai (client_id, canal, actif, motif, ajoute_par)
  values (p_client, p_canal, p_actif, trim(p_motif), auth.uid())
  on conflict (client_id, canal) do update set actif = excluded.actif, motif = excluded.motif,
                                               ajoute_par = excluded.ajoute_par, ajoute_le = now();
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.destinataire_essai', 'client', p_client::text, null,
                         jsonb_build_object('canal', p_canal, 'actif', p_actif));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.6 Lever une suppression : administrateur, motif ; ne rend jamais le consentement.
create or replace function public.lever_suppression_communication(p_suppression bigint, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif d''au moins 5 caractères.');
  end if;
  update public.communication_suppressions
     set leve_le = clock_timestamp(), leve_par = auth.uid(), motif_levee = trim(p_motif)
   where id = p_suppression and leve_le is null;
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Suppression introuvable ou déjà levée.');
  end if;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.suppression_levee', 'communication_suppression', p_suppression::text, null, null);
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.7 Conservation et purge (revue 1.1, C5).
-- Fixer une durée : seulement avec la référence de l'avis du juriste.
create or replace function public.regler_conservation_communication(p_categorie text, p_duree_jours integer,
                                                                    p_apres text, p_base text, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_reference, ''))) < 5 then
    perform public.erreur_metier('LEGAL_REFERENCE_REQUIRED', 'Référence de l''avis du juriste obligatoire.');
  end if;
  update public.communication_conservation
     set duree_jours = p_duree_jours, apres = p_apres, base_juridique = p_base, reference_juridique = trim(p_reference),
         regle_par = auth.uid(), regle_le = now()
   where categorie = p_categorie;
  perform set_config('goship.motif', trim(p_reference), true);
  perform public.auditer('communication.conservation', 'communication_conservation', p_categorie, null,
                         jsonb_build_object('duree_jours', p_duree_jours, 'apres', p_apres));
  return jsonb_build_object('ok', true);
end;
$$;

-- Demander une purge : échéance (administrateur) ; effacement demandé par une personne
-- (administrateur ou gérant, communications.consents, qui note la demande du client).
create or replace function public.demander_purge_communication(p_type text, p_categorie text, p_client uuid, p_motif text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if p_type = 'echeance' then
    perform public.exiger_permission('communications.manage');
  else
    perform public.exiger_permission('communications.consents');
  end if;
  insert into public.communication_demandes_purge (type, categorie, client_id, motif, demandee_par)
  values (p_type, p_categorie, p_client, trim(p_motif), auth.uid())
  returning id into v_id;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.purge_demandee', 'communication_demande_purge', v_id::text, null,
                         jsonb_build_object('type', p_type, 'categorie', p_categorie));
  return v_id;
end;
$$;

-- Approuver ou refuser : un AUTRE administrateur que le demandeur (quatre yeux, toujours).
create or replace function public.approuver_purge_communication(p_demande bigint, p_accepter boolean, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'                 -- D5 (P-03) : au-delà, erreur (jamais d'attente sans fin)
as $$
declare
  d public.communication_demandes_purge;
begin
  perform public.exiger_permission('communications.approve');
  select * into d from public.communication_demandes_purge where id = p_demande for update;
  if not found or d.statut <> 'demandee' then
    perform public.erreur_metier('NOT_FOUND', 'Demande introuvable ou déjà traitée.');
  end if;
  if d.demandee_par = auth.uid() then
    perform public.erreur_metier('FOUR_EYES', 'Un autre administrateur doit approuver cette purge.');
  end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif d''au moins 5 caractères.');
  end if;
  update public.communication_demandes_purge
     set statut = case when p_accepter then 'approuvee' else 'refusee' end, approuvee_par = auth.uid(), approuvee_le = now(),
         empreintes = case when p_accepter then empreintes end    -- refusée : les empreintes ne servent plus (IR2-15)
   where id = d.id;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.purge_' || case when p_accepter then 'approuvee' else 'refusee' end,
                         'communication_demande_purge', d.id::text, null, null);
  return jsonb_build_object('ok', true);
end;
$$;


-- 4.8 L'ARRÊT D'URGENCE (Phase 1.3.1, corrigé en D5 le 20/11/2026). Conception complète et preuves :
-- docs/communication-center/PHASE_1_3_1_KILL_SWITCH_DESIGN.md (section « D5 »).
--
-- RÈGLE : un arrêt n'est déclaré RÉUSSI (STOP_CONFIRMED, état arret_confirme) que si
--   (1) N0 a été obtenu en EXCLUSIF après la demande (ou dans sa transaction) : aucune
--       transaction autorisée n'était alors en cours, et toute transaction qui demande N0 ensuite
--       lit l'état d'arrêt et refuse ;
--   (2) plus aucune requête déjà validée n'attend d'être transmise par pg_net ;
--   (3) l'état est écrit avec synchronous_commit = on (durable avant la réponse).
-- D5 (P-07, revue finale RF-01) : la DEMANDE et le CONSTAT sont deux appels, donc deux
-- transactions. arreter_communications n'écrit QUE la demande et la valide : rien de ce qui
-- arrive ensuite (constat en erreur, délai d'exécution dépassé, schéma de pg_net absent, recul
-- d'horloge, client coupé) ne peut plus l'annuler. confirmer_arret_communications (l'écran,
-- toutes les quelques secondes) et le travailleur (au début de chaque passage) font le constat.
-- Écrire la demande n'exige pas N0 : la porte prend N0 partagé PUIS lit l'état ; toute porte
-- qui lit après le COMMIT de la demande refuse. N0 exclusif ne sert qu'à PROUVER que les portes
-- ouvertes avant la demande ont fini — c'est le rôle du constat.
-- Réponses : STOP_REQUESTED (demande écrite), STOP_CONFIRMED, STOP_PENDING (demande écrite,
-- arrêt pas encore prouvé), STOP_NOT_CONFIRMED (cet appel n'a rien pu écrire : réessayer).
-- Ordre des verrous : la demande prend la ligne d'arrêt seule ; le constat et la levée prennent
-- N0 (exclusif, tenté) PUIS la ligne. Le constat verrouille en plus, par
-- communication_observer_sorties, des lignes de communication_envois et de
-- communication_modeles_meta, UNIQUEMENT en SKIP LOCKED : il n'attend jamais une de ces lignes
-- (P-01, P-02 ; preuve : PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md).
-- version : +1 à chaque appui, à chaque changement d'état (fermeture des autorisations,
-- confirmation, levée) ; jamais pour une simple tentative de confirmation.

-- Le constat commun, appelé par les fonctions ci-dessous, la ligne d'arrêt DÉJÀ verrouillée.
-- p_n0_exclusif : la transaction appelante tient-elle N0 en exclusif ?
create or replace function public.communication_conclure_arret(p_n0_exclusif boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.communication_arret;
  v_transmissions integer;
  v_partages integer;
  v_closes timestamptz;
begin
  select * into a from public.communication_arret;               -- verrouillée par l'appelant
  if not found then
    raise exception 'ARRET_LIGNE_ABSENTE';                       -- jamais « confirmé » sur une table vide (IR2-11)
  end if;
  if a.etat = 'actif' then
    return jsonb_build_object('etat', 'STOP_NOT_REQUESTED', 'version', a.version);
  end if;
  if a.etat = 'arret_confirme' then
    return jsonb_build_object('etat', 'STOP_CONFIRMED', 'confirme_le', a.confirme_le, 'version', a.version);
  end if;
  -- (1) Les autorisations : seulement sous N0 exclusif
  v_closes := a.autorisations_closes_le;
  if v_closes is null then
    if not p_n0_exclusif then
      -- Indication (non une preuve) : verrous consultatifs PARTAGÉS détenus en ce moment
      select count(*) into v_partages from pg_catalog.pg_locks l
       where l.locktype = 'advisory' and l.mode = 'ShareLock' and l.granted;
      update public.communication_arret
         set tentatives = tentatives + 1, derniere_tentative_le = clock_timestamp(),
             derniere_raison = 'VERROU_NON_OBTENU', maj_le = clock_timestamp();
      return jsonb_build_object('etat', 'STOP_PENDING', 'raison', 'VERROU_NON_OBTENU',
                                'transactions_autorisees_actives_indicatif', v_partages,
                                'demande_le', a.demande_le, 'version', a.version);
    end if;
    -- D5 : jamais avant la demande, même si l'horloge du serveur a reculé (contrainte de la table)
    v_closes := greatest(clock_timestamp(), a.demande_le);
    update public.communication_arret
       set autorisations_closes_le = v_closes, version = version + 1, maj_le = clock_timestamp();
  end if;
  -- (2) Les requêtes déjà validées qui peuvent encore partir (43 §13, lecture seule de pg_net) —
  -- comptées par requête, à partir du moment où on les a VUES quitter la file (IR2-01)
  perform public.communication_observer_sorties();
  v_transmissions := public.communication_transmissions_en_cours();
  if v_transmissions > 0 then
    update public.communication_arret
       set tentatives = tentatives + 1, derniere_tentative_le = clock_timestamp(),
           derniere_raison = 'TRANSMISSIONS_EN_COURS', maj_le = clock_timestamp();
    return jsonb_build_object('etat', 'STOP_PENDING', 'raison', 'TRANSMISSIONS_EN_COURS',
                              'transmissions_en_cours', v_transmissions, 'demande_le', a.demande_le);
  end if;
  update public.communication_arret
     set etat = 'arret_confirme', confirme_le = greatest(clock_timestamp(), v_closes), tentatives = tentatives + 1,
         derniere_tentative_le = clock_timestamp(), derniere_raison = null, version = version + 1,
         maj_le = clock_timestamp();
  perform public.auditer('communication.arret_confirme', 'communication_arret', 'arret', null, null);
  return jsonb_build_object('etat', 'STOP_CONFIRMED', 'confirme_le', clock_timestamp(),
                            'version', (select version from public.communication_arret));
end;
$$;

-- Couper : administrateur ET gérant (communications.pause — couper ne peut que protéger).
-- D5 (P-07) : écrit la DEMANDE, et rien d'autre. Ne prend PAS N0 (aucune attente derrière les
-- envois en cours) ; seulement la ligne d'arrêt, 5 s au plus (un autre arrêt ou une levée).
-- L'écran appelle ensuite confirmer_arret_communications jusqu'à STOP_CONFIRMED.
create or replace function public.arreter_communications(p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.communication_arret;
  v_trouve boolean;
begin
  perform public.exiger_permission('communications.pause');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Dites pourquoi vous coupez tout (5 caractères au moins).');
  end if;
  perform set_config('synchronous_commit', 'on', true);          -- la demande est durable au COMMIT
  -- 5 s au plus pour la ligne (sous les 8 s du rôle authenticated, mesurés le 20/11/2026)
  perform set_config('lock_timeout', '5s', true);
  begin
    select * into a from public.communication_arret for update;
    v_trouve := found;
  exception when lock_not_available then
    return jsonb_build_object('etat', 'STOP_NOT_CONFIRMED', 'raison', 'ARRET_CONCURRENT_EN_COURS',
                              'conseil', 'Réessayez : un autre arrêt ou une levée est en cours. Rien n''a été écrit.');
  end;
  if not v_trouve then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;
  -- CHAQUE appui est daté, compté (version) et journalisé, même si l'arrêt est déjà demandé ou
  -- confirmé (IR2-03) : une levée commencée avant cet appui le verra et refusera
  update public.communication_arret
     set derniere_demande_le = clock_timestamp(), version = version + 1, maj_le = clock_timestamp();
  perform set_config('goship.motif', left(trim(p_motif), 300), true);
  perform public.auditer('communication.arret_appui', 'communication_arret', 'arret', null,
                         jsonb_build_object('etat', a.etat));
  -- La DEMANDE, écrite si elle ne l'est pas déjà (jamais « confirmée » ici)
  if a.etat = 'actif' then
    update public.communication_arret
       set etat = 'arret_demande', demande_le = clock_timestamp(), demande_par = auth.uid(),
           motif = left(trim(p_motif), 300),                          -- jamais d'échec à cause du texte (IR2-04)
           autorisations_closes_le = null, confirme_le = null, tentatives = 0, derniere_tentative_le = null,
           derniere_raison = null, leve_le = null, leve_par = null, motif_levee = null, maj_le = clock_timestamp();
    perform public.auditer('communication.arret_demande', 'communication_arret', 'arret', null, null);
  end if;
  return jsonb_build_object(
    'etat', case when a.etat = 'arret_confirme' then 'STOP_CONFIRMED' else 'STOP_REQUESTED' end,
    'version', (select version from public.communication_arret),
    'suite', 'confirmer_arret_communications');
end;
$$;

-- Terminer un arrêt DEMANDÉ : le constat (même règle, même ordre des verrous). Appelée par
-- l'écran (après la demande, puis à intervalles) et, sans attente, par le travailleur au début
-- de chaque passage (communication_confirmer_arret_auto).
-- D5 (P-07) : le constat est dans un bloc qui rattrape toute erreur, annulation comprise : un
-- constat impossible répond STOP_PENDING / CONSTAT_IMPOSSIBLE, jamais un faux succès. La
-- demande, validée par l'appel précédent, n'est jamais touchée.
create or replace function public.confirmer_arret_communications()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n0 boolean;
  v_trouve boolean;
  v_resultat jsonb;
  v_etat text;
begin
  perform public.exiger_permission('communications.pause');
  perform set_config('synchronous_commit', 'on', true);
  -- 3 s pour N0, puis 2 s pour la ligne (sous les 8 s du rôle)
  perform set_config('lock_timeout', '3s', true);
  begin
    perform public.communication_verrou_interrupteurs(true);
    v_n0 := true;
  exception when lock_not_available then
    v_n0 := false;                                               -- PAS de contournement : on le dira
  end;
  perform set_config('lock_timeout', '2s', true);
  begin
    perform 1 from public.communication_arret for update;
    v_trouve := found;
  exception when lock_not_available then
    return jsonb_build_object('etat', 'STOP_NOT_CONFIRMED', 'raison', 'ARRET_CONCURRENT_EN_COURS');
  end;
  if not v_trouve then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;
  -- D5 (P-03) : plus de « lock_timeout = 0 » : le constat ne doit attendre aucune ligne (SKIP
  -- LOCKED) ; si une attente imprévue survenait, elle s'arrêterait à 2 s (erreur rattrapée)
  v_etat := null;
  begin
    v_resultat := public.communication_conclure_arret(v_n0);
  exception
    when query_canceled then                                     -- délai d'exécution, annulation
      v_etat := '57014';
    when others then
      get stacked diagnostics v_etat = returned_sqlstate;
  end;
  if v_etat is not null then                                     -- le bloc a été annulé, rien d'autre
    update public.communication_arret
       set tentatives = tentatives + 1, derniere_tentative_le = clock_timestamp(),
           derniere_raison = 'CONSTAT_IMPOSSIBLE:' || v_etat, maj_le = clock_timestamp();
    v_resultat := jsonb_build_object('etat', 'STOP_PENDING', 'raison', 'CONSTAT_IMPOSSIBLE', 'code', v_etat);
  end if;
  return v_resultat || jsonb_build_object('n0_exclusif_obtenu', v_n0);
end;
$$;

-- La même, sans permission ni attente : appelée par le travailleur (procédure, 43 §8.6), qui ne
-- tient alors AUCUN verrou. Tentative non bloquante de N0 exclusif (pg_try_advisory_xact_lock).
create or replace function public.communication_confirmer_arret_auto()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n0 boolean;
begin
  if (select etat from public.communication_arret) <> 'arret_demande' then
    return null;
  end if;
  perform set_config('synchronous_commit', 'on', true);
  v_n0 := pg_try_advisory_xact_lock(hashtextextended('goship-communication:interrupteurs', 0));
  perform 1 from public.communication_arret for update nowait;   -- une autre tentative en cours : on laisse
  return public.communication_conclure_arret(v_n0);
exception when lock_not_available then
  return null;
end;
$$;

-- L'état, pour l'écran (communications.view) : rien n'est modifié.
create or replace function public.etat_arret_communications()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.view');
  return (select to_jsonb(a) - 'demande_par' - 'leve_par' from public.communication_arret a)
         || jsonb_build_object('transmissions_en_cours', public.communication_transmissions_en_cours());
end;
$$;

-- Lever l'arrêt : administrateur seulement, motif de 10 caractères au moins, journalisé.
-- D5 : (1) la levée exige la VERSION de l'état que son écran a affichée (p_version_attendue) :
-- si un appui sur « Arrêt » ou un changement d'état a eu lieu depuis, elle refuse
-- (STOP_STATE_CHANGED) — même un appui écrit juste avant son début mais validé pendant son
-- attente (cas que le seul contrôle par l'heure laissait passer) ; (2) attentes bornées à
-- 3 s + 3 s (sous les 8 s du rôle authenticated, mesurés le 20/11/2026), puis BUSY.
-- Les envois en attente repartent SOUS TOUTES LES RÈGLES (consentement, heures, empreinte de la
-- campagne…) ; une campagne qui ne doit pas reprendre s'annule ou se met en pause avant.
drop function if exists public.lever_arret_communications(text);
create or replace function public.lever_arret_communications(p_motif text, p_version_attendue bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.communication_arret;
  v_debut timestamptz := clock_timestamp();
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_motif, ''))) < 10 then
    perform public.erreur_metier('REASON_REQUIRED', 'Dites pourquoi l''envoi peut reprendre (10 caractères au moins).');
  end if;
  if p_version_attendue is null then
    perform public.erreur_metier('VERSION_REQUIRED', 'Rechargez l''état de l''arrêt avant de le lever.');
  end if;
  perform set_config('lock_timeout', '3s', true);                -- jamais d'attente sans fin (IR2-03, P-03)
  begin
    perform public.communication_verrou_interrupteurs(true);
    select * into a from public.communication_arret for update;
  exception when lock_not_available then
    perform public.erreur_metier('BUSY', 'Des envois ou un autre arrêt sont en cours : réessayez dans quelques secondes.');
  end;
  if a.etat is null then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;
  if a.etat = 'actif' then
    perform public.erreur_metier('INVALID_TRANSITION', 'Aucun arrêt d''urgence en cours.');
  end if;
  -- D5 : l'état n'est plus celui que l'écran a montré
  if a.version <> p_version_attendue then
    perform public.erreur_metier('STOP_STATE_CHANGED',
      'L''état de l''arrêt a changé depuis l''affichage : vérifiez la situation avant de relever.');
  end if;
  -- IR2-03 (gardé en plus) : quelqu'un a appuyé sur « Arrêt » pendant que cette levée attendait
  if a.derniere_demande_le > v_debut then
    perform public.erreur_metier('STOP_REQUESTED_DURING_LIFT',
      'Un arrêt a été demandé pendant la levée : vérifiez la situation avant de relever.');
  end if;
  update public.communication_arret
     set etat = 'actif', autorisations_closes_le = null, confirme_le = null, leve_le = clock_timestamp(),
         leve_par = auth.uid(), motif_levee = trim(p_motif), version = version + 1, maj_le = clock_timestamp();
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.arret_leve', 'communication_arret', 'arret',
                         jsonb_build_object('etat', a.etat), jsonb_build_object('etat', 'actif'));
  return jsonb_build_object('ok', true, 'etat', 'actif', 'version', a.version + 1);
end;
$$;

-- 4.9 Ce que prouve une réponse HTTP d'erreur (Phase 1.3, correction 4) : seulement avec la
-- page officielle du fournisseur. Une 5xx ne prouve JAMAIS un refus : elle ne peut être
-- notée qu'« incertain ». « rejet_temporaire » (nouvel essai automatique) : 4xx seulement.
create or replace function public.verifier_issue_http(p_fournisseur text, p_code integer, p_issue text, p_preuve text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_preuve, ''))) < 10 then
    perform public.erreur_metier('PROOF_REQUIRED', 'Citez la page officielle du fournisseur et sa date.');
  end if;
  if p_code >= 500 and p_issue <> 'incertain' then
    perform public.erreur_metier('UNSAFE_RULE', 'Une réponse 5xx ne prouve pas que le message a été refusé : « incertain » seulement.');
  end if;
  perform set_config('lock_timeout', '3s', true);             -- D5 (P-03, RF-07) : jamais d'attente sans fin
  begin
    perform public.communication_verrou_interrupteurs(true);   -- N0 exclusif : réglage d'envoi (1.3, C1)
  exception when lock_not_available then
    perform public.erreur_metier('BUSY', 'Des envois sont en cours : réessayez dans quelques secondes.');
  end;
  perform set_config('lock_timeout', '2s', true);
  insert into public.communication_issues_http (fournisseur, code_http, issue, preuve, verifie_par)
  values (p_fournisseur, p_code, p_issue, trim(p_preuve), auth.uid())
  on conflict (fournisseur, code_http) do update
    set issue = excluded.issue, preuve = excluded.preuve, verifie_par = excluded.verifie_par, verifie_le = now();
  perform set_config('goship.motif', trim(p_preuve), true);
  perform public.auditer('communication.issue_http', 'communication_issue_http', p_fournisseur || ':' || p_code, null,
                         jsonb_build_object('issue', p_issue));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.10 Les fuseaux horaires (Phase 1.3, correction 6) -------------------------------------------------
-- Un État des USA à UN SEUL fuseau : administrateur, avec la preuve (base IANA, date). Un État
-- à plusieurs fuseaux ne s'enregistre pas : ses clients déclarent le leur.
create or replace function public.regler_fuseau_region(p_region text, p_fuseau text, p_preuve text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_preuve, ''))) < 10 then
    perform public.erreur_metier('PROOF_REQUIRED', 'Citez la source (base IANA, date) et confirmez que l''État n''a qu''un fuseau.');
  end if;
  if not public.communication_fuseau_valide(p_fuseau) then
    perform public.erreur_metier('INVALID_TIMEZONE', 'Nom de fuseau inconnu (exemple : America/Chicago).');
  end if;
  insert into public.communication_fuseaux_regions (pays, region, fuseau, preuve, verifie_par)
  values ('US', trim(p_region), p_fuseau, trim(p_preuve), auth.uid())
  on conflict (pays, region) do update
    set fuseau = excluded.fuseau, preuve = excluded.preuve, verifie_par = excluded.verifie_par, verifie_le = now();
  perform set_config('goship.motif', trim(p_preuve), true);
  perform public.auditer('communication.fuseau_region', 'communication_fuseau', 'US:' || trim(p_region), null,
                         jsonb_build_object('fuseau', p_fuseau));
  return jsonb_build_object('ok', true);
end;
$$;

-- Le client déclare SON fuseau (Mon compte, Phase 2c) ; l'équipe peut le noter pour lui, s'il
-- le lui a dit (communications.consents, motif). Valable tant que pays et région ne changent pas.
create or replace function public.declarer_fuseau_communication(p_fuseau text, p_client uuid default null, p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid := coalesce(p_client, auth.uid());
  cl record;
begin
  if p_client is null then
    if auth.uid() is null or not exists (select 1 from public.clients where id = auth.uid() and role = 'client' and supprime_le is null) then
      perform public.erreur_metier('PERMISSION_DENIED', 'Réservé à l''espace client.');
    end if;
  else
    perform public.exiger_permission('communications.consents');
    if length(trim(coalesce(p_motif, ''))) < 5 then
      perform public.erreur_metier('REASON_REQUIRED', 'Dites comment le client vous a donné son fuseau.');
    end if;
  end if;
  if not public.communication_fuseau_valide(p_fuseau) then
    perform public.erreur_metier('INVALID_TIMEZONE', 'Fuseau inconnu.');
  end if;
  select pays, region into cl from public.clients where id = v_client and supprime_le is null;
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Compte introuvable.');
  end if;
  insert into public.communication_fuseaux_clients (client_id, fuseau, source, pays, region, auteur_id)
  values (v_client, p_fuseau, case when p_client is null then 'client' else 'equipe' end, cl.pays, cl.region, auth.uid())
  on conflict (client_id) do update
    set fuseau = excluded.fuseau, source = excluded.source, pays = excluded.pays, region = excluded.region,
        auteur_id = excluded.auteur_id, cree_le = now();
  if p_client is not null then
    perform set_config('goship.motif', trim(p_motif), true);
    perform public.auditer('communication.fuseau_client', 'client', v_client::text, null, jsonb_build_object('fuseau', p_fuseau));
  end if;
  return jsonb_build_object('ok', true, 'fuseau', p_fuseau);
end;
$$;


-- 5. Droits ----------------------------------------------------------------------------------------
revoke execute on function public.communication_mots_confirmation() from public, anon, authenticated, service_role;
revoke execute on function public.communication_suivre_client() from public, anon, authenticated, service_role;
revoke execute on function public.communication_conclure_arret(boolean) from public, anon, authenticated, service_role;
revoke execute on function public.communication_confirmer_arret_auto() from public, anon, authenticated, service_role;

-- La confirmation par lien est la seule fonction de ce fichier ouverte SANS compte (à ajouter à
-- la liste blanche de controle-securite.sql, section 6) : protégée par un jeton aléatoire de
-- 256 bits, à usage unique et à durée limitée — la clé publique de Supabase n'autorise rien.
revoke execute on function public.confirmer_consentement_communication(text) from public;
grant execute on function public.confirmer_consentement_communication(text) to anon, authenticated;

do $droits$
declare
  f text;
begin
  foreach f in array array[
    'public.mes_consentements_communication(text)',
    'public.demander_consentement_communication(text, text, text, text)',
    'public.retirer_mon_consentement_communication(text, text)',
    'public.consentements_client(uuid)',
    'public.retirer_consentement_client(uuid, text, text)',
    'public.ajouter_suppression_communication(uuid, text, text)',
    'public.ecrire_texte_consentement(text, text, text, text)',
    'public.attester_texte_consentement(text, text, text, text)',
    'public.regler_communications(jsonb, text)',
    'public.verifier_quota_brevo(integer, integer, integer, boolean, text)',
    'public.regler_whatsapp_commercial(text, integer, text)',
    'public.valider_identite_expediteur(text, text, text)',
    'public.verifier_tarif_communication(text, text, text, text, numeric, text)',
    'public.verifier_indicatif_communication(text, text, boolean, text)',
    'public.regler_destinataire_essai(uuid, text, boolean, text)',
    'public.lever_suppression_communication(bigint, text)',
    'public.regler_conservation_communication(text, integer, text, text, text)',
    'public.demander_purge_communication(text, text, uuid, text)',
    'public.approuver_purge_communication(bigint, boolean, text)',
    'public.arreter_communications(text)',
    'public.confirmer_arret_communications()',
    'public.etat_arret_communications()',
    'public.lever_arret_communications(text, bigint)',
    'public.verifier_issue_http(text, integer, text, text)',
    'public.regler_fuseau_region(text, text, text)',
    'public.declarer_fuseau_communication(text, uuid, text)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$droits$;
-- ===== FIN DU CONTENU INERTE =====
$brouillon_goship_non_executable$ as brouillon_non_executable;
