-- =============================================================================
-- Goship Express — corrections du tableau de bord (12/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE trois colonnes (vides) et remplace des fonctions. Il ne change aucune
-- donnée existante — aucun colis ne reçoit de ville, de poids ni d'adresse qu'il
-- n'avait pas, aucune facture ne change d'un centime — et peut être relancé autant
-- de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-frais-service.sql. Il remplace des fonctions de supabase-services.sql :
-- relancer celui-là impose de relancer ce fichier ensuite (la règle de la chaîne).
--
-- Ce qui change :
--   1. Prix fixé à la main : le poids n'est plus exigé pour calculer un prix qui
--      ne se calcule pas. Il reste obligatoire au prix calculé (poids × tarif). Un
--      poids saisi est toujours > 0 et ≤ 10 000 lb : jamais de poids à zéro.
--   2. Le pays ET la ville de livraison sont obligatoires pour un nouveau colis
--      (et pour un colis dont on change la destination). Un ancien colis sans
--      ville reste tel quel et reste modifiable : on ne lui invente rien.
--      L'adresse de livraison (adresse_livraison) est un champ du colis, distinct
--      de l'adresse personnelle du client : c'est elle, et elle seule, que
--      l'étiquette imprime.
--   3. Historique des modifications : le journal d'audit garde le motif d'une
--      modification, ne se modifie ni ne s'efface plus, garde aussi l'échéance et
--      la note d'une facture ; modifier_facture remplace l'écriture directe du
--      tableau de bord (motif obligatoire pour corriger un montant, date de
--      rectification sur la facture) ; historique_modifications le rend lisible,
--      pour audit_logs.view seulement.
--
-- Les notifications (e-mail, WhatsApp) ne changent pas ici : la base les crée
-- déjà elle-même (supabase-notifications.sql). C'est le tableau de bord qui
-- appelait encore les anciennes fonctions d'envoi, fermées depuis.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. colonnes : colis.adresse_livraison, factures.rectifiee_le, journal_audit.motif
--    3. auditer : le motif de la transaction
--    4. le journal ne se modifie ni ne s'efface
--    5. regles_colis : poids selon le mode de prix, ville obligatoire
--    6. creer_colis : l'adresse de livraison
--    7. modifier_colis : l'adresse de livraison et le motif
--    8. factures : date de rectification, échéance et note au journal
--    9. modifier_facture
--   10. historique_modifications
--   11. la vue colis_details, refaite
--   12. droits
--   13. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.frais_service_interne(uuid, boolean)') is null
     or to_regprocedure('public.regles_colis()') is null
     or to_regprocedure('public.modifier_colis(uuid, jsonb, timestamptz)') is null
     or to_regprocedure('public.nom_compte(uuid)') is null
     or to_regclass('public.journal_audit') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Colonnes ----------------------------------------------------------------------
-- Toutes vides pour les lignes existantes : rien n'est deviné après coup.
alter table public.colis add column if not exists adresse_livraison text not null default '';
comment on column public.colis.adresse_livraison is
  'Adresse de livraison du colis (rue, quartier, repère), saisie par l''équipe ; jamais copiée du profil du client';

alter table public.factures add column if not exists rectifiee_le timestamptz;
comment on column public.factures.rectifiee_le is
  'Date de la dernière correction du montant d''une facture émise ; null = montant d''origine';

alter table public.journal_audit add column if not exists motif text not null default '';


-- 3. Le motif d'une modification ----------------------------------------------------
-- Une fonction de service pose le motif pour la durée de sa transaction
-- (set_config(..., true)) ; chaque ligne du journal écrite par les déclencheurs
-- de cette transaction le reprend. Hors de ces fonctions, le motif est vide.
create or replace function public.auditer(p_action text, p_entite text, p_entite_id text,
                                          p_avant jsonb, p_apres jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.journal_audit (auteur_id, action, entite, entite_id, avant, apres, motif)
  values (auth.uid(), p_action, p_entite, coalesce(p_entite_id, ''), p_avant, p_apres,
          left(coalesce(current_setting('goship.motif', true), ''), 300));
end;
$$;


-- 4. Le journal ne se modifie ni ne s'efface ------------------------------------------
-- Personne n'y écrit déjà directement (les droits sont fermés) ; ce déclencheur
-- ferme aussi la porte à un compte qui aurait les droits du propriétaire. Une
-- erreur dans le journal se corrige par une nouvelle ligne, jamais en réécrivant
-- l'ancienne.
create or replace function public.journal_immuable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.erreur_metier('AUDIT_LOG_LOCKED',
    'Le journal des modifications ne se modifie ni ne s''efface.');
  return null;
end;
$$;

drop trigger if exists journal_immuable on public.journal_audit;
create trigger journal_immuable
  before update or delete on public.journal_audit
  for each row execute function public.journal_immuable();
drop trigger if exists journal_immuable_vider on public.journal_audit;
create trigger journal_immuable_vider
  before truncate on public.journal_audit
  for each statement execute function public.journal_immuable();


-- 5. Règles des colis ---------------------------------------------------------------
-- La règle de supabase-services.sql (partie 7), avec trois changements :
--   - le poids n'est obligatoire qu'au prix calculé (poids × tarif). Un prix fixé à
--     la main n'a pas besoin de poids ; un poids saisi reste > 0 et ≤ 10 000 lb. On
--     revient au prix calculé : il faut alors un poids ;
--   - la ville de livraison est obligatoire à la création, et quand la destination
--     (pays ou ville) change : un pays sans ville ne s'enregistre plus ;
--   - l'adresse de livraison est nettoyée et bornée comme les autres textes.
-- À la modification, un champ n'est contrôlé que s'il change : un vieux colis sans
-- poids ni ville reste modifiable.

create or replace function public.regles_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  t jsonb := public.tarifs();
  v_nouveau boolean := tg_op = 'INSERT';
  v_fixe boolean := new.prix_fixe_usd is not null;
  v_autre text;
  v_precedent text;
begin
  -- Textes nettoyés et bornés, comme le profil client
  new.description := left(trim(coalesce(new.description, '')), 300);
  new.expediteur  := left(trim(coalesce(new.expediteur, '')), 80);
  new.destination := left(trim(coalesce(new.destination, '')), 80);
  new.adresse_livraison := left(trim(coalesce(new.adresse_livraison, '')), 160);
  new.lieu        := left(trim(coalesce(new.lieu, '')), 80);
  new.note        := left(trim(coalesce(new.note, '')), 300);
  new.suivi_transporteur := left(coalesce(new.suivi_transporteur, ''), 60);

  -- Client : un vrai client, pas un compte de l'équipe
  if v_nouveau or new.client_id is distinct from old.client_id then
    if v_nouveau and new.client_id is null then
      perform public.erreur_metier('CLIENT_NOT_FOUND', 'Choisissez le client à qui appartient ce colis.');
    end if;
    if new.client_id is not null
       and not exists (select 1 from public.clients where id = new.client_id and role = 'client') then
      perform public.erreur_metier('CLIENT_NOT_FOUND', 'Aucun client avec cet identifiant.');
    end if;
  end if;

  if (v_nouveau or new.description is distinct from old.description) and new.description = '' then
    perform public.erreur_metier('INVALID_DESCRIPTION', 'Décrivez le contenu du colis.');
  end if;

  -- Poids. Saisi : toujours plus de zéro, jamais absurde. Absent : permis quand le
  -- prix est fixé à la main, puisque rien ne se calcule alors (voir plus bas, au
  -- calcul du prix).
  if new.poids_lb is not null and (v_nouveau or new.poids_lb is distinct from old.poids_lb) then
    if new.poids_lb <= 0 then
      perform public.erreur_metier('INVALID_WEIGHT', 'Le poids doit être supérieur à zéro, en livres.');
    end if;
    -- Au-delà, c'est une faute de frappe : 45 000 lb feraient une facture de
    -- 225 000 $.
    if new.poids_lb > 10000 then
      perform public.erreur_metier('INVALID_WEIGHT', 'Poids supérieur à 10 000 lb : vérifiez la saisie.');
    end if;
  end if;
  if (v_nouveau or new.service is distinct from old.service)
     and coalesce(new.service, '') not in ('aerien', 'maritime', 'terrestre') then
    perform public.erreur_metier('INVALID_SERVICE', 'Service inconnu : aérien, maritime ou terrestre.');
  end if;

  if (v_nouveau or new.pays_destination is distinct from old.pays_destination)
     and coalesce(new.pays_destination, '') not in ('HT', 'DO', 'US') then
    perform public.erreur_metier('INVALID_DESTINATION', 'Destination inconnue : HT, DO ou US.');
  end if;

  -- Ville de livraison : obligatoire dès que la destination se décide (création)
  -- ou change (pays ou ville). Changer de pays sans changer de ville est refusé
  -- par la page ; ici, on refuse au moins une ville vide.
  if (v_nouveau or new.destination is distinct from old.destination
      or new.pays_destination is distinct from old.pays_destination)
     and new.destination = '' then
    perform public.erreur_metier('CITY_REQUIRED', 'Indiquez la ville de livraison du colis.');
  end if;

  if (v_nouveau or new.recu_le is distinct from old.recu_le) and new.recu_le > now() + interval '1 hour' then
    perform public.erreur_metier('INVALID_DATE', 'La date de réception ne peut pas être dans le futur.');
  end if;

  -- Suivi vendeur unique. Le verrou empêche deux enregistrements simultanés du
  -- même numéro de passer chacun le contrôle avant que l'autre soit écrit.
  if new.suivi_transporteur <> ''
     and (v_nouveau or new.suivi_transporteur is distinct from old.suivi_transporteur) then
    perform pg_advisory_xact_lock(hashtextextended('goship-suivi:' || new.suivi_transporteur, 0));
    select numero into v_autre from public.colis
     where suivi_transporteur = new.suivi_transporteur and id <> new.id
     limit 1;
    if v_autre is not null then
      perform public.erreur_metier('TRACKING_ALREADY_EXISTS',
        'Le numéro de suivi ' || new.suivi_transporteur || ' est déjà celui du colis ' || v_autre || '.');
    end if;
  end if;

  -- Prix fixé à la main (prix_fixe_usd) : il remplace poids × tarif. Aucun tarif
  -- à la livre ne s'applique alors (tarif_lb_usd vide, et la facture n'en
  -- affiche pas). Comme un tarif particulier, c'est un geste de facturation
  -- (invoices.edit). prix_usd, lui, n'est toujours jamais pris tel qu'envoyé.
  if v_fixe then
    if (v_nouveau or new.prix_fixe_usd is distinct from old.prix_fixe_usd)
       and (new.prix_fixe_usd < 0 or new.prix_fixe_usd > 100000) then
      perform public.erreur_metier('INVALID_PRICE', 'Le prix du colis doit être compris entre 0 et 100 000 $.');
    end if;
    if auth.uid() is not null and not public.peut('invoices.edit')
       and (v_nouveau or new.prix_fixe_usd is distinct from old.prix_fixe_usd) then
      perform public.erreur_metier('PERMISSION_DENIED',
        'Un prix fixé à la main est réservé à qui peut modifier les factures.');
    end if;
    new.prix_fixe_usd := round(new.prix_fixe_usd, 2);
    new.tarif_lb_usd := null;
    new.prix_usd := new.prix_fixe_usd;
  else
    -- Revenir au prix calculé, pour un colis qui avait un prix fixé : c'est
    -- aussi un geste de facturation.
    if not v_nouveau and old.prix_fixe_usd is not null
       and auth.uid() is not null and not public.peut('invoices.edit') then
      perform public.erreur_metier('PERMISSION_DENIED',
        'Un prix fixé à la main est réservé à qui peut modifier les factures.');
    end if;
    -- Tarif et prix. Le prix n'est jamais accepté tel qu'envoyé : il est
    -- recalculé quand le poids ou le tarif change, et sinon il reste celui qui
    -- a été arrêté — une facture déjà remise ne bouge pas.
    if v_nouveau then
      new.tarif_lb_usd := coalesce(new.tarif_lb_usd, (t ->> 'par_livre')::numeric);
    else
      new.tarif_lb_usd := coalesce(new.tarif_lb_usd, old.tarif_lb_usd, (t ->> 'par_livre')::numeric);
    end if;
    if (v_nouveau or new.tarif_lb_usd is distinct from old.tarif_lb_usd)
       and (new.tarif_lb_usd < 0 or new.tarif_lb_usd > 1000) then
      perform public.erreur_metier('INVALID_RATE', 'Le tarif doit être compris entre 0 et 1 000 $ la livre.');
    end if;
    -- Un tarif autre que celui de la maison change ce que paiera le client :
    -- c'est un geste de facturation (invoices.edit), pas d'entrepôt. Le SQL
    -- Editor, sans compte connecté, reste libre.
    if auth.uid() is not null and not public.peut('invoices.edit')
       and ((v_nouveau and new.tarif_lb_usd is distinct from (t ->> 'par_livre')::numeric)
            or (not v_nouveau and old.prix_fixe_usd is null
                and new.tarif_lb_usd is distinct from old.tarif_lb_usd)) then
      perform public.erreur_metier('PERMISSION_DENIED',
        'Un tarif particulier est réservé à qui peut modifier les factures.');
    end if;
    -- Le prix se recalcule aussi quand on quitte un prix fixé. Jamais sans poids :
    -- poids × tarif ferait 0 $, un prix que personne n'a décidé. Un nouveau colis,
    -- un poids effacé, un tarif changé ou un prix fixé qu'on quitte demandent donc
    -- un poids ; un ancien colis qui n'en a jamais eu garde son prix tel quel.
    if v_nouveau
       or new.poids_lb is distinct from old.poids_lb
       or new.tarif_lb_usd is distinct from old.tarif_lb_usd
       or old.prix_usd is null
       or old.prix_fixe_usd is not null then
      if new.poids_lb is null then
        if v_nouveau
           or old.poids_lb is not null
           or new.tarif_lb_usd is distinct from old.tarif_lb_usd
           or old.prix_fixe_usd is not null then
          perform public.erreur_metier('INVALID_WEIGHT',
            'Indiquez le poids, en livres : le prix se calcule poids × tarif. Sans poids, fixez le prix à la main.');
        end if;
        new.prix_usd := old.prix_usd;
      else
        new.prix_usd := public.prix_transport(new.poids_lb, new.tarif_lb_usd);
      end if;
    else
      new.prix_usd := old.prix_usd;
    end if;
  end if;

  -- Statut. Un colis naît « Reçu » : c'est l'événement initial de son
  -- historique. Ensuite, seule une transition de la matrice est acceptée.
  if v_nouveau then
    if coalesce(new.statut, 'recu') <> 'recu' then
      perform public.erreur_metier('INVALID_STATUS',
        'Un colis est enregistré au statut « Reçu » ; changez ensuite son statut.');
    end if;
    new.statut := 'recu';
  elsif new.statut is distinct from old.statut then
    if not (public.transitions_statut() ? coalesce(new.statut, '')) then
      perform public.erreur_metier('INVALID_STATUS', 'Statut inconnu : ' || coalesce(new.statut, '(vide)') || '.');
    end if;
    v_precedent := public.statut_precedent(new.id, old.statut);
    if not public.transition_permise(old.statut, new.statut, v_precedent) then
      raise log 'goship transition refusee numero=% de=% vers=%', new.numero, old.statut, new.statut;
      perform public.erreur_metier('INVALID_STATUS_TRANSITION',
        public.texte_statut(old.statut) || ' → ' || public.texte_statut(new.statut) ||
        ' : transition interdite pour le colis ' || new.numero || '.');
    end if;
  end if;

  -- « Disponible » dit au client où retirer son colis : sans agence, le
  -- message ne sert à rien.
  if new.statut = 'disponible' and new.lieu = ''
     and (v_nouveau or new.statut is distinct from old.statut or new.lieu is distinct from old.lieu) then
    perform public.erreur_metier('LOCATION_REQUIRED', 'Indiquez l''agence où le client peut retirer son colis.');
  end if;

  -- La clé d'idempotence est celle de la création ; elle ne se change pas.
  if not v_nouveau then
    new.cle_idempotence := old.cle_idempotence;
  end if;
  return new;
end;
$$;


-- 6. Enregistrer un colis ---------------------------------------------------------------
-- creer_colis de supabase-services.sql, avec l'adresse de livraison. Même
-- contrat : { colis, facture, deja }, tout ou rien, clé d'idempotence.
create or replace function public.creer_colis(p_colis jsonb, p_cle text default null,
                                              p_facturer boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_client uuid;
  v_id uuid;
  v_existant public.colis;
  v_facture jsonb;
  v_recu timestamptz;
begin
  perform public.exiger_permission('shipments.create');
  if p_colis is null or jsonb_typeof(p_colis) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Données du colis manquantes.');
  end if;
  if v_cle is not null and length(v_cle) > 80 then
    perform public.erreur_metier('INVALID_INPUT', 'Clé de requête trop longue.');
  end if;
  v_client := public.lire_uuid(p_colis -> 'client_id', 'CLIENT_NOT_FOUND', 'Identifiant de client illisible.');

  -- Requête répétée (double clic, connexion revenue) : on rend le colis déjà
  -- créé. Le verrou couvre le cas où les deux envois arrivent en même temps.
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-colis:' || v_cle, 0));
    select * into v_existant from public.colis where cle_idempotence = v_cle;
    if found then
      if v_existant.client_id is distinct from v_client then
        perform public.erreur_metier('DUPLICATE_OPERATION',
          'Cette requête a déjà servi à enregistrer le colis ' || v_existant.numero || ' pour un autre client.');
      end if;
      raise log 'goship creer_colis repete numero=%', v_existant.numero;
      return jsonb_build_object(
        'colis', public.colis_json(v_existant.id),
        'facture', (select public.facture_json(l.facture_id)
                      from public.facture_lignes l join public.factures f on f.id = l.facture_id
                     where l.colis_id = v_existant.id and f.statut <> 'annulee'
                     order by f.cree_le desc limit 1),
        'deja', true);
    end if;
  end if;

  begin
    v_recu := coalesce(nullif(p_colis ->> 'recu_le', '')::timestamptz, now());
  exception when others then
    perform public.erreur_metier('INVALID_DATE', 'Date de réception illisible.');
  end;

  insert into public.colis (client_id, description, expediteur, suivi_transporteur, poids_lb, service,
                            pays_destination, destination, adresse_livraison, recu_le, tarif_lb_usd,
                            prix_fixe_usd, lieu, note, statut, cle_idempotence)
  values (v_client,
          coalesce(p_colis ->> 'description', ''),
          coalesce(p_colis ->> 'expediteur', ''),
          coalesce(p_colis ->> 'suivi_transporteur', ''),
          public.lire_nombre(p_colis -> 'poids_lb', 'INVALID_WEIGHT', 'Poids illisible.'),
          coalesce(nullif(p_colis ->> 'service', ''), 'aerien'),
          coalesce(nullif(p_colis ->> 'pays_destination', ''), 'HT'),
          coalesce(p_colis ->> 'destination', ''),
          coalesce(p_colis ->> 'adresse_livraison', ''),
          v_recu,
          public.lire_nombre(p_colis -> 'tarif_lb_usd', 'INVALID_RATE', 'Tarif illisible.'),
          public.lire_nombre(p_colis -> 'prix_fixe_usd', 'INVALID_PRICE', 'Prix du colis illisible.'),
          coalesce(nullif(p_colis ->> 'lieu', ''), 'Miami (Medley), FL'),
          coalesce(p_colis ->> 'note', ''),
          'recu',
          v_cle)
  returning id into v_id;

  -- La facture naît avec le colis : c'est la règle de la maison, pas une
  -- facturation à part. Elle ne demande donc pas invoices.create — un employé
  -- qui enregistre un colis produit sa facture, sans pouvoir en faire d'autres.
  if p_facturer then
    v_facture := public.facturer_colis_interne(v_id) -> 'facture';
  end if;

  return jsonb_build_object('colis', public.colis_json(v_id), 'facture', v_facture, 'deja', false);
end;
$$;


-- 7. Modifier un colis ------------------------------------------------------------------
-- modifier_colis de supabase-services.sql, avec l'adresse de livraison et le motif
-- (p_champs.motif, facultatif, 300 caractères au plus) : il accompagne la ligne du
-- journal. Même signature, même réponse : le colis tel que la base l'a enregistré.
-- Le statut n'est pas un champ d'ici : il change par changer_statut_colis.
create or replace function public.modifier_colis(p_id uuid, p_champs jsonb, p_maj_le timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.colis;
  v jsonb := coalesce(p_champs, '{}'::jsonb);
  v_motif_avant text := coalesce(current_setting('goship.motif', true), '');
begin
  perform public.exiger_permission('shipments.edit');
  select * into c from public.colis where id = p_id for update;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Ce colis n''existe plus.');
  end if;
  if p_maj_le is not null and c.maj_le <> p_maj_le then
    perform public.erreur_metier('CONCURRENT_MODIFICATION',
      'Le colis ' || c.numero || ' a été modifié par quelqu''un d''autre entre-temps : rechargez-le.');
  end if;

  perform set_config('goship.motif', left(trim(coalesce(v ->> 'motif', '')), 300), true);
  update public.colis set
    client_id          = case when v ? 'client_id'
                              then public.lire_uuid(v -> 'client_id', 'CLIENT_NOT_FOUND', 'Identifiant de client illisible.')
                              else client_id end,
    description        = case when v ? 'description' then coalesce(v ->> 'description', '') else description end,
    expediteur         = case when v ? 'expediteur' then coalesce(v ->> 'expediteur', '') else expediteur end,
    suivi_transporteur = case when v ? 'suivi_transporteur' then coalesce(v ->> 'suivi_transporteur', '')
                              else suivi_transporteur end,
    poids_lb           = case when v ? 'poids_lb'
                              then public.lire_nombre(v -> 'poids_lb', 'INVALID_WEIGHT', 'Poids illisible.')
                              else poids_lb end,
    service            = case when v ? 'service' then v ->> 'service' else service end,
    pays_destination   = case when v ? 'pays_destination' then v ->> 'pays_destination' else pays_destination end,
    destination        = case when v ? 'destination' then coalesce(v ->> 'destination', '') else destination end,
    adresse_livraison  = case when v ? 'adresse_livraison' then coalesce(v ->> 'adresse_livraison', '')
                              else adresse_livraison end,
    recu_le            = case when v ? 'recu_le' then coalesce(nullif(v ->> 'recu_le', '')::timestamptz, recu_le)
                              else recu_le end,
    tarif_lb_usd       = case when v ? 'tarif_lb_usd'
                              then public.lire_nombre(v -> 'tarif_lb_usd', 'INVALID_RATE', 'Tarif illisible.')
                              else tarif_lb_usd end,
    -- null (ou vide) : revenir au prix calculé ; absent : inchangé
    prix_fixe_usd      = case when v ? 'prix_fixe_usd'
                              then public.lire_nombre(v -> 'prix_fixe_usd', 'INVALID_PRICE', 'Prix du colis illisible.')
                              else prix_fixe_usd end
  where id = p_id;
  perform set_config('goship.motif', v_motif_avant, true);

  return public.colis_json(p_id);
end;
$$;


-- 8. Factures : date de rectification, échéance et note au journal ----------------------
-- Un montant corrigé après l'émission (facture libre : celui d'une facture de colis ne
-- change pas, regles_facture) date la facture « rectifiée » : le document imprimé le
-- dit, au lieu de se présenter comme l'original. Les frais de service et les
-- paiements (contexte_finances) ne sont pas des corrections : ils ne la datent pas.
create or replace function public.rectifier_facture()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.montant_usd is distinct from old.montant_usd and not public.contexte_finances() then
    new.rectifiee_le := now();
  elsif new.rectifiee_le is distinct from old.rectifiee_le then
    new.rectifiee_le := old.rectifiee_le;   -- une page ne la pose ni ne l'efface
  end if;
  return new;
end;
$$;

drop trigger if exists rectifier_facture on public.factures;
create trigger rectifier_facture
  before update on public.factures
  for each row execute function public.rectifier_facture();

-- Le journal d'une facture : les champs financiers, comme avant, plus l'échéance et
-- la note (ce que le client lit sur sa facture). Le lien de paiement n'y est pas :
-- posé à chaque enregistrement de colis, il noierait les vraies modifications.
create or replace function public.journaliser_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb;
  v_finances text[] := array['numero', 'client_id', 'montant_usd', 'frais_service_usd',
                             'montant_paye_usd', 'statut', 'moyen', 'payee_le'];
  v_suivis text[] := v_finances || array['echeance_le', 'note'];
begin
  if tg_op = 'INSERT' then
    perform public.auditer('facture.creation', 'facture', new.id::text, null,
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(new)) e(k, v) where k = any (v_finances)));
  elsif tg_op = 'UPDATE' then
    d := public.difference(
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(old)) e(k, v) where k = any (v_suivis)),
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(new)) e(k, v) where k = any (v_suivis)));
    if d -> 'apres' = '{}'::jsonb then
      return null;
    end if;
    -- Un montant corrigé (hors frais et paiements) reste une modification, même si
    -- l'état de paiement suit : c'est la correction qu'on cherchera au journal.
    perform public.auditer(
      case when (d -> 'apres') ? 'montant_usd' and not public.contexte_finances() then 'facture.modification'
           when (d -> 'apres') ?| array['montant_paye_usd', 'statut', 'moyen', 'payee_le']
           then 'facture.paiement' else 'facture.modification' end,
      'facture', new.id::text, d -> 'avant', d -> 'apres');
  else
    perform public.auditer('facture.suppression', 'facture', old.id::text,
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(old)) e(k, v) where k = any (v_finances)), null);
  end if;
  return null;
