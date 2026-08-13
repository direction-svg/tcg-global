-- ============================================================================
-- TCG GLOBAL — Migration 0002
-- Ajouts : produits scellés (displays/boosters/coffrets), images/scan,
--          fondations IA (veille nouveautés + opportunités d'achat).
-- Cible : Supabase (PostgreSQL). À appliquer après 0001.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ENUMS
-- ----------------------------------------------------------------------------
create type product_type as enum (
  'BOOSTER_BOX',        -- display / boîte de boosters
  'BOOSTER_PACK',       -- booster à l'unité
  'STARTER_DECK',       -- deck de démarrage
  'PREMIUM_BOOSTER',    -- premium booster
  'CARD_COLLECTION_SET',-- coffret à livret (One Piece Card Collection 1/2/3...)
  'GIFT_COLLECTION',    -- gift collection / coffret cadeau
  'ULTRA_DECK',         -- ultra deck
  'DOUBLE_PACK_SET',    -- double pack set (DON!!...)
  'PROMO_PACK',         -- pack promotionnel
  'CASE',               -- carton scellé (case de displays)
  'OTHER'
);

create type product_condition as enum (
  'SEALED',      -- scellé d'origine
  'OPENED',      -- ouvert
  'DAMAGED_BOX', -- boîte abîmée
  'LOOSE'        -- vrac / sans emballage
);

create type opportunity_type as enum (
  'UNDERVALUED',        -- sous-coté vs marché
  'TRENDING_UP',        -- momentum haussier
  'NEW_RELEASE',        -- nouveauté qui sort
  'PREORDER',           -- précommande intéressante
  'GRADING_CANDIDATE'   -- bon candidat à la gradation
);

-- ----------------------------------------------------------------------------
-- PRODUITS SCELLÉS / COLLECTIBLES (parallèle aux cartes)
-- ----------------------------------------------------------------------------
create table product (
  id            uuid primary key default gen_random_uuid(),
  set_id        uuid references card_set(id) on delete set null, -- set lié si pertinent
  language      language_code not null,
  product_type  product_type not null,
  name          text not null,                 -- ex: 'One Piece Card Collection Vol.2 (JP)'
  product_code  text,                           -- code produit / SKU si connu
  description   text,                           -- contenu (nb boosters, livret, promo incluse...)
  is_exclusive  boolean not null default false, -- exclusivité marché
  image_url     text,

  -- Rapprochement multi-sources
  oja_id        text,
  collectr_id   text,
  tcgplayer_id  text,
  cardmarket_id text,
  external_ids  jsonb not null default '{}',

  release_date  date,
  created_at    timestamptz not null default now(),
  unique (language, product_type, name)
);

create index on product (language);
create index on product (product_type);

-- Exemplaire de produit possédé (scellé ou non)
create table collection_product_item (
  id                uuid primary key default gen_random_uuid(),
  product_id        uuid not null references product(id) on delete restrict,
  quantity          integer not null default 1 check (quantity > 0),
  condition         product_condition not null default 'SEALED',
  acquired_date     date,
  acquired_price    numeric(12,2),
  acquired_currency text default 'EUR',
  storage_location  text,
  source_app        source_app,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index on collection_product_item (product_id);

create trigger trg_collection_product_item_updated
  before update on collection_product_item
  for each row execute function set_updated_at();

-- ----------------------------------------------------------------------------
-- PRIX : rendre price_point polymorphe (carte OU produit scellé)
-- ----------------------------------------------------------------------------
alter table price_point alter column printing_id drop not null;
alter table price_point add column product_id uuid references product(id) on delete cascade;
alter table price_point add constraint price_point_target_ck
  check (num_nonnulls(printing_id, product_id) = 1);  -- exactement une cible
create index on price_point (product_id, market, captured_at desc);

-- ----------------------------------------------------------------------------
-- IMAGES / SCAN — plusieurs images par déclinaison, + empreinte pour le scan
-- (l'embedding vectoriel viendra avec l'extension pgvector, phase scan/IA)
-- ----------------------------------------------------------------------------
create table card_image (
  id            uuid primary key default gen_random_uuid(),
  printing_id   uuid references card_printing(id) on delete cascade,
  product_id    uuid references product(id) on delete cascade,
  url           text not null,                 -- URL (Supabase Storage ou source)
  kind          text default 'front',          -- 'front','back','box','detail'...
  phash         text,                           -- perceptual hash (reconnaissance scan)
  is_primary    boolean not null default false,
  created_at    timestamptz not null default now(),
  constraint card_image_target_ck check (num_nonnulls(printing_id, product_id) = 1)
);

create index on card_image (printing_id);
create index on card_image (product_id);
create index on card_image (phash);

-- ----------------------------------------------------------------------------
-- FONDATIONS IA — veille nouveautés + opportunités d'achat
-- (alimentées plus tard par le module IA ; tables posées dès maintenant)
-- ----------------------------------------------------------------------------

-- Veille des nouveautés / annonces (sets, produits, promos) par langue
create table release_watch (
  id            uuid primary key default gen_random_uuid(),
  language      language_code,
  title         text not null,                 -- ex: 'OP-13 announced', 'Promo XYZ'
  kind          text,                           -- 'set','product','promo'
  announced_date date,
  release_date  date,
  source_url    text,
  status        text not null default 'announced', -- announced/released/cancelled
  detected_at   timestamptz not null default now()
);

-- Opportunités repérées par l'IA (bons coups, cartes qui peuvent monter)
create table market_opportunity (
  id            uuid primary key default gen_random_uuid(),
  printing_id   uuid references card_printing(id) on delete cascade,
  product_id    uuid references product(id) on delete cascade,
  opportunity_type opportunity_type not null,
  market        market_code,
  score         numeric(5,2),                  -- score de conviction (0-100)
  rationale     text,                           -- explication générée
  source_url    text,
  status        text not null default 'open',   -- open/dismissed/acted
  detected_at   timestamptz not null default now()
);

create index on market_opportunity (status, opportunity_type);
create index on market_opportunity (printing_id);
create index on market_opportunity (product_id);

-- ----------------------------------------------------------------------------
-- VUE : produits scellés enrichis (pour l'app)
-- ----------------------------------------------------------------------------
create view product_collection_enriched as
select
  cpi.id            as item_id,
  cpi.quantity,
  cpi.condition,
  cpi.acquired_price,
  cpi.acquired_currency,
  p.id              as product_id,
  p.language,
  p.product_type,
  p.name            as product_name,
  p.is_exclusive,
  p.image_url,
  cs.code           as set_code,
  cs.name           as set_name
from collection_product_item cpi
join product p    on p.id = cpi.product_id
left join card_set cs on cs.id = p.set_id;

-- ============================================================================
-- Rappel Supabase : penser RLS sur product / collection_product_item /
-- card_image / market_opportunity / release_watch avant prod.
-- Pour le scan (phase ultérieure) : activer l'extension "vector" (pgvector)
-- et ajouter une colonne embedding à card_image pour la recherche visuelle.
-- ============================================================================
