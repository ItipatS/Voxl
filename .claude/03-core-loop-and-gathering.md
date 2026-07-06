# 03 — Core Loop, Biomes & Gathering

## The core loop [DECIDED]

```
gather (biome-flavored)
  → carry (throttled by backpack weight)
    → craft (hand = fast, factory = offline/capped)
      → build your star  ← the point
        → trade at resource stars (optional convenience)
          → back to gather
```

Everything reinforces the next step. The economy sits *around* this loop as connective tissue, not inside it as a gate.

## Biomes [DECIDED, roster OPEN]

Biomes already exist in `WorldGen.luau`: **Plains, Desert, Forest, Mountains, SnowHighlands** (+ water level, caves). Design roster may expand (Swamp is referenced in design discussion). Each biome is defined by **what it is rich in and what it lacks**.

### Inverted scarcity — the keystone mechanic [DECIDED]

A biome grants a **crafting/production bonus for the material it LACKS**, and abundance in what it has. Example intent:

| Biome | Abundant | Scarce | Crafting bonus toward |
|---|---|---|---|
| Forest | wood, rock, animals | fiber | fiber goods |
| Desert | ores, animals, fiber | rock | rock goods |
| (etc.) | ... | ... | ... |

Why this is the best idea in the design: it makes a **desert player genuinely need a forest player** (and vice-versa) for the *actual material*, not for fungible money. That demand cannot dissolve into a currency number — it is social gravity that survives (principle 1). It is "min-maxing that makes sense in the loop."

> **Do not weaken this.** Every other economic system exists to serve the interdependence this creates.

## Gradient scarcity: nodes vs normal spawns [DECIDED]

This is *how* we make scarcity opt-in (principle 4) instead of a hard wall. **No biome fully locks you out of any material** — it is faster or slower.

- **Node:** a rich, fast-to-gather, fast-to-renew source. Always refills fully on renew. A biome that "has" a resource has it as **nodes**.
- **Normal spawn:** an ordinary source. Slow to gather, slow to renew/respawn. A biome that "lacks" a resource still has it as **normal spawns**.

Example: both Forest and Swamp have wood. Forest has **tree nodes** (fast, full renew). Swamp has **normal trees** (slow gather, slow spawn). The swamp player *can* get wood — it is just slow enough that trading for it, or specializing, becomes the smart play. This is the difference between an economy players resent and one they opt into.

**Implementation notes:**
- Resource sources are entities/blocks with a `renewRate`, `gatherSpeed`, and `nodeTier` (node vs normal).
- Renewal is server-authoritative and timestamp-based.
- [TUNE] node vs normal gather-speed ratio, renew-rate ratio, spawn density per biome.

## Weight / backpack [DECIDED — this is a keystone too]

**Weight is a progression axis that also throttles the economy.** One system, three jobs:

1. **Gathering efficiency:** a bigger backpack = fewer trips = more effective gathering.
2. **Trade throttle:** you can arbitrage cheap-desert-fiber → expensive-forest-fiber, but a small pack means tiny loads, so it is slow and effortful — *this is our yellow-zone friction* (principle 6), the reason regional price gaps persist instead of instantly flattening.
3. **Progression:** backpack tiers are a core unlock path. Better pack = the reward that simultaneously improves gathering, hauling, and trading.

**Rules:**
- Each resource has a `weight`. Backpack has a `maxWeight` by tier.
- Over capacity = cannot pick up (or heavily slowed — [OPEN] which).
- [TUNE] weight per resource, maxWeight per tier, number of tiers. **This is the single most sensitive tuning value in the game** (too loose → arbitrage flattens all prices → global-market problem; too tight → hauling miserable → economy freezes). Find the "effortful but worth it" band with real players.

## CORE INVARIANT: everything is crafted, terrain doesn't drop [DECIDED — load-bearing]

> **Natural/terrain blocks do NOT drop anything when broken. Everything (even a dirt block) is crafted. Only factory & man-made blocks drop** (so you can retrieve placed machines).

This is one of the most important rules in the game. It removes Minecraft's infinite free-material firehose (mine dirt → get dirt forever), which would trivialize all scarcity. Instead every raw comes from finite-per-effort gatherable **sources** (nodes/spawns), so weight, nodes, biome scarcity, and tiers actually bite. It also prevents strip-mine griefing of shared resource stars. See doc 11.

## Tier geography [DECIDED — full detail in doc 11]

Tiers are carried by **biomes/sub-biomes** (reusing the existing biome system), distributed as a **probability gradient in "stitches"** — higher-tier patches get denser farther from spawn, never a clean ring or a center bullseye. **Banding invariant:** a tier-N patch has mostly tier-N + some tier-(N−1) filler, **never** tier-(N+1) — so you must travel outward for anything higher. Tier-1 stays edge-accessible so **building is always open to the pure builder**. This is the *quality* gradient; node-vs-normal above is the *speed* gradient. They stack (full game only; the slice uses node/normal alone).

## Building [DECIDED]

Placing/removing voxels is already implemented (client mesh via `Mesher.luau`, data via streaming). Building **consumes materials permanently** — every placed block is stone/wood spent. This is also the primary economic sink (doc 05). Building happens in your owned star (doc 06); gathering happens in public resource stars.
