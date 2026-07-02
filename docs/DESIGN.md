# Voxl — Game Design

Status: **living design doc.** Captures the vision and the open decisions.
Technical/agent notes live in `/CLAUDE.md`; terrain/biome spec in `WORLDGEN.md`.

## Pillars

1. **Immersive infinite voxel world** — deterministic, client-rendered, cheap to
   stream. Minecraft-grade terrain, Growtopia-grade social/building.
2. **Named persistent worlds** — you type a name, you get a world; anyone can
   join any world by name.
3. **Freedom by default, protection by choice** — unclaimed land is fully open
   (anyone digs/places). A **lock** protects an area (and its contents) for its
   owner. Freedom is the point; the lock is opt-in property.
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

## 2. Locks (property + protection)

**Unclaimed land is 100% free** — anyone can dig terrain and place blocks
anywhere there is no lock. That freedom is the core feel (classic Growtopia
openness). A **lock** is the *only* protection mechanic, and it's opt-in.

A lock is an item a player places. It claims a **cylinder**: a circle of a given
**radius** in XZ, **unbounded in Y** (floor to sky). Inside a lock, only the
owner (and players the owner trusts) may dig, place, or interact with contents.

- **Cylinder, not cube.** A radius covers a natural build footprint at any height
  — a 50-block-radius small lock is plenty for a starter house — and never has to
  reason about vertical limits. Simple to check: `dist2(x,z, lock.x,lock.z) <=
  r²`.
- **Radius = tier.** Bigger radius costs more (currency for small, Robux for
  large). Exact radii TBD; small ≈ 50.
- **The lock is property + gameplay in one.** It gates building *and* access to
  what's inside — houses, chests, doors. One mechanic delivers ownership,
  security, and the monetization hook. This is the whole point.

Rules:

- Outside every lock: free-for-all build/break by anyone.
- Inside a lock: owner + trust list only (build, break, open containers).
- Locks **can't overlap** another player's lock (first-come). A lock records
  owner + trust list + radius.
- Locks gate *editing/interaction*, never *visibility* — everyone still sees all
  terrain and structures (client-rendered). A lock is a data record checked on
  edit/interact; it has nothing to do with the mesher.

**Open:** upkeep/decay for abandoned locks? refunds/moving a lock? nesting or
resizing? a visible lock-area boundary effect?

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
