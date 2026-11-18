-- =============================================================================
-- BROUILLON — PHASE 1 DU CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- (voir l'en-tête de 40-supabase-communications-fondation.sql)
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Phase 1 du Centre de communication) : ne pas exécuter.';
end;
$brouillon$;

-- =============================================================================
-- Goship Express — Centre de communication : consentement, suppression, réglages
-- (brouillon du 18/11/2026). À la suite de 40-…-fondation.
--
--   1. Le client : lire et régler SON consentement commercial (« Mon compte », puis
--      l'application). Par défaut : AUCUN consentement (décision D-I). Jamais pré-coché.
--   2. L'équipe : lire l'historique d'un client ; noter un RETRAIT qu'il demande.
--   3. L'administrateur : textes de consentement (approbation juridique), réglages,
--      plafonds, tarifs, destinataires d'essai, levée d'une suppression.
--   4. Les retraits automatiques : changement d'adresse ou de numéro, suppression du
--      compte (déclencheurs EN LECTURE sur clients : ils n'empêchent jamais l'écriture).
-- Chaque écriture de l'équipe va au journal d'audit (auditer), avec son motif.
-- =============================================================================


-- 1. Le client ------------------------------------------------------------------------

-- Ce que « Mon compte » affiche : pour chaque canal, l'état, et le texte à présenter (le
-- dernier texte approuvé par le juriste dans la langue demandée). Pas de texte approuvé :
-- recueil_ouvert = false, la page n'affiche pas la case.
create or replace function public.mes_consentements_communication(p_langue text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_langue text;
  v_resultat jsonb := '[]'::jsonb;
  v_canal text;
  t public.communication_textes_consentement;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client') then
    perform public.erreur_metier('PERMISSION_DENIED', 'Réservé à l''espace client.');
  end if;
  v_langue := coalesce(nullif(p_langue, ''), (select langue from public.clients where id = v_moi), 'fr');
  if v_langue not in ('fr', 'en', 'es', 'ht') then v_langue := 'fr'; end if;
  foreach v_canal in array array['email', 'whatsapp'] loop
    select * into t from public.communication_textes_consentement x
     where x.canal = v_canal and x.langue = v_langue and x.statut = 'approuve_juridique'
     order by x.approuve_le desc limit 1;
    v_resultat := v_resultat || jsonb_build_array(jsonb_build_object(
      'canal', v_canal,
      'accorde', public.communication_consentement_actuel(v_moi, v_canal),
      'joignable', public.communication_cible(v_moi, v_canal) is not null,
      'recueil_ouvert', t.version is not null,
      'version', t.version,
      'texte', t.texte,
      'depuis', (select k.cree_le from public.communication_consentements k
                  where k.client_id = v_moi and k.canal = v_canal
                  order by k.cree_le desc, k.id desc limit 1)));
  end loop;
  return jsonb_build_object('canaux', v_resultat);
end;
$$;

-- Accorder ou retirer. Un accord exige la version EXACTE du texte affiché (approuvé, même
-- langue, même canal) : la preuve dit ce que le client a lu. Un retrait est toujours permis.
-- p_source : 'compte_web' ou 'application', rien d'autre (l'équipe n'accorde jamais).
create or replace function public.regler_mon_consentement_communication(p_canal text, p_accorde boolean,
                                                                       p_version text default null,
                                                                       p_langue text default null,
                                                                       p_source text default 'compte_web')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_cible text;
  t public.communication_textes_consentement;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Réservé à l''espace client.');
  end if;
  if p_canal not in ('email', 'whatsapp') then
    perform public.erreur_metier('INVALID_CHANNEL', 'Canal inconnu.');
  end if;
  if p_source not in ('compte_web', 'application') then
    perform public.erreur_metier('INVALID_SOURCE', 'Origine du choix inconnue.');
  end if;
  -- Même état que demandé : rien à écrire (un double clic ne fait pas deux lignes)
  if public.communication_consentement_actuel(v_moi, p_canal) = coalesce(p_accorde, false) then
    return public.mes_consentements_communication(p_langue);
  end if;
  v_cible := public.communication_cible(v_moi, p_canal);

  if p_accorde then
    if v_cible is null then
      perform public.erreur_metier('NO_TARGET', 'Ajoutez d''abord votre adresse e-mail ou votre numéro WhatsApp à votre profil.');
    end if;
    select * into t from public.communication_textes_consentement x
     where x.version = p_version and x.canal = p_canal and x.langue = coalesce(nullif(p_langue, ''), 'fr')
       and x.statut = 'approuve_juridique';
    if not found then
      perform public.erreur_metier('CONSENT_TEXT_INVALID', 'Ce texte n''est plus en vigueur : rechargez la page.');
    end if;
    insert into public.communication_consentements (client_id, canal, action, source, texte_version, texte_empreinte,
                                                    langue, cible_empreinte, contexte, auteur_id)
    values (v_moi, p_canal, 'accorde', p_source, t.version, t.empreinte, t.langue,
            public.communication_empreinte(p_canal, v_cible), jsonb_build_object('source', p_source), v_moi);
  else
    insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte, auteur_id)
    values (v_moi, p_canal, 'retire', p_source, public.communication_empreinte(p_canal, v_cible), v_moi);
  end if;
  return public.mes_consentements_communication(p_langue);
