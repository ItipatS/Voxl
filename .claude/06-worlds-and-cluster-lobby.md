# 06 — Worlds & The Cluster Lobby

## World model [DECIDED]

Two kinds of "stars" (worlds):

### 1. Player-owned stars (bounded, ownable)
- Named worlds. **Type a name → join that world if it exists, else create a new one with a new seed.** (Growtopia's ownership model.)
- **Bounded**, not infinite. Start small; expandable up to **max 1000 × 255 × 1000**.
- Have an **owner**, a name, a 5-star rating, permissions.
- Stored as **seed + edited voxels only** (doc 07) — so millions of tiny worlds cost almost nothing.
- No marketplace here (markets live only on resource stars, doc 05).
- Biome of a player star is **chosen by the player** [DECIDED] — biome is a meaningful economic identity (what you're rich/poor in), so it must be an intentional choice, never silently assigned by map position.

### 2. Public resource stars (shared gathering hubs)
- Shared, high-population worlds where anyone gathers.
- Each has a **biome** and a **marketplace** (doc 05).
- The "wild" that supplies the whole economy.
- Node vs normal spawns (doc 03) live here.

## The Cluster (cosmic lobby) [DECIDED — name OPEN]

The lobby is a **zero-gravity star map** — a multiplayer social space where worlds appear as stars/planets.

- Each star is sized ~like a player, shows a **thumbnail of that world**, and UI for name, owner, 5-star rating.
- Stars have **permanent positions** once created.
- It is **both** a browsable directory **and** a hangout (players are present in it).

**Working name:** "Cosmic Lobby" (placeholder). Suggested: **"The Cluster"** (double meaning: star cluster + worlds cluster by biome region) or **"The Expanse."** [OPEN — pick a name that *means* something in the fiction.]

### Critical scale rules [DECIDED]
A permanent-position star map becomes a graveyard/void at scale (Cubic Castles' skymap rotted exactly this way). Two mandatory mitigations:

1. **Cull aggressively** — only render nearby / active / high-rated stars. Never render all.
2. **Discovery layer on top** — search, featured, sort by rating/activity. The spatial map is the *vibe*; it cannot be the only door.

### Thumbnail rendering [DECIDED — important perf rule]
Render each world's thumbnail from its datastore **once, to a cached image**. **Do NOT run live `ViewportFrame`s for dozens of worlds simultaneously** — that will melt phones. Cache thumbnails as images; refresh on world update, not per-frame.

## Social sharding vs global economy [DECIDED — keep these separate]
- **Social presence = sharded.** Many lobby instances / many copies of a resource star are fine (Skyblock does exactly this with `mini###` instances). Players auto-join one with space.
- **Economy/marketplace = must be conceptually global per resource type/region**, even if presence is sharded. Otherwise each shard becomes a walled economy and interdependence collapses into isolated ponds.
- **Nuance from design discussion:** because markets are *regional* (per biome resource star, doc 05), "global" here means "all instances of the Forest resource star share one Forest market," not "one market for the whole game." Presence shards; the *regional* market behind those shards is unified.

> This is a datastore/market-service decision to make **now**, not retrofit (doc 07).

## Biome-of-a-resource-star [DECIDED]
Original idea ("biome depends on nearest public resource star") is kept as *flavor for player stars near a region* but biome is ultimately **chosen**, not physically assigned, to avoid late players getting stuck with leftover slots. Many lobbies exist as needed — running out of good positions is not a Roblox constraint problem.

---

## Star hosting architecture (Fork A/B resolved) [DECIDED]

### Owned stars = datastore keys, single-live
A star is **not a place you travel to — it's a datastore key you load** (`seed + edited-voxel delta`).
- **Display position** in the Cluster (lobby coords + thumbnail) is just **metadata**, fully decoupled from **where the star runs** when opened.
- **Owner presence is irrelevant** — visiting reads their *data*, not talks to *them*. You can access an offline player's star datastore. A player anywhere opens a star owned by anyone; it's a datastore read + delta apply into a world context.
- **Scales to millions:** a star nobody is viewing costs **one datastore key and zero compute**. Loaded on demand.
- **Single-live [DECIDED]:** each open star runs in exactly **one** in-memory world context on **one** server. **Visiting = teleport to the server where that star lives** (that *is* the visit — never spin a second copy). `MemoryStore` holds `starId → serverId`; opening a star joins the live server if present, else claims the slot and loads it.
  - Kills all concurrency/dupe/last-write-wins bugs: only one copy of a delta ever exists.
  - Tradeoff: visiting is a teleport (has a load beat), not an instant in-process pop-in. Make the transition feel good.
- **Save path [DECIDED]:** dirty-flag on edit → **debounced autosave** (every N seconds if changed) + **save on last-viewer-leave** (context unloads → final write → release MemoryStore lock). **Session lock has a TTL** so a crashed server's star becomes claimable again (worst case: lose the last debounce window, never the whole world).
- **Open thread:** delta size × write cadence (doc 12 L12) — big edits → big delta → DataStore throttle risk. A tuning/compaction problem on one key, not architecture. Doesn't block building.

### Resource stars = dedicated places
- One **dedicated Roblox place per biome-region**, sharded for population (they're few and heavily populated — dedicated servers fit).
- Host the **regional market service** (doc 05) and the **per-account depletion record** (doc 12 L2).
- Session flow: Cluster lobby → tap your star (teleport to its live server) → "go gather" → **teleport to the Forest resource place** → gather → teleport back. Teleports happen only at lobby↔resource boundaries and star visits, never for browsing.

---

## Ownership & permissions [DECIDED]

### Roles (star-wide baseline)
| Role | Edit/remove blocks | Use machines | Access storage | Notes |
|---|---|---|---|---|
| **Owner** | ✓ | ✓ | ✓ | grants roles, places crowns |
| **Co-owner** | ✓ | ✓ | ✓ | trusted builder/partner |
| **User** | ✗ | ✓ | ✓ (per crown policy) | helper/shopkeeper — runs the base, can't rearrange it |
| **Visitor** | ✗ | Class-A only | ✗ | look + walk + opt-in public crafting |

Enforced **server-side per action** in the single-live context. Role is the player's relationship to the star, checked at the moment of interaction — **no per-machine permission flags**. This is also the enforcement that closes theft (doc 12 L15): a visitor *cannot* edit/take because the server rejects the action.

### Object risk classes
Interactables split by risk, and each class has its own default reach:
- **Class A — public-safe (crafting tables/benches):** run on the **user's own materials → user's own output**. Nothing to drain. Owner may expose these **star-wide as "charity"** to anyone (Visitor+) safely.
- **Class B — restricted (factories, storage, resource-consuming machines):** hold/consume value. **Never star-wide, never Visitor.** Access requires **Co-owner**, or a **Crown zone** explicitly granting a **User** in-zone.

| | Class A (crafting table) | Class B (factory / storage) |
|---|---|---|
| Owner | ✓ | ✓ |
| Co-owner | ✓ | ✓ |
| User | ✓ | ✓ **only inside a crown zone** |
| Visitor | ✓ (if owner allows, even star-wide) | ✗ ever |

The chaos of "whole star usable" is structurally impossible: charity only reaches Class A (drain-proof); Class B can never be charity/Visitor.

### The Crown block (zonal permission) [DECIDED]
Growtopia's World-Lock pattern. A placeable block that projects a **spatial** permission zone — lets access-holders *use* objects **inside a bounded area** without whole-star access. **This is what makes player shops possible** (a public counter zone walled off from private storage — the proper version of Cubic Castles' cash-register shop).
- **One crown type.** The **object's class** determines what the crown can expose (a crown can't make a Visitor touch Class B — the class rule overrides). No need for separate use/storage crowns.
- **Zone = flood-fill of adjacent usable blocks from the crown.** Your rule: contiguous only, **a 1-block gap severs the zone**.
- **Computed on-change and cached** (recompute the zone once when a usable block is placed/broken near a crown; interactions are then O(1) membership lookups — never live-scan per click).
- **Anti-grief [DECIDED]:** only **owner/co-owner-placed** usable blocks can join a zone (a visitor's block never counts); only the **owner places/moves crowns**. Otherwise the crown becomes a griefing lever (extend/sever attacks).
- **Non-overlapping zones**, nearest-crown-wins tiebreak (a block is in exactly one zone).
- Persisted as just the **crown position in the delta**; the zone re-derives on load. Cheap to store, safe to enforce (server-side, single-live context).
