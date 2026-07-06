# Voxl — Project Brief for Claude Code

> Entry point. Read this first, then the numbered design docs in **`.claude/01–17`** (the `/docs` folder is deprecated — do not use it). **For how the code is actually structured, read `.claude/16-engine-baseline.md` — the engineering map (layers, dependency rule, what's canonical vs ported rot).** **To resume in-progress work, read `.claude/14-lobby-build-state.md` first** — it's the as-built state + next step. This file is the map; the docs are the territory.

> ⚠️ **WORLD-MODEL PIVOT — read `DESIGN.md` (repo root).** Voxl is now an **explore-and-claim** game: **one procedural star type** across an unlimited universe; you explore, find a world worth living in, and **claim it as your home** with a Starseed. `DESIGN.md` **SUPERSEDES the world model in docs 03/05/06** (fixed resource-regions, biome-places, and weight are gone; the 5 pentagram points are now communal **starter hub-towns**). Soul (01/02), progression (10/11), and the core crafting invariant are **unchanged**. Where `DESIGN.md` conflicts with 03/05/06, it wins. (Distinct from the deprecated `docs/DESIGN.md`.)

## What Voxl is (one paragraph)

Voxl is a **3D voxel builder-gatherer** on Roblox. Players **explore an unlimited, procedurally-generated universe of stars** — each star a small public world with its own random biome mix, tier, and quality (proxy-rendered, so map size is no cost). You gather in any unclaimed star, then **plant a rare Starseed to claim one as your permanent home** and build in it. Gathering feeds hand-crafting and offline **factories**, which feed **building your star** — the actual point of the game. A light **economy** (hub-town markets, tradeable star-keys) connects players who specialized into different biomes, but it's **connective tissue, not the core**: a player can always self-supply. Worlds are stored as **seed + edited voxels only**, so millions of tiny worlds cost almost nothing to host — which is what makes an unlimited frontier and permanent homes affordable. *(Full world model: `DESIGN.md`.)*

The design lineage, and the *one load-bearing idea* stolen from each:
- **Minecraft / Terraria** — the gather → craft → build spine, and worldgen variety.
- **Cubic Castles** — owned worlds placed in a shared, browsable social space.
- **Growtopia** — worlds-as-content + player-driven economy (but not its forced-scarcity gating).
- **Hypixel Skyblock** — many activities feeding **one integrated economy**; specialization is coherent because the market links the lanes.
- **Albion Online** — **distance as economic friction**: hauling goods across space has a real, felt cost (but NOT its full-loot PvP). *Voxl expresses this as zero-G **flight-time between stars**, not weight — see `DESIGN.md`.*
- **Satisfactory** — factory building as an *active, fun* alternative to timer-crafting.
- **BitCraft** — profession specialization that makes players depend on each other.

## The spine (never lose this)

**Gather → craft → improve your space.** This is what a bored player with no goal does in minute one. Everything else (economy, factories, skills, trade, social) hangs off this default loop. If mining a block and placing it does not *feel good on its own*, no amount of system depth rescues the game.

## The Tuesday-player test (answered)

"Who logs in on a random Tuesday with no event on?" A player who wants to **gather in their biome, craft, and build their star** — and *optionally* trade. Proven coherent by Skyblock: a player can specialize into one activity (e.g. farming) and ignore 75% of the game, yet still thrive, because one economy links their lane to everyone else's.

## How to use these docs

| Doc | Covers |
|---|---|
| **`DESIGN.md` (repo root)** | **⭐ CURRENT world-model canon — the explore-and-claim pivot. One star type, procedural universe, claim-your-home, starter hub-towns, slots-not-weight. SUPERSEDES 03/05/06 where they conflict. Read first for anything world/economy/ownership.** |
| `docs/01-vision.md` | Pitch, what it is / isn't, target feel, non-goals |
| `docs/02-design-principles.md` | The hard rules every system must obey |
| `docs/03-core-loop-and-gathering.md` | Gather loop, biomes, node vs normal scarcity, weight — ⚠️ *weight & fixed biomes superseded by `DESIGN.md`; node-vs-normal + gather feel still canon* |
| `docs/04-progression-and-crafting.md` | Skills/mastery, rarity + tier crafting, factories, offline |
| `docs/05-economy-and-markets.md` | Resource-star markets, sinks, guardrails, two-market split — ⚠️ *regional/biome-market geography superseded by `DESIGN.md`; sinks/guardrails still canon* |
| `docs/06-worlds-and-cluster-lobby.md` | Star worlds, ownership, the cosmic lobby, biome choice — ⚠️ *resource/private split & fixed-biome choice superseded by `DESIGN.md`; ownership/permissions/hosting still canon* |
| `docs/07-technical-architecture.md` | **Current repo reality** + the big open technical forks |
| `docs/08-vertical-slice.md` | The MINIMUM playable thing to build & feel-test FIRST |
| `docs/09-open-questions.md` | Everything undecided, flagged for discussion |
| `docs/10-progression.md` | Skills, gear split, journal/milestones, rarity, backbone |
| `docs/11-skill-equipment-tier-matrix.md` | Reference tables: skill matrix, gear grid, tier bands, core invariant |
| `docs/12-loopholes-and-exploits.md` | Known exploitable gaps to defend against |
| `.claude/13-constellations-and-plots.md` | Lobby layout, plots, warp/no-plant radii |
| `.claude/15-data-schema.md` | ProfileStore + MemoryStore storage shapes |
| **`.claude/16-engine-baseline.md`** | **Engineering entry point — the codebase map: layers, dependency rule, canonical vs ported rot. Read before touching any system.** |
| `.claude/17-items-and-inventory.md` | Item layer (ItemDB, weight, Blink, Star Seed) — first subsystem rebuilt to the baseline |
| `.claude/18-planting.md` | Planting a private star: overlay → CreatePlanet prompt → server-validated commit; `UIController` |
| `.claude/19-ui-conventions.md` | **UI framework + house style** (UIController/UISound/UITween/Notifier): sound, transitions, modals, notices — read before adding any UI |
| `.claude/20-items-hotbar-tools.md` | Item `kind` (Tool/Consumable/Material), hotbar equip → server-spawned held Tool + particle LOD, activation → behavior |

## Decision status convention

Throughout the docs:
- **[DECIDED]** — locked. Build to this.
- **[OPEN]** — not yet settled; do not invent an answer. Flag it, propose options, wait.
- **[TUNE]** — a number/balance value that can only be found by testing with real players. Ship a placeholder, expect to change it.

## Codebase conventions (from the existing repo)

- **Language:** Luau (`--!strict` / `--!native` / `--!optimize 2` where hot).
- **ECS:** `jecs`. The **world is a singleton** (`std/world.luau`) — require it, don't pass it around.
- **Scheduling:** custom phase scheduler (`std/scheduler.luau`) with a dependency graph of phases (`std/phases.luau`). Systems register via `scheduler.SYSTEM(fn, phase)`; `start.luau` calls `COLLECT()` then `BEGIN()`.
- **Networking:** Blink-generated (`Net.blink` → `ServerNet.luau` / `ClientNet.luau`). **Do not hand-edit generated files** — edit `Net.blink` and regenerate.
- **Components:** declared in `std/components.luau`, frozen, named for jabby.
- **Cross-system messaging:** `std/mailbox.luau` (singleton buffers keyed by component).
- **Entity refs by key:** `std/ref.luau`.
- **Server-authoritative** by default. Client renders from replicated data; it does not own state.
- **Moving many parts per frame:** batch them into ONE `Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)` — never per-part `.CFrame`/`.Position`/`:PivotTo` in a `RenderStepped`/`Heartbeat` loop (each of those hits property-change + replication + physics events individually). Reuse persistent `parts`/`cframes` buffers, trim the tail to the live count, and bake per-part rotation into the CFrame. (Applied in `StarField`/`StarRenderer`/`AsteroidRenderer`.)

## Tooling & capabilities (what Claude can run directly)

You have these tools in this environment — use them directly, don't ask the user to do
tool work you can do yourself.

- **Blink CLI** — `blink Net.blink` regenerates `ServerNet`/`ClientNet` after any `Net.blink`
  edit. Runs directly in the Bash tool (Blink ≥0.18). **Always regen yourself** after editing
  the IDL; never hand-edit the generated files.
- **Rojo** — `default.project.json` maps `src/` → the DataModel (see `.claude/16` §2). Live-sync
  pushes code into an open Studio. Folders not in the project file (e.g. `src/_graveyard`) don't sync.
- **Roblox Studio MCP** — connected to the live Studio session:
  - **Inspection (use freely):** `inspect_instance`, `search_game_tree`, `script_read`,
    `script_search`, `script_grep`, `get_studio_state`, `get_console_output`, `screen_capture`,
    `list_roblox_studios`. This is how you check the **authored scene + GUI** (e.g. the
    `PlayerGui.Interface` child names before wiring UI) — read-only, always allowed.
  - **Write/generate (exist, use with care):** `execute_luau`, `multi_edit`, `insert_asset`,
    `search_asset`, `generate_mesh`/`generate_material`/`generate_procedural_model`, image tools.
    But **scene objects are authored in Studio or live in `ReplicatedStorage.Assets`** — don't
    code-spawn scene content, and don't hand-edit scripts that Rojo owns (edit `src/` instead).
  - **FORBIDDEN — never playtest:** `start_stop_play`, `user_keyboard_input`, `user_mouse_input`.
    Playtesting is a human job ([[no-playtest-inspect-instead]]). Inspect the running/edit state
    read-only; never drive the game.
- **Linear MCP** — the MAIN team's Voxlstar project (M1–M10 board). Reconcile plan/progress here.
- **Git / `gh`** — standard; commit/push only when asked (see repo rules).

## Golden rule for any new system

> The convenient option must always stay the *worse* option. Gathering yourself is faster than hand-crafting is faster than factories. Buying is worse value than gathering. NPC sell price is worse than player-to-player. If you ever make the lazy path the optimal path, you have broken the game.
