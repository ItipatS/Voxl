# 07 — Technical Architecture

> This doc describes the **repo as it exists today**, then flags the **big technical forks** we still need to talk through ("the crazy part"). Do not treat OPEN forks as decided.

## Current stack (as built)

### ECS — `jecs`
- `std/world.luau` — the world is a **singleton**. Require it; don't thread it through calls.
- `std/components.luau` — components declared, named (for jabby), and `table.freeze`d. Existing: `Character, Model, Player, Target, Transform, Velocity, Previous, Size, PendingChunks`.
- `std/ref.luau` — entity handles by arbitrary key (e.g. `player.UserId`). Handles are not cached (they invalidate); refs are re-resolved.

### Scheduler — custom, phase-graph based (`std/scheduler.luau`)
- Phases are entities with `Phase` tag, optional `Event` (an RBXScriptSignal), and a `DependsOn` relation forming an execution order.
- `SYSTEM(fn, phase)` registers a system under a phase; `PHASE(cfg)` creates one; `COLLECT()` walks the phase graph per event; `BEGIN(events)` connects them to Roblox signals.
- Integrated with **jabby** for live scheduler/world inspection.
- `std/phases.luau` — the full phase dependency chain (EarlyUpdate → Input → GameLogic → Physics chain → AI chain → Combat/Health/Inventory/Economy → Network → Cleanup, plus Heartbeat and client PreRender branches). **This order is a contract** — changing it reorders system execution.
- `std/start.luau` — requires all system modules, then `COLLECT()` + `BEGIN()`.

### Networking — Blink (generated)
- Source of truth: **`Net.blink`**. Generated → `Server/ServerNet.luau` + `std/ClientNet.luau`. **Never hand-edit the generated files.**
- Current events: `ChunkFullStream` (Server→Client, Reliable, `ChunkFull[]`) and `UnloadChunks` (Server→Client, Reliable, `string[]`).
- `ChunkFull = { cx:i16, cz:i16, blocks: map<u32,u8>, heightfields: map<u32,u8> }`.
- Batched replication on Heartbeat (per-player buffer accumulation, `StepReplication`).

### World generation — `Misc/WorldGen.luau`
- `CHUNK_SIZE = 16`, `WORLD_HEIGHT = 256`, `BLOCK_SIZE = 3.5`, `BASE_SEED = 1339`.
- Biomes: Plains, Desert, Forest, Mountains, SnowHighlands. Height/temp/humidity via `math.noise`; `pickBiome`; `computeColumnHeight` with biome-specific shaping; simple 3D cave noise.
- **Sparse block storage:** `blocks[idx3] = blockId`, `idx3(x,y,z) = x + y*16 + z*16*256`, only non-air stored. Plus per-column `heightfields`.

### Meshing — `Misc/Mesher.luau` (client)
- **Client renders the world from replicated data** — server sends data only, client builds geometry. How much a player can render is bounded by their device.
- **Greedy meshing** per face direction (+Y/-Y/±X/±Z), 2D greedy on per-layer masks, cross-chunk neighbor lookups, **Part pooling** (`getPooledPart`/`RecyclePart`/`RecycleChunkModel`).
- Cave face culling via `CAVE_VIS_MIN_Y` + `renderCaves`.

### Streaming — `Server/systems/ChunkServer.luau` + `Client/ChunkClient.luau`
- **Server:** per-player region streaming. `REGION_RADIUS_CHUNKS = 24`, join-boost fast batches then normal, region-shift when the player walks far enough, `UnloadChunks` for chunks left behind. Server-side `ChunkCache` (generate-once).
- **Client:** `ChunkClient` keeps `ClientWorld`, a mesh queue (near/far radii, unload radius), meshes a few chunks per RenderStepped frame, recycles models on unload.
- `std/mailbox.luau` — singleton buffers keyed by component (used by the (currently commented) network delta path).

## The big technical forks [OPEN — this is "the crazy part"]

