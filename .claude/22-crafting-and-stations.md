# 22 — Crafting, Stations & the Recipe Ladder

The answer to "from the materials we have, **what can a player craft?**" — a map from biome
raws → refined → products, across tiers. Canon it obeys: doc 11 (tier-ascension recipe shape,
tool→speed / armor→yield split, **core invariant**), doc 04 (factories/offline), doc 21 (biome
node raws), the golden rule (**gather > hand-craft > factory**, buying always worse).

## The three crafting surfaces [DECIDED]
| Surface | How | Makes |
|---|---|---|
| **Crafting Table** | **3×3 PATTERN** (shaped + shapeless, instant) — Minecraft-style | tools, gear, building blocks, stations, utility/decor, components |
| **Stations** | **TIME-based** (input + fuel → output over N seconds), 1 recipe per station type | refine raw → processed (smelt, cut, crush, …) |
| **Factory** | **automates a recipe** — you set the **pattern** (which table/station recipe) + feed it; runs offline (capped, doc 04) | anything a table/station makes, slower per-unit than by hand |

- **Recipes unlock on first obtaining the material** (per user — simpler than doc 11's skill-gate;
  skill-gating can layer on later). So the tree reveals itself as you gather.
- **MUST ship an in-game inspectable crafting tree** (doc 11) — non-negotiable, or it's wiki hell.

## Material flow (core invariant: terrain doesn't drop; nodes + man-made do) [DECIDED]
```
NODE (mesh, doc 21) → RAW  →[station]→ REFINED  →[table pattern]→ PRODUCT (tool/block/gear/…)
```
**Raws** (one primary + 2 secondary per biome family, tiered T1–T5):
| Family | Raws |
|---|---|
| Flora | **Log**, Fiber, Sap |
| Stone | **Ore**, Gem, Rock |
| Sand  | **Silica**, Glass, Salt |
| Frost | **Ice**, Cryo-crystal, Rime |
| Bog   | **Spore**, Tar, Fungus |

Fuel = **Charcoal** (Log→furnace) early, **Coal** later. Metals come from Ore by tier:
**Copper(1) → Iron(2) → Steel(2, iron+coal) → Gold(3) → …**, with **Gems** (Quartz→Ruby→Diamond→
Emerald) from Gem nodes for high components/gear.

## Station roster (time-based) [DECIDED set, TUNE times/yields]
| Station | Turns | into |
|---|---|---|
| **Furnace** (needs fuel) | Ore → **Ingot** · Silica/Sand → **Glass** · Clay → **Brick** · Log → **Charcoal** · raw food → **cooked** |
| **Sawmill** | Log → **Planks ×4 + Sawdust** · Planks → **Panels / Sticks** (better yield than by hand) |
| **Crusher** | Rock → **Gravel** → **Sand** · Ore → **Ore Dust** (crush-then-smelt = 2× ingots) · Gem → **Gem Dust** |
| **Kiln** | Clay → **Terracotta** · Sand → **Sandstone** · glass → **tempered glass**, glazes |
| **Loom** | Fiber → **Thread** → **Cloth** → **Rope** |
| **Alchemy Vat** | Spore / Tar / Sap → **reagents, dyes, adhesive, potions** |
| **Press** | dust → **plate** · Ice → **Packed Ice** · powder → **block** |

(Furnace / Sawmill / Crusher first; the rest unlock with their materials.)

## What you craft (product categories × the block/item registries)
- **Tools** (→ speed, doc 11): Pick / Axe / Shovel / Hoe / Skinning-Knife — `plank+stick` → `ingot+stick` → tiered.
- **Armor/Robes** (→ yield + rarity, durability sink): from ingots + cloth (Miner Garb, Lumberer Robe, …).
- **Building blocks** (the `Blocks.luau` placeable palette — all CRAFTED, per invariant): Planks, Cobblestone/Cut-Stone, Brick, Sandstone, Terracotta, Glass, Glass-Pane, Packed-Ice, decorative variants.
- **Stations & Factory** (man-made → they DROP so you retrieve them): Furnace `8×rock`, Sawmill `planks+iron+saw`, Crusher `iron+rock`, Factory `plates+gears+circuit`.
- **Utility / decor**: Torch `stick+sap|coal`, Chest, Ladder, Fence, Door, Lamp `glowstone`, Bed `plank+cloth`, Sign.
- **Components** (feed advanced recipes/factories): Stick, Panel, Gear `ingot`, Plate `press`, Circuit `gem+plate+wire`, Wire `copper`.

## The TIER LADDER (the "plan") — doc 11 recipe shape [DECIDED shape, TUNE recipes]
Ascension = **lower-tier CRAFTED good + same-tier RAW from a deeper biome** (can't skip, can't
pure-buy at one radius). Applies to tools, armor, and key blocks.
```
Tier-2 Axe  = 1× Tier-1 Axe  + 2× Iron Ingot        (Iron only from a T2 biome patch)
Tier-2 Cloth = 2× Tier-1 Cloth + 2× Tier-2 Fiber
```

| Band | Unlocks (representative) |
|---|---|
| **T1** (edge, always reachable) | wood + **copper** tools, **crafting table**, **furnace**, planks/thatch/mud-brick/cobble, torch, chest — the full "cozy builder" loop with no travel |
| **T2** | **iron** tools/armor, **sawmill + crusher**, cut-stone/glass/brick/rope/cloth, better blocks |
| **T3** | **gold/gem** tools, **Factories unlock** (automate stations), gem components, potions, decorative blocks |
| **T4** | **diamond + biome-T4 raws** (Deep-Ice, Mesa-Crystal, Giant-Spore, Heartwood) → advanced gear, exotic blocks, faster factories |
| **T5** | **legendary raws** (Voidstone, Lumin-Wood, Prime-Glass, Aurora-Crystal, Prime-Spore) → best (glowing) gear, unique light/energy blocks, endgame machines |

Each biome family flavours its band (a T4 Flora world grows **Heartwood** → the Flora-line T4 gear;
a T4 Stone world yields **Deep Lode** → Stone-line T4 gear), so worlds specialise and the market
(doc 05) links the lanes.

## Why this answers the worry
Every raw now has a **named path to a product**, and the ladder says **what unlocks when**:
a fresh player on a T1 world can build the whole cozy loop; deeper worlds gate iron→gold→
diamond→legendary; stations refine, factories automate (always worse than doing it yourself).
The full recipe list is large but **generated from these rules**, not hand-invented per item.

## Open / next
- **[OPEN]** exact recipe quantities + station times (TUNE with play). **[OPEN]** durability numbers.
- **[OPEN]** does the Factory automate table-patterns, station-recipes, or both? (leaning both).
- **[BUILD]** recipe registry (`std/recipes` — shaped/shapeless patterns + station recipes, shared
  server+client), crafting-table UI (3×3 + result), station UI (input/fuel/progress), factory
  pattern-select UI. Then the in-game crafting-tree browser (doc 11 requirement).
- Reconcile: `Blocks.luau` ore-BLOCKS vs doc 21 ore-NODES (ores become node meshes; the ore *block*
  may retire or stay as a decorative placed variant). Retire the leftover **weight** machinery in
  `itemdb` (pivot dropped weight → slots).
