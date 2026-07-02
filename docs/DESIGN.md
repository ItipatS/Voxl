# Voxl — Game Design

Status: **living design doc.** Captures the vision and the open decisions.
Technical/agent notes live in `/CLAUDE.md`; terrain/biome spec in `WORLDGEN.md`.

## Pillars

1. **Immersive infinite voxel world** — deterministic, client-rendered, cheap to
   stream. Minecraft-grade terrain, Growtopia-grade social/building.
2. **Named persistent worlds** — you type a name, you get a world.
3. **Own your space** — claim/lock land to build; unclaimed land is protected.
4. **MMO-capable** — a deterministic grid makes server-side collision and
   pathfinding nearly free, so many players + NPCs per world is realistic.

---

## 1. Worlds (`world = name`)

Enter a name → if it doesn't exist, it's created; if it does, you visit it.

- **World name → seed** by hashing the name. The base terrain is fully
  deterministic, so a world costs **zero storage until someone edits it**. This
  is the big advantage over Growtopia's fixed grids: worlds are infinite and
  free to spin up.
- **Persistence per world** = only the *diffs*: a sparse set of edited blocks +
  the claim/lock records + world metadata (owner, settings). Stored per world
  name (DataStore / a datastore lib like Lyra, already vendored).

### Discrete worlds vs. one infinite MMO — the tension to resolve

"World per name" (discrete rooms, Growtopia) and "make it an MMO" (one big
shared world) pull in different directions. **Recommended hybrid:**

- The **named world is the unit**. Each named world is its own shared server
  instance that can host **many concurrent players** (a mini-MMO per world).
- **Inside** a world it's still infinite + procedural + claimable.
- Popular worlds scale out (reserved servers / matchmaking); quiet worlds sleep.

This keeps "type a name, get a world" *and* "lots of people in a world together"
without needing global cross-server sharding on day one. Global sharding of a
single mega-world can come later if desired.

**Open:** max players per world instance; how visiting/teleport between worlds
works (a hub/menu — `Server/services/Menu` already exists); private vs public
worlds.

---

## 2. Claims / Locks (build permission + monetization)

Growtopia's World Lock / Area Lock, generalized to 3D cubes. A **lock** is an
item you place; it claims a cube and grants build/break rights inside it.

| Lock tier | Cube edge (blocks) | Volume | Acquire with |
|---|---|---|---|
| Small claim | 10 | 10³ = 1e3 | in-game currency |
| Large claim | 100 | 100³ = 1e6 | currency (expensive) or Robux |
| Region claim | 1000 | 1000³ = 1e9 | Robux (premium) |
| **World lock** | whole world | — | Robux (premium, world owner) |

Rules (recommended):

- **Building requires a claim you own or are trusted in.** Unclaimed land is
  **protected** (view/mine-only or fully read-only — see open question). This is
  griefing-proof by default, unlike Growtopia's open chaos, and it's a natural
  sink for the economy.
- Claims **can't overlap** another player's claim. A lock records owner + a
  trust list (friends allowed to build).
- **World lock** = the world owner gets build rights everywhere in that world
  and admin controls (kick, world settings, spawn). This is the premium anchor.

### My take on whether this works

Yes — it's a proven loop (Growtopia monetizes locks heavily) and it maps cleanly
onto a voxel grid. Two things to get right:

1. **Land monopoly.** 1000³ = a *billion* blocks. In an infinite world that's
   fine spatially, but price it so it's a real Robux commitment, and consider a
   **per-player claim cap** or upkeep so whales can't fence off spawn.
2. **Rendering ≠ permission.** Locks gate *editing*, not *visibility*. Everyone
   still sees all terrain (it's deterministic and client-rendered). Keep those
   two concepts separate in code — a lock is a data record checked on
   place/break, nothing to do with the mesher.

**Open:** is unclaimed land fully read-only, or mine-only (you can dig but not
place)? Claim shape — always a cube anchored at the lock, or a selectable box?
Upkeep/decay for abandoned claims? Refunds?

---

## 3. Economy

- **Soft currency** (coins/gems) from gameplay: mining ores, selling, quests,
  daily play. Buys small claims, basic blocks, tools.
- **Robux** for premium: large/region/world locks, cosmetics, world-name
  vanity, maybe render-distance-independent perks.
- Ores/resources are the gameplay sink+source and tie directly into WORLDGEN
  (ore distribution per biome/depth — see `WORLDGEN.md`).

**Open:** trading between players; a marketplace; whether blocks are consumable
(inventory) or free-place in your own claim.

---

## 4. MMO on a deterministic grid

The user's key insight, and it's correct: **the server can query any block via
`WorldGen.blockAt` (deterministic) + the world's edit diff — O(1), no stored
terrain, no Roblox physics.** That makes normally-expensive server systems cheap:

- **Server-side collision** for NPCs/mobs = grid solidity checks, not physics
  parts. (The terrain has *no server instances* — it's client-rendered — so
  server collision *must* be these grid queries.)
- **Pathfinding** = A* / JPS directly on the grid (`isSolid(x,y,z)` = base ⊕
  edits). No navmesh, no `PathfindingService`, updates instantly when blocks
  change.
- Because a block query is a few noise ops (cacheable), one server can afford
  many mobs + players.

Caveats to design around:

- **Players are client-authoritative** for movement (they own their character
  and collide against their local mesh). The server validates against the grid
  (anti-cheat: reject impossible positions using `blockAt`).
- **Edits must be in the collision query.** Server collision/pathfinding read
  `base ⊕ world.diff`, or mobs walk through built structures.
- Mob/NPC *rendering* is normal replicated models; only their *simulation* uses
  the grid.

This is the feature that makes "Voxl MMO" plausible where a physics-based voxel
game wouldn't be.

---

## Roadmap (suggested order)

1. **Block editing** — break/place. Raycast → grid cell (parts already
   `CanQuery`), write to the world diff, re-mesh the affected chunk (cave-aware,
   widen the meshed Y-range around the edit). Foundation for everything else.
2. **World persistence** — per-name seed + diff + metadata (DataStore/Lyra).
3. **Claims/locks** — data model + place/break permission checks + lock item/UI.
4. **World routing** — name entry → load/create → join the world server (Menu).
5. **WorldGen v2** — biomes/climate expansion (`WORLDGEN.md`).
6. **Economy + ores**, then **MMO layer** (server mobs, pathfinding).
7. **Lighting** for caves (currently pitch black).

## Reference

Biome/worldgen inspiration from open-source Minecraft biome mods (Biomes O'
Plenty, Geophilic) — see `WORLDGEN.md`.
