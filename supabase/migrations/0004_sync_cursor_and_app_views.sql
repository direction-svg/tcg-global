-- 0004 — Curseur de synchronisation + vues publiques pour l'app
-- Ajoute :
--   * la valeur 'PRICECHARTING' à l'enum de source de prix (si absente)
--   * la table tcg_global.sync_cursor (reprise des backfills par lots)
--   * la vue public.app_collection consommée par l'app mobile (docs/index.html)

-- 1) Source de prix PriceCharting -------------------------------------------
-- price_point.source utilise l'enum tcg_global.source_app.
do $$
begin
  if not exists (
    select 1 from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'tcg_global' and t.typname = 'source_app' and e.enumlabel = 'PRICECHARTING'
  ) then
    alter type tcg_global.source_app add value 'PRICECHARTING';
  end if;
end$$;

-- 2) Curseur de synchronisation ---------------------------------------------
create table if not exists tcg_global.sync_cursor (
  job        text primary key,
  pos        integer not null default 0,
  total      integer,
  done       boolean not null default false,
  updated_at timestamptz not null default now()
);

insert into tcg_global.sync_cursor(job, pos, done)
values ('pricecharting', 0, false)
on conflict (job) do nothing;

-- 3) Vue publique consommée par l'app ---------------------------------------
-- Expose la collection (source_app='OJA') à plat, avec image et les 3 prix
-- de référence (JP brut, EN brut, PSA 10). L'app calcule la valeur côté client.
create or replace view public.app_collection as
 select ci.id as item_id,
    ci.quantity,
    ci.is_graded,
    ci.grading_company::text as grading_company,
    ci.cert_number,
    ci.grade,
    cp.language::text as language,
    cp.variant,
    cp.variant_label,
    cp.origin::text as origin,
    coalesce(cp.image_url, ( select pi.image_url
           from tcg_global.card_printing pi
          where pi.card_id = c.id and pi.image_url is not null
          order by pi.created_at
         limit 1)) as image_url,
    c.number as card_number,
    c.name as card_name,
    c.category::text as category,
    cs.code as set_code,
    cs.name as set_name,
    jp.price as price_jp,
    en.price as price_en,
    psa10.price as price_psa10
   from tcg_global.collection_item ci
     join tcg_global.card_printing cp on cp.id = ci.printing_id
     join tcg_global.card c on c.id = cp.card_id
     join tcg_global.card_set cs on cs.id = c.set_id
     left join lateral ( select p.price
           from tcg_global.price_point p
          where p.printing_id = cp.id and p.grading_company is null and p.market = 'JP'::tcg_global.market_code
          order by p.captured_at desc
         limit 1) jp on true
     left join lateral ( select p.price
           from tcg_global.price_point p
          where p.printing_id = cp.id and p.grading_company is null and p.market = 'EN'::tcg_global.market_code
          order by p.captured_at desc
         limit 1) en on true
     left join lateral ( select p.price
           from tcg_global.price_point p
          where p.printing_id = cp.id and p.grading_company = 'PSA'::tcg_global.grading_company and p.grade = 10::numeric
          order by p.captured_at desc
         limit 1) psa10 on true
  where ci.source_app = 'OJA'::tcg_global.source_app;

grant select on public.app_collection to anon, authenticated;
