# 15 — Data Schema (DataStore + MemoryStore)

The persistence foundation, reconciled to the **explore-and-claim pivot** (`DESIGN.md`).
Uses **ProfileStore** (`DevPackages`) for durable per-entity data, plain **DataStore** for
global registries, and **MemoryStore** for hot / rotating / self-expiring state. Decide
storage shapes here; biome/gather/market/claim logic layers on top without reshaping it.

> ⚠️ **Supersedes the pre-pivot schema.** The old model keyed a star by its owner
> (`star_<UserId>`, one star per player, biome = nearest fixed resource star). That's gone —
> see "What changed" + "Migration" at the bottom.

## The two locked decisions (everything below follows from these)

1. **A star is a first-class entity; `starId` = its permanent universe COORDINATE.** A star is
   a slot in a discrete universe grid (like the planting/dust grids). Its coordinate never
   changes, so it's a stable key even as `owner` transfers. The coordinate doubles as the
   frontier generator's **skip-set** and as the star's permanent "plot". A player owns **0..N**
   stars (a list of coordinates), not one keyed to them.
2. **The unclaimed frontier is ZERO storage — seed-derived, exactly like the dust field
   (`std/dust`).** Which slots hold an unclaimed star this week, and each star's biome/tier/
   quality, are a pure function of a weekly **universe seed** + the slot coordinate. Nothing is
   stored until a star is **claimed**; the only persistent star state is claimed stars + the set
   of occupied coordinates. Wire/DB cost is proportional to *claims*, never to universe size.

---

## Universe generation (no storage) [DECIDED]

The universe is a discrete grid of **star slots**. For a given week:
- A slot holds an unclaimed star iff `hash(universeSeed_week, slot)` passes a density threshold.
- That star's **seed** = `hash(universeSeed_week, slot)` → deterministically rolls its biome mix,
  tier, quality, and the 3 approach-preview resource types (DESIGN.md star-approach UX).
