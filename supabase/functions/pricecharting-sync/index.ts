import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const SYNC_SECRET = "sync-tcgglobal-8811";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const BATCH = 30;
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
function slug(s: string){ return (s||"").toLowerCase().replace(/[^a-z0-9]+/g,"_").replace(/^_|_$/g,"") || "normal"; }
const GRADES = [
  { col:"loose-price", gc:null, grade:null },
  { col:"manual-only-price", gc:"PSA", grade:10 },
  { col:"graded-price", gc:"PSA", grade:9 },
  { col:"box-only-price", gc:"PSA", grade:9.5 },
  { col:"bgs-10-price", gc:"BGS", grade:10 },
  { col:"condition-17-price", gc:"CGC", grade:10 },
  { col:"condition-18-price", gc:"SGC", grade:10 },
];

Deno.serve(async (req: Request) => {
  if (req.headers.get("x-sync-secret") !== SYNC_SECRET) return new Response("forbidden", { status: 403 });
  const sql = postgres(DB_URL, { prepare: false });
  const report: any = { processed: 0, products: 0, jpCreated: 0, prices: 0, errors: 0 };
  try {
    const [{ token }] = await sql`select (select decrypted_secret from vault.decrypted_secrets where name='pricecharting_token') as token`;
    const [cur] = await sql`select pos, total, done from tcg_global.sync_cursor where job='pricecharting'`;
    if (cur?.done) { return new Response(JSON.stringify({ done:true, pos:cur.pos }), { headers:{"Content-Type":"application/json"} }); }
    const [{ total }] = await sql`select count(*)::int as total from tcg_global.card`;
    const pos = cur?.pos ?? 0;
    const codes = (await sql`select number from tcg_global.card order by number offset ${pos} limit ${BATCH}`).map((r:any)=>r.number);
    if (!codes.length) { await sql`update tcg_global.sync_cursor set done=true, total=${total}, updated_at=now() where job='pricecharting'`; return new Response(JSON.stringify({done:true}), {headers:{"Content-Type":"application/json"}}); }

    // Prefetch maps
    const tcgMap = new Map<string,string>();
    for (const r of await sql`select id, tcgplayer_id from tcg_global.card_printing where tcgplayer_id is not null`) tcgMap.set(String(r.tcgplayer_id), r.id);
    const cardMap = new Map<string,string>();
    for (const r of await sql`select id, number from tcg_global.card`) cardMap.set(r.number, r.id);

    const touched = new Set<string>();
    const priceRows: any[] = [];
    for (const code of codes) {
      try {
        const url = `https://www.pricecharting.com/api/products?t=${token}&q=${encodeURIComponent("one piece "+code)}`;
        const r = await fetch(url);
        const j = await r.json();
        const prods = j?.products ?? [];
        const codeRe = new RegExp(code.replace(/[-]/g,"\\-") + "(?![0-9A-Za-z])");
        for (const p of prods) {
          const pname = p["product-name"] || "";
          if (!codeRe.test(pname)) continue;
          report.products++;
          const cons = p["console-name"] || "";
          const lang = /japanese/i.test(cons) ? "JP" : "EN";
          const tcgId = p["tcg-id"] ? String(p["tcg-id"]) : null;
          let pid: string | null = null;
          if (lang === "EN" && tcgId && tcgMap.has(tcgId)) pid = tcgMap.get(tcgId)!;
          if (!pid) {
            const cardId = cardMap.get(code); if (!cardId) continue;
            const m = pname.match(/\[([^\]]+)\]/); const label = m ? m[1] : null; const variant = label ? slug(label) : "normal";
            const src = "pricecharting:" + p.id;
            const [row] = await sql`insert into tcg_global.card_printing(card_id,language,variant,variant_label,origin,source_ref)
              values(${cardId}, ${lang}, ${variant}, ${label}, 'STANDARD', ${src})
              on conflict (source_ref) where source_ref is not null do update set variant_label=excluded.variant_label returning id`;
            pid = row.id; if (lang==="JP") report.jpCreated++;
          }
          touched.add(pid);
          for (const g of GRADES) {
            const cents = p[g.col];
            if (cents && cents > 0) priceRows.push({ pid, market: lang, gc: g.gc, grade: g.grade, price: (cents/100).toFixed(2) });
          }
        }
      } catch(e) { report.errors++; report.lastError = String(e).slice(0,200); }
      await sleep(180);
    }
    // Idempotent: clear then insert PriceCharting prices for touched printings
    if (touched.size) {
      const arr = [...touched];
      await sql`delete from tcg_global.price_point where source='PRICECHARTING' and printing_id in (select value::uuid from jsonb_array_elements_text(${sql.json(arr)}::jsonb))`;
    }
    if (priceRows.length) {
      await sql`insert into tcg_global.price_point(printing_id,market,source,grading_company,grade,price,currency)
        select (r->>'pid')::uuid, (r->>'market')::tcg_global.market_code, 'PRICECHARTING', nullif(r->>'gc','')::tcg_global.grading_company, nullif(r->>'grade','')::numeric, (r->>'price')::numeric, 'USD'
        from jsonb_array_elements(${sql.json(priceRows)}::jsonb) r`;
      report.prices = priceRows.length;
    }
    const newPos = pos + codes.length;
    const done = codes.length < BATCH;
    await sql`update tcg_global.sync_cursor set pos=${newPos}, total=${total}, done=${done}, updated_at=now() where job='pricecharting'`;
    report.processed = codes.length; report.pos = newPos; report.total = total; report.done = done;
    return new Response(JSON.stringify(report), { headers:{"Content-Type":"application/json"} });
  } catch(e) {
    return new Response(JSON.stringify({ error:String(e), report }), { status:500, headers:{"Content-Type":"application/json"} });
  } finally { await sql.end({ timeout: 5 }); }
});
