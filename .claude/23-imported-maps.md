# 23 — Imported maps (baked worlds)

**Status: [DECIDED] for the mechanism, [TUNE] for which crop ships.**

A star's world is normally *rolled* — a seed plus a biome mix, generated identically
on server and client (doc 21). This doc adds the second kind: a **baked world**,
imported from a real Minecraft save. The first one is `FantasyMedieval` — the
*Fantasy Medieval 1.21.4* map — reachable from any of the five **hub-towns**.

Companion docs: **23a** (block coverage — the generated inventory of what an
imported map actually needs), 16 (engine baseline — the layer rules this obeys),
21 (biomes and bounded-star worldgen), 13/15 (worlds and storage).

---

## 1. Why this fits the design rather than fighting it

The explore-and-claim universe is procedural on purpose: unlimited stars cost
almost nothing because a world is *seed + edits*. A baked world breaks that — it
IS bytes. So it is deliberately rare and deliberately special:

- **It belongs on a HUB, not on the frontier.** The five hub-towns are already the
  fixed geography: always there, same for everyone, never reshuffled. That
  permanence is exactly what justifies baking static data for one. A frontier star
  has to stay a seed, because there are unlimited numbers of them — pinning a
  hand-authored world inside a generator built to reshuffle would be fighting it.
- **Everything else is unchanged.** A baked star is still bounded, still
  server-authoritative, still editable, and its edits still persist through the
  same `WorldDiff` / `WorldStore` path as any other star. Baking replaces where
  the *base* terrain comes from, and nothing else.

---

## 2. The one seam: three functions

Every system that touches terrain — the mesher, block editing, spawn placement,
lock claims — goes through exactly three `WorldGen` calls. Baking swaps what
answers them, so nothing else in the codebase knows or cares:

```
                    procedural                     baked
getColumn(wx,wz)    noise → height + biome         column top + B_IMPORTED
getSurfaceHeight    same height                    column top
blockAt(...)        materials + caves + trees      a lookup in the blob
```

`WorldGen.applyPrebaked(map)` flips the switch; `applyStar*` flips it back. A star
config gained one optional field:

```lua
{ seed, radius, biomes, map: string? }   -- `map` names a baked world
```

When `map` is set the seed and biomes are ignored — the terrain is imported, not
rolled. The name rides to the star place in `TeleportData.starMap`.

---

## 3. Where the data lives: server-only, streamed by the chunk

**The map is never shipped to a client.** That rules out the obvious approach
(bundle it in `ReplicatedStorage`), because one codebase builds both places, so
every lobby player would download a map they will never visit.

Instead the shape is the one every voxel game converges on:

```
  ServerStorage.MapData.<Name>      ← 1.9 MB of base64, server-only,
        │                              never replicated to anyone
        │  PrebakedMap.open()
        ▼
  ChunkServer  ──MapChunks──►  PrebakedMap.receiver()  ──►  WorldGen  ──►  Mesher
   (~550 B per chunk,             client, starts EMPTY
    still compressed)             and fills in as you walk
```

- **The lobby ships nothing.** `ServerStorage` does not replicate, so a lobby
  client downloads zero bytes of map data.
- **A star client downloads only what it visits.** ~550 B per chunk; a full 17×17
  view is ~156 KB. Walking the whole 896×896 island would eventually cost the
  1.4 MB it's worth, and most players never will.
- **The server never decompresses to forward.** Records are stored deflated and
  sent deflated, so streaming a chunk costs the server a table lookup.
- Records are sent **immediately before** the `LoadChunks` that announces the
  chunk, in the same reliable flush, so the data is always in hand before the
  client tries to build it. A client also refuses to mesh a chunk until all eight
  neighbours have been announced — otherwise the mesher would read a
  not-yet-arrived neighbour as empty and grow a wall along the streaming frontier.
- `starconfig.applyServer` / `applyClient` are the two entry points; the client is
  handed only the map's **meta** (grid origin/size, radius, y floor) on a
  replicated attribute — six numbers, not the world.

