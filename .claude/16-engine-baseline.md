# 16 — Engine Baseline (read before touching any system)

This is the **map of the engine as it actually is**, written so nobody — human or
Claude — has to re-derive "where is this wired / what was this built for" mid-task.
The codebase grew as *stitches and patches from earlier games*; this doc draws the
line between what is **canonical Voxl** (build on it) and what is **ported rot**
(dormant or dead — don't build on it, don't let it confuse you).

Companion docs: **17 (items & inventory)** = the first subsystem rebuilt to this
baseline. 07 = architecture forks. 13/15 = worlds/data.

---

## 1. The one rule: dependency direction (data flows down, never up)

```
        DATA (static)         →   authoritative STATE (server)   →   MIRROR (client)   →   VIEW (UI/VFX)
   ReplicatedStorage.std/Misc      ServerScriptService              StarterPlayerScripts    Interface GUI
   itemdb, WorldGen, Blocks,       ProfileStore + jecs world        client-side caches      tooltip/tier/tween
   constellation, starsize         (weight, counts, edits)          fed only by Blink        helpers
```

- **A layer may require the layer(s) to its left, never to its right.** The server
  never requires client code; a client mirror never requires the UI; `std`/`Misc`
  never require server or client.
- **The server is authoritative for all mutable state.** The client owns *nothing*
  — it renders a mirror the server pushes over Blink. This is why there are no
  inventory races: there is exactly one writer.
- **Static data is shared and immutable** (`ReplicatedStorage`), required by both
  sides so ids/shapes never disagree.

If a new module would violate this direction, the design is wrong — fix the design,
don't add a back-channel.

---

## 2. Rojo layout → where it lives at runtime (`default.project.json`)

| repo path | runtime location | what runs it |
|---|---|---|
| `src/Server` | `ServerScriptService` | `main/init.server.luau` (the ONLY `*.server`) |
| `src/Client` | `StarterPlayer.StarterPlayerScripts` | `main.client.luau` (the ONLY `*.client`) |
| `src/std` | `ReplicatedStorage.std` | required on demand (shared) |
| `src/Misc` | `ReplicatedStorage.Misc` | required on demand (shared) |
| `src/jecs.luau` | `ReplicatedStorage.ecs` | the ECS lib |
| `src/ClientServices` | `ReplicatedStorage.ClientServices` | **dormant library** — required on demand, nothing alive requires most of it |
| `DevPackages` | `ServerScriptService.DevPackages` | ProfileStore |
| `Packages` | `ReplicatedStorage.Packages` | jecs/topbarplus/etc. |
| `src/_graveyard` | **not mapped** | never syncs — quarantined dead code |

**Consequence that matters:** the two `*.server`/`*.client` entry files are the
*single source of truth for what actually executes.* If a module isn't reached by a
require chain from one of them, **it does not run**, no matter how real it looks.
`ClientServices` is a library shelf, not a running system.

> Note: `default.project.json` maps `ReplicatedStorage.ClientSystems → src/ClientSystems`,
> which does not exist. Harmless (Rojo skips missing paths) but should be removed.

---

## 3. The engine spine (canonical — this is Voxl, build on it)

**ECS + scheduler (`src/std`)** — the runtime backbone:
- `world.luau` — the jecs world **singleton**. Require it; never pass it around.
- `components.luau` — component defs, frozen, named for jabby.
- `scheduler.luau` + `phases.luau` + `collect.luau` + `start.luau` — phase-graph
  scheduler. Systems register via `scheduler.SYSTEM(fn, phase)`; entry calls
  `COLLECT()` then `BEGIN()`.
- `mailbox.luau` (cross-system buffers keyed by component), `ref.luau` (entity refs
  by key), `interval.luau` (timing). All canonical utilities.

**Networking** — Blink IDL:
- `Net.blink` is the **source**. `ServerNet.luau` (`src/Server`) + `ClientNet.luau`
  (`src/std`) are **generated — never hand-edit**. Edit `Net.blink`, run `blink Net.blink`.
