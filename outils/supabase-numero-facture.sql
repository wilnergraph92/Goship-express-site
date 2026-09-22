-- =============================================================================
-- Goship Express — nouveau format des numéros de facture (22/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, aucune facture
-- existante n'est modifiée, et le script peut être relancé autant de fois
-- qu'on veut.
--
-- Avant : FAC-2026-0003  (année, puis un compteur qui ne repart jamais)
-- Après : 2026-09-0417    (année, mois, quatre chiffres tirés au hasard)
--
-- Il ne touche que les **nouvelles** factures. Celles déjà remises à un client
-- gardent leur numéro : c'est celui qu'il a sous les yeux, et celui qu'il
-- mentionnera en payant.
-- =============================================================================

-- Numéro de facture : année, mois, quatre chiffres tirés au hasard, jamais
-- deux fois le même. 10 000 numéros par mois — de quoi voir venir, et le
-- compteur repart à chaque mois.
create or replace function public.preparer_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numero text;
  v_essais int := 0;
begin
  if coalesce(trim(new.numero), '') = '' then
    loop
      v_numero := to_char(now(), 'YYYY-MM') || '-'
                  || lpad(floor(random() * 10000)::int::text, 4, '0');
      exit when not exists (select 1 from public.factures where numero = v_numero);
      v_essais := v_essais + 1;
      -- Sans cette limite, un mois déjà bien rempli ferait tourner la boucle
      -- sans fin : la facture ne s'enregistrerait plus, sans rien dire.
      if v_essais >= 200 then
        raise exception 'Plus de numéro de facture libre pour %  : % numéros déjà pris sur 10 000.',
          to_char(now(), 'YYYY-MM'),
          (select count(*) from public.factures
           where numero like to_char(now(), 'YYYY-MM') || '-%');
      end if;
    end loop;
    new.numero := v_numero;
  end if;
  if new.statut = 'payee' and new.payee_le is null then
    new.payee_le := now();
  end if;
  return new;
end;
$$;

drop trigger if exists preparer_facture on public.factures;
create trigger preparer_facture
  before insert or update on public.factures
  for each row execute function public.preparer_facture();

revoke execute on function public.preparer_facture() from public, anon, authenticated;

-- L'ancien compteur public.numero_facture_seq n'est plus utilisé. On le laisse
-- en place sans y toucher : le supprimer casserait une base où ce script
-- n'aurait pas encore été lancé.


-- Contrôle : combien de factures portent chaque format
select count(*) filter (where numero ~ '^[0-9]{4}-[0-9]{2}-[0-9]{4}$') as au_nouveau_format,
       count(*) filter (where numero ~ '^FAC-')                        as a_l_ancien_format,
       count(*)                                                        as factures_en_tout,
       10000 - count(*) filter (where numero like to_char(now(), 'YYYY-MM') || '-%')
                                                                       as numeros_libres_ce_mois
from public.factures;