end;
$$;


-- 2. L'équipe : historique et retrait sur demande ---------------------------------------
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
    'email', public.communication_consentement_actuel(p_client, 'email'),
    'whatsapp', public.communication_consentement_actuel(p_client, 'whatsapp'),
    'historique', coalesce((select jsonb_agg(jsonb_build_object(
        'canal', k.canal, 'action', k.action, 'source', k.source, 'version', k.texte_version,
        'langue', k.langue, 'le', k.cree_le, 'par_equipe', k.auteur_id is distinct from k.client_id,
        'motif', k.motif) order by k.cree_le desc, k.id desc)
      from public.communication_consentements k where k.client_id = p_client), '[]'::jsonb),
    'suppressions', coalesce((select jsonb_agg(jsonb_build_object(
        'canal', s.canal, 'raison', s.raison, 'le', s.cree_le, 'levee_le', s.leve_le) order by s.cree_le desc)
      from public.communication_suppressions s where s.client_id = p_client), '[]'::jsonb));
end;
$$;

-- Le client demande, au téléphone ou au comptoir, à ne plus rien recevoir : l'équipe le note.
-- Retrait seulement ; motif obligatoire (qui a demandé, comment).
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
  insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte, auteur_id, motif)
  values (p_client, p_canal, 'retire', 'equipe_sur_demande',
          public.communication_empreinte(p_canal, public.communication_cible(p_client, p_canal)), auth.uid(), trim(p_motif));
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.consentement_retire', 'client', p_client::text, null,
                         jsonb_build_object('canal', p_canal));
  return public.consentements_client(p_client);
end;
$$;


