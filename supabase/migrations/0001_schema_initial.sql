-- ============================================================================
-- TCG GLOBAL — Schéma initial de la base de données unifiée
-- Cible : Supabase (PostgreSQL)
-- Version : 0001
-- ============================================================================
-- Modèle à 3 niveaux :
--   1) card            = la carte "abstraite" (identité partagée entre langues)
--   2) card_printing   = une déclinaison par LANGUE / ÉDITION / VARIANTE d'art
--   3) collection_item = TON exemplaire physique (état, gradation, achat...)
-- + prix historisés par marché/source, imports, référentiels.
-- ============================================================================

create extension if not exists "pgcrypto";      -- pour gen_random_uuid()

-- ----------------------------------------------------------------------------
-- ENUMS / types
-- ----------------------------------------------------------------------------
create type language_code   as enum ('JP', 'EN', 'FR', 'CN');
create type market_code     as enum ('JP', 'EN', 'FR', 'CN');  -- marché de prix
create type card_category   as enum ('LEADER', 'CHARACTER', 'EVENT', 'STAGE', 'DON');
create type card_condition  as enum ('MINT','NEAR_MINT','EXCELLENT','GOOD','LIGHT_PLAYED','PLAYED','POOR');
create type grading_company as enum ('PSA','BGS','CGC','SGC','ARS','OTHER');  -- Beckett = BGS
create type source_app      as enum ('OJA','COLLECTR','PSA','BECKETT','TCGPLAYER','CARDMARKET','MANUAL','SCAN','OTHER');

-- ----------------------------------------------------------------------------
-- RÉFÉRENTIELS
-- ----------------------------------------------------------------------------

-- Séries / sets (OP-01, EB-01, ST-01, Promo P-...). Un set peut ne pas exister
-- dans toutes les langues -> voir card_set_availability.
create table card_set (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,          -- ex: 'OP01', 'EB01', 'ST01', 'PRB01'
  name          text not null,                 -- ex: 'Romance Dawn'
  series        text,                           -- regroupement marketing éventuel
  release_date  date,
  created_at    timestamptz not null default now()
);

-- Disponibilité d'un set par langue (une même série sort à des dates différentes
-- selon les langues, et certaines n'existent pas partout).
create table card_set_availability (
  set_id        uuid not null references card_set(id) on delete cascade,
  language      language_code not null,
  release_date  date,
  primary key (set_id, language)
);

-- ----------------------------------------------------------------------------
-- NIVEAU 1 : CARTE ABSTRAITE (identité indépendante de la langue)
-- ----------------------------------------------------------------------------
create table card (
  id            uuid primary key default gen_random_uuid(),
  set_id        uuid not null references card_set(id) on delete restrict,
  number        text not null,                 -- ex: 'OP01-003' (identifiant carte)
  name          text not null,                 -- nom du personnage / de la carte
  category      card_category,
  colors        text[] default '{}',           -- ['Red'], ['Blue','Green']...
  card_type     text,                           -- ex: 'Straw Hat Crew / Supernovas'
  -- Un même 'number' peut exister dans plusieurs langues via card_printing,
  -- MAIS certaines cartes sont des exclusivités d'un seul marché (une seule
  -- déclinaison existera alors).
  created_at    timestamptz not null default now(),
  unique (set_id, number)
);

-- ----------------------------------------------------------------------------
-- NIVEAU 2 : DÉCLINAISON par LANGUE / VARIANTE (ce qui se collectionne réellement)
-- ----------------------------------------------------------------------------
create table card_printing (
  id             uuid primary key default gen_random_uuid(),
  card_id        uuid not null references card(id) on delete cascade,
  language       language_code not null,
  rarity         text,                          -- 'C','UC','R','SR','SEC','L','P'...
  variant        text not null default 'normal',-- 'normal','parallel','alt_art',
                                                 -- 'manga','special','full_art','box_topper'...
  variant_label  text,                          -- libellé lisible de la variante
  is_exclusive   boolean not null default false,-- exclusivité de ce marché/langue
  image_url      text,

  -- Identifiants externes pour rapprocher les apps/sources (clé de dédoublonnage)
  oja_id         text,
  collectr_id    text,
  tcgplayer_id   text,
  cardmarket_id  text,
  external_ids   jsonb not null default '{}',   -- autres ids éventuels

  created_at     timestamptz not null default now(),
  unique (card_id, language, variant)
);

create index on card_printing (language);
create index on card_printing (oja_id);
create index on card_printing (collectr_id);
create index on card_printing (tcgplayer_id);
create index on card_printing (cardmarket_id);

