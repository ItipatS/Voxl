# WorldGen & Biomes

How terrain is generated, and the plan to make it Minecraft-grade. Everything
here must stay **deterministic and identical on client & server** (see
`/CLAUDE.md`). All of it lives in `src/Misc/WorldGen.luau`.

## Current state (v1)

- 3 noise fields: height (`continents + ridges + detail`), temperature, humidity.
- 5 biomes: Plains, Desert, Forest, Mountains, SnowHighlands, chosen by
  `pickBiome(temp, humid, baseHeight)`.
- Per-biome: `top`/`under` block, `soilDepth`, `min/maxHeight`, some per-biome
  height shaping. Beaches under y<55, lake-basin flattening, `WATER_LEVEL=60`.
- Caves: 3D `sampleCaveNoise` carves stone in `[CAVE_START_Y, surface-CAVE_END_OFFSET]`.
- Cave **entrances**: `sampleEntranceNoise > ENTRANCE_THRESHOLD` lets the carve
  breach the surface (cuts soil too) in scattered regions.

Key API (used by the mesher, deterministic):
`getColumn(wx,wz) -> surfaceY, biomeId` · `materialAt(y,surfaceY,biomeId)` ·
`blockAt(wx,y,wz,surfaceY,biomeId)` (adds caves + entrances).

## v2 target — Minecraft-style multi-noise placement

Minecraft places biomes from **6 climate axes**, not 3. Adopting more of them is
what buys the "more variety" we want:

| Axis | What it controls | We have? |
|---|---|---|
| Temperature | hot ↔ cold biome band | yes |
| Humidity (downfall) | dry ↔ wet | yes |
| **Continentalness** | ocean ↔ coast ↔ inland ↔ far-inland | **add** |
| **Erosion** | mountainous ↔ hilly ↔ flat | **add** |
| **Weirdness / PV** | ridges, valleys, "peaks & valleys" shaping | **add** |
| Depth | above/below the terrain surface (3D biomes, caves) | later |

**Why each matters for us:**
- *Continentalness* gives real **oceans, beaches, rivers, inland plains** instead
  of one uniform landmass — the single biggest variety win, and it defines where
  `WATER_LEVEL` matters.
- *Erosion* decouples "how mountainous" from "which biome", so the same forest
  can be flat or windswept. This is what makes MC terrain feel non-repetitive.
- *Weirdness/PV* adds ridgelines and valleys (the "peaks and valleys" spline).

Placement approach: compute the axes as low-frequency noise, then select biome by
**nearest match in climate space** (a parameter list per biome, like MC's
`multi_noise`), rather than the current hard-coded `if` ladder. Height is shaped
by continentalness + erosion + PV splines, *then* the biome tints/decorates it.

## v2 target — biome palette

Expand from 5 toward ~15–25. A sensible first set (from the reference mods):

`ocean, beach, river, plains, sunflower_plains, meadow, forest, birch_forest,
dark_forest, flower_forest, cherry_grove, taiga, snowy_taiga, snowy_plains,
jungle, sparse_jungle, savanna, desert, badlands, swamp, windswept_hills,
windswept_forest, grove, stony_peaks`.

Per biome, define (matching the MC biome JSON we referenced):
- **surface**: top block, filler block, depth.
- **colours**: `grass_color`, `foliage_color`, `water_color`, `sky_color`. These
  are the cheap, high-impact variety lever — our mesher already colours per
  block, so a per-biome grass/foliage tint makes biomes read instantly. (See the
  Geophilic `biome/*.json` `effects` blocks for real values.)
- **height shaping**: contribution to the erosion/PV splines.
- **features**: trees, flowers/decoration, and **ores** (placed by depth).
- **carvers**: cave density/style (some biomes carve more).

## Ores & resources (ties into the economy)

Ores are the gameplay source/sink (`docs/DESIGN.md` §3). Distribute by **depth
bands** (MC-style): coal high, iron mid, gold/redstone/lapis low, diamond very
low, emerald in mountains. Deterministic 3D noise gates each ore, same pattern as
caves. Because generation is deterministic, ore *positions* are free to compute;
only *mined* ores need storing (in the world diff).

## Dimensions (later)

A "dimension" is just another seed + gen ruleset (nether/end analogues, or themed
worlds). Cheap given deterministic gen — a dimension id feeds `BASE_SEED` and
selects a gen profile. Good fit for premium/event content.

## Implementation notes

- Keep every new field a pure function of `(wx, wz[, y])` and the seed. No state.
- Client and server share `WorldGen`; a mismatch desyncs terrain. Add unit-style
  checks in Studio (MCP) comparing client vs server `blockAt` on sample points.
- Performance: the mesher walks the full cave depth per chunk. New generation
  work is per-column where possible (cache `getColumn` per column, as the mesher
  already does). Watch mountain-chunk mesh time (was ~7 ms) as complexity grows.
- Changing generation **changes every existing world's terrain** (worlds are
  seed+diff). Version the gen ruleset if worlds are already persisted.

## Reference material

`~/Downloads/Biome Reference/`:
- **Biomes O' Plenty** — large vanilla-style biome set (Java; placement via
  TerraBlender). Good for the biome *list* and feel.
- **Geophilic** — datapack biome JSONs (`biomes_1_21_*/.../worldgen/biome/*.json`).
  Directly readable `temperature`, `downfall`, `effects` (colours), `features`,
  `carvers`, `spawners` — the concrete per-biome numbers to copy.
