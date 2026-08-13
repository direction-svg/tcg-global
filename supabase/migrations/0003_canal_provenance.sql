-- ============================================================================
-- TCG GLOBAL — Migration 0003
-- Dimension "canal / provenance" de la déclinaison :
-- une même carte peut exister en set standard, en promo (JP/CN exclusive),
-- en version tournoi, battle/winner, premium collection, magazine, etc.
-- Chacune est déjà une card_printing distincte ; on la CLASSE explicitement.
-- À appliquer après 0002.
-- ============================================================================

create type print_origin as enum (
  'STANDARD',            -- carte de set principal (OP01, EB…, ST…)
  'PROMO',               -- carte promotionnelle (souvent exclusive JP/CN…)
  'TOURNAMENT',          -- promo de tournoi
  'BATTLE_EVENT',        -- Standard Battle / Winner / Official Event Prize
  'PREMIUM_COLLECTION',  -- Premium Booster / Premium Collection (PRB…)
  'MAGAZINE',            -- promo magazine / Jump
  'PRODUCT_EXCLUSIVE',   -- exclusivité produit (Mini-Tin, Pack Set, Gift, Starter, Asia ver.)
  'OTHER'
);

alter table card_printing
  add column origin print_origin not null default 'STANDARD';

create index on card_printing (origin);

comment on column card_printing.origin is
  'Canal de sortie de la déclinaison (set standard, promo, tournoi, battle/event, premium collection, magazine, exclusivité produit). Dimension distincte de la variante d''art.';