-- ----------------------------------------------------------------------------
-- NIVEAU 3 : EXEMPLAIRE PHYSIQUE POSSÉDÉ (dont cartes gradées)
-- ----------------------------------------------------------------------------
create table collection_item (
  id                uuid primary key default gen_random_uuid(),
  printing_id       uuid not null references card_printing(id) on delete restrict,
  quantity          integer not null default 1 check (quantity > 0),
  condition         card_condition,             -- pour les cartes NON gradées

  -- Gradation
  is_graded         boolean not null default false,
  grading_company   grading_company,            -- PSA, BGS (Beckett), CGC...
  cert_number       text,                        -- n° de certificat
  grade             numeric(3,1),                -- 10, 9.5, 9...
  grade_subscores   jsonb,                       -- sous-notes Beckett (centering...)

  -- Acquisition / suivi perso
  acquired_date     date,
  acquired_price    numeric(12,2),
  acquired_currency text default 'EUR',
  storage_location  text,                        -- classeur, boîte, coffre...
  source_app        source_app,                  -- provenance de la donnée
  notes             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- Un certificat est unique par organisme de gradation
  unique (grading_company, cert_number)
);

create index on collection_item (printing_id);
create index on collection_item (is_graded);
create index on collection_item (cert_number);

-- ----------------------------------------------------------------------------
-- PRIX historisés — par déclinaison, par marché, par source, dans le temps
-- ----------------------------------------------------------------------------
create table price_point (
  id            uuid primary key default gen_random_uuid(),
  printing_id   uuid not null references card_printing(id) on delete cascade,
  market        market_code not null,            -- marché de référence du prix
  source        source_app not null,             -- d'où vient le prix
  -- Contexte du prix : brut (non gradé) ou pour une note de gradation précise
  grading_company grading_company,               -- null = carte brute
  grade         numeric(3,1),                     -- null = carte brute
  price         numeric(12,2) not null,
  currency      text not null default 'EUR',
  captured_at   timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

create index on price_point (printing_id, market, captured_at desc);
create index on price_point (source);

-- Vue : dernier prix connu par déclinaison / marché / source / contexte de grade
create view price_latest as
select distinct on (printing_id, market, source, grading_company, grade)
       printing_id, market, source, grading_company, grade,
       price, currency, captured_at
from price_point
order by printing_id, market, source, grading_company, grade, captured_at desc;

-- ----------------------------------------------------------------------------
-- IMPORTS — traçabilité des exports CSV chargés
-- ----------------------------------------------------------------------------
create table import_batch (
  id            uuid primary key default gen_random_uuid(),
  source        source_app not null,
  filename      text,
  row_count     integer,
  status        text not null default 'pending', -- pending/processed/error
  notes         text,
  imported_at   timestamptz not null default now()
);

create table import_row (
  id            uuid primary key default gen_random_uuid(),
  batch_id      uuid not null references import_batch(id) on delete cascade,
  raw           jsonb not null,                  -- ligne brute pour rejouabilité
  matched_printing_id uuid references card_printing(id),
  status        text not null default 'pending', -- pending/matched/unmatched/error
  message       text
);

create index on import_row (batch_id, status);

-- ----------------------------------------------------------------------------
-- VUES pratiques pour l'application
-- ----------------------------------------------------------------------------

-- Vue "collection enrichie" : chaque exemplaire avec sa carte, sa langue,
-- et son dernier prix marché brut (pour non gradées) — les prix gradés se
-- joignent via grade/grading_company côté application.
create view collection_enriched as
select
  ci.id                as item_id,
  ci.quantity,
  ci.condition,
  ci.is_graded,
  ci.grading_company,
  ci.cert_number,
  ci.grade,
  ci.acquired_price,
  ci.acquired_currency,
  cp.id                as printing_id,
  cp.language,
  cp.rarity,
  cp.variant,
  cp.is_exclusive,
  cp.image_url,
  c.number             as card_number,
  c.name               as card_name,
  c.category,
  c.colors,
  cs.code              as set_code,
  cs.name              as set_name
from collection_item ci
join card_printing cp on cp.id = ci.printing_id
join card c           on c.id  = cp.card_id
join card_set cs      on cs.id = c.set_id;

-- ----------------------------------------------------------------------------
-- Trigger : maj automatique de updated_at sur collection_item
-- ----------------------------------------------------------------------------
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_collection_item_updated
  before update on collection_item
  for each row execute function set_updated_at();

-- ============================================================================
-- NOTE Supabase : activer la Row Level Security (RLS) sur les tables exposées
-- via l'API PostgREST avant la mise en production. Politiques à définir selon
-- que la base soit mono-utilisateur (toi) ou multi-utilisateurs plus tard.
-- ============================================================================
