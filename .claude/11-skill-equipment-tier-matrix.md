# 11 — Skill / Equipment / Tier Reference Matrix

Build-off reference tables for Claude Code. All specific values are [TUNE].

## Skill matrix [DECIDED structure, roster OPEN]

| Material | Gathering skill | Crafting skill |
|---|---|---|
| Wood | ✓ | ✓ |
| Fiber | ✓ | ✓ |
| Stone | ✓ | ✓ |
| Ore | ✓ | ✓ |
| Rock | ✓ | ✓ |
| Equipment | — | ✓ (own track) |
| Factory | — | ✓ (own track) |

- Gathering ↑ = faster gather + higher yield/rarity chance (with gear).
- Crafting ↑ = unlocks recipes within the path + **gates tier ascension**.
- Independent: you may buy materials instead of gathering.
- [OPEN] final material roster (Swamp/other biomes may add types); XP curves.

## Equipment grid [DECIDED structure]

Per field: one **tool** (speed) + one **robe/armor** (yield + rarity). Examples:

| Field | Tool (→ speed) | Robe/Armor (→ yield + rarity) |
|---|---|---|
| Woodcutting | Axe | Lumberer Robe |
| Hunting | Skinning Knife | Hunter Robe |
| Mining (ore) | Pickaxe | Miner Garb |
| Stone/Rock | (tool TBD) | (robe TBD) |
| Fiber | (tool TBD) | (robe TBD) |

- Tool tier = tactile per-resource upgrade gate.
- Armor doubles as the **durability sink** (doc 05) — wears from use.
- [TUNE] speed multipliers per tool tier; yield/rarity bonuses per robe tier; durability burn rates.

## Tier geography rules [DECIDED]

Tiers are carried by **biomes/sub-biomes**, not radius math (reuses existing biome system).

**Distribution = probability gradient in "stitches," NOT clean rings and NOT a center bullseye.**
- Near spawn/edge: mostly tier-1 patches, rare higher-tier stitch.
- Farther out: higher-tier patches get *denser*, lower-tier stitched between.
- No single "best spot" to camp → the field stays populated, weight/haul friction stays meaningful.

**Banding invariant (load-bearing):**
> A tier-N biome patch contains **mostly tier-N raws + some tier-(N−1) as filler**. It **never** contains tier-(N+1). To get tier-(N+1) you must physically travel to a tier-(N+1) patch (farther out).

| Biome tier | Contains |
|---|---|
| Tier 1 | tier-1 only (always edge-accessible — protects the pure builder) |
| Tier 2 | mostly tier-2, some tier-1 filler |
| Tier 3 | mostly tier-3, some tier-2 filler |
| Tier N | mostly tier-N, some tier-(N−1) filler |

Consequences: supply chains can't be skipped or bought at one radius; each patch is self-limiting (spawns only its band), so per-area resource caps fall out for free.

## Recipe shape [DECIDED — example]

Tier ascension mixes a lower-tier *crafted* good with same-tier *raw* from deeper:

```
Tier-2 cloth = 2 × Tier-1 cloth  +  2 × Tier-2 fiber   (requires Fiber-crafting ≥ N)
```
- Can't skip tiers (needs the lower crafted item).
- Can't pure-buy up at one radius (needs deeper raw).
- **MUST ship with an in-game inspectable crafting tree** (see doc 10 / doc 02). Without it, this becomes the Cubic-Castles wiki-dependency nightmare. Pair them or don't ship radius-tiering.

## Two stacking gradients [DECIDED — full game, NOT the slice]
- **Node vs normal** = *speed* gradient (doc 03).
- **Biome tier** = *quality* gradient (this doc).
They stack: deep+node = fast high-tier; edge+normal = slow low-tier; etc. Rich space, but **one gradient at a time** — the vertical slice (doc 08) uses node/normal only, wood only. Tier geography comes after feel is proven.

## Core invariant [DECIDED — flag everywhere]
> **Everything is crafted. Natural/terrain blocks do NOT drop anything when gathered/broken. Only factory & man-made blocks drop (so you can retrieve your machines).**

This is load-bearing for the whole economy: it removes Minecraft's infinite free-material firehose, so all raws come from finite-per-effort gatherable sources — making weight, nodes, tiers, and biome scarcity actually matter. Also prevents strip-mine griefing of shared resource stars.