end;
$$;


-- 9. Modifier une facture (invoices.edit) ---------------------------------------------
-- Ce que le tableau de bord écrivait directement dans la table, avec un motif :
--   p_champs : { echeance_le, note, lien_paiement, montant_usd } — rien d'autre n'est lu ;
--   p_motif  : obligatoire (5 caractères au moins) pour corriger un montant, facultatif
--              sinon ; il accompagne la ligne du journal.
-- Les règles sont celles de la table (garde_facture, regles_facture), vérifiées ici
-- d'abord pour répondre avant de demander un motif : une facture annulée ne change plus,
-- une facture de colis garde son total, un total ne descend jamais sous ce qui est
-- payé. Les paiements ne sont jamais touchés.
-- Réponse : la facture complète (payé, solde, état, paiements).
create or replace function public.modifier_facture(p_facture uuid, p_champs jsonb, p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.factures;
  v jsonb := coalesce(p_champs, '{}'::jsonb);
  v_motif text := left(trim(coalesce(p_motif, '')), 300);
  v_motif_avant text := coalesce(current_setting('goship.motif', true), '');
  v_montant numeric;
  v_echeance date;
  v_lien text;
begin
  perform public.exiger_permission('invoices.edit');
  if jsonb_typeof(v) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Données de la facture manquantes.');
  end if;
  select * into f from public.factures where id = p_facture for update;
  if not found then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
  end if;

  v_montant := case when v ? 'montant_usd'
                    then public.lire_nombre(v -> 'montant_usd', 'INVALID_AMOUNT', 'Montant illisible.')
                    else f.montant_usd end;
  if v_montant is null or v_montant < 0 or v_montant > 1000000 then
    perform public.erreur_metier('INVALID_AMOUNT', 'Le montant doit être compris entre 0 et 1 000 000 $.');
  end if;
  v_montant := round(v_montant, 2);
  -- Ce qui ne se corrige pas du tout, d'abord : demander un motif pour refuser
  -- ensuite ne servirait à rien. Mêmes refus que les déclencheurs de la table.
  if f.statut = 'annulee' then
    perform public.erreur_metier('INVOICE_LOCKED', 'Une facture annulée ne se modifie plus.');
  end if;
  if v_montant is distinct from f.montant_usd then
    if exists (select 1 from public.facture_lignes where facture_id = f.id and colis_id is not null) then
      perform public.erreur_metier('INVOICE_LOCKED',
        'Le total d''une facture de colis est celui de ses colis et de ses frais : il ne se modifie pas.');
    end if;
    if v_montant < public.paye_usd(f) then
      perform public.erreur_metier('INVALID_AMOUNT',
        'Le nouveau total est inférieur à ce qui est déjà payé (' || to_char(public.paye_usd(f), 'FM999999990.00') || ' $).');
    end if;
    if length(v_motif) < 5 then
      perform public.erreur_metier('REASON_REQUIRED',
        'Indiquez le motif de la correction du montant (5 caractères au moins) : il est gardé au journal.');
    end if;
  end if;

  begin
    v_echeance := case when v ? 'echeance_le' then nullif(v ->> 'echeance_le', '')::date else f.echeance_le end;
  exception when others then
    perform public.erreur_metier('INVALID_DATE', 'Date d''échéance illisible.');
  end;

  v_lien := case when v ? 'lien_paiement' then trim(coalesce(v ->> 'lien_paiement', '')) else f.lien_paiement end;
  if v_lien is distinct from f.lien_paiement and v_lien <> ''
     and (v_lien !~* '^https://[^[:space:]]+$' or length(v_lien) > 500) then
    perform public.erreur_metier('INVALID_INPUT', 'Le lien de paiement doit être une adresse https://.');
  end if;

  perform set_config('goship.motif', v_motif, true);
  update public.factures set
    montant_usd   = v_montant,
    echeance_le   = v_echeance,
    lien_paiement = coalesce(v_lien, ''),
    note          = case when v ? 'note' then left(trim(coalesce(v ->> 'note', '')), 500) else note end
  where id = f.id;
  perform set_config('goship.motif', v_motif_avant, true);

  return public.facture_complete(f.id);
end;
$$;


-- 10. Historique des modifications (audit_logs.view) ------------------------------------
-- Le journal des colis et des factures, lisible : la référence (numéro du colis ou de
-- la facture, même supprimés), l'auteur (nom et rôle), l'avant, l'après, le motif.
--   p_debut, p_fin : bornes de la période (fin exclue) ; null = sans borne ;
--   p_recherche    : un numéro de colis ou de facture, ou un morceau ;
--   p_auteur       : un compte de l'équipe ; p_entite : '', 'colis' ou 'facture' ;
--   p_page, p_par_page : la page (50 par défaut, 200 au plus).
-- Réponse : { total, lignes: [...], auteurs: [{ id, nom, role }] }. Un client, un
-- employé, un gérant : PERMISSION_DENIED, même en appelant la fonction directement.
create or replace function public.historique_modifications(p_debut timestamptz default null,
                                                           p_fin timestamptz default null,
                                                           p_recherche text default '',
                                                           p_auteur uuid default null,
                                                           p_entite text default '',
                                                           p_page integer default 0,
                                                           p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(trim(coalesce(p_recherche, '')));
  v_entite text := coalesce(p_entite, '');
  v_par integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('audit_logs.view');
  if v_entite not in ('', 'colis', 'facture') then
    perform public.erreur_metier('INVALID_INPUT', 'Objet inconnu : colis ou facture.');
  end if;
  v_ref := replace(replace(replace(v_ref, '\', '\\'), '%', '\%'), '_', '\_');

  return (
    with j as (
      select j.id, j.cree_le, j.action, j.entite, j.entite_id, j.auteur_id, j.avant, j.apres, j.motif,
             coalesce(co.numero, fa.numero, j.avant ->> 'numero', j.apres ->> 'numero', '') as reference
        from public.journal_audit j
        left join public.colis co on j.entite = 'colis' and co.id::text = j.entite_id
        left join public.factures fa on j.entite = 'facture' and fa.id::text = j.entite_id
       where j.entite in ('colis', 'facture')
         and (v_entite = '' or j.entite = v_entite)
         and (p_debut is null or j.cree_le >= p_debut)
         and (p_fin is null or j.cree_le < p_fin)
         and (p_auteur is null or j.auteur_id = p_auteur)
    ), t as (
      select * from j where v_ref = '' or upper(j.reference) like '%' || v_ref || '%'
    )
    select jsonb_build_object(
      'total', (select count(*) from t),
      'lignes', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', x.id, 'cree_le', x.cree_le, 'action', x.action, 'entite', x.entite,
                 'entite_id', x.entite_id, 'reference', x.reference, 'auteur_id', x.auteur_id,
                 'auteur', coalesce(nullif(public.nom_compte(x.auteur_id), ''),
                                    case when x.auteur_id is null then 'Système' else '' end),
                 'role_auteur', (select c.role from public.clients c where c.id = x.auteur_id),
                 'avant', x.avant, 'apres', x.apres, 'motif', x.motif)
               order by x.cree_le desc, x.id desc)
          from (select * from t order by cree_le desc, id desc offset v_page * v_par limit v_par) x),
        '[]'::jsonb),
      'auteurs', coalesce((
        select jsonb_agg(jsonb_build_object('id', a.auteur_id, 'nom', public.nom_compte(a.auteur_id),
                                            'role', (select c.role from public.clients c where c.id = a.auteur_id))
               order by public.nom_compte(a.auteur_id))
          from (select distinct auteur_id from public.journal_audit
                 where entite in ('colis', 'facture') and auteur_id is not null) a),
        '[]'::jsonb))
  );
end;
$$;


-- 11. La vue colis_details, refaite --------------------------------------------------------
-- « c.* » y est figé à la création de la vue : sans la refaire, adresse_livraison
-- n'apparaîtrait pas au tableau de bord. Même définition que supabase-services.sql.
drop view if exists public.colis_details;
create view public.colis_details
with (security_invoker = true) as
  select c.*,
         cl.code        as code_client,
         cl.nom_complet as nom_client,
         cl.telephone   as telephone_client,
         cl.email       as email_client,
         cl.adresse     as adresse_client,
         cl.region      as region_client,
         cl.ville       as ville_client,
         cl.pays        as pays_client,
         cl.langue      as langue_client
  from public.colis c
  left join public.clients cl on cl.id = c.client_id;

revoke all on public.colis_details from anon;
grant select on public.colis_details to authenticated, service_role;


-- 12. Droits --------------------------------------------------------------------------------
revoke execute on function public.auditer(text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.journal_immuable() from public, anon, authenticated;
revoke execute on function public.regles_colis() from public, anon, authenticated;
revoke execute on function public.rectifier_facture() from public, anon, authenticated;
revoke execute on function public.journaliser_facture() from public, anon, authenticated;
revoke execute on function public.creer_colis(jsonb, text, boolean) from public, anon;
revoke execute on function public.modifier_colis(uuid, jsonb, timestamptz) from public, anon;
revoke execute on function public.modifier_facture(uuid, jsonb, text) from public, anon;
revoke execute on function public.historique_modifications(timestamptz, timestamptz, text, uuid, text, integer, integer)
  from public, anon;
grant execute on function public.creer_colis(jsonb, text, boolean) to authenticated;
grant execute on function public.modifier_colis(uuid, jsonb, timestamptz) to authenticated;
grant execute on function public.modifier_facture(uuid, jsonb, text) to authenticated;
grant execute on function public.historique_modifications(timestamptz, timestamptz, text, uuid, text, integer, integer)
  to authenticated;


-- 13. Contrôle --------------------------------------------------------------------------------
-- colonnes : 3 ; fonctions : 2 ; ouvertes_aux_visiteurs : false ; journal_protege : 2.
select (select count(*) from information_schema.columns
        where table_schema = 'public'
          and (table_name, column_name) in (('colis', 'adresse_livraison'), ('factures', 'rectifiee_le'),
                                            ('journal_audit', 'motif')))                       as colonnes,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('modifier_facture', 'historique_modifications')) as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('modifier_facture', 'historique_modifications', 'auditer'))           as ouvertes_aux_visiteurs,
       (select count(*) from pg_trigger where tgrelid = 'public.journal_audit'::regclass
          and tgname in ('journal_immuable', 'journal_immuable_vider'))                          as journal_protege;
