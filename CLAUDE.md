# CLAUDE.md — Voxl

Guidance for AI agents working in this repo. Read this first.

## What Voxl is

An infinite voxel sandbox for Roblox — **Minecraft × Growtopia**: procedurally
generated, freely buildable, immersive client-side rendering, with named
persistent worlds and a claim/lock economy. See `docs/DESIGN.md` for the game
vision and `docs/WORLDGEN.md` for the terrain/biome plan.

**The one idea that makes everything work:** the terrain is 100% deterministic
(`WorldGen`). Both client and server can regenerate any block from its
coordinates alone. So the server never ships block data — it streams **chunk
coordinates** (~4 bytes each) and the client generates + renders locally. Player
edits are a sparse diff layered on top of the deterministic base.

## Toolchain & running

Tools are managed by **rokit** (`rokit.toml`): `rojo`, `blink`, `wally`, `lune`.

- Sync to Studio: `rojo serve` (uses `default.project.json`).
- Install deps: `wally install` (populates `Packages/`; **wally-managed, do not
  hand-edit `Packages/`**).
- Regenerate networking: `blink Net.blink` (see below).
- There is **no CLI test suite**; verification is done live in Studio via the
  Roblox Studio MCP (`execute_luau`, `screen_capture`, `Stats`). Measure, don't
  assume.

## Layout

```
src/
  Misc/WorldGen.luau      deterministic terrain: getColumn, materialAt, blockAt (cave-aware)
  Misc/Mesher.luau        3D greedy mesher -> pooled Parts (visual AND collision)
  Client/ChunkClient.luau nearest-first, time-budgeted meshing around the player
  Server/systems/         ECS systems started by main (ChunkServer, players, spawn)
  Server/services/        larger subsystems (PlacementService, EventManager, Menu, SunAnim)
  ClientServices/         build controller, input, UI/inventory, weather/visual FX
  std/                    ECS framework: jecs world, scheduler, phases, components, ...
Net.blink                 networking IDL -> src/Server/ServerNet.luau + src/std/ClientNet.luau (GENERATED)
```

## The terrain pipeline (core of the game)

1. **`WorldGen`** — pure/deterministic. `getColumn(wx,wz) -> surfaceY, biomeId`;
   `materialAt(y,surfaceY,biomeId)`; `blockAt(...)` adds cave carving +
   entrances. `CHUNK_SIZE = 16`, `BLOCK_SIZE = 3.5`, world seeded by `BASE_SEED`.
2. **`ChunkServer`** (server) — per player, sends the coordinates of chunks in
   `LOAD_RADIUS`, nearest-first, **no rate throttle** (coords are tiny). Unloads
   out-of-range coords.
3. **`ChunkClient`** (client) — meshes chunks the server asked for, **nearest
   first**, bounded by a per-frame **time budget** (`MESH_TIME_BUDGET`) so plains
   blast through and a mountain never spikes the frame. No neighbor gating
   (boundary faces are deterministic).
4. **`Mesher.BuildChunk(chunk, parent)`** — builds a cave-carved solidity grid
   for the chunk (+1 border), 3D-greedy-merges exposed blocks into solid boxes.
   Each box is BOTH the visual (material+colour) and the collision
   (`CanCollide`, `CanQuery` for future raycast-to-cell). Parts are pooled.

## Networking (Blink)

`Net.blink` is the source of truth. `ServerNet.luau` / `ClientNet.luau` are
**generated — never hand-edit them** (they carry a "not meant to be edited"
header). Change the schema and run `blink Net.blink`. Current events:
`LoadChunks` (server→client, `ChunkCoord[]`) and `UnloadChunks` (string keys).
Consult the `blink` skill before editing schemas.

## ECS / scheduler

`std/scheduler.luau` is a jecs-backed phase scheduler. `scheduler.SYSTEM(fn,
phase)` registers; `main/init.server.luau` requires every module under
`systems/` then `COLLECT()` + `BEGIN()` wires them to their event (Heartbeat,
etc.). **`begin()` must actually call each system's callback** — a past refactor
that removed the profiler accidentally emptied that loop and silently killed all
systems (no streaming, no errors). If systems mysteriously don't run, check
that first.

## Gotchas (learned the hard way)

- **Rojo sync drift**: Studio sometimes runs a stale copy of a file even though
  disk is correct (seen with `main` and `scheduler`). Symptom: behavior doesn't
  match the code and there are no errors. Fix: touch/edit the file to force a
  re-sync, then restart Play.
- **EditableMesh is NOT viable** for chunks: a persistent `MeshPart` keeps its
  source `EditableMesh` alive, and in-experience only ~8 live editable meshes are
  allowed before the budget is exhausted. We use pooled `Part`s instead. Don't
  reach for EditableMesh again for terrain.
- **jabby is optional**: the scheduler/profiler must run without it (it may be
  absent from `Packages/`). Don't hard-require it.
- **Determinism is sacred**: `getColumn`/`materialAt`/`blockAt` must stay pure
  and identical on client and server, or terrain desyncs. Any change to
  generation changes every existing world's terrain.
- **Studio Play FPS is throttled** when the window is unfocused (~15–36 fps
  flat). Judge performance by `Stats` CPU/mem and part counts, not the FPS
  counter, when driving via MCP.
- `CHUNK_SIZE = 16`, `BLOCK_SIZE = 3.5`. World Y = block Y × 3.5.

## Conventions

- Match the surrounding file's style. Luau with `--!strict`/`--!native`/
  `--!optimize 2` headers where present.
- Prefer measuring in Studio (MCP) over guessing; screenshot visual changes.
- Commit only when asked. Keep dependency/`Packages/` churn out of feature
  commits.