> A DataStore would also keep the map out of the lobby, but it is the wrong home
> for immutable content: 4 MB per key, a manual upload step, and the client still
> has to be fed the blocks somehow. The only thing it buys is swapping a map
> without republishing. `PrebakedMap.open` takes a plain source table, so adding a
> DataStore-backed source later touches one function and nothing else.

---

## 4. Storage format (VXM3)

A Minecraft column is ~380 blocks tall and almost all of it is undifferentiated
rock. Four ideas take the 896×896 island from ~11 MB to **1.9 MB**:

1. **Store only the visible shell.** A column is stored from its top down to the
   first run of solid natural rock; below that, the runtime returns `Stone`. The
   inside of an island is never seen, so it costs nothing. (Caves and ravines
   interrupt that run, so a column also stops 24 levels below the *first* rock —
   otherwise a handful of ravines would drag the whole world's Y range down.
   Columns with nothing under them at all — airships, cloud islands — keep
   descending, because stopping early would put the implicit stone floor in
   mid-air, as a pillar under every cloud.)
2. **RLE each column.** ~4 runs per column on this map.
3. **Compact empty vertical bands at bake time.** This map has a low island near
   y=20, ordinary terrain at y=62, and a wool-and-sea-lantern sky layer at y≈265
   with 40 completely empty levels beneath it — together more than a `u8` y can
   hold. Bands containing no blocks anywhere are squashed. Empty is invisible, so
   nothing is lost; the sky just hangs lower. Purely a bake-time remap.
4. **DEFLATE each chunk record on its own** — 6.4 MB → 1.4 MB (21%). Per-chunk
   compression lands within a few percent of compressing the whole blob (a chunk's
   256 columns are highly self-similar) while keeping every chunk independently
   decodable, which is exactly what the streaming above needs.

```
header  "VXM3" | i16 cx0 | i16 cz0 | u16 nx | u16 nz | u16 radius | u8 yFloor | u8 flags
index   nx*nz × { u32 offset, u32 compLen, u16 rawLen }    compLen 0 = void chunk
record  deflate-raw of
        256 columns × { u8 yBot, u8 nRuns, nRuns × (u8 id, u8 len) }
```

Integers are big-endian (Node wrote them); `PrebakedMap` swaps on read. Chunk
coordinates are **Voxl** chunk coordinates with the crop centre at world (0,0).
Below `yBot`: `Stone`. Above the last run: air. `nRuns == 0` means a void column.

**Leading air is never folded away.** It looks like free compression, but "below
`yBot`" means solid island, so folding would turn a cave mouth or an overhang at
the world floor into a wall of stone. (This was a real bug; the round-trip test
catches it.)

### Decompression

Roblox has no built-in decompressor, so `Misc/inflate.luau` is a raw-DEFLATE
decoder (RFC 1951 — stored, fixed and dynamic Huffman blocks), structured after
zlib's `puff` reference: correctness over throughput, because it only ever runs on
~550-byte records. It measures ~2.7 MB/s, i.e. **under a millisecond per chunk**.
`tools/mcimport/test_inflate.luau` checks it against Node's zlib across every
block type, all ten compression levels, and the whole 6.4 MB blob.

Decoded chunks are cached (~600, about 20 MB; a render radius of 8 needs ~290) and
dropped when the server unloads them.

---

## 5. The block registry grew (ids 39–189)

An imported map is mostly *building materials*, which Voxl had none of.
`Blocks.luau` now defines **189 blocks** in four waves:

| ids | what |
|---|---|
| 1–38 | the original terrain set |
| 39–72 | **builder set** — water, lava, stone bricks, cobblestone variants, six plank types, quartz, prismarine, glass, metal blocks, hay/bookshelf/pumpkin |
| 73–136 | **dyed families** — Wool / Terracotta / Concrete / Glass × 16 dyes, generated from a fixed dye order |
| 137–155 | **identity blocks** — things that were collapsing onto something else and losing their character: iron bars, deepslate, cobbled deepslate, deepslate bricks, bedrock, tuff, calcite, basalt, blackstone, obsidian, magma, cactus, cracked/chiseled stone bricks, chiseled quartz, netherrack, nether bricks, polished granite/diorite |
| 156–189 | **slabs** — 17 materials × {bottom, top} |

