-- =============================================================================
-- Goship Express — contrôle d'intégrité des données (Phase 12)
--
-- LECTURE SEULE. Ne corrige rien : une anomalie se lit, se comprend, puis se
-- corrige par la voie prévue (événement CORRECTION, annulation de paiement ou de
-- facture), jamais par un UPDATE écrit à la main. À lancer dans Supabase >
-- SQL Editor avant et après chaque mise en production, et après une restauration.
-- Une seule requête : le SQL Editor n'affiche que le résultat de la dernière.
--
-- Chaque ligne : controle | verdict | nombre | exemples
--   ALERTE  une règle que la base garantit est rompue : à comprendre avant d'aller plus loin
--   INFO    à relire (données anciennes, antérieures aux règles actuelles, par exemple)
--   OK      rien à signaler
--
-- Les « exemples » ne montrent que des numéros (colis, factures) ou des
-- identifiants, jamais un nom, une adresse ou un montant.
-- =============================================================================

with
controles(ordre, controle, gravite, nombre, exemples) as (
  -- 1. Rattachements : chaque ligne pointe vers ce qui existe
  select 1, 'Colis sans client', 'ALERTE', count(*),
         string_agg(c.numero, ', ' order by c.numero)
    from public.colis c where not exists (select 1 from public.clients k where k.id = c.client_id)
  union all
  select 1, 'Événements sans colis', 'ALERTE', count(*), string_agg(h.id::text, ', ' order by h.id)
    from public.colis_historique h where not exists (select 1 from public.colis c where c.id = h.colis_id)
  union all
  select 1, 'Factures sans client', 'ALERTE', count(*), string_agg(f.numero, ', ' order by f.numero)
    from public.factures f where not exists (select 1 from public.clients k where k.id = f.client_id)
  union all
  select 1, 'Lignes de facture sans facture', 'ALERTE', count(*), string_agg(l.id::text, ', ' order by l.id)
    from public.facture_lignes l where not exists (select 1 from public.factures f where f.id = l.facture_id)
  union all
  select 1, 'Lignes de facture vers un colis disparu', 'ALERTE', count(*), string_agg(l.id::text, ', ' order by l.id)
    from public.facture_lignes l
   where l.colis_id is not null and not exists (select 1 from public.colis c where c.id = l.colis_id)
  union all
  select 1, 'Paiements sans facture', 'ALERTE', count(*), string_agg(p.id::text, ', ')
    from public.paiements p where not exists (select 1 from public.factures f where f.id = p.facture_id)
  union all
  select 1, 'Paiements d''un autre client que la facture', 'ALERTE', count(*), string_agg(f.numero, ', ')
    from public.paiements p join public.factures f on f.id = p.facture_id
   where p.client_id is distinct from f.client_id
  union all
  select 1, 'Notifications sans client', 'ALERTE', count(*), string_agg(n.id::text, ', ' order by n.id)
    from public.notifications n
   where n.client_id is not null and not exists (select 1 from public.clients k where k.id = n.client_id)
  union all
  select 1, 'Envois sans notification', 'ALERTE', count(*), string_agg(e.id::text, ', ' order by e.id)
    from public.notification_envois e
   where not exists (select 1 from public.notifications n where n.id = e.notification_id)
  union all
  select 1, 'Téléphones sans client', 'INFO', count(*), null
    from public.appareils a where not exists (select 1 from public.clients k where k.id = a.client_id)
  union all
  -- 2. Identifiants uniques : aucun doublon
  select 2, 'Codes clients en double', 'ALERTE', count(*), string_agg(code, ', ')
    from (select code from public.clients where code is not null group by code having count(*) > 1) d
  union all
  select 2, 'Numéros de colis en double', 'ALERTE', count(*), string_agg(numero, ', ')
    from (select numero from public.colis group by numero having count(*) > 1) d
  union all
  select 2, 'Numéros de facture en double', 'ALERTE', count(*), string_agg(numero, ', ')
    from (select numero from public.factures group by numero having count(*) > 1) d
  union all
  select 2, 'Clés de paiement en double', 'ALERTE', count(*), null
    from (select cle_idempotence from public.paiements where cle_idempotence is not null
           group by cle_idempotence having count(*) > 1) d
  union all
  select 2, 'Clés de notification en double', 'ALERTE', count(*), null
    from (select cle from public.notifications where cle is not null group by cle having count(*) > 1) d
  union all
  -- 3. Argent : le payé d'une facture est la somme de ses paiements non annulés,
  -- jamais plus que son total ; un colis n'est que sur une facture active
  select 3, 'Payé ≠ somme des paiements', 'ALERTE', count(*), string_agg(f.numero, ', ' order by f.numero)
    from public.factures f
   where abs(coalesce(f.montant_paye_usd, 0) - coalesce((select sum(p.montant_usd) from public.paiements p
                                                          where p.facture_id = f.id and p.annule_le is null), 0)) > 0.005
  union all
  select 3, 'Factures payées au-delà du total', 'ALERTE', count(*), string_agg(f.numero, ', ' order by f.numero)
    from public.factures f where coalesce(f.montant_paye_usd, 0) > f.montant_usd + 0.005
  union all
  select 3, 'Montants négatifs', 'ALERTE', count(*), null
    from (select id from public.factures where montant_usd < 0 or coalesce(montant_paye_usd, 0) < 0
          union all select id from public.paiements where montant_usd <= 0) d
  union all
  select 3, 'Statut « payée » incohérent', 'ALERTE', count(*), string_agg(f.numero, ', ' order by f.numero)
    from public.factures f
   where f.statut <> 'annulee'
     and ((f.statut = 'payee') <> (f.montant_usd > 0 and coalesce(f.montant_paye_usd, 0) >= f.montant_usd - 0.005))
  union all
  select 3, 'Colis sur deux factures actives', 'ALERTE', count(*), string_agg(numero, ', ')
    from (select c.numero from public.facture_lignes l
            join public.factures f on f.id = l.facture_id and f.statut <> 'annulee'
            join public.colis c on c.id = l.colis_id
           group by c.numero having count(distinct f.id) > 1) d
  union all
  -- Total arrêté à la création = lignes + frais de service. Les factures sans ligne
  -- (saisies avant les lignes de facture) sont laissées de côté.
  select 3, 'Total ≠ lignes + frais', 'INFO', count(*), string_agg(f.numero, ', ' order by f.numero)
    from public.factures f
   where exists (select 1 from public.facture_lignes l where l.facture_id = f.id)
     and abs(f.montant_usd - (select sum(l.montant_usd * coalesce(l.quantite, 1))
                                from public.facture_lignes l where l.facture_id = f.id)
                           - coalesce(f.frais_service_usd, 0)) > 0.005
  union all
  select 3, 'Factures d''avant le 22/09/2026 sans frais de service', 'INFO', count(*),
         'voulu : leur total ne devait pas changer rétroactivement'
    from public.factures where cree_le < '2026-09-22' and coalesce(frais_service_usd, 0) = 0
  union all
  -- 4. Colis : le statut est celui du dernier événement (corrections comprises)
  select 4, 'Statut ≠ dernier événement', 'INFO', count(*), string_agg(c.numero, ', ' order by c.numero)
    from public.colis c
   where exists (select 1 from public.colis_historique h where h.colis_id = c.id)
     and c.statut <> coalesce((select h.statut from public.colis_historique h
                                where h.colis_id = c.id and h.statut is not null
                                  and not public.evenement_corrige(h.id)
                                order by h.id desc limit 1), c.statut)
  union all
  select 4, 'Colis sans aucun événement', 'INFO', count(*), string_agg(c.numero, ', ' order by c.numero)
    from public.colis c where not exists (select 1 from public.colis_historique h where h.colis_id = c.id)
  union all
  -- 5. Files d'attente : rien ne doit rester coincé
  select 5, 'Envois en attente depuis plus de 15 min', 'ALERTE', count(*), null
    from public.notification_envois where statut = 'attente' and prochain_essai_le < now() - interval '15 minutes'
  union all
  select 5, 'Envois bloqués « en cours » depuis plus de 10 min', 'ALERTE', count(*), null
    from public.notification_envois where statut = 'envoi' and verrouille_le < now() - interval '10 minutes'
  union all
  select 5, 'Envois en échec (24 h)', 'INFO', count(*),
         (select string_agg(code_erreur || ' ×' || n, ', ') from
            (select coalesce(code_erreur, '?') code_erreur, count(*) n from public.notification_envois
              where statut = 'echec' and maj_le > now() - interval '24 hours' group by 1) x)
    from public.notification_envois where statut = 'echec' and maj_le > now() - interval '24 hours'
  union all
  -- traite_le est posé par le déclencheur notifier_evenement_facturation, dans la
  -- transaction qui crée l'événement. Ceux d'avant l'installation des notifications
  -- (actives_depuis) n'ont jamais eu de déclencheur et restent vides pour toujours :
  -- les compter en alerte ferait sonner le contrôle chaque semaine pour rien.
  select 5, 'Événements de facturation non traités (15 min)', 'ALERTE', count(*), null
    from public.evenements_facturation
   where traite_le is null and cree_le < now() - interval '15 minutes'
     and cree_le >= coalesce((select actives_depuis from public.notification_moteur limit 1), '-infinity')
  union all
  select 5, 'Événements de facturation d''avant les notifications (jamais traités, voulu)', 'INFO', count(*), null
    from public.evenements_facturation
   where traite_le is null
     and cree_le < coalesce((select actives_depuis from public.notification_moteur limit 1), '-infinity')
)
select controle,
       case when nombre = 0 then 'OK' else gravite end as verdict,
       nombre,
       case when nombre = 0 then '' else left(coalesce(exemples, ''), 200) end as exemples
  from controles
 order by ordre, case when nombre = 0 then 2 when gravite = 'ALERTE' then 0 else 1 end, controle;