- The `blink` CLI runs directly in Bash — regenerate yourself after every `Net.blink`
  edit. Never ask the user to run it, and never hand-edit the generated files.

**Voxel core (`src/Misc`, shared):** `Blocks`, `Mesher` (greedy), `WorldGen` (terrain
+ `BLOCK` ids + `BLOCK_SIZE`), `WorldDiff`. Healthy; the game's foundation.

**Place resolver (`src/std/placemode.luau`):** one codebase, two published places.
`Mode` = `"Lobby"` | `"ResourceStar"` from `PlaceId`. Both entry files branch on it.

**Lobby config (`src/std`):** `constellation` (centre/resource-star ring/black hole/
landmarks/plant rules), `starsize` (expandTier → footprint×height), `planting`
(resident grid). All canonical, all new.

**Server systems (`src/Server/systems`, canonical):** wired BY NAME in
`main/init.server.luau`'s `LOBBY_SYSTEMS` / `RESOURCE_SYSTEMS` — a file in this folder
that appears in neither list does not run, and a name in a list with no file only warns.

- **both** — `players`, `PlayerStore`, `crafting`
- **Lobby** — `constellation`, `collectables`, `asteroids`, `PlayerState`, `dustfield`,
  `starentry`, `PrivateStarStore`, `PlantService`, `EquipService`, `devspawn`
  (+ `lobby`, listed but with no file: it warns on every boot)
- **Star** — `starworld`, `ChunkServer`, `BlockEditServer`, `EquipService`, `daynight`,
  `starexit`
- **required directly, not listed** — `WorldStore` + `LockService` (by `BlockEditServer`),
  `StarRouting` (by `starentry` and `starworld`)
- **orphaned** — `spawn` (superseded by `starworld`), `RegionSeed` (nothing requires it)

**Client (`src/Client`, canonical):** wired in `main.client.luau`.

- **both** — `UI`, `Prompts`, `CameraController` (owns first/third person on **T**),
  `Music`, `ItemMirror`, `ItemInventory`, `ItemHotbar`, `HeldTools`
- **Lobby** — `FlightController`, `FlightStun`, `DustField`, `StarRenderer`,
  `AsteroidRenderer`, `SpaceProxies`, `MawWarning`, `UniverseField`, `ZoneWatcher`,
  `CreatePlanetController`, `PlantingController`
- **Star** — `StarWorld`, `ChunkClient`, `StarFly`, `BlockEdit`, `LockController`,
  `StarExit`, plus `ClientServices.EventHandler.DayNightRenderer` (required by path,
  since `req()` only looks in StarterPlayerScripts)
- **libraries** — `FlightAnims` (shared flight animation state machine), `BlockPreview`,
  `ItemDrag`, `ItemUse`
- **graveyard** — `BlockInventory`, `Hotbar`, `InventoryRender`, `ResourceStarEntry`

**Data (durable + hot):** `PlayerStore` (THE inventory — 54 unified slots holding materials, tools AND blocks; ProfileStore),
`PrivateStarStore` (private star, ProfileStore), `RegionSeed` (MemoryStore). Schema
in doc 15.

---

## 4. The load-bearing example: ONE server-owned inventory

`PlayerStore` is the reference implementation of the dependency rule. Copy its shape
for every future stateful subsystem:

```
PlayerStore (server)            Net.blink                 client
  ProfileStore VoxlPlayer_v1      ItemSync        →   ItemMirror (read-only cache)
  54 slots: materials, tools      (server→client)      ItemInventory / ItemHotbar
  AND blocks alike                                     (render only)
  .giveItem/.consumeItem                               EditBlock / MoveItem / UseSlot /
  .add/.consume (blocks)                               EquipItem (client→server) ASK;
  syncItems() pushes full state                        server validates + re-syncs
  after every change
```

