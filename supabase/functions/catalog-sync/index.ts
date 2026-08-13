import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const SYNC_SECRET = "sync-tcgglobal-8811";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const CAT: Record<string,string> = { Leader:"LEADER", Character:"CHARACTER", Event:"EVENT", Stage:"STAGE" };
const SEALED: Record<string,string> = { booster_box:"BOOSTER_BOX", booster_pack:"BOOSTER_PACK", starter_deck:"STARTER_DECK", structure_deck:"STARTER_DECK", theme_deck:"STARTER_DECK", collection_box:"CARD_COLLECTION_SET", tin:"CARD_COLLECTION_SET", bundle:"GIFT_COLLECTION", blister:"PROMO_PACK", prerelease_kit:"PROMO_PACK", elite_trainer_box:"GIFT_COLLECTION" };
function slug(s: string){ return (s||"").toLowerCase().replace(/[^a-z0-9]+/g,"_").replace(/^_|_$/g,"") || "normal"; }
function parseVariant(name: string){
  const groups = [...(name||"").matchAll(/\(([^)]+)\)/g)].map(m=>m[1].trim());
  let label: string|null = null;
  for (const g of groups) if (!/^\d+$/.test(g)) label = g;
  const clean = (name||"").replace(/\s*\([^)]*\)/g,"").trim();
  return { clean, label };
}
function originOf(setCode: string, setName: string){
  const s = (setName||"").toLowerCase(); const c = setCode||"";
  if (/tournament/.test(s)) return "TOURNAMENT";
  if (/winner|battle|event|prize|champion/.test(s)) return "BATTLE_EVENT";
  if (c.includes("PRB") || /premium/.test(s)) return "PREMIUM_COLLECTION";
  if (/magazine|jump/.test(s)) return "MAGAZINE";
  if (/pre-release|pre release|starter|deck| tin|gift/.test(s)) return "PRODUCT_EXCLUSIVE";
  if (/promo|promotion/.test(s) || c==="OP-PR") return "PROMO";
  return "STANDARD";
}
const RCOLS = "r(set_code text, set_name text, release_date text, number text, card_name text, category text, variant text, variant_label text, rarity text, origin text, image_url text, tcgplayer_id text, source_ref text, price numeric, product_type text)";

async function upsertCardsPage(sql: any, rows: any[]){
  const j = sql.json(rows); const R = sql.unsafe(RCOLS);
  await sql`insert into tcg_global.card_set(code,name,release_date)
    select distinct on (r.set_code) r.set_code, r.set_name, nullif(r.release_date,'')::date
    from jsonb_to_recordset(${j}::jsonb) as ${R} order by r.set_code
    on conflict(code) do update set name=excluded.name, release_date=coalesce(excluded.release_date, tcg_global.card_set.release_date)`;
  await sql`insert into tcg_global.card(set_id,number,name,category)
    select distinct on (r.number) cs.id, r.number, r.card_name, nullif(r.category,'')::tcg_global.card_category
    from jsonb_to_recordset(${j}::jsonb) as ${R} join tcg_global.card_set cs on cs.code=r.set_code
    order by r.number on conflict(number) do update set name=excluded.name, category=coalesce(excluded.category, tcg_global.card.category)`;
  await sql`insert into tcg_global.card_printing(card_id,set_id,language,variant,variant_label,rarity,origin,image_url,tcgplayer_id,source_ref)
    select distinct on (r.source_ref) c.id, cs.id, 'EN', r.variant, r.variant_label, nullif(r.rarity,''), r.origin::tcg_global.print_origin, r.image_url, r.tcgplayer_id, r.source_ref
    from jsonb_to_recordset(${j}::jsonb) as ${R} join tcg_global.card c on c.number=r.number join tcg_global.card_set cs on cs.code=r.set_code
    order by r.source_ref
    on conflict (source_ref) where source_ref is not null do update set image_url=coalesce(excluded.image_url, tcg_global.card_printing.image_url), rarity=coalesce(excluded.rarity, tcg_global.card_printing.rarity), variant=excluded.variant, variant_label=excluded.variant_label, origin=excluded.origin, tcgplayer_id=coalesce(excluded.tcgplayer_id, tcg_global.card_printing.tcgplayer_id)`;
  await sql`insert into tcg_global.price_point(printing_id,market,source,price,currency)
    select cp.id,'EN','TCGPLAYER', r.price, 'USD' from (select distinct on (source_ref) source_ref, price from jsonb_to_recordset(${j}::jsonb) as ${R}) r
    join tcg_global.card_printing cp on cp.source_ref=r.source_ref where r.price is not null`;
}

