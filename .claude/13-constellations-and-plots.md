# 13 — Constellations, Plots & Spatial Layout

Resolves the [OPEN] hosting/position questions in docs 06/07 for the **flyable-space lobby** actually built. **Supersedes doc 06's "position = non-scarce metadata / biome chosen not placed" stance** — position is now physical, shared, and permanent.

## Runtime vs storage [DECIDED]

The confusion "where does a star live" dissolves once storage and runtime are separated:

- **Storage (permanent, DataStore):** one key per star (`star:<id>` = seed + delta + owner + **plot position**) + a **constellation manifest** (`constellation:<Name>` = resident star-ids, resource seeds, name). **Never one giant lobby blob** — 20 stars of edits blow past the 4 MB key limit.
- **Runtime (ephemeral):** a **constellation** = one **named** (Orion, Lyra, Draco…), capacity-capped server that **boots on demand**, loads its manifest → resident stars → resource seeds, builds one shared flyable sky, and **despawns when empty**. A star doesn't need a server always running — it needs persistent data + deterministic reload. **Single-live per constellation** via MemoryStore (`constellation → serverId`).
- **Divergence from doc 06 [DECIDED]:** stars are **co-resident in one shared sky** (fly from your island to a friend's), not per-star teleport-in. Deliberate — it's what makes the flyable lobby feel like one place. Capacity trade-off: ~20 resident stars per constellation; "resident full" → next planter gets another/fresh constellation.

## Permanent plots [DECIDED]

Planting a private star claims a **permanent spatial spot** (everyone sees your planet sitting there in space). Load-bearing, not cosmetic:

1. **Economic geography (doc 05):** markets live only on resource stars + weight/haul is the friction → your plot location = *which regional market you're cheaply plugged into*. Free relocation flattens the geography into one market.
2. **Star-size expansion (doc 10):** reserves the max-growth footprint so a neighbor can't box you in.
3. **Social gravity (principle 1):** stable neighbors = a real neighborhood.

- **Move mechanic:** **1 free relocation / week** (regret valve) + **Robux to skip the cooldown**. Frame Robux as *convenience (skip cooldown)*, **not** *buy prime real estate* — keep the haul advantage **modest** so it stays golden-rule-safe (doc 05 monetization).
- **Footprint reservation:** reserve the **full max-growth footprint** (≤ 1000×1000, doc 06) at plant time, not just the starting size.
- **Leftover-spot mitigation (doc 06's exact worry):** route new residents to constellations with **open prime spots** (or a fresh one — every constellation has its own resource stars, so fresh prime real estate always exists). Keep the haul edge modest so a non-prime spot is a mild tax, never a wall.

## Spatial layout [TUNE — placeholders, tune by flight feel]

Anchor everything to flight speed ≈ **120 studs/s** (`FlightController.SPEED`). Distances are *seconds of travel*, not arbitrary studs.

| Thing | Value | Why |
|---|---|---|
| **Resource stars per constellation** | 5 | doc 06 ("5 near-infinite resource worlds") |
| **Inter-resource-star distance** | **~6000 studs (~50 s hop)** | "very far" — a committed journey between biomes |
| **Layout** | ring, radius **~5000** around centre, Y jittered ±800 | 5 on a pentagon → adjacent ≈ 5900; 3D depth |
| **No-plant radius (per resource star)** | **~1000 studs** | keeps a clear gather-hub commons; = the resource-star ↔ resident-area boundary |
| **Warp-in** | opt-in "Enter" ProximityPrompt within **~250 studs** of the core | avoids accidental warps; [OPEN: prompt vs auto-warp at ~120] |
| **Island footprint reservation** | **1000×1000 + ~200 buffer** → islands ≥ **~1200 apart** | max star size can't overlap a neighbour |
| **Plantable zone** | anywhere beyond every resource star's 1000 sphere **and** ≥1200 from other islands; any Y (3D) | the gaps are the residency |
| **Constellation span** | ~10–12k studs across | holds 5 hubs + ~20 islands comfortably |

**Example resource-star coords** (ring r = 5000, centre ~(0, 500, 0); reposition ForestStar to node 1):
- 0°  → (5000, 500, 0)
- 72° → (1545, 900, 4755)
- 144°→ (-4045, 300, 2939)
- 216°→ (-4045, 800, -2939)
- 288°→ (1545, 200, -4755)

All [TUNE] — the ratios (hop-time, no-plant vs warp radius, footprint spacing) matter more than the exact studs; nail them by flying it.
