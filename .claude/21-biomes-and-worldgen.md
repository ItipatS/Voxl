# 21 — Biomes & World Generation

How a procedural **star** looks and what it yields. Canon source: `DESIGN.md` (bounded
Terraria-small stars, biome *mix*, mostly T1 / ≤1 T5, "5 resource types × 5 biomes",
approach shows 3 types, node-vs-normal). Reference vibe: **Biomes O' Plenty + Geophilic**.
Reuses the existing voxel gen (`src/Misc/WorldGen.luau`) — see "Bounded-star gen" below.

## The model [DECIDED]
**5 resource TYPES, each owning a 5-rung tier LADDER of biomes = 25 biomes.** A star is a
**bounded world with a biome MIX**: mostly T1 rungs, rarer higher, and **≤1 T5** if it rolls
one. `std/universe.buildStar` already rolls this (`biomes: {type, tier}`, weights
`{80,14,4.5,1.3,0.2}`). The **3 types shown on approach** = which families the star's biomes
draw from (the hook); tier/node/quality stay hidden (the payoff).

## The 5 resource types (gather families) [DECIDED names, TUNE crafting roles]
Each is a **skill lane** (progression docs) with its own **node** (a special mesh you harvest).
| Type | Material | Node examples (special mesh) | Crafting role |
|---|---|---|---|
| **Flora** | wood / fiber / sap | trees, giant stalks, glowcaps | frames, handles, growth/food |
| **Stone** | rock / ore / gem | ore veins, crystal clusters, geodes | structure, tool-heads, refining |
| **Sand** | silica / glass / salt | silica spires, glass shards, salt flats | glass/optics, circuitry, décor |
| **Frost** | ice / cryo-crystal | ice cores, frost crystals, rime | coolant, preservation, energy |
| **Bog** | mud / peat / fungus | spore pods, tar pools, fungal blooms | alchemy, fuel, biotech |

## What a TIER means (one axis: wildness × reward × rarity) [DECIDED shape, TUNE values]
- **Terrain** — T1 gentle/flat → T2 classic → T3 dramatic → T4 wild/extreme → **T5 surreal**
  (floating land, glowing, gravity-defying, alien geology).
- **Nodes** — density ↑, per-node yield ↑, mesh gets more exotic, and higher tiers **need better
  tools** (gating). T1 nodes = quick commons; T5 nodes = the grail.
- **Palette / atmosphere** — natural → otherworldly (bioluminescence, strange sky/fog).
- **Hazard** — T1 safe → T4/T5 environmental risk (extreme cold, spores, unstable ground) as
  optional risk/reward `[OPEN]`.
- **Rarity in the roll** — T1 common → **T5 ≤1 per star** and scarce across the frontier.

## The 25 biomes
`term`: rough terrain gen (maps to `WorldGen` `BiomeDef`: flatness / hilliness / ridged). `node`:
signature special-mesh resource. Existing 15-biome defs slot in at the marked rungs.

### Flora (green, organic) — needs sun + water
- **T1 Meadow** — flat grass + wildflowers; sparse saplings. *node:* herb/sapling clusters. *(≈ Plains)*
- **T2 Forest** — rolling, dense oak. *node:* full trees. *(existing Forest/SeasonalForest)*
- **T3 Jungle** — tall, humid, layered canopy + vines. *node:* giant stalks, hanging fruit. *(existing Jungle)*
- **T4 Ancient Grove** — colossal old-growth trees, root-arches, soft light shafts. *node:* heartwood giants (slow, rich).
- **T5 Bioluminescent Wildwood** — glowing flora, floating leaf-isles, spore-lit night. *node:* lumin-sap trees (grail).

### Stone (grey/brown, mineral) — elevation-driven
- **T1 Rockland** — low scree + boulders. *node:* surface ore chunks. *(gentle Crag)*
- **T2 Crag** — jagged ridged hills, exposed stone. *node:* ore veins. *(existing Crag)*
- **T3 Highland** — high plateaus + cliffs. *node:* gem geodes. *(existing Highland)*
- **T4 Peaks** — sharp ridged mountains, deep caves. *node:* rich ore + rare gems. *(existing SnowyPeaks sans snow)*
- **T5 Floating Monoliths** — gravity-defying stone islands, arch-bridges, hollow geode-caverns. *node:* voidstone / prime-gem.

### Sand (tan/ochre, silica) — hot + dry
- **T1 Dunes** — smooth rolling sand. *node:* silica pockets. *(gentle Desert)*
- **T2 Desert** — dunes + rock outcrops, cacti. *node:* silica spires. *(existing Desert)*
- **T3 Badlands** — banded mesa cliffs, hoodoos. *node:* colored-glass shards. *(new)*
- **T4 Mesa** — towering layered plateaus, canyon slots. *node:* rare crystal-glass. *(new)*
- **T5 Glass Sea** — a fused-glass plain, refractive spires, mirage light. *node:* prime-glass (grail).