async function upsertSealedPage(sql: any, rows: any[]){
  const j = sql.json(rows); const R = sql.unsafe(RCOLS);
  await sql`insert into tcg_global.card_set(code,name,release_date)
    select distinct on (r.set_code) r.set_code, r.set_name, nullif(r.release_date,'')::date
    from jsonb_to_recordset(${j}::jsonb) as ${R} order by r.set_code on conflict(code) do update set name=excluded.name`;
  await sql`insert into tcg_global.product(set_id,language,product_type,name,image_url,tcgplayer_id,release_date)
    select distinct on (r.product_type, r.card_name) cs.id, 'EN', r.product_type::tcg_global.product_type, r.card_name, r.image_url, r.tcgplayer_id, nullif(r.release_date,'')::date
    from jsonb_to_recordset(${j}::jsonb) as ${R} left join tcg_global.card_set cs on cs.code=r.set_code
    order by r.product_type, r.card_name
    on conflict(language,product_type,name) do update set image_url=coalesce(excluded.image_url, tcg_global.product.image_url), tcgplayer_id=coalesce(excluded.tcgplayer_id, tcg_global.product.tcgplayer_id)`;
  await sql`insert into tcg_global.price_point(product_id,market,source,price,currency)
    select p.id,'EN','TCGPLAYER', r.price,'USD' from (select distinct on (product_type, card_name) product_type, card_name, price from jsonb_to_recordset(${j}::jsonb) as ${R}) r
    join tcg_global.product p on p.language='EN' and p.product_type=r.product_type::tcg_global.product_type and p.name=r.card_name where r.price is not null`;
}

Deno.serve(async (req: Request) => {
  if (req.headers.get("x-sync-secret") !== SYNC_SECRET) return new Response("forbidden", { status: 403 });
  let body: any = {}; try { body = await req.json(); } catch(_) {}
  const type = body.type || "card";
  const startPage = body.startPage ?? 1;
  const maxPages = Math.min(body.maxPages ?? 10, 60);
  const sql = postgres(DB_URL, { prepare: false });
  const report: any = { type, startPage, pages: 0, imported: 0, errors: 0 };
  try {
    const [keys] = await sql`select (select decrypted_secret from vault.decrypted_secrets where name='apitcg_key') as apitcg`;
    let page = startPage; const endPage = startPage + maxPages - 1;
    while (page <= endPage) {
      const url = `https://api.apitcg.com/api/products?tcg=one-piece&type=${type}&limit=100&page=${page}`;
      const r = await fetch(url, { headers: { "x-api-key": keys.apitcg } });
      if (!r.ok) { report.lastStatus = r.status; break; }
      const j = await r.json();
      const data = j?.data ?? [];
      if (!data.length) break;
      const rows = data.map((p: any) => {
        const setCode = p?.set?.code || "MISC"; const setName = p?.set?.name || setCode;
        const rel = p?.set?.release_date || "";
        const { clean, label } = parseVariant(p.name || "");
        const tcgId = p?.markets?.tcgplayer?.id ?? null;
        const source_ref = tcgId ? ("tcgplayer:" + tcgId) : ("apitcg:" + p._id);
        const price = p?.markets?.tcgplayer?.prices?.market ?? null;
        const image = p?.images?.[0]?.large ?? p?.images?.[0]?.medium ?? null;
        const st = p?.sealed_type ? (SEALED[p.sealed_type] || "OTHER") : "OTHER";
        return { set_code:setCode, set_name:setName, release_date:rel, number:p.code||null,
          card_name: (type==="card" ? (clean||p.code) : p.name), category: (p?.attributes?.CardType && CAT[p.attributes.CardType]) || "",
          variant: label?slug(label):"normal", variant_label: label, rarity: p?.attributes?.Rarity || "",
          origin: originOf(setCode,setName), image_url:image, tcgplayer_id:tcgId, source_ref, price, product_type: st };
      });
      const valid = type==="card" ? rows.filter((x:any)=>x.number) : rows;
      try { if (valid.length){ if (type==="card") await upsertCardsPage(sql, valid); else await upsertSealedPage(sql, valid);} report.imported += valid.length; }
      catch(e){ report.errors++; report.lastError = String(e).slice(0,300); }
      report.pages++;
      if (data.length < 100) { report.done = true; break; }
      page++;
    }
    report.nextPage = report.done ? null : page;
    return new Response(JSON.stringify(report), { headers: { "Content-Type": "application/json" } });
  } catch(e) {
    return new Response(JSON.stringify({ error: String(e), report }), { status: 500, headers: { "Content-Type": "application/json" } });
  } finally { await sql.end({ timeout: 5 }); }
});
