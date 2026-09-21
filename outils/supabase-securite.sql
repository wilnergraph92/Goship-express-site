-- =============================================================================
-- Goship Express — renforcement de la sécurité (20/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, et le script peut
-- être relancé autant de fois qu'on veut.
--
-- Ce fichier est déjà inclus dans outils/supabase.sql (partie 13) : si vous
-- relancez le fichier complet, vous n'avez pas besoin de celui-ci.
--
-- Ce qu'il corrige :
--   1. Les notifications sur téléphone ne peuvent plus être déclenchées que par
--      le tableau de bord (avant : par n'importe quel client connecté).
--   2. Un téléphone qui change de main ne reçoit plus les colis de l'ancien
--      propriétaire ; au plus 10 téléphones par client.
--   3. Un client ne peut plus modifier que les champs qui le regardent dans ses
--      pré-alertes (ni leur statut, ni le colis rattaché).
--   4. Nom, adresse, téléphone… sont bornés en longueur, à l'inscription comme
--      à la modification.
--   5. Les fonctions internes ne sont plus appelables depuis le site.
-- =============================================================================


-- 1. Notifications sur téléphone : tableau de bord uniquement -------------------

create or replace function public.pousser_colis(p_colis uuid, p_evenement text default 'maj')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_colis    public.colis;
  v_code     text;
  v_messages jsonb := '[]'::jsonb;
  v_requete  bigint;
  a          record;
begin
  -- Réservé au tableau de bord (et aux automatismes de la base, qui n'ont pas de
  -- compte) : sans cela, n'importe quel client connecté pourrait faire sonner le
  -- téléphone d'un autre client.
  if auth.uid() is not null and not public.est_admin() then
    raise exception 'Accès réservé aux administrateurs' using errcode = '42501';
  end if;
  select * into v_colis from public.colis where id = p_colis;
  if not found or v_colis.client_id is null then
    return 'sans-client';
  end if;
  select code into v_code from public.clients where id = v_colis.client_id;

  for a in select * from public.appareils where client_id = v_colis.client_id loop
    v_messages := v_messages || jsonb_build_object(
      'to', a.jeton,
      'title', public.texte_statut(v_colis.statut, a.langue),
      'body', coalesce(nullif(v_colis.description, ''), v_colis.numero) || ' · ' || v_colis.numero,
      'sound', 'default',
      'channelId', 'colis',
      'priority', 'high',
      'data', jsonb_build_object('colis_id', v_colis.id, 'evenement', p_evenement)
    );
  end loop;

  if jsonb_array_length(v_messages) = 0 then
    return 'sans-appareil';
  end if;

  select net.http_post(
    url := 'https://exp.host/--/api/v2/push/send',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Accept', 'application/json'),
    body := v_messages
  ) into v_requete;

  insert into public.notifications (colis_id, canal, evenement, destinataire, requete)
  values (p_colis, 'push', p_evenement, coalesce(v_code, ''), v_requete);
  return 'envoye';
end;
$$;


-- 2. Téléphones : un seul propriétaire à la fois --------------------------------
-- L'application n'écrit plus directement dans la table : elle passe par cette
-- fonction, qui vérifie le jeton et rattache le téléphone au client connecté.
-- Un téléphone revendu ou prêté cesse donc de recevoir les colis de l'ancien
-- propriétaire dès que le nouveau se connecte.

create or replace function public.enregistrer_appareil(p_jeton text,
                                                       p_plateforme text default '',
                                                       p_langue text default 'fr')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid := auth.uid();
begin
  if v_client is null then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  -- Un vrai jeton Expo, pas une valeur inventée
  if coalesce(p_jeton, '') !~ '^Ex(ponent)?PushToken\[[A-Za-z0-9_%+/=.-]{1,200}\]$' then
    raise exception 'Jeton de notification invalide' using errcode = '22023';
  end if;

  delete from public.appareils where jeton = p_jeton and client_id <> v_client;

  insert into public.appareils (client_id, jeton, plateforme, langue, maj_le)
  values (v_client, p_jeton,
          left(coalesce(p_plateforme, ''), 20),
          case when p_langue in ('fr', 'en', 'es', 'ht') then p_langue else 'fr' end,
          now())
  on conflict (jeton) do update
    set plateforme = excluded.plateforme, langue = excluded.langue, maj_le = now();

  -- Au plus 10 téléphones par client : les plus anciens sont oubliés
  delete from public.appareils
   where client_id = v_client
     and id not in (select id from public.appareils
                     where client_id = v_client
                     order by maj_le desc
                     limit 10);
end;
$$;

revoke execute on function public.enregistrer_appareil(text, text, text) from public, anon;
grant execute on function public.enregistrer_appareil(text, text, text) to authenticated;

-- L'application ne peut plus écrire en direct (elle garde la lecture et la
-- suppression de ses propres téléphones, pour la déconnexion)
revoke insert, update on public.appareils from authenticated;


-- 3. Pré-alertes : seuls les champs du client sont modifiables -------------------
-- Avant : un client pouvait marquer sa pré-alerte « reçue » ou la rattacher au
-- colis de quelqu'un d'autre. Le rapprochement reste fait par la base seule.

revoke insert, update on public.prealertes from authenticated;
grant insert (client_id, magasin, description, suivi_transporteur, valeur_usd, service)
  on public.prealertes to authenticated;
grant update (magasin, description, suivi_transporteur, valeur_usd, service)
  on public.prealertes to authenticated;


-- 4. Longueurs bornées -----------------------------------------------------------
-- Le profil était borné à l'inscription, mais pas lors des modifications : un
-- compte pouvait y ranger des textes énormes.

create or replace function public.borner_profil_client()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.nom_complet := left(trim(coalesce(new.nom_complet, '')), 120);
  new.pays        := left(upper(trim(coalesce(new.pays, ''))), 2);
  new.region      := left(trim(coalesce(new.region, '')), 80);
  new.ville       := left(trim(coalesce(new.ville, '')), 80);
  new.adresse     := left(trim(coalesce(new.adresse, '')), 200);
  new.telephone   := left(trim(coalesce(new.telephone, '')), 40);
  new.email       := left(trim(coalesce(new.email, '')), 160);
  new.langue      := case when new.langue in ('fr', 'en', 'es', 'ht') then new.langue else 'fr' end;
  return new;
end;
$$;

drop trigger if exists borner_profil_client on public.clients;
create trigger borner_profil_client
  before insert or update on public.clients
  for each row execute function public.borner_profil_client();

create or replace function public.borner_prealerte()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_en_cours integer;
begin
  new.magasin            := left(trim(coalesce(new.magasin, '')), 80);
  new.description        := left(trim(coalesce(new.description, '')), 300);
  new.suivi_transporteur := left(upper(trim(coalesce(new.suivi_transporteur, ''))), 60);

  if tg_op = 'INSERT' then
    select count(*) into v_en_cours
      from public.prealertes
     where client_id = new.client_id and statut = 'attente';
    if v_en_cours >= 60 then
      raise exception 'Trop de pré-alertes en attente' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists borner_prealerte on public.prealertes;
create trigger borner_prealerte
  before insert or update on public.prealertes
  for each row execute function public.borner_prealerte();


-- 5. Fonctions internes fermées au site -------------------------------------------
-- PostgreSQL ouvre par défaut l'exécution des nouvelles fonctions à tout le monde ;
-- on referme celles qui n'ont rien à faire dans les mains d'un visiteur.

revoke execute on function public.est_admin() from public, anon;
revoke execute on function public.borner_profil_client() from public, anon, authenticated;
revoke execute on function public.borner_prealerte() from public, anon, authenticated;
revoke execute on function public.preparer_facture() from public, anon, authenticated;
revoke execute on function public.rapprocher_prealerte() from public, anon, authenticated;
revoke execute on function public.pousser_au_changement() from public, anon, authenticated;
revoke execute on function public.telephone_international(text, text) from public, anon, authenticated;
revoke execute on function public.formater_code_client(bigint) from public, anon, authenticated;
revoke execute on function public.texte_statut(text, text) from public, anon;
grant execute on function public.est_admin() to authenticated;
grant execute on function public.texte_statut(text, text) to authenticated;


-- 6. Facultatif : numéros de colis imprévisibles -----------------------------------
-- Les numéros se suivent (GSE-1001-HT, GSE-1002-HT…) : n'importe qui peut donc
-- essayer les numéros voisins sur la page « Suivre mon colis » et voir passer
-- toute l'activité de l'entreprise (statuts, destinations, dates). Aucune donnée
-- personnelle n'est exposée, mais le volume d'affaires, lui, l'est.
--
-- Pour que les nouveaux colis reçoivent un numéro tiré au hasard
-- (GSE-48207391-HT), enlevez les deux tirets au début des lignes suivantes et
-- relancez ce fichier. Les colis déjà enregistrés gardent leur numéro.
--
-- create or replace function public.preparer_colis()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = ''
-- as $$
-- declare
--   v_numero text;
-- begin
--   if tg_op = 'INSERT' then
--     if coalesce(trim(new.numero), '') = '' then
--       loop
--         v_numero := 'GSE-' || (10000000 + floor(random() * 90000000))::bigint || '-' || new.pays_destination;
--         exit when not exists (select 1 from public.colis where numero = v_numero);
--       end loop;
--       new.numero := v_numero;
--     end if;
--     new.numero := upper(trim(new.numero));
--     new.cree_le := now();
--   else
--     new.numero := old.numero;
--     new.cree_le := old.cree_le;
--   end if;
--   new.recu_le := coalesce(new.recu_le, now());
--   new.suivi_transporteur := upper(trim(new.suivi_transporteur));
--   new.maj_le := now();
--   return new;
-- end;
-- $$;
-- revoke execute on function public.preparer_colis() from public, anon, authenticated;


-- Fin. Rien d'autre à faire ici : les réglages restants (confirmation des
-- adresses e-mail, adresses de retour autorisées, longueur des mots de passe)
-- se font dans les écrans de Supabase. Voir README.md, « Sécurité ».