-- 3. Les retraits automatiques -----------------------------------------------------------
-- Un e-mail ou un numéro qui change : l'accord donné pour l'ancien ne vaut pas pour le
-- nouveau (communication_consentement_actuel le sait déjà par l'empreinte) ; on écrit quand
-- même la ligne « cible_changee » pour que l'historique l'explique. Compte supprimé : retrait
-- sur les deux canaux. Jamais d'échec : l'écriture du client passe toujours.
create or replace function public.communication_suivre_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_canal text;
begin
  begin
    foreach v_canal in array array['email', 'whatsapp'] loop
      if (new.supprime_le is not null and old.supprime_le is null)
         or (v_canal = 'email' and new.email is distinct from old.email)
         or (v_canal = 'whatsapp' and (new.telephone is distinct from old.telephone or new.pays is distinct from old.pays)) then
        if exists (select 1 from public.communication_consentements k where k.client_id = new.id and k.canal = v_canal) then
          insert into public.communication_consentements (client_id, canal, action, source, auteur_id)
          values (new.id, v_canal, 'retire',
                  case when new.supprime_le is not null and old.supprime_le is null then 'suppression_compte' else 'cible_changee' end,
                  auth.uid());
        end if;
      end if;
    end loop;
  exception when others then
    raise warning 'communication_suivre_client : %', sqlerrm;   -- jamais bloquant
  end;
  return new;
end;
$$;
drop trigger if exists communication_suivre_client on public.clients;
create trigger communication_suivre_client
  after update of email, telephone, pays, supprime_le on public.clients
  for each row execute function public.communication_suivre_client();


-- 4. L'administrateur --------------------------------------------------------------------

-- 4.1 Un texte de consentement : écrit en brouillon, puis approuvé avec la référence de l'avis
-- juridique. Un texte approuvé ne se modifie plus : une nouvelle version le remplace.
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
    perform public.erreur_metier('CONSENT_TEXT_LOCKED', 'Ce texte est approuvé ou retiré : créez une nouvelle version.');
  end if;
  insert into public.communication_textes_consentement (version, canal, langue, texte, empreinte)
  values (p_version, p_canal, p_langue, p_texte, encode(extensions.digest(p_texte, 'sha256'), 'hex'))
  on conflict (version, canal, langue) do update set texte = excluded.texte, empreinte = excluded.empreinte;
  perform public.auditer('communication.texte_consentement', 'communication_texte', p_version || ':' || p_canal || ':' || p_langue,
                         null, jsonb_build_object('empreinte', encode(extensions.digest(p_texte, 'sha256'), 'hex')));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.approuver_texte_consentement(p_version text, p_canal text, p_langue text,
                                                               p_reference_juridique text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_reference_juridique, ''))) < 5 then
    perform public.erreur_metier('LEGAL_REFERENCE_REQUIRED',
      'Notez la référence de l''avis du conseil juridique (nom, date) : sans elle, le texte ne peut pas être présenté aux clients.');
  end if;
  update public.communication_textes_consentement
     set statut = 'approuve_juridique', reference_juridique = trim(p_reference_juridique),
         approuve_par = auth.uid(), approuve_le = now()
   where version = p_version and canal = p_canal and langue = p_langue and statut = 'brouillon';
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Aucun brouillon à cette version.');
  end if;
  perform set_config('goship.motif', trim(p_reference_juridique), true);
  perform public.auditer('communication.texte_approuve', 'communication_texte', p_version || ':' || p_canal || ':' || p_langue,
                         null, jsonb_build_object('reference', trim(p_reference_juridique)));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.2 Les réglages : une liste blanche de champs, chaque changement journalisé avec avant/après.