### FORK A — Infinite streaming vs bounded owned worlds — [RESOLVED, see doc 06]
**Resolution:** split by population shape.
- **Owned stars = datastore keys**, loaded on demand into an **in-memory world context**, **single-live** (one server per open star, visiting = teleport to that server). Display-position decoupled from run-location; owner presence irrelevant. Scales to millions (cold star = 1 key, 0 compute).
- **Resource stars = dedicated places**, one per biome-region, sharded for population; host the market service + per-account depletion.
- Your existing infinite-streaming tech is NOT wasted — it's the engine of the **resource stars** (the "wild"), which are infinite + regenerate from a fixed regional seed. Bounded owned stars use seed+delta.

### FORK B — Persistence: seed + edited-voxel deltas — [MOSTLY RESOLVED, see doc 06]
- Owned star = `seed + delta` datastore key. Base terrain recomputed from seed on load; edits applied on top.
- **Single-live** removes all concurrency/dupe races (only one in-memory copy ever).
- **Save:** debounced autosave (dirty-flag) + save-on-last-leave + MemoryStore session lock with TTL for crash safety.
- **Still open (tuning, not architecture):** delta size × write cadence (doc 12 L12) — per-world edit caps / compaction to stay under DataStore limits.

### FORK A-old / B-old (original text kept for reference below)
**Tension:** `ChunkServer` today streams a Minecraft-**infinite** region and generates outward forever. The design (doc 06) is **bounded, ownable named worlds** (≤ 1000×255×1000) plus separate **public resource stars**.
- Need: a world-instance concept (owned star vs resource star), bounded generation, and per-world lifecycle.
- Question: is a "star" a Roblox place, a server instance, or an in-memory world context within a shared server? This decides everything downstream.

### FORK B — Persistence: seed + edited-voxel deltas
**Design:** store **only edited voxels** over the seed. Today nothing persists — worlds regenerate from seed each time.
- Need: a delta store keyed per world: `world_id → { seed, edits: sparse map of (idx3 → blockId) }`.
- Base terrain is recomputed from seed on load; edits are applied on top. This is what makes millions of tiny worlds cheap.
- Question: chunk-granularity deltas vs whole-world delta blob; compaction; how edits replicate/merge.

### FORK C — Storage backends
- **DataStore** = durable source of truth (world deltas, player inventory/skills, auction listings).
- **MemoryStoreService** = hot transient cross-server state (live bazaar order-book, cross-lobby coordination). Note its shape: queue + sorted-map, TTLs, size caps — **not** a durable ledger.
- **External DB (AWS)** = later, when volume justifies (deep market history, analytics).
- **Mandatory design rule:** the marketplace/persistence API must be **backend-swappable** so "MemoryStore now, AWS later" is a config change, not a rewrite.

### FORK D — Regional market service
- One unified market per (biome resource star) region behind sharded presence (doc 06).
- Bazaar = order-book (MemoryStore hot); Auction = listings (DataStore durable).
- Server-authoritative order matching; anti-exploit on all timestamps.

### FORK E — Factory offline simulation
- On rejoin: `elapsed = serverNow - lastSeen`; fast-forward all factories in one Heartbeat pass; clamp to per-factory **cap** (storage full → stop).
- Question: where factory state lives (ECS components per machine? per-world blob?), and how it interacts with the delta store.

### FORK F — Resource nodes as entities
- Nodes/normal-spawns (doc 03) need server-authoritative renewal timers. ECS components (`Renewable`, `GatherSpeed`, `NodeTier`) on resource entities, ticked under an appropriate phase (there's an unused `Environment`/`WorldManagement`/`Spawning` phase chain ready for this).

## Guidance for Claude Code on technical work
- Prefer extending the existing ECS + phase-scheduler patterns over introducing new frameworks.
- Any new replication goes through `Net.blink` (regenerate), never ad-hoc RemoteEvents.
- Keep the client as a pure renderer/predictor; never let it become authoritative.
- Flag any FORK decision back to the human before building past it.