### Frost (white/blue, cryo) — cold
- **T1 Frostfield** — flat snow + frozen ponds. *node:* rime clusters. *(gentle Tundra)*
- **T2 Taiga** — snowy conifer hills. *node:* frost-sap conifers. *(existing Taiga/SnowyForest)*
- **T3 Tundra** — bleak rolling permafrost, ice sheets. *node:* ice cores. *(existing Tundra/ColdDesert cold)*
- **T4 Glacier** — carved ice cliffs + crevasses. *node:* deep-ice crystal. *(existing SnowHighlands)*
- **T5 Aurora Shelf** — floating ice shelves under an aurora, singing crystals. *node:* aurora-crystal (grail).

### Bog (murky green/brown, decay) — wet + warm
- **T1 Marsh** — shallow reedy wetland. *node:* peat/reed. *(gentle Swamp)*
- **T2 Swamp** — muddy pools, hanging moss, gnarled trees. *node:* fungal blooms. *(existing Swamp)*
- **T3 Fen** — deeper mire, tar seeps, mist. *node:* tar pools. *(new)*
- **T4 Mire** — sinking ground, giant fungus, bog-lights. *node:* giant spore-pods. *(new)*
- **T5 Spore Hollow** — a cavernous fungal underworld, glowing caps, drifting spores. *node:* prime-spore (grail).

## Bounded-star world generation [DECIDED shape, TUNE numbers]
A star is **not** an infinite continent — it's a small **bounded world** (`std/starsize`:
48×48 → 256×256 footprint, tall). Generation reuses `WorldGen` with two changes:
1. **Bounded disc.** Terrain fills a disc/round island of the star's footprint; beyond the rim it
   **falls off into void/ocean** (a little world floating in space). Height + caves + trees/nodes
   as today, but clamped to the disc + seeded by the star's **`originSeed`** (not the global
   `BASE_SEED`) so each star is its own deterministic world.
2. **Restricted palette = the star's rolled mix.** Instead of the fixed global 15-biome table,
   `pickBiome` chooses only from **this star's rolled `biomes` list** (its `{type,tier}` set from
   `std/universe`). Placement: a per-star climate/Voronoi field assigns **regions** — the T1 rungs
   cover most of the disc; higher-tier rungs are **smaller, rarer patches**; the **T5 (if any) is a
   single special locus** (often central / elevated / cavernous for drama). Each biome's gen params
   come from its ladder rung (higher tier = wilder flatness/ridged/features).

**Result:** fly to a star → its 3 types tell you the *families*; land and explore → you discover
the actual biomes, and *maybe* stumble on that one T5 patch — Terraria "check your seed", per world.

## Resource nodes (the gatherables) [DECIDED shape]
- **Node-vs-normal (doc 03):** terrain blocks **don't drop**; only **nodes** (special meshes) do.
  Nodes = authored meshes placed deterministically (like trees are today), one primary per biome
  (its family's resource) + optional secondary.
- **By tier:** node **density**, **per-node yield**, **mesh exoticness**, and **tool requirement**
  all scale with the biome's tier. A T5 node is rare, rich, needs top gear.
- Placed on the surface + in caves; deterministic from `originSeed` so server+client agree and a
  claimed star's nodes are stable.

## Mapping the existing 15 biomes → ladder rungs (migration)
Plains→Flora T1 · Forest/SeasonalForest→Flora T2 · Jungle→Flora T3 · Savanna→(Flora T1 dry variant
or drop) · Crag→Stone T2 · Highland→Stone T3 · SnowyPeaks→Stone T4 (or Frost) · Desert→Sand T2 ·
ColdDesert→(Frost T3 / drop) · Taiga+SnowyForest→Frost T2 · Tundra→Frost T3 · SnowHighlands→Frost T4 ·
Swamp→Bog T2. **New to author:** all T1 calm rungs, all T4 extras, and the 5 **T5** show-stoppers.

## Open / TUNE
- **[TUNE]** tier weights (currently `{80,14,4.5,1.3,0.2}`), node density/yield curves, star footprint
  vs biome-patch count (how many biomes fit a small world — likely 2–5).
- **[OPEN]** hazards on high tiers (yes/no + which). **[OPEN]** Savanna/ColdDesert — keep as dry
  variants or cut to keep 5 clean ladders. **[OPEN]** secondary nodes per biome.
- **[OPEN]** T5 uniqueness — "≤1 T5 biome per star" is set; is a given T5 *biome* also globally rare
  (a few per week across the frontier)? Ties to `std/universe` weights + the weekly reroll.
- **Next build step:** adapt `WorldGen` to (a) bounded disc + `originSeed`, (b) rolled-palette
  `pickBiome`, then author the ladder `BiomeDef`s + node meshes.