Blocks used to be a SECOND inventory beside this one — `Data.blocks`, its own
`InventorySync` channel, its own client UI — and the two places disagreed about what a
player was carrying. They are ordinary items now (`block_<id>`, doc 17), which is what
makes this diagram the whole picture rather than half of it.

One writer (server), full-state push after each change, client asks via events and
never mutates its own counts. **No races, no desync, no "who owns this."** Doc 17
generalizes exactly this into an item layer.

---

## 5. Ported rot — dormant or dead (do NOT build on it)

`ClientServices` is a graft from earlier RPG projects. **Nothing in the running
require-chain reaches it.** Categories:

| status | modules | verdict |
|---|---|---|
| **DEAD → quarantined** (`src/_graveyard`) | `UI/InventoryManager`, `Control/ItemController` | broken deps (`Data.MainLocalProfile`, `Shared.Maid`, `Remotes.*` — none exist). Replaced by doc 17. |
| **MOVED into the UI framework** | `UI/TooltipBuilder→Client/UI/Tooltip`, `UI/TierEffectManager→Effect`, `UI/TweenManager→TextFX`, `UI/UIData→UIData` | pure view helpers; consolidated under `src/Client/UI/` so ALL UI code has one home (doc 19). |
| **DORMANT — not wired, audit before reuse** | `Control/InputManager`, `BuildController`, `SoundHandler/*`, `EventHandler/*` | ported; not required by any entry. Keep for possible salvage; treat as unknown until audited. (`UI/UI` UIManager + `UI/QuickMenu` were quarantined.) |
| **KEEP for later** (resource-star ambiance) | `VisualEffects/*` (Weather, Shoreline, LensFlare, WindController, MeteorImpact, ScreenRain) | dormant but intentional future content; leave in place. |
| **RETIRED → quarantined** | `Client/StarRings`, `Client/BlackHoleProxy` | superseded by `SpaceProxies` (doc 14). |

**Server `services/`** (`SunAnim`, `Menu`, `EventManager/*`, `PlacementService`) are
likewise **not in either `SYSTEMS` list** → dormant ported. Audit before wiring.

**Rule of thumb:** if it's under `ClientServices` or `Server/services` and you can't
trace a require to it from an entry file, assume it's ported and does not run. Verify
before reusing; prefer rebuilding to the baseline over re-animating an old graft.

---

## 6. Non-negotiable conventions (with teeth)

1. **Server-authoritative.** Client renders a mirror; it never owns mutable state.
2. **Blink is the only client↔server channel.** No `RemoteEvent`/`Remotes` folder,
   no `_G`, no `BindableEvent` across the boundary. Generated files are read-only.
3. **Static data is shared + immutable**, required by both sides (one source of ids).
4. **Systems register with the scheduler**; don't spin ad-hoc `RunService` loops in
   gameplay code when a phase fits. VFX/UI in `Client`/`ClientServices` may use
   `RunService` directly (they're leaf renderers).
5. **One writer per piece of state.** If two systems can write the same field,
   route both through one owner (a store module) — that is the race-prevention rule.
6. **Entry files are the manifest.** To add a system, add it to `LOBBY_SYSTEMS` /
   `RESOURCE_SYSTEMS` (server) or the require list in `main.client.luau`. If it's not
   there, it doesn't run — by design.
7. **Never playtest via Studio MCP** ([[no-playtest-inspect-instead]]); inspect
   read-only. Scene objects are Studio-built or `Assets` templates, not code-spawned.

---

## 7. What to touch next, and what not to

- **Build on:** the ECS/scheduler spine, Blink, the voxel core, the ProfileStore data
  layer, the block-inventory pattern, the lobby systems. These are healthy.
- **Rebuild to baseline, don't re-animate:** inventory/items (doc 17, in progress).
- **Leave alone for now:** `VisualEffects` (future ambiance), dormant `services`.
- **Delete when convinced:** everything in `src/_graveyard`.
