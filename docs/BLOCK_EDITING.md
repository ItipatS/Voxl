# Block Editing (dig / place)

The foundation feature. Everything (caves-by-digging, houses, locks, economy)
sits on it. This doc is the plan + the open decisions to settle before building.

## Core model: deterministic base ⊕ edit diff

The world is `base ⊕ diff`:

- **base** = `WorldGen.blockAt(...)` (deterministic, free, never stored).
- **diff** = a sparse map `cellKey -> blockId` of everything a player has
  changed. A broken block is `diff[key] = Air`; a placed block is
  `diff[key] = SomeBlock`. Only the diff is ever stored/transmitted.

`resolvedBlockAt(wx,y,wz)` = `diff[key]` if present, else `base`. Both the mesher
(rendering/collision) and the server (validation/pathfinding) read through this.
Key = packed `(wx,y,wz)`.

## Data flow (server-authoritative)

```
player aims + clicks
  -> client raycasts collision box -> target cell (+ face for placement)
  -> client sends EditRequest{ cell, action=break|place, block }
server:
  -> validate: reach, cell is loaded, lock permission, valid block, rate limit
  -> apply to the world diff, persist (debounced)
  -> broadcast Edit{ cell, block } to everyone in the world
clients (incl. sender):
  -> apply Edit to local diff -> re-mesh the affected chunk (+ border neighbor)
```

**Open decision — prediction:** do we apply the edit **optimistically** on the
sender's client immediately (snappy, but must roll back if the server rejects),
or wait for the server `Edit` broadcast (simpler, ~1 RTT of lag)? Recommend:
start **server-confirmed** for correctness, add optimistic prediction later.

## Re-meshing

- An edit re-meshes the **one chunk** containing the cell. If the cell is on a
  chunk border (local x/z is 0 or 15), also re-mesh the touching neighbor (shared
  face). Re-mesh = `RecycleChunkModel` + `BuildChunk` (~1–7 ms, fine per edit;
  batch/throttle for rapid edits or mass tools).
- The mesher must read `diff`, and its **Y range must grow to cover edits**:
  today it meshes `[CAVE_FLOOR, maxSurfaceY]`. Placing blocks above the surface
  (building up) or digging below needs per-chunk tracked edit `minY/maxY` so the
  solidity grid spans them.

## Target selection

- Raycast from the camera along view dir, `FilterType=Include` on the chunk
  collision parts (already `CanQuery=true`), max distance = reach.
- **Break cell** = `floor((hit.Position - hit.Normal*0.5*BLOCK_SIZE)/BLOCK_SIZE)`.
- **Place cell** = `floor((hit.Position + hit.Normal*0.5*BLOCK_SIZE)/BLOCK_SIZE)`.
- **Open decision — reach**: default ~5–6 blocks (≈ 18–21 studs).
- A wireframe/highlight box on the targeted cell (the classic Minecraft outline).

## Block palette

Terrain uses `BLOCK` (Air, Grass, Dirt, Sand, Stone, Snow). Building needs more
(Wood, Planks, Brick, Glass, ...). The palette is shared client+server; the
mesher needs a colour+material per id. `diff` stores the id, so **the palette id
space is a permanent contract** — never renumber existing ids (worlds store
them). Add new ids append-only.

**Open decision — v1 blocks:** minimal set to prove the loop (e.g. break returns
the block to a hotbar, place from hotbar), or a fixed creative palette?

## Special / data blocks (the "block entity" layer)

Chests, doors, signs, the lock itself — blocks that are non-cube, interactive, or
carry data — should **not** go through the voxel mesher (it assumes full cubes).
Instead: a separate layer of **block entities** = a real Roblox model placed at
the cell + a data record keyed by cell (chest contents, sign text, lock
owner/radius). The mesher renders terrain; block entities render themselves.

This keeps the mesher simple and is how locks/chests/doors get their gated
interaction (checked against the lock the same way edits are).

## Persistence

- Per world: `diff` + block-entity data + locks + metadata, keyed by world name
  (DataStore; **Lyra** is already vendored). Save debounced on edit + periodic +
  on world close; load on open.
- Watch DataStore key size (4 MB): serialize per-chunk, only store non-empty
  chunks, compress if needed. Deterministic base means only edits are stored.

## Future-prone list (things that will bite if ignored)

1. **Palette ids are forever** — append-only; never renumber. Version the format.
2. **Block states / orientation** (slabs, stairs, rotated logs, open doors) —
   the cube mesher can't express these. Either keep them as block entities
   (models) or extend the diff value to `(id, state)` later. Decide the diff
   value shape now so it's future-safe: recommend `diff[key] = id` for cubes and
   push everything stateful to block entities.
3. **Re-mesh under load** — mass edits/explosions must batch re-meshes (dirty-set
   of chunks flushed per frame within a time budget), not re-mesh per block.
4. **Diff growth** — big built worlds hit storage limits; chunked + compressed
   storage from the start avoids a painful migration.
5. **Cross-chunk / cross-Y edits** — border re-mesh and the growing Y range must
   be handled from day one (above).
6. **Free-area griefing is intended** (freedom), but decide if unclaimed terrain
   ever "heals"/reverts to reclaim storage, or persists forever.
7. **Fluids** (place/dig near water, flow) — out of scope for v1; the diff model
   supports it later.
8. **Anti-cheat** — server validates reach, permission, rate; never trust the
   client's target cell blindly.
9. **Determinism vs. gen changes** — if `WorldGen` changes later, existing diffs
   were authored against the old base; version the gen ruleset per world.

## v1 scope (proposed)

Break + place full-cube blocks in **unclaimed** areas, server-confirmed, with a
target highlight, a tracked diff, per-chunk re-mesh with a growing Y range, and a
small hardcoded palette — **no persistence, no locks yet** (added right after).
Proves the loop end-to-end so persistence and locks layer on cleanly.
