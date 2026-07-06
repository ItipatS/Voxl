# 15 — Data Schema (DataStore + MemoryStore)

The persistence foundation. Decide storage shapes here; biome/gather/market logic
layers on top without reshaping the data. Uses **ProfileStore** (`DevPackages`) for
durable data and **MemoryStore** for hot/cross-server/self-expiring state.

## DataStore (ProfileStore) — durable

### `star_<UserId>` — a player's private star (`PrivateStarStore.luau`)
Seed + delta only; base terrain recomputes from `seed`, so an unbuilt star is a few bytes.
| field | meaning |
|---|---|
| `owner` | UserId |
| `name` | display name |
| `seed` | **permanent** worldgen seed (base terrain) |
| `plot` | `{x,y,z}` permanent spot in the constellation (doc 13); `{0,0,0}` = unplanted |
| `biome` | set at plant = **nearest resource star's biome** (flavor + tier-1 nodes) |
| `expandTier` | 0..5 → `{footprint, height}` via `std/starsize` — the star-size progression lever |
| `edits` | the delta: `"wx,y,wz" → blockId` |
| `claims` | crown/lock records (later) |
| `createdAt` | os.time() |
| `rating` | 5-star (later) |

Access: **owner in the lobby** → `StartSessionAsync` (session-locked, single-live, autosave).
**Preview a neighbour** → `GetAsync` (read-only, no lock, works while owner offline).

### `player_<UserId>` — the player (`PlayerStore.luau`, to extend)
Inventory (blocks) today; add skills/journal, currency, `homeConstellation` later.

### `constellation_<name>` — resident manifest (later)
Resident star ids + plots, so a constellation server can load/render offline neighbours.

## MemoryStore — hot / cross-server / self-expiring

### `RegionSeeds` (SortedMap) — resource-star daily seed (`RegionSeed.luau`)
Key `<biome>:<dayNumber>` → random seed, TTL ~25h, atomic get-or-init via `UpdateAsync`.
All servers of a biome share one seed per day; rotates at midnight (fresh world daily).
**Divergence from doc 12:** trades a *permanent learnable* seed for a *daily fresh* world.

### `Depletion` (SortedMap) — per-account daily gather record (later)
Key `<userId>:<biome>:<dayNumber>` → depletion level. Needed because a daily *shared*
seed still lets you server-hop for fresh nodes within a day; per-account tracking (doc
12 L2) makes "gathered today" follow the account, not the server.

### `MarketOrders` — bazaar order-book (later, doc 05/07 FORK D)

## Decided sizes (revises doc 06's flat 1000×255×1000)
Private stars are **small-footprint, tall** (`std/starsize`): 48×48×256 (tier 0) →
256×256×1024 (tier 5). Small footprint = cozy distinct islands (≈20 fit a constellation
at 1,200 spacing); tall height = the verticality signature (up to 4× the wild). All [TUNE].

## Environment rule
A private star's terrain = its permanent `seed`, **biome-locked** to the nearest resource
star's biome, with a few **tier-1 nodes** of that biome (self-supply trickle, principle 5).
Resource-star worlds use the **daily** regional seed instead.
