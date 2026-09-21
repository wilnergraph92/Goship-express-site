-- =============================================================================
-- Goship Express — format des codes clients : « GSE- » + 4 chiffres (21/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, et le script peut
-- être relancé autant de fois qu'on veut.
--
-- Ce fichier est déjà inclus dans outils/supabase.sql (partie 1) : si vous
-- relancez le fichier complet, vous n'avez pas besoin de celui-ci.
--
-- Avant : « GSE- » suivi de 10 chiffres (GSE-1028370934).
-- Après : « GSE- » suivi de 4 chiffres (GSE-4323).
--
-- Il ne touche que les **nouveaux** comptes. Les codes déjà attribués restent
-- tels quels : un client a pu donner le sien à Amazon, et des colis peuvent
-- déjà porter son ancien code. Voir en bas comment les voir, et comment les
-- changer si vous le voulez vraiment.
-- =============================================================================

-- Code client tiré au hasard : « GSE- » suivi de 4 chiffres (GSE-4323), jamais
-- deux fois le même. 9 000 codes sont possibles (1000 à 9999) : de quoi voir
-- venir, mais ce n'est pas illimité — voir README, « Le format des codes
-- clients », qui explique comment passer à 5 chiffres le jour où il faudra.
create or replace function public.nouveau_code_client()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text;
  v_essais int := 0;
begin
  loop
    v_code := 'GSE-' || (1000 + floor(random() * 9000))::int;
    exit when not exists (select 1 from public.clients where code = v_code);
    v_essais := v_essais + 1;
    -- Sans cette limite, une base presque pleine ferait tourner la boucle sans
    -- fin : la création de compte resterait bloquée, sans rien dire. Mieux vaut
    -- un message clair, qui nomme le problème et la solution.
    if v_essais >= 200 then
      raise exception 'Plus de code client libre au format GSE-0000 : % codes déjà pris sur 9000. Voir README, « Le format des codes clients ».',
        (select count(*) from public.clients where code is not null);
    end if;
  end loop;
  return v_code;
end;
$$;

revoke execute on function public.nouveau_code_client() from public, anon, authenticated;


-- Combien de codes sont pris, et lesquels ne suivent pas le nouveau format
select count(*) filter (where code is not null)                        as codes_attribues,
       count(*) filter (where code ~ '^GSE-[1-9][0-9]{3}$')            as au_nouveau_format,
       count(*) filter (where code is not null
                          and code !~ '^GSE-[1-9][0-9]{3}$')           as a_l_ancien_format,
       9000 - count(*) filter (where code is not null)                 as codes_encore_libres
from public.clients;


-- Changer les codes déjà attribués : à ne faire que si vous êtes sûr que
-- personne n'a encore donné son code à une boutique, et qu'aucun colis n'a été
-- expédié avec. Un client dont le code change ne sera plus reconnu sur les
-- colis déjà en route. Enlevez les deux tirets pour l'utiliser.
--
-- update public.clients
--    set code = public.nouveau_code_client()
--  where code is not null
--    and code !~ '^GSE-[1-9][0-9]{3}$';
