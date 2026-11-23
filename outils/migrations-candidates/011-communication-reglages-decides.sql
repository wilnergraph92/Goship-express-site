-- CANDIDATE LOCALE — Communication Center, réglages décidés le 23/11/2026.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Dépend de 003-communication-consentements.sql.
--
-- Pourquoi un fichier séparé : la candidate 003 laisse volontairement ses seuils
-- à NULL, et ses RPC échouent fermé (POLICY_UNCONFIGURED) tant qu'aucune décision
-- ne les fixe. Les valeurs ci-dessous sont celles des décisions H2 et H3
-- (docs/communication-center/COMMUNICATION_CENTER_DECISIONS_DELEGUEES.md), qui
-- reprennent les choix analysés en D5 (N-02). Elles ne remplacent JAMAIS une
-- valeur déjà réglée : un Admin qui a changé un seuil le garde.
--
--   expiration_secondes          3600   code valable 60 min
--   maximum_tentatives           5      au 5e code faux...
--   portee_tentatives            contact ...toutes les demandes ouvertes du numéro sont annulées
--   fenetre_tentatives_secondes  3600   les essais comptent sur la durée de validité
--   fenetre_demandes_secondes    86400  plafonds de demandes sur 24 h
--   maximum_demandes_compte      3      par compte (D5 : 3 demandes par 24 h)
--   maximum_demandes_contact     3      par numéro, quel que soit le compte
--   politique_contact_partage    bloquer  numéro partagé : aucune demande (règle D2 prudente)
--
-- Limite connue : D5 prévoyait aussi « au plus une demande par minute et par
-- compte ». La table de 003 n'a pas de réglage pour cela ; le plafond de 3 par
-- 24 h borne déjà les demandes répétées.
begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.communication_consentement_reglages') is null then
    raise exception 'COMMUNICATION_C11_DEPENDENCY_MISSING';
  end if;
end
$garde$;

insert into public.communication_consentement_reglages (id)
values (true)
on conflict (id) do nothing;

update public.communication_consentement_reglages
   set expiration_secondes         = coalesce(expiration_secondes, 3600),
       maximum_tentatives          = coalesce(maximum_tentatives, 5),
       portee_tentatives           = coalesce(portee_tentatives, 'contact'),
       fenetre_tentatives_secondes = coalesce(fenetre_tentatives_secondes, 3600),
       fenetre_demandes_secondes   = coalesce(fenetre_demandes_secondes, 86400),
       maximum_demandes_compte     = coalesce(maximum_demandes_compte, 3),
       maximum_demandes_contact    = coalesce(maximum_demandes_contact, 3),
       politique_contact_partage   = coalesce(politique_contact_partage, 'bloquer'),
       maj_le                      = pg_catalog.clock_timestamp()
 where id is true
   and (expiration_secondes is null or maximum_tentatives is null
        or portee_tentatives is null or fenetre_tentatives_secondes is null
        or fenetre_demandes_secondes is null or maximum_demandes_compte is null
        or maximum_demandes_contact is null or politique_contact_partage is null);

-- Empreinte lue par outils/production/controle-securite.sql (section 12).
comment on column public.communication_consentement_reglages.politique_contact_partage is
  'Numéro partagé entre comptes : « bloquer » par défaut, décision D2 du 23/11/2026 (candidate 011).';

commit;