- Server + client both compute this (same seed) → everyone sees the same frontier, nothing streamed.
- **Claimed slots are skipped** by the unclaimed generator (they're in `ClaimedCoords`) and render
  from their own frozen `originSeed` instead — so the weekly reshuffle never touches a home.

**Weekly frontier refresh** = rotate `universeSeed_week` (new week ⇒ new key ⇒ fresh unclaimed
rolls everywhere). Claimed stars are immune. This is the dust cooldown-ledger pattern at universe
scale: seed-derived positions + a small persistent "occupied" set. Slot spacing / density are
`[TUNE]` (ties to `constellation` + `std/planting`).

**Starter stars** (the 5 pentagram hub-towns, DESIGN.md) are **fixed slots with constant seeds**
— communal, no per-player persistence, no permanent building. Their markets live in `MarketOrders`.

---

## DataStore (ProfileStore) — durable per-entity

### `star_<starId>` — a CLAIMED star  *(was `star_<UserId>`; `PrivateStarStore.luau`)*
`starId` = the slot coordinate (stable, transfer-safe). Seed + delta only, so an unbuilt claimed
star is a few bytes.
| field | meaning |
|---|---|
| `starId` | permanent slot coordinate (the key) |
| `owner` | UserId — **mutable** (star-key transfer changes it; the star doesn't move) |
| `originSeed` | the star's procedural seed, **frozen at claim** — pins its biome/terrain forever, immune to the weekly reshuffle |
| `name` | display name (globally unique via `PlanetNames`; follows the star through transfers) |
| `expandTier` | 0..5 → `{footprint,height}` via `std/starsize` — the star-size progression lever |
| `edits` | the build delta: `"wx,y,wz" → blockId` (base terrain recomputes from `originSeed`) |
| `plantedAt` | os.time() of the claim |
| `reclaimLockUntil` | `plantedAt + 3 days` — no reclaim/transfer before this (anti plant→strip→hop) |
| `locks` | crown/land-claim records (`LockService`) |
| `rating` | 5-star (later) |

Access: **current owner in the lobby** → `StartSessionAsync` (session-locked, single-live,
autosave). **Preview any star you fly near** → `GetAsync` (read-only, no lock; works while the
owner is offline). Unclaimed stars have no record — preview renders straight from the seed.

### `player_<UserId>` — the player  *(`PlayerStore.luau`, to extend)*
| field | meaning |
|---|---|
| `slots` | 54 inventory slots (1-9 hotbar, 10-54 inventory) — **the throttle is slots + travel time, NOT weight** |
| `ownedStars` | `{ starId }` — the coordinates this player owns (0..N) |
| `homeStarId` | respawn pointer ("last star", owned or starter) |
| *(later)* | skills / journal / currency |

> **Weight is removed** (DESIGN.md). Drop any `weight`/`capacity` remnants; the item layer is
> already slot-based. Cross-star arbitrage is braked by **flight time + slot caps** now.

---

## DataStore (plain) — global registries  *(`PlanetRegistry.luau`)*

Atomic reservations via `UpdateAsync` (the transform never returns nil, so it never aborts;
compare the returned value to know who won). Fails **open** in Studio without API access (allow +
warn) — `[TUNE]` to fail-closed if strict dedup is required during outages.

| store | key → value | role |
|---|---|---|
| `PlanetNames_v1` | `lower(name) → starId` | global name uniqueness. Was `→ownerUserId`; now `→starId` because owner moves and the name follows the star. |
| `ClaimedCoords_v1` | `coord → owner` | **the permanence record + the frontier generator's skip-set.** Presence = claimed (skip when generating unclaimed stars). Value = owner for a fast ownership check without loading the profile. `coord` *is* the `starId`. |

Claiming reserves `ClaimedCoords[coord]` and `PlanetNames[name]` together; roll one back if the
other loses the race (existing `reserve*/release*` pattern).

---

## MemoryStore — hot / rotating / self-expiring

| map (SortedMap) | key → value | role |
|---|---|---|
| `UniverseSeed` | `week:<weekNumber> → seed` (TTL ~8d) | the weekly frontier seed; atomic get-or-init via `UpdateAsync`. **Rotating it = the weekly refresh.** *(replaces the pre-pivot `RegionSeeds` daily biome seed)* |
| `StarServers_v1` (HashMap) | `starId → reserved server access code` (TTL 1 day, refreshed while anyone is home) | **BUILT** (`systems/StarRouting`). Single-live routing: everyone entering one star meets on one server. A stale entry is harmless — an access code names a private SERVER, not a running process, so re-joining a dead one starts a fresh instance. Hub ids (`hub:<i>`) exclude the week; frontier ids (`slot:<cx>:<cy>:<cz>:<week>`) include it. |
| `ClaimQuota` | `<userId>:<weekNumber> → count` (TTL ~8d) | enforces **2 claims/week** (base); atomic increment, checked before a plant commits. |
| `Depletion` | `<userId>:<starId>:<dayNumber> → level` (later) | per-account daily gather record so "gathered today" follows the account, not the server (doc 12 L2). Now keyed per-star, not per-biome-region. |
| `MarketOrders` | order-book (later, doc 05/07 FORK D) | hub-town bazaars — incl. the **star-key** real-estate market. |

---

## How the pieces interact (the claim/transfer flows)

**Claim (plant a Starseed on an unclaimed star):**
1. Client proposes `(name, coord)`. 2. Server checks `ClaimQuota[user:week] < 2`.
3. Reserve `ClaimedCoords[coord]` + `PlanetNames[name]` (atomic; abort + release on loss).
4. Compute the star's seed from `(universeSeed_week, coord)`; create `star_<coord>` with
   `originSeed` = that seed, `owner` = user, `plantedAt` = now, `reclaimLockUntil` = now+3d.
5. Consume the Starseed item; increment `ClaimQuota`; append `coord` to `player.ownedStars`.

**Transfer (star-key, later — sketch only):** validate `now > reclaimLockUntil` + **empty storage**
(doc 06 no-free-bulk-teleport); reassign `star.owner`, update `ClaimedCoords[coord]` value, move
`coord` between the two players' `ownedStars`; `PlanetNames` unchanged (name follows the star).
Guard with session-lock so an online owner can't edit mid-transfer.

**Unclaimed-expired star:** past its weekly expiry it lingers 1 day (grace) then vanishes from the
frontier next roll — it was never stored, so "vanish" = the generator stops emitting it. A player
who wants it converts it via a **star-key** instead (creates the `star_<coord>` record).

---

## Decided sizes (`std/starsize`)
Claimed stars are **small-footprint, tall**: 48×48×256 (tier 0) → 256×256×1024 (tier 5). Small
footprint = cozy distinct worlds; tall = the verticality signature. All `[TUNE]`.

---

## What changed vs the pre-pivot schema
- **`star_<UserId>` → `star_<starId>`**: stars are entities keyed by coordinate; a player owns a
  list, not one. `owner` is mutable (transfer); `biome`-from-nearest-neighbour → `originSeed`
  (per-star procedural). Added `plantedAt`/`reclaimLockUntil` (3-day lock).
- **`PlanetCells_v1` → `ClaimedCoords_v1`**: was just dedup; now load-bearing as the generator
  skip-set + permanence record. `PlanetNames` value `ownerUserId → starId`.
- **`RegionSeeds` (daily biome seed) → `UniverseSeed` (weekly frontier seed)**: fixed
  resource-regions are gone; biome lives in each star's seed; the seed rotates weekly, not daily.
- **Weight → slots** everywhere.
- New: `ClaimQuota` (2/week), `player.ownedStars`/`homeStarId`.

## Migration (current code → this schema)
Nothing here is built to the new shape yet — the as-built code still keys by UserId:
- `PrivateStarStore.luau` — reshape from one-star-per-user (`keyFor(uid)`, `p.Data.owner==0` mint)
  to `star_<coord>` records + a `player.ownedStars` index; `plant()` takes a coordinate as the id.
- `PlanetRegistry.luau` — repoint values to `starId`; promote `ClaimedCoords` to the generator's
  skip-set (a new universe-gen module reads it).
- ~~`RegionSeed.luau` — retire~~ **DONE** (deleted; nothing ever required it). The
  `UniverseSeed` weekly rotator is still to build.
- `PlayerStore.luau` — add `ownedStars`/`homeStarId`; ensure no weight fields.
- New: `std/universe.luau` (shared seed→star generator, mirrors `std/dust`) + a server frontier
  system + the claim/quota/reclaim service.

## Open / TUNE
- **[TUNE]** slot spacing + unclaimed density (frontier "should find a better star within ~1 min");
  `[OPEN]` whether proxy glow becomes a *required* difficulty hint for the on-ramp (DESIGN.md).
- **[OPEN]** market topology — per-hub vs one cross-hub book (doc 05 assumed biome regions).
- **[OPEN]** star-key transfer + expiry mechanics (economy layer) — schema stubs above; flows later.
- **[TUNE]** claim cap (2/week base), reclaim lock (3d), unclaimed-expiry grace (1d).
