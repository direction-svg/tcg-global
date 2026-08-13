# TCG GLOBAL

Système de gestion de collection **One Piece Card Game** — base multilingue (JP / EN / FR / CN),
cartes gradées, produits scellés, prix marché par marché, et une app mobile pour consulter
la collection depuis le téléphone.

Même stack que SYOLO / RYOLO : **Supabase** (Postgres + Edge Functions), **GitHub** (code + hébergement de l'app via Pages).

---

## 1. Ce que contient ce dépôt

```
docs/                          → l'app mobile (servie par GitHub Pages)
  index.html                   → app autonome (HTML/CSS/JS, se connecte à Supabase en lecture)
  .nojekyll                    → dit à Pages de servir le dossier tel quel
supabase/
  migrations/                  → schéma de la base (à appliquer dans l'ordre)
    0001_schema_initial.sql
    0002_produits_scelles_images_ia.sql
    0003_canal_provenance.sql
    0004_sync_cursor_and_app_views.sql
  functions/
    catalog-sync/index.ts      → import catalogue + prix EN + images (API TCG)
    pricecharting-sync/index.ts→ backfill prix JP + gradés (PriceCharting)
```

Tout est **déjà déployé et en fonctionnement** sur le projet Supabase `RYOLO`
(schéma isolé `tcg_global`). Ce dépôt sert à **versionner le code** et à **héberger l'app**.

---

## 2. Mettre l'app en ligne sur le téléphone (GitHub Pages)

L'app est un seul fichier `docs/index.html` qui interroge Supabase en lecture. Une fois
le dépôt poussé sur GitHub et Pages activé, tu obtiens une **URL permanente** consultable
depuis n'importe quel téléphone.

### a. Pousser le dépôt sur GitHub

Crée un dépôt vide `tcg-global` sur GitHub (sans README), puis, depuis ce dossier :

```bash
git init
git add .
git commit -m "TCG GLOBAL — base, sync, et app mobile"
git branch -M main
git remote add origin https://github.com/<ton-compte>/tcg-global.git
git push -u origin main
```

### b. Activer GitHub Pages

Sur GitHub : **Settings → Pages**
- **Source** : `Deploy from a branch`
- **Branch** : `main` — **dossier** : `/docs`
- **Save**

Au bout d'une minute, l'URL s'affiche en haut de la page Pages :

```
https://<ton-compte>.github.io/tcg-global/
```

Ouvre-la sur le téléphone → **Ajouter à l'écran d'accueil** pour l'avoir comme une app.

> L'app se met à jour toute seule à chaque ouverture : elle lit les données en direct
> depuis Supabase. Pas besoin de la redéployer quand la collection ou les prix changent.

---

## 3. Réappliquer / recréer la base (si besoin un jour)

Les migrations sont déjà appliquées sur RYOLO. Pour repartir de zéro ailleurs
(Supabase CLI lié au projet) :

```bash
supabase db push          # applique supabase/migrations/*
supabase functions deploy catalog-sync
supabase functions deploy pricecharting-sync
```

### Secrets (Vault Supabase — jamais en clair dans le code)

Les fonctions lisent leurs clés depuis le **Vault** :

| Nom du secret          | Utilisé par           |
|------------------------|-----------------------|
| `apitcg_key`           | catalog-sync          |
| `justtcg_key`          | (radar prix EN, à venir) |
| `pricecharting_token`  | pricecharting-sync    |

À créer via SQL une seule fois :

```sql
select vault.create_secret('LA_CLE', 'apitcg_key');
select vault.create_secret('LE_TOKEN', 'pricecharting_token');
```

---

## 4. Lancer les synchronisations

Les fonctions sont protégées par l'en-tête `x-sync-secret: sync-tcgglobal-8811`.

**Catalogue + prix EN + images** (par pages de 100, `maxPages` ≤ 60) :

```bash
curl -X POST "https://<ref>.functions.supabase.co/catalog-sync" \
  -H "x-sync-secret: sync-tcgglobal-8811" \
  -H "Content-Type: application/json" \
  -d '{"type":"card","startPage":1,"maxPages":60}'
# puis type:"sealed" pour les produits scellés
```

**Prix JP + gradés** (reprend tout seul là où il s'était arrêté, via `sync_cursor`) :

```bash
curl -X POST "https://<ref>.functions.supabase.co/pricecharting-sync" \
  -H "x-sync-secret: sync-tcgglobal-8811"
```

Un `pg_cron` rappelle `pricecharting-sync` en boucle jusqu'à `done=true`.

---

## 5. État actuel des données (RYOLO / schéma tcg_global)

- **72 sets**, **2 743 cartes**, **6 629+ déclinaisons** avec images et prix EN
- Prix **JP + gradés** backfillés depuis PriceCharting (**~32 000 points de prix**)
- Collection perso : **1 620 lignes / 1 880 exemplaires**, 8 cartes PSA 10,
  valorisée ~**10 300 €** (prix JP en priorité)

---

## 6. Modèle de données (3 niveaux)

```
card            → la carte abstraite (unique par numéro, ex. OP01-016)
  card_printing → une déclinaison = (variante d'art) × (canal/provenance) × (langue)
                  ex. OP01-016 "manga art" JP, ou une promo, un tournoi, une battleship…
    collection_item / collection_product_item → l'exemplaire physique possédé
price_point     → un prix daté, par marché (JP/EN…), source, et grade éventuel
```

C'est ce qui permet de distinguer proprement les variantes (art) **et** les provenances
(promo, tournament, battleship, premium collection, magazine, exclusivité produit),
qui ont des valeurs très différentes.

---

## Sécurité — à faire

Les 3 clés API ont transité par la conversation lors de la mise en place.
**Régénère-les** depuis les portails respectifs (API TCG, JustTCG, PriceCharting)
et mets à jour le Vault : elles restent uniquement côté serveur, jamais dans l'app.
