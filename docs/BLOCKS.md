# Blocks — texture wishlist & how to add one

Every block lives in **`src/Misc/Blocks.luau`** — one entry in `defs` + its texture
ids in `TEX`. WorldGen, the mesher, editing and the UI all read from there.

## How to add a block

1. Add an id to `Blocks.ID` (**append only** — ids are persisted in worlds &
   inventories, never renumber or reuse).
2. Add its texture ids to `TEX` (upload the image, paste `rbxassetid://…`).
3. Add a `defs[ID.Foo] = { … }` entry.

```lua
defs[ID.RedSand] = {
    name = "Red Sand",
    tex = uniform(TEX.redSand),           -- or cube(top, side, bottom)
    color = C(190, 100, 50),              -- fill/fallback tint
    material = Enum.Material.Sand,
    placeable = true,                     -- players can place it
    -- opaque = false, alpha = 1,         -- for glass/leaves/plants (cutout)
    -- tintGrass = true,                  -- top tinted by biome grass colour
    -- render = "cross"/"vine"/"fluid",   -- non-cube (coming with plants/water)
    -- light = 15,                        -- emission (coming with lighting)
}
```

## Texture format

- **Pixel art upscaled to ~1600×1600** (bilinear stays crisp; see the existing
  grass/stone textures). One image per face.
- **Cube block** needs `top`, `side`, `bottom` — but `uniform(tex)` reuses one
  image for all faces (most blocks). Only use `cube(top, side, bottom)` when faces
  differ (grass, logs, sandstone).
- **Cutout blocks** (leaves, glass, plants) need a texture **with alpha holes** —
  the part is drawn fully transparent so only the texture shows (real see-through).
- **Grayscale for biome tinting**: `grassTop` and the leaf textures should be
  **grayscale** so the per-biome colour tint produces true hues (tan savanna,
  olive swamp, bright jungle). A green texture can't be tinted to tan.

---

## Wishlist

### ✅ Stubbed now (cube) — just fill `TEX` (marked FILL in Blocks.luau)

**Soils** — `coarseDirt`, `podzolTop`+`podzolSide`, `mud`, `mossBlock`
**Sand/desert** — `redSand`, `sandstoneTop`+`sandstoneSide`, `redSandstoneTop`+`redSandstoneSide`, `terracotta`
**Stone** — `cobblestone`, `granite`, `diorite`, `andesite`, `gravel`, `clay`
**Ice** — `ice` (cutout/alpha), `packedIce`
**Woods** (top + side + leaf each) — `birch*`, `spruce*`, `jungle*`, `acacia*`
**Ores** (uniform) — `coalOre`, `ironOre`, `copperOre`, `goldOre`, `diamondOre`, `emeraldOre`
**Light** — `glowstone`

**Grayscale re-uploads (for biome colours):** `grassTop`, `oakLeaf` (and the new
leaves). Swap these and every grass/leaf biome instantly gets its BoP hue.

### 🌊 Water (next step 2) — Roblox water render + voxel logic
- `water` — rendered as Roblox Terrain water (physics/swim) where voxel logic says
  a cell is water; no texture needed (uses Roblox's water look). Optional `waterOverlay`.

### 🌿 Plants / foliage (step 3) — **render = "cross"** (X-shaped, on ground)
Single texture each, with alpha:
- `tallGrass`, `fern`, `largeFern`
- Flowers: `poppy`, `dandelion`, `blueOrchid`, `allium`, `oxeyeDaisy`, `cornflower`,
  `tulipRed/Orange/White/Pink`, `lavender` (BoP)
- `deadBush`, `sapling` (oak/birch/spruce/jungle/acacia), `mushroomRed`,
  `mushroomBrown`
- Tall (2-block): `sugarCane`, `bamboo`, `cactusTop`+`cactusSide` (cactus is a
  slim cube, not cross)

### 🪝 Vines / hanging (step 3) — **render = "vine"/"hang"**
Single texture, alpha, sticks to a surface:
- `vine` (clings to vertical walls)
- `glowBerryVine` (hangs from ceilings, **light = ~12**) ← the glow-in-the-dark one
- `roots`, `hangingMoss`
- `kelp` (underwater vertical, with water)

### 💡 Light emitters (step 3/4) — any render + `light`
- `torch` (small on floor/wall, ~14) — mineshaft/cave lighting
- `lantern` (hangs), `glowLichen` (flat on surface), `shroomlight`, `seaLantern`,
  `amethystCluster`
- `magmaBlock` (dim glow), `lava` (fluid, bright) — later

### ⛏️ Structure / mineshaft blocks (later — for generated structures)
- `oakPlanks`, `woodFence`, `ladder`, `rail`, `cobweb`, `mossyCobblestone`,
  `chest`, `barrel`, `torch` (reuse)

---

## Render types (engine support)

| type | status | shape |
|---|---|---|
| `cube` | ✅ working | full block, greedy-merged |
| `fluid` | step 2 | Roblox water, voxel-driven |
| `cross` | step 3 | two crossed quads (plants) |
| `vine` / `hang` | step 3 | flat quad on a surface |
| `light` (field) | step 4 | any shape + PointLight from `light` |

Fill whatever you like from the ✅ list and I'll map them into biomes as they land;
the rest arrive with their steps (water → plants → lighting).