-- Allumer les campagnes ou passer en production exige un motif et les vérifications préalables.
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
  v_permis text[] := array['campagnes_actives', 'mode', 'email_actif', 'whatsapp_actif', 'plafond_jour_usd',
                           'plafond_jour_messages', 'brevo_quota_jour', 'brevo_quota_mois', 'brevo_reserve_jour',
                           'lot_par_minute', 'heure_debut', 'heure_fin', 'frequence_max_jour',
                           'frequence_max_semaine', 'attente_transactionnel_max', 'quatre_yeux'];
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif d''au moins 5 caractères.');
  end if;
  for v_cle in select jsonb_object_keys(coalesce(p_champs, '{}'::jsonb)) loop
    if not v_cle = any (v_permis) then
      perform public.erreur_metier('INVALID_FIELD', 'Réglage inconnu : ' || v_cle);
    end if;
  end loop;
  select * into v_avant from public.communication_reglages for update;
  update public.communication_reglages set
    campagnes_actives = coalesce((p_champs ->> 'campagnes_actives')::boolean, campagnes_actives),
    mode = coalesce(p_champs ->> 'mode', mode),
    email_actif = coalesce((p_champs ->> 'email_actif')::boolean, email_actif),
    whatsapp_actif = coalesce((p_champs ->> 'whatsapp_actif')::boolean, whatsapp_actif),
    plafond_jour_usd = coalesce((p_champs ->> 'plafond_jour_usd')::numeric, plafond_jour_usd),
    plafond_jour_messages = coalesce((p_champs ->> 'plafond_jour_messages')::integer, plafond_jour_messages),
    brevo_quota_jour = case when p_champs ? 'brevo_quota_jour' then (p_champs ->> 'brevo_quota_jour')::integer else brevo_quota_jour end,
    brevo_quota_mois = case when p_champs ? 'brevo_quota_mois' then (p_champs ->> 'brevo_quota_mois')::integer else brevo_quota_mois end,
    brevo_quota_verifie_le = case when p_champs ?| array['brevo_quota_jour', 'brevo_quota_mois'] then now() else brevo_quota_verifie_le end,
    brevo_quota_verifie_par = case when p_champs ?| array['brevo_quota_jour', 'brevo_quota_mois'] then auth.uid() else brevo_quota_verifie_par end,
    brevo_reserve_jour = coalesce((p_champs ->> 'brevo_reserve_jour')::integer, brevo_reserve_jour),
    lot_par_minute = coalesce((p_champs ->> 'lot_par_minute')::integer, lot_par_minute),
    heure_debut = coalesce((p_champs ->> 'heure_debut')::integer, heure_debut),
    heure_fin = coalesce((p_champs ->> 'heure_fin')::integer, heure_fin),
    frequence_max_jour = coalesce((p_champs ->> 'frequence_max_jour')::integer, frequence_max_jour),
    frequence_max_semaine = coalesce((p_champs ->> 'frequence_max_semaine')::integer, frequence_max_semaine),
    attente_transactionnel_max = coalesce((p_champs ->> 'attente_transactionnel_max')::integer, attente_transactionnel_max),
    quatre_yeux = coalesce((p_champs ->> 'quatre_yeux')::boolean, quatre_yeux),
    maj_le = now(), maj_par = auth.uid()
  returning * into v_apres;

  -- Passer en production : l'adresse postale (D-G) doit être validée si l'e-mail est allumé
  if v_apres.mode = 'production' and v_apres.email_actif and v_apres.adresse_postale is null then
    perform public.erreur_metier('POSTAL_ADDRESS_REQUIRED',
      'Un e-mail commercial doit porter l''adresse postale de l''entreprise : faites-la valider (décision D-G) avant la production.');
  end if;
  if v_apres.email_actif and v_apres.brevo_quota_jour is null and v_apres.brevo_quota_mois is null then
    perform public.erreur_metier('BREVO_QUOTA_REQUIRED',
      'Notez d''abord le quota vérifié de l''abonnement Brevo (décision D-C).');
  end if;

  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.reglages', 'communication_reglages', 'reglages',
                         to_jsonb(v_avant), to_jsonb(v_apres));
  return to_jsonb(v_apres);
end;
$$;

-- L'adresse postale de l'entreprise (D-G) : posée par l'administrateur, jamais inventée.
create or replace function public.valider_adresse_postale(p_adresse text, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Dites qui a confirmé cette adresse (décision du CEO).');
  end if;
  update public.communication_reglages
     set adresse_postale = trim(p_adresse), adresse_postale_validee_par = auth.uid(), maj_le = now(), maj_par = auth.uid();
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.adresse_postale', 'communication_reglages', 'adresse_postale', null,
                         jsonb_build_object('adresse', trim(p_adresse)));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.3 Un tarif vérifié sur la grille officielle du fournisseur.