Deliberately NOT given ids: **chest, barrel, crafting table, furnace, dropper** —
those are functional blocks doc 22 will build as real crafting stations, and a
decorative twin now would only be in the way. Imports map them to their material
(planks, cobblestone), so a furnace built into a wall still leaves a wall rather
than a hole. Same call for **cut sandstone** and **blue ice**: too close to their
parents to be worth an id.

**147 are load-bearing for this map.** Doc 23a §0 lists the whole palette with
per-block usage, so "do we have X?" is answerable without reading code.

### Slabs are real geometry; stairs are not

`BlockDef.shape = "slab"` means half height, sitting at the bottom of its cell (or
the top, for `top = true`). The mesher sizes the part accordingly and **refuses to
merge slabs vertically** — two stacked slabs are two half blocks with a gap, not one
tall box. They're also excluded from same-block face culling, or a slab directly
above another would cull the lower one's top face and punch a hole through it.
A Minecraft `type=double` slab is simply the full block.

Stairs still collapse to the full block: a stair's diagonal has nowhere to live in a
cube grid. The map has 29k stairs and 46k slabs, so this recovers the larger half.

Two rules with teeth:

- **Id order is load-bearing.** Baked maps store raw ids. `Blocks.luau` and
  `tools/mcimport/voxlids.js` build the dyed families, identity blocks and slabs
  from the same ordered lists, and `test_ids.luau` fails if they ever disagree.
  New ids append after 189; the format's `u8` leaves room for ~66 more.
- **These blocks are texture-less on purpose.** `BlockDef.tex` is optional; they
  render as flat colour + material. A debug-texture placeholder on 150 blocks looks
  far worse than clean flat colour. The mesher and `BlockPreview` both branch on
  "no texture".

### Adding textures

`tools/textures/upload.js` uploads image files through Roblox Open Cloud and
generates `Misc/BlockTextures.luau` (block name → per-face asset ids), which
`Blocks.luau` applies over its defs *before* slabs clone their parents, so slabs
inherit their material's texture. Filenames resolve through the same `blockmap.js`
the importer uses, so a Minecraft resource pack drops straight in.

This is **purely additive**: baked data stores block *ids*, and textures are
appearance, so adding them never needs a re-bake and never shifts an id. Auth is an
Open Cloud **API key**, not OAuth — and note Open Cloud has no endpoint that lists
assets you own, which is why the tool uploads rather than fetches: the id comes
back from the upload and is cached, so no id is ever typed by hand. Details:
`tools/textures/README.md`.

## 6. Two engine changes this forced

Both are strict improvements to the procedural game as well:

- **Same-block face culling.** A face between two cells of the *same* block is now
  hidden, not just a face against an opaque one. Without it an ocean meshes its
  entire volume instead of its skin, because every water cell sees a non-opaque
  neighbour. Leaves benefit too.
- **Non-solid blocks.** `BlockDef.solid = false` (water, lava) makes the mesher emit
  parts with `CanCollide` and `CanQuery` off — you fall through them, and they don't
  eat the raycast that block editing fires at the world. *There is no swimming yet:
  you sink to the seabed and walk. See §9.*

Plus one that only matters here: **the mesher's floor is per-chunk.** It used to
start at the constant cave floor; it now asks `WorldGen.meshFloor(cx, cz)`, and a
baked map answers from its own index. On this map that cuts the average meshed span
from 94 levels to 40.

---

## 7. The pipeline (`tools/mcimport/`)

Pure Node, no dependencies — Anvil is zlib + NBT, both built in.

