# Voxlstar

A voxel builder-gatherer on Roblox: an unlimited procedural universe of small
worlds you explore, gather in, and eventually claim as a permanent home.

The interesting part isn't the game loop — it's that **the client renders the
world and the server never holds a single terrain part.** Everything below
follows from that.

Demo - https://www.roblox.com/games/126553668196124/Voxlstar-Demo

---

## The constraint that shapes everything

Roblox replicates every `Workspace` instance to every client. So a server-built
voxel world means every player downloads the whole world — and the server holds
it too, at ~1 KB of engine state per part. An 896-block world is ~2,400 chunks ×
~350 boxes ≈ **840,000 parts**. That is dead before anyone joins.

So terrain is **generated and meshed on the client**, and the server sends the
least it can get away with:

| world type | what crosses the wire |
|---|---|
| procedural star | **chunk coordinates only** — zero block bytes. Both sides derive terrain from one shared seed, so they cannot disagree |
| imported (baked) world | one deflated chunk record, ~800 B, as you walk into range |

Server cost is O(players), not O(world). Ten players in ten different stars cost
ten teleports, not ten worlds.

## Rendering

A **3D greedy mesher** merges runs of identical blocks into the fewest boxes that
reproduce the world exactly. On the imported map that's **351 boxes per chunk**
where one-part-per-block would be thousands.

Doubled or overlapping parts are close to invisible in a voxel world — the world
looks right and the frame rate quietly dies — so the invariant is *tested*, not
assumed. `tools/mcimport/test_mesher.luau` runs the real mesher against both a
synthetic field and the real imported map and asserts **every cell is covered at
most once**.

Other things the renderer does, each because a measurement said so:

- **Budgets new INSTANCES per frame, not milliseconds.** A cheap chunk meshes in
  ~0.05 ms, so a 5 ms Luau budget built ~100 chunks in one frame and handed the
  engine ~35,000 parts. The engine ingests those inside `RenderViewUpdate`, on the
  main thread, where no script timer can see it — the profile shows a 50 ms render
  bar with no Lua under it and reads as "the renderer is slow."
- **Fast leaves.** Leaves are ~30% of all boxes and were fully transparent, which
  put ~30,000 parts into a per-frame depth sort — standing still. They now draw the
  same cutout texture on an opaque part coloured with the texture's own
  alpha-weighted mean.
- **Water is Roblox Terrain**, not parts: one render object instead of thousands of
  transparent ones, and swimming, buoyancy and underwater fog come free.
- Live tuning knobs (`RenderRadius`, `TextureRadius`, `MeshBudget`, `FancyLeaves`)
  as `Workspace` attributes — graphics settings for a weak client, not fixes.

## Importing a real Minecraft world

`tools/mcimport/` reads Minecraft's Anvil format in **pure Node, no dependencies**
— location tables, zlib chunk streams, NBT, palette + packed-long block states —
and bakes it into a custom column-run format (**VXM3**).

Roblox has no inflate, so `src/Misc/inflate.luau` is a **raw DEFLATE decoder
written in Luau**, structured after zlib's `puff` and validated against Node's
zlib.

An 896 × 896 world ships as **1.9 MB** in `ServerStorage`, streamed a chunk at a
time. `test_reader.luau` decodes the shipped blob with the real production reader
and diffs it against the original `.mca` files.

## Verification without playtesting

Every load-bearing invariant is checked by running the **real modules** outside
Roblox under [lune](https://lune-rs.github.io/):

| harness | proves |
|---|---|
| `test_mesher` | no cell is ever covered twice; per-block box census |
| `test_reader` | the shipped world matches the Minecraft source |
| `test_itemdb` | every block round-trips to an item; no id or key collides |
| `test_inflate` | the Luau DEFLATE decoder matches Node's zlib |
| `syntax` | every file compiles (run after every edit) |

## Stack

Luau (`--!strict`), [jecs](https://github.com/Ukendio/jecs) ECS with a phase
scheduler, [Blink](https://github.com/1Axen/blink) for buffer-packed networking,
ProfileStore, Rojo, Rokit, lune. Textures are uploaded through Roblox **Open
Cloud** by `tools/textures/`, which writes the block → asset-id table itself —
no asset id is ever typed by hand.

## Also in here

- **One inventory across both places.** Blocks are ordinary items (`block_<id>`,
  with a `placesBlock` field), so the same 54 slots hold materials, tools and
  blocks. Breaking a block can *fail* when you're full — slots are finite.
- **Single-live routing.** `StarRouting` keeps `starId → reserved server access
  code` in MemoryStore, so everyone entering the same star meets on one server.
- **Seed + edits only.** A world is a seed and a diff table, which is what makes
  an unlimited frontier of permanent homes affordable to host.