create or replace function public.verifier_tarif_communication(p_fournisseur text, p_canal text, p_categorie text,
                                                               p_pays text, p_prix_usd numeric, p_autorise boolean,
                                                               p_source text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.manage');
  if length(trim(coalesce(p_source, ''))) < 5 then
    perform public.erreur_metier('SOURCE_REQUIRED', 'Notez où le prix a été lu (grille officielle, date).');
  end if;
  insert into public.communication_tarifs (fournisseur, canal, categorie, pays, prix_usd, autorise, source,
                                           verifie, verifie_par, verifie_le)
  values (p_fournisseur, p_canal, p_categorie, p_pays, p_prix_usd, p_autorise, trim(p_source), true, auth.uid(), now())
  on conflict (fournisseur, canal, categorie, pays) do update
    set prix_usd = excluded.prix_usd, autorise = excluded.autorise, source = excluded.source,
        verifie = true, verifie_par = excluded.verifie_par, verifie_le = excluded.verifie_le;
  perform public.auditer('communication.tarif', 'communication_tarif',
                         p_fournisseur || ':' || p_canal || ':' || p_categorie || ':' || p_pays, null,
                         jsonb_build_object('prix_usd', p_prix_usd, 'autorise', p_autorise, 'source', trim(p_source)));
  return jsonb_build_object('ok', true);
end;
$$;

-- 4.4 La liste d'essai : un compte de l'équipe, ou un client qui a consenti sur ce canal.
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
    perform public.erreur_metier('CONSENT_REQUIRED',
      'Un client ne devient destinataire d''essai que s''il a lui-même consenti sur ce canal.');
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

-- 4.5 Lever une suppression (erreur de saisie, demande écrite du client) : ne rend pas le
-- consentement.
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
     set leve_le = now(), leve_par = auth.uid(), motif_levee = trim(p_motif)
   where id = p_suppression and leve_le is null;
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Suppression introuvable ou déjà levée.');
  end if;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.suppression_levee', 'communication_suppression', p_suppression::text, null, null);
  return jsonb_build_object('ok', true);
end;
$$;


-- 5. Droits -------------------------------------------------------------------------------
revoke execute on function public.communication_suivre_client() from public, anon, authenticated;

revoke execute on function public.mes_consentements_communication(text) from public, anon;
revoke execute on function public.regler_mon_consentement_communication(text, boolean, text, text, text) from public, anon;
revoke execute on function public.consentements_client(uuid) from public, anon;
revoke execute on function public.retirer_consentement_client(uuid, text, text) from public, anon;
revoke execute on function public.ecrire_texte_consentement(text, text, text, text) from public, anon;
revoke execute on function public.approuver_texte_consentement(text, text, text, text) from public, anon;
revoke execute on function public.regler_communications(jsonb, text) from public, anon;
revoke execute on function public.valider_adresse_postale(text, text) from public, anon;
revoke execute on function public.verifier_tarif_communication(text, text, text, text, numeric, boolean, text) from public, anon;
revoke execute on function public.regler_destinataire_essai(uuid, text, boolean, text) from public, anon;
revoke execute on function public.lever_suppression_communication(bigint, text) from public, anon;

grant execute on function public.mes_consentements_communication(text) to authenticated;
grant execute on function public.regler_mon_consentement_communication(text, boolean, text, text, text) to authenticated;
grant execute on function public.consentements_client(uuid) to authenticated;
grant execute on function public.retirer_consentement_client(uuid, text, text) to authenticated;
grant execute on function public.ecrire_texte_consentement(text, text, text, text) to authenticated;
grant execute on function public.approuver_texte_consentement(text, text, text, text) to authenticated;
grant execute on function public.regler_communications(jsonb, text) to authenticated;
grant execute on function public.valider_adresse_postale(text, text) to authenticated;
grant execute on function public.verifier_tarif_communication(text, text, text, text, numeric, boolean, text) to authenticated;
grant execute on function public.regler_destinataire_essai(uuid, text, boolean, text) to authenticated;
grant execute on function public.lever_suppression_communication(bigint, text) to authenticated;
