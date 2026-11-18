-- =============================================================================
-- BROUILLON — CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- Version Phase 1.2 (18/11/2026) — voir l'en-tête de 40-supabase-communications-fondation.sql
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.2) : ne pas exécuter.';
end;
$brouillon$;

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
as $$
declare
  v_moi uuid := auth.uid();
  r public.communication_reglages;
  t public.communication_textes_consentement;
  v_cible text;
  v_empreinte text;
  v_id bigint;
  v_code text;
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

  if p_canal = 'whatsapp' then
    -- Code court tiré par un générateur cryptographique ; il ne suffit jamais seul : le
    -- message doit AUSSI venir du numéro dont l'empreinte est celle de la demande (43 §7).
    v_code := lpad(((('x' || encode(extensions.gen_random_bytes(2), 'hex'))::bit(16)::integer) % 10000)::text, 4, '0');
  end if;
  insert into public.communication_confirmations (consentement_id, client_id, canal, cible_empreinte, code, expire_le)
  values (v_id, v_moi, p_canal, v_empreinte, v_code, clock_timestamp() + make_interval(hours => r.confirmation_validite_h));
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
as $$
declare
  f public.communication_confirmations;
  k public.communication_consentements;
begin
  if coalesce(p_jeton, '') !~ '^[A-Za-z0-9_-]{43}$' then
    return jsonb_build_object('ok', false);                      -- contrôle bon marché avant toute lecture
  end if;
  select * into f from public.communication_confirmations
   where jeton_empreinte = encode(extensions.digest(p_jeton, 'sha256'), 'hex') for update;
  if not found or f.utilise_le is not null or f.annule_le is not null or f.expire_le < now() then
    return jsonb_build_object('ok', false);
  end if;
  perform public.communication_verrou('consentement:' || f.client_id || ':' || f.canal);
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
declare
  v_canal text;
  v_ancienne text;
  v_change boolean;
begin
  begin
    foreach v_canal in array array['email', 'whatsapp'] loop
      v_change := (new.supprime_le is not null and old.supprime_le is null)
               or (v_canal = 'email' and public.communication_normaliser('email', new.email)
                                         is distinct from public.communication_normaliser('email', old.email))
               or (v_canal = 'whatsapp' and public.telephone_international(new.telephone, new.pays)
                                            is distinct from public.telephone_international(old.telephone, old.pays));
      if v_change and exists (select 1 from public.communication_consentements k
                               where k.client_id = new.id and k.canal = v_canal) then
        perform public.communication_verrou('consentement:' || new.id || ':' || v_canal);
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
    end loop;
  exception when others then
    begin
      insert into public.communication_erreurs (source, code, detail)
      values ('communication_suivre_client', sqlstate, left(sqlerrm, 300));
    exception when others then
      null;                                        -- même le journal en échec ne bloque pas le client
    end;
    raise warning 'communication_suivre_client : %', sqlstate;
  end;
  return new;
end;
$$;
drop trigger if exists communication_suivre_client on public.clients;
create trigger communication_suivre_client
  after update of email, telephone, pays, supprime_le on public.clients
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
                           'quatre_yeux', 'adresse_miami_validee'];
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
     set statut = case when p_accepter then 'approuvee' else 'refusee' end, approuvee_par = auth.uid(), approuvee_le = now()
   where id = d.id;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.purge_' || case when p_accepter then 'approuvee' else 'refusee' end,
                         'communication_demande_purge', d.id::text, null, null);
  return jsonb_build_object('ok', true);
end;
$$;


-- 5. Droits ----------------------------------------------------------------------------------------
revoke execute on function public.communication_mots_confirmation() from public, anon, authenticated;
revoke execute on function public.communication_suivre_client() from public, anon, authenticated;

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
    'public.approuver_purge_communication(bigint, boolean, text)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$droits$;