| file | does |
|---|---|
| `nbt.js` / `anvil.js` | read `.mca` regions → chunk sections + palettes |
| `blockmap.js` | Minecraft block name → Voxl id + preview colour, by rule not by table (`<wood>_stairs`, `<dye>_terracotta`, …). Stairs/slabs/fences/panes collapse to the full block of their base material; torches, flowers and rails become air |
| `voxlids.js` | mirror of `Blocks.luau`'s id table |
| `shell.js` | the "where does a column stop being scenery" rule, shared by baker and test so they can't drift |
| `survey.js` | scan a whole save: relief + built-density PNG, hottest windows |
| `render.js` | true-colour top-down render of a crop — how you pick where to cut |
| `bake.js` | the baker → `src/ServerStorage/MapData/<Name>/` |
| `inventory.js` | the block-coverage report (doc 23a) |
| `verify.js` | decode a blob back and render it; compare against `render.js` |
| `samples.js` + `test_reader.luau` | run the REAL `PrebakedMap.luau` under Lune against the REAL blob: check every sampled column against the Minecraft source, then re-check via the streaming path |
| `test_inflate.luau` | the DEFLATE decoder against Node's zlib |
| `test_ids.luau` | Luau/JS block id parity |
| `syntax.luau` | compile-check Luau outside Studio |

`--dry` reports the size without writing, which is how you choose a radius.

---

## 8. What ships today

| | |
|---|---|
| crop | MC centre (0, −350), radius **448** → an 896×896 disc, the whole island |
| contains | the red/white temple complex, the green-roofed walled town, the wooden port city, the ship fleet, the arcane circle, a frozen ocean, the sky/airship layer, ~a dozen villages |
| stored | 6.5 MB raw → 1.4 MB deflated → **1.9 MB of base64**, in `ServerStorage` |
| lobby cost | **zero** |
| star client cost | ~570 B per chunk; ~160 KB for a full view |
| block coverage | 98.6% of blocks in the shell; 147 Voxl blocks used, of 189 defined (doc 23a) |
| Voxl y | 19 … 250; typical column top 92, mesher span ~40 |
| spawn | baked in: block (−5, 79, 3), picked as dry + flat + as central as possible |
| reachable from | all five hub-towns on the 30k constellation ring (`std/constellation` HUBS) |

**Verified:** every sampled column's top is exact, every shell block matches the
Minecraft source run for run, nothing floats above a column top, the island beneath
is solid, and a fresh receiver fed only streamed records agrees with the server on
every one. 0.7% of columns lose the tail of their shell to the world floor
(underwater seabed detail) — reported, not hidden.

### Dialling it down

Radius is the only knob that matters. `--radius 256` centred on the same point is
~600 KB and still holds the ships, the villages and the arcane circle; `--radius 192`
at `--cx 128 --cz -600` is just the temple. Re-bake and update
`universe.LANDMARKS[1].radius` — nothing else changes.

---

## 9. Known costs and follow-ups

- **No swimming.** Water is a non-colliding block: you sink and walk the seabed.
  Real buoyancy needs either Roblox terrain water or a swim controller.
- **The sky layer is expensive to mesh.** Chunks holding both ground and the y≈246
  cloud city span 166 levels. The time budget in `ChunkClient` keeps it to one chunk
  per frame, so it shows up as an occasional hitch near the airships, not a stall.
- **The island has no underside.** The mesher treats below-floor as solid and draws
  no bottom faces, so from beneath, the world is invisible. Fine while stars are
  walked, not flown.
- **Stairs, fences and panes are full blocks** — the buildings read chunkier than in
  Minecraft. Slabs are real half blocks (§5); stairs cannot be, in a cube grid.
- **Snow layers become full blocks**, so snowfields sit one block proud. The
  alternative was losing every snowfield on the map (55k columns).
- **Underground variety is gone by design.** Below the shell everything is `Stone`,
  so mining into a hillside finds plain rock rather than the map's ore veins.
- **Light sources are dropped** (torches, lanterns, campfires, end rods). They have
  no cube worth placing until there's a lighting pass; doc 23a lists them so they
  can be reinstated then.
