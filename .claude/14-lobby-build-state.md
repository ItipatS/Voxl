# 14 — Lobby Build: Current State & Pickup

**Read this first to resume.** The checkpoints below are a LOG, newest first — older ones describe what was true when written and are not corrected in place. For the current shape of the code read the top checkpoint plus `.claude/16` (the engine map); for anything older, trust the code.

 The Linear M1–M10 board is the *plan*; this is what's *actually built* in the lobby prototype (the flyable Cluster) as of the last session, plus the next step. Design rationale lives in doc 13 (constellations/plots), **doc 15 (data schema — DataStore + MemoryStore)**, + docs 06/07.

## ✅ Checkpoint (latest session) — THE STAR PLACE BECAME A PLACE

The imported Minecraft town is playable and the star place stopped being a
half-built copy of the lobby. Roughly ten commits; the load-bearing parts:

- **ONE inventory.** Blocks are ITEMS now — `itemdb` generates a def per block
  (`kind = "Block"`, key `block_<id>`, id `10000 + blockId`, field `placesBlock`),
  so the same 54 slots hold materials, tools and blocks. The star place runs the
  lobby's modules (`ItemMirror`/`ItemInventory`/`ItemHotbar`/`HeldTools`);
  `BlockInventory`/`Hotbar`/`InventoryRender` are in `_graveyard`, `InventorySync`
  is deleted from `Net.blink`, and `PlayerStore` drains any old `Data.blocks` into
  slots once on load. All 189 blocks are usable, not a hardcoded 7. Blocks draw
  their own cube in a slot (`BlockPreview`) rather than needing 190 sprites.
  Breaking a block now REFUSES when the inventory is full — slots are finite where
  the old map was not. (docs 17/20; `tools/mcimport/test_itemdb.luau` guards the ids)
- **Rendering, after a long wrong turn.** A pegged `RenderViewUpdate` with no script
  time under it was us: the mesher budgeted its own LUAU time (5 ms), so it built
  ~100 cheap chunks in a frame and handed the engine ~35,000 parts to ingest. It
  now budgets INSTANCES per frame (`INSTANCE_BUDGET`, `ChunkMesher.InstancesBuilt()`)
  — instances, not boxes, because a textured box is a part plus up to six Textures.
  Separately, leaves are 30% of all boxes and were `alpha = 1`, so ~30,000
  TRANSPARENT parts were depth-sorted every frame, standing still. Leaves are now
  FAST by default (opaque, `lodColor` = the texture's own measured mean,
  SmoothPlastic); `FancyLeaves` toggles. Water is Roblox TERRAIN, not parts — one
  render object, plus swimming and underwater fog. Terrain casts shadows again;
  turning them off had bought nothing.
- **Live tuning knobs** (client, no rebuild): `Workspace:SetAttribute` →
  `TextureRadius` (texture LOD, ships OFF), `RenderRadius`, `MeshBudget`,
  `FancyLeaves`. These are graphics settings for a weak client, not fixes.
- **The star is a world.** `systems/daynight` revives the long-dead cycle
  (5 min day / 5 min night, 8-phase moon from `services/EventManager/MoonPhase`,
  replicated as a LINE the client integrates per frame). Sky comes from
  `ReplicatedStorage.Skybox.Planet`. `starconfig.MAP_SPAWN` holds an AUTHORED spawn
  per map (chosen by eye, in studs) that beats the bake's mechanical guess.
- **Entry actually arrives where you pressed.** `ResourceStarEntry` teleported from
  the CLIENT with `{biome = "Forest"}` — truthy, so `starworld` skipped its fallback
  and read nil out of every field, landing every hub entry in the procedural TEST
  star with no map and no warning. Invisible in Studio, where the fallback runs and
  works. It is in `_graveyard`; `configure` now validates the SHAPE.
- **`StarRouting`** pins each starId to one reserved server via MemoryStore, so
  everyone entering the same world meets there. Hub ids exclude the week, frontier
  slot ids include it (a slot holds a different star each week).
- **A way out.** `QuickMenu.Back` → the authored `Promt` frame → `LeaveStar` →
  server teleports to the lobby. Before this, entering a star was permanent.
- **Client parity.** `CameraController` runs in BOTH places (Roblox's default camera
  eats the scroll wheel the hotbar needs) and owns first/third person on **T**
  (Tab belongs to Roblox's leaderboard). `FlightAnims` shares the flight animation
  state machine, so star flight is no longer a T-pose. `Music` runs in both.
- **The quick menu was dead.** Every button path read `quickMenu` while the frame is
  `QuickMenu`; `FindFirstChild` is case-sensitive and a nil path is a silent skip,
  so Bag/Map/Quest had never done anything. Fixed; `QuickMenu` is a registered panel
  raised by `Menu`; buttons whose panel does not exist are greyed out.
  `UITween.rest` adds a RESTING scale that hover/press compose on top of, so the
  held hotbar slot sits 12% larger without hover snapping it back.

## ✅ Checkpoint — TELEPORT TRANSITION + PLANET LOADING SCREEN
A cartoon iris wipe + custom teleport/loading screen wrap the star-entry so it reads as one
continuous move (and degrades gracefully in Studio, where cross-place teleport can't complete).
- **`std/transition.luau`** (shared, dependency-free so ReplicatedFirst can require it): a black **iris disc** (square Frame + `UICorner 0.5` = circle; grows to the screen diagonal to cover, shrinks to reveal) + a **planet card** (`CanvasGroup` so it fades as a unit): name · RichText resource chips (per-type colour) · "N explorers here" · pulsing subtitle. API: `close(info)` / `cover(info)` / `open()` / `setLive(partial)` / `buildTeleportGui(info)`. Live overlay is a single shared module-state instance across all client scripts.
- **Source (Lobby `UniverseField`):** Enter → `SetTeleportGui(buildTeleportGui(info))` + `close()` the iris + fire `EnterStar`. A **`traveling` guard** + `EnterDenied` handler + a 12s backstop **re-open** the iris if the trip doesn't happen — so Studio (teleport fails) shows the wipe then reverses instead of a stuck black screen.
- **Destination (`src/ReplicatedFirst/LoadingScreen.client.luau`, NEW Rojo mount):** `RemoveDefaultLoadingScreen()` → `cover(info from GetLocalPlayerTeleportData)` → wait `game:IsLoaded()` + (Star place) `StarSeed` attr + character/HRP + a beat → `setLive({players})` → `open()`. Also handles direct joins + a clean Lobby intro wipe.
- **Blink `EnterDenied`** (S→C, `u8` reason) added + regenerated; `starentry` fires it on no-star / too-far / teleport-fail and now also puts `starName` in TeleportData. `default.project.json` gains a **`ReplicatedFirst` → `src/ReplicatedFirst`** mount.

## ✅ Checkpoint — LANDING + TIER-AWARE 25-BIOME WORLDGEN
Landing on a procedural star now generates its **real rolled biome mix**, and the entry is robust.
- **Tier threaded end-to-end.** The universe already rolls `star.biomes = {{type,tier}}` per star, but entry discarded it. Now `starentry` puts the full `star.biomes` in TeleportData → `starworld` → `starconfig` (serialised `"type:tier,…"` attr) → client `StarWorld`, and both sides call the new **`WorldGen.applyStarByBiomes(seed,radius,biomes)`**. `applyStarByTypes` kept as a tier-less fallback (each type → its T2 rung) for direct/Studio joins.
- **The 25-biome ladder is authored (doc 21).** `WorldGen` now has the full **family × tier grid** (`LADDER[type][tier]→biomeId`): 9 rungs reuse the legacy climate defs, **16 new biomes** added (calm T1s Meadow/Rockland/Dunes/Frostfield/Marsh; wild T4s Ancient Grove/Peaks/Mesa/Glacier/Mire; surreal T5s Wildwood/Monoliths/Glass Sea/Aurora Shelf/Spore Hollow — plus Badlands/Fen). Each has real `BiomeDef` gen params (flatness/hilliness/ridged/treeDensity/palette) using the existing block set.
- **Placement = discovery.** `pickStarBiome` sorts the palette low→high tier and blends region noise with an **inward radial bias**: common low-tier rungs cover the rim/most area, the rare high-tier rung surfaces as the island's **central heart** (doc 21 "T5 = a single special locus, often central"). You cross ordinary terrain and *discover* the payoff biome at the core.
- **Robust spawn.** `starworld.positionSpawn` no longer needs an authored SpawnLocation — it **creates a functional spawn anchor** if none exists, and `findSpawnColumn` scans centre + two rings and drops the player on the **lowest solid column** (safe/flat ground, off the tall exotic core, which then reads as a landmark to walk toward). Never spawns into the void.

## ✅ Checkpoint — BOUNDED-STAR GEN + ENTRY + CRAFTING FOUNDATION
The worlds become enterable + craftable; design canon for biomes/crafting written.
- **Bounded-star worldgen** (`src/Misc/WorldGen.luau` gains star mode): `applyStar/applyStarByTypes` = per-star seed + radial **island disc** (slopes into void beyond the rim) + **restricted rolled biome palette** (region field, lower tiers more area); legacy infinite continent still the fallback. `std/starconfig` publishes `{seed,radius,types}` via ReplicatedStorage attrs; server `systems/starworld` + client `Client/StarWorld` both `applyStarByTypes(get())` so terrain matches; spawn lands on the island centre; `CharacterAutoLoads` off until configured. TEST star for Studio/direct joins.
- **Real star entry**: `UniverseField` planets have an expressive **Enter** ProximityPrompt (`Style=Custom`) → Blink `EnterStar(slot)` → lobby `systems/starentry` recomputes the star (must exist this week) + checks proximity → `TeleportAsync(RESOURCE_PLACE_ID, {seed,radius,types})`. **Two places: Lobby + Star (= ResourceStar PlaceId), one live server per starId (MemoryStore routing later).**
- **Biome canon (doc 21)**: 25 biomes = 5 families (Flora/Stone/Sand/Frost/Bog) × 5-tier ladders; tier = terrain wildness × node richness × rarity; nodes = **meshes** (`Assets.Resources`), 3/biome, T1-varied → T2+-iconic, tiny hover overlay. Still coarse in code (`WorldGen.TYPE_BIOME` maps type→one biome, tier ignored).
- **Crafting canon (doc 22) + foundation BUILT**: three surfaces (3×3 pattern **table** / time **stations** furnace-sawmill-crusher-… / **factory** automates a pattern). **Two axes: TIER (unified material per tier) vs AESTHETIC (cosmetic stain-styling OFF the tier tree).** `std/materials` (75 raws + refined + stains), `std/recipes` (station chains generated per tier + table core + doc-11 tier-upgrade rule + `byId`/`inputsOf`). `itemdb` **generates** all craftables as placeholder-icon items (mats 1000+ / tools 2000+ / product placeholders 3000+). Server `systems/crafting` (both places): `Craft(recipeId)` → validate/consume/grant (MVP instant). `PlayerStore` `[TEST]`-grants mats.
- **User tuning (uncommitted this session):** boost back to **deplete-lock** (full refill after 0) + SFX tail-gate; proxy depths split (**stars far 18000, black hole close ~100/baseScale 50** — its particles cull at distance); `MawWarning` = ForceField `SpecialMesh` sphere that **fades in near the void**; hit/collect SFX at `SoundService` (miss sound = `Mice`); added `RbxCharacterSounds.client`.

## ✅ Checkpoint — PROCEDURAL UNIVERSE + FEEL POLISH
The explore-and-claim spine goes visible, plus data-schema reconcile + a feel pass.
- **`std/universe.luau`** (shared, seed-derived — 3rd of the `std/dust`/`std/zones` family): `starAt(slot, week)` = the unclaimed star in a grid slot this week (rerolls weekly); `buildStar(slot, seed)` reproduces a star's identity from a seed (used for unclaimed AND claimed via frozen `originSeed`). **`starId == slot coordinate`**; `SLOT_SIZE=8000`; void-culled; unlimited; deterministic exact-f64 hash. **Tier = a biome mix** (each of the 3 featured resource types is a biome, rolled `{80,14,4.5,1.3,0.2}` T1→T5, **≤1 T5/star**; headline `star.tier` = best biome; ~51% of stars all-T1). Procedural **Latin/scientific names** ("Verdantia borealis").
- **`Client/UniverseField.luau`** renders it: clones **`Assets.Planet`** (MeshPart+SurfaceAppearance) per nearby slot, tint `Color`/`EmissiveTint` by resource TYPE + glow by tier (Neon-ball fallback), 2047-stud planets, cell load/unload (static, no per-frame loop). **Approach preview** BillboardGui (name + 3 resource TYPES; tier/node hidden) auto-shown via `MaxDistance=4000`. ⚠️ template path is `ReplicatedStorage.Essential.Planet` (user's edit) — `WaitForChild` there hangs if that folder is missing.
- **Doc 15 reconciled** to the pivot: stars are entities keyed by coordinate, unclaimed frontier is zero-storage, `ClaimedCoords`/`ClaimQuota`/`UniverseSeed`. **Not built yet: claim service** (skip-set + `star_<coord>` + 2/week) + claimed overlay + residential-zone cull (procedural stars currently generate inside the cluster too).
- **Dust now covers the whole universe** (removed the `std/dust` FIELD_RADIUS cap; void-only). **Landmark proxies no longer occlude** the real universe: `constellation` LANDMARKS `proxyDist=18000` > render distance (apparent size = baseScale/d, independent of proxyDist).
- **Server-authoritative player state** (`systems/PlayerState.luau`): client predicts fuel, server owns the value + validates gains, reconciles `PlayerStateSync`@4Hz. **Dust collect is instant client-side** (removed `DustCollected` confirm; ~1s stall gone). Blink `PlayerStateSync`/`BoostState`.
- **Maw void + zone framework**: `VOID_RADIUS=14000` (dust/stars stop; `MawWarning` = ForceField `SpecialMesh` sphere). `std/zones.luau` declarative zones (maw/brink/starter/cluster); `ZoneWatcher` announces on change + join/respawn.
- **Feel polish:** boost SFX fades (no hard cut) + **0.75s re-boost cooldown** (replaced full-refill lock); `Music` fades + random silence between tracks; dust collect FX on the player (HRP burst + reliable clone-sound); asteroid hit = `Hit` boosting / `Miss` otherwise. Flight speed 160 (boost ×2.4).

## ✅ Checkpoint — STAR DUST = SEED-DERIVED COLLECTABLE
Star dust promoted from client-only decoration → a real server-authoritative collectable, using the **chunk model** (seed-derived positions, only cooldown deltas on the wire). Fly through dust → auto-collect → **star fuel** (refills `FlightBoost` stamina) → mote dims for a cooldown.
- **Why it's cheap (the key idea):** dust positions are a pure function of a global seed (`std/dust`), so BOTH sides generate the identical field per-cell — **zero position bytes streamed**. Server stores ONLY a cooldown ledger of *collected* motes (bucketed by cell). No field-wide loop anywhere: client auto-collects against its own ~1700 local motes; server validates the ONE mote it's told (hash it) + broadcasts dim by looping players (≤50). Byte cost ∝ collection activity, not dust count. Wire sizes: `MoteRef` 7B, `DustCollect`/`DustCollected` 7B, `DustCooldown` 9B/entry.
- **`std/dust.luau`** (shared): `DUST_SEED`, `CELL_SIZE=400`, `MOTES_PER_CELL=5`, `FIELD_RADIUS=22000`, `COLLECT_RADIUS=22`, `COOLDOWN=25`, `FUEL_PER_MOTE=14` [TUNE]. `cellOf`, `motesInCell(cx,cy,cz)` (deterministic via `Random.new(cellSeed)`; index alignment = MoteRef validity), `moteAt`.
- **Blink** (regen'd): `MoteRef{cx,cy,cz:i16, idx:u8}`, `DustCollect`(C→S), `DustCollected`(S→collector), `MoteCool{ref,remaining:u16 deciseconds}` + `DustCooldown[]`(S→nearby; live delta AND enter-sync batch).
- **Server `systems/dustfield.luau`** (LOBBY_SYSTEMS): cooling ledger `[cellKey][idx]=expiry`; `DustCollect` handler (moteAt validate + proximity `COLLECT_RADIUS+12` + not-cooling → set cooldown, `DustCollected` to collector, `DustCooldown` broadcast to players within `SYNC_RADIUS=1400`); enter-sync on player cell-change (resend nearby cooling); prune loop.
- **Client `DustField.luau`** (replaces `StarField` in main.client): cell load/unload around player (±`RENDER_CELLS=3` = 343 cells), generate motes from seed, **one `Workspace:BulkMoveTo`/frame** + wobble, auto-collect (squared-dist, 10Hz, `pending` debounce) → `DustCollect`, `DustCollected`→ `FlightBoost.addFuel` + `Assets.Particles.DustCollect` burst tinted to mote colour + dim, `DustCooldown`→ dim. `coolByKey` holds cooldowns even for not-yet-loaded motes. ⚠️ cell-cross loads a ~245-mote slab (micro-hitch at boost speed) — spread across frames if it bites.
- **`FlightBoost.addFuel(n)`**: dust refuels stamina ("star fuel") + lifts the deplete-lock above 15. Boost SFX is now `SFX.Effect.Spaceboost`.
- Old **`StarField.luau`** left on disk but no longer required.

## ✅ Checkpoint — PIVOT RENAME / ASTEROIDS / SLOWER FLIGHT / DUST
First code aligned to the explore-and-claim pivot (`DESIGN.md`), plus a new hazard.
- **Rename resource-star → starter-star (lobby landmarks only).** `constellation.RESOURCE_STARS` → **`STARTER_STARS`** (the 5 pentagram points are now starter hub-towns); updated `planting.luau` + comments/labels (SpaceProxies, collectables, ZoneWatcher label "Starter Star"). ⚠️ **Intentionally LEFT the `ResourceStar` *place*** (`placemode.Mode`/`RESOURCE_PLACE_ID`/`ResourceStarEntry`/`RESOURCE_SYSTEMS`) — that's the generic star-*interior* you teleport into; under the pivot it renames toward "Star" (not "StarterStar") and belongs with the procedural-star rework. Don't half-rename it.
- **Flight speed halved:** `FlightController.SPEED 320 → 160` (boost ×2.4 ≈ 384). `constellation` header speed-anchor comment updated to 160.
- **Dust shape variety:** `StarField` now clones random authored meshes from `ReplicatedStorage.Assets.Stars` (9 shapes incl. a Ring) instead of neon balls — `makeSpeck()`, uniform-scaled to `DUST_SIZE`, random orientation, still firefly-tinted + wrap + wobble. Falls back to a neon ball if the folder's empty.
- **Asteroids — server-authoritative moving hazard (NEW).** Mirrors the star field but each rock **drifts at constant velocity**. Blink: `AsteroidStream`(id/dp/vel/size/shape, Unreliable)/`AsteroidUnload`/`AsteroidHit`(dir/stun) — **regenerated**. Server `systems/asteroids.luau` (in `LOBBY_SYSTEMS`): `COUNT=1600`, `FIELD_RADIUS=22000`, `STREAM_RADIUS=3500`, size 18-85, speed 45-130 (**< cruise 160 so dodgeable un-boosted; a booster rams them**), streams pos+vel ONCE on entry (client dead-reckons), detects collision → `humanoid:TakeDamage(22)` + fires `AsteroidHit` + per-player i-frame (`STUN 1.1` + 0.5). Client `AsteroidRenderer` (clone random `Assets.Astroids` mesh, scale to size, **faint occluded Highlight**, dead-reckon + slow spin) + `FlightStun` (on `AsteroidHit`: input-freeze + decaying knockback shove + i-frame transparency flash + best-effort impact SFX `SFX.Effect.Hit/Impact/Explosion`). `FlightController` consults `FlightStun.stunned()`/`.knock(dt)`; idle velocity-zero guarded so knockback isn't cancelled. Both required in `main.client` lobby branch. ⚠️ collision is O(COUNT·players) brute force — fine at 1600/few players; bucket it if COUNT grows. Client render lags true pos by ~latency·speed (collision is server-side, so it can clip you just before visual contact).

## ✅ Checkpoint — FLIGHT FEEL / VFX / PROMPTS / EXPANSION
The lobby "feel" pass. Read top-down; item/UI checkpoint below is still current.
- **Universe expanded ~6×** off ONE knob: `constellation.RING_RADIUS = 30000` (was ~5000) drives the 5-point resource ring; `NO_PLANT_RADIUS 6000`, `WARP_RADIUS 2200`, `BLACKHOLE {radius=12000, pull=600, coreRadius=700}`, landmark `baseScale=6` (BlackHole 20). We rely on **parallax proxies** now, so real positions are free — the map can be huge. `planting.ZONE_RADIUS=24000`, collectables `FIELD_RADIUS=22000`.
- **Flight boost (`FlightBoost.luau`, Hold LeftShift):** `FlightController.SPEED=320`, boosted ×`BOOST_MULT 2.4`. Stamina bar BillboardGui at the legs (adorned to HRP), feet exhaust (`Assets.Particles.Boost`) + camera speed part (`Assets.Particles.BoostCam`), `SFX.Effect.Boost` looped with pitch rising as stamina drops. **Deplete-lock:** hit 0 → `depleted=true`, bar red, can't re-boost until fully refilled (kills the SFX-flicker-at-empty bug). Boost only runs while `moving()`.
  - **Feet-plume camera-coupling FIXED:** the `Boost` emitter's `VelocityInheritance=1` was launching particles along the character's travel velocity (= camera-forward at ~768/s, 8× emission speed) so the plume chased the camera. Clone now sets `LockedToPart=true` + `VelocityInheritance=0` → plume stays at the feet, emits along the feet axis, camera-independent. Aim is the feet attachment rotation `CFrame.Angles(math.pi,0,0)` (line ~70) — that's the knob if direction's off.
- **`CameraController.luau`** (BOTH places now; owns first/third person on **T**) (already in prior checkpoint): scriptable over-shoulder shiftlock; scroll→hotbar, Alt+scroll→zoom, Alt / UI-open → free cursor + custom crosshair.
- **expressive-prompts wired (`Prompts.luau` = `Init()`+style):** star-catch `ProximityPrompt.Style=Custom` renders the styled billboard (`StarRenderer`). **ResourceStar entry stays an approach-countdown** (fly near → "Entering The <Biome>… 3" → `TeleportService`), NOT click-to-teleport — deliberate.
- **Random cluster spawn:** `FlightController` spawns you at a random angle in the residential annulus (outside the black hole, inside the ring), facing outward — far from resource stars.
- **Engine fixes:** (1) `lobby.luau` `Workspace.FallenPartsDestroyHeight = -1000000` — the default −500 kill-plane was instantly killing low-flying players. (2) `StarField` spread wider (`FIELD_RADIUS 300→1800`, `DUST_COUNT→900`, bigger size/wobble) so near dust parallaxes slower → travel stops looking too fast.

## ✅ Checkpoint (item system) — still current
Item system + UI framework are built (docs 17/19/20). Highlights & recent fixes:
- **Items are SLOT-based** (server-authoritative, `PlayerStore.slots`: 1-9 hotbar, 10-54 inventory). `ItemInventory` (45 static slots, Minecraft cursor pick/drop = **clone of the slot frame**, right-click consume, full-spec tooltip), `ItemHotbar` (1-9/scroll/click → equip; gray "held" dim + `HotBarText`), `ItemDrag`. Blink: `ItemSync`(slots)/`MoveItem`/`UseSlot`/`EquipItem` (regen done).
- **Held tools:** server spawns only a bare **Handle** (`EquipService`); each client clones the mesh + LODs particles (`HeldTools`); tool `Activated` → behavior (seed → `PlantingController` → `PlantService`; name+cell unique via `PlanetRegistry`). **Star Seed granted every join `[TEST]`.**
- **`tier` (numeric item level) vs `grade` (rarity common→mythical)** are separate. Grade visuals in one table `UIData.Grade` (+ effect flags colorLoop/gradient/glow; border tiles via `UIData.Border` index). **All UI text = `UIData.Font` Silkscreen** (UIRegistry stamps it).
- **Custom camera** (`CameraController`, **both places**): over-shoulder shiftlock, scroll→hotbar, Alt+scroll→zoom, Alt/UI→free cursor, **T = first/third person**. Roblox backpack CoreGui disabled.
- **Server cold-start FIXED (was 30s):** `lobby.luau` blocked on `WaitForChild("ForestStar",30)` (star is in Assets now, not Workspace) — removed. `players.playersRemoved` jecs error fixed. `start()` logs per-module boot timing. Collectables use spatial buckets (scales to 10k+ stars).


**Active workstream: engine baseline + item layer.** Re-evaluated the codebase and wrote
**doc 16 (engine baseline)** — the map of canonical Voxl vs ported rot + the dependency
rule. Quarantined the dead RPG inventory graft to `src/_graveyard` (not synced) and retired
`StarRings`/`BlackHoleProxy`. Built the item layer to that baseline (**doc 17**): `std/itemdb`
(Star Seed + weight bridge), Blink item events, `PlayerStore` extended to items + weight +
`UseItem`/`DropItem` (now loads in BOTH modes), `ItemBehaviors` (`plant_star`), `ItemMirror`
(client cache) + `ItemInventory` (the UI — renders `Interface.Inventory.ItemSlots` from the
authored `StarterGui.ItemTemplate`, grade visuals + tooltip + weight bar; left-click use /
right-click drop). All wired into `main.client` (both places; `InventoryToggle` added to the
Lobby). **`blink Net.blink` is regenerated.** Blink CLI + read-only Studio MCP inspection both run
directly — no need to ask the user. **Item layer is functionally complete** (minor follow-ups in
doc 17: 3D icons, always-on weight HUD, E-key rebind).

**Planting is built (doc 18).** Click the Star Seed (Lobby) → ghost `Assets.Planet` overlay snaps
to the grid (green/red) → **[F]** locks the cell + opens the `CreatePlanet` prompt (input↔confirm
states, log + `SFX.Confirm`/`Error`, breathing Confirm) → server `PlantService` re-validates
(seed owned, not already planted, cell plantable, **name + cell globally unique** via
`PlanetRegistry` DataStore) → commits plot/biome/name + consumes seed. New client modules:
`UIController` (the one UI manager — all future UI goes through it), `CreatePlanetController`,
`PlantingController`, `ItemUse`. Blink regenerated (`PlantStar`/`PlantStarResult`). **Next:**
authoritative replicated render of planted stars + the fly-near ViewportFrame thumbnail (doc 18
follow-ups) — the `Assets.Planet` model is the render + thumbnail source.

**UI framework built (doc 19) + ALL UI unified under it.** `UIRegistry` is the one declarative
place: it registers every panel, wires open/close buttons by path, and auto-binds hover+click
feedback to every button under Interface (current + future via DescendantAdded). `UIController`
(multi-frame panels, exclusive groups, toggle-close, modal input context + Esc / `gameplayBlocked()`,
toggle keys), `UISound` (name-based semantic sounds, recursive lookup under `SoundService.SFX/<cat>`),
`UITween` (pop dot→large + fades), `Notifier` (zone titles + toasts), `ZoneWatcher`. `InventoryToggle`
retired → `UIRegistry`. CreatePlanet is a `main`-group modal; FlightController freezes while a modal
is up. **To add UI: author the frame + one line in `Registry` (recipe in doc 19).** ⚠️ SFX are now
in subfolders (UI/Env/Entity/Block/Effect); the framework's `Sound` uses recursive lookup — fixed
StarRenderer's catch sound.

**All UI code now lives under `src/Client/UI/`** (Controller/Sound/Tween/Notifier/Registry +
Tooltip/Effect/UIData moved out of `ClientServices.UI`), behind one facade: `local UI =
require(script.Parent.UI)`. Requiring it bootstraps the framework. Universal button feedback is
now hover **scale + sound** + click, auto-applied to every button (current + future). Consolidated
so there's no UI code split across dirs. Dormant `ClientServices.UI` UIManager/QuickMenu quarantined.
Contextual button FX added (`UITween.buttonFX`, auto on all buttons: hover=brighter+bigger,
press=dimmer+smaller). **Emitter2D 2D-particle bursts** wired in via `UI.burst(target,name,count)` —
tag-based (`"Emitter2D"`), no module require; author configs under `ReplicatedStorage.Assets.Emitters`
(named burst = safe no-op until authored). The Emitter2D engine lives at `src/Client/Emitter2D/`
(plugin-managed loader + reference module) — don't disturb it.

**Items/hotbar/held-tools (doc 20).** Explicit item `kind`: **Tool** (hotbar, held-in-hand,
activate to use) / **Consumable** (inventory-click) / **Material** (inert). Star Seed = Tool
(`model="StarSeed"` in `Assets.Items`). `ItemHotbar` (1-9/click select, scale-up, hide-quantity,
grade tint) → Blink `EquipItem` → server `EquipService` spawns a **replicated Tool** on the
character (unanchored/massless; particles OFF). `HeldTools` = own-tool `Activated` → item behavior
(seed → planting) + **particle distance-LOD** (near = full FX, far = model only). Inventory-click is
**Consumable-only** now (tools used via hotbar). Debounce added to sound/toasts/panel-toggle.

Earlier foundation (still current): `PrivateStarStore` (per-player `star_<UserId>`),
`std/starsize`, `std/planting` (grid). Schema in doc 15. (`RegionSeed` has since been deleted.)
After the item UI: `WorldGen` seed param, then the fly-near ViewportFrame preview.

## Architecture

**The module-by-module map lives in `.claude/16-engine-baseline.md` and is kept
accurate there.** This section used to repeat it and drifted: it described entry via
`TeleportData.biome`, `StarField`, `ResourceStarEntry` and a `constellation` server
system, none of which exist. Only what is specific to the lobby is kept here.

- **One codebase, two published places.** `std/placemode.luau` resolves `Mode` from
  `game.PlaceId`, with a `STUDIO_OVERRIDE` for testing. ⚠️ That override means
  **Studio never exercises the teleport path** — a broken hand-off is invisible there.
- **Lobby place** = The Cluster (zero-g flight, hub-towns, black hole, collectables).
- **Star place** = one bounded voxel world per star, configured from TeleportData
  (`starSeed`/`starRadius`/`starBiomes`/`starMap`) and pinned to one reserved server
  per star by `StarRouting`.

### Lobby gotchas worth keeping

- **`SpaceProxies` must run at `BindToRenderStep(RenderPriority.Camera + 1)`**, never
  `RenderStepped:Connect`. A proxy is rendered close to the camera, so its position is
  hyper-sensitive to it and MUST update after `CameraController` (which binds at
  `RenderPriority.Camera`) or it reads a stale camera and shakes at high speed.
- **Landmark models are templates in `ReplicatedStorage.Assets`**, named to match
  `LANDMARKS[].template`: `BlackHole`, `ForestStar`, `DesertStar`, `MountainStar`,
  `HillStar`, `SwampStar`. (Those are ART names; the five hubs they render are
  Aldermoor / Dunhollow / Cragfell / Greenbarrow / Mirefen.) A missing one warns and
  skips. **Keep them out of Workspace** or you double-render.
- Persistent landmark models need `ModelStreamingMode = Persistent` — spawn is ~5000
  studs from centre and they otherwise stream out.
- `Assets.Star` (collectable template), `Assets.Planet` (frontier stars),
  `Assets.Items.*` (held tools), `SoundService.Musics` + `SoundService.SFX`.

### Config: `src/std/constellation.luau`

`CENTER` (0,500,0), **`RING_RADIUS = 30000`** (one knob → the 5-point hub ring, with
`Y_JITTER`), `NO_PLANT_RADIUS` 6000, `WARP_RADIUS` 2200,
`BLACKHOLE {radius=12000, pull=600, coreRadius=700}`, `VOID_RADIUS`, `HUB_DEFS` →
`M.HUBS` (name/pos/template/biomes/`map`) → `M.LANDMARKS` (derived, so the proxy list
cannot drift out of step), `canPlantAt()`. Sibling radii that must track it:
`planting.ZONE_RADIUS = 24000`, `collectables.FIELD_RADIUS = 22000`.

**All five hubs carry `map = "FantasyMedieval"`** — one imported town, shared. Terrain
cannot tell you which hub you are in; only `starName` and the seed (1001-1005) do.
## ⚠️ Must-dos / gotchas
- **Blink is regenerated.** `ServerNet`/`ClientNet` are current. The item channel is `ItemSync` carrying `ItemInv{weight,capacity,slots:SlotEntry[]}` plus `MoveItem`/`UseSlot`/`EquipItem`; `ItemStack`/`UseItem`/`DropItem` were never built and `InventorySync`/`BlockCount` have been deleted (blocks ride in `ItemSync`). After any future `Net.blink` edit, run `blink Net.blink` (the CLI works directly in Bash — don't ask the user to do it).
- **Never playtest via MCP** — inspect only ([[no-playtest-inspect-instead]]).

## NEXT

**This is the only NEXT in the file.** The per-checkpoint ones were stale directives
buried in history and have been deleted — a checkpoint records what happened, not what
to do.

In rough order:

1. **Node meshes** — retire voxel trees; the imported map and every procedural star
   still grow oak everywhere. Biome-appropriate species, then T5 set-pieces. (doc 21)
2. **Crafting UI** — the recipe layer exists (`std/recipes`, `systems/crafting`,
   Blink `Craft`) with no interface on it. Tree browser, station/time gating,
   factories. (doc 22)
3. **Gathering that is not "break a block"** — resource nodes as real drops, tool
   tier gating, so `pickaxe_3` means something. Today breaking any block yields
   exactly that block, 1:1.
4. **Return-trip polish** — leaving a star works (`StarExit`), but the lobby does
   not know you came back from anywhere.
5. **Server capacity for a popular hub** — `StarRouting` pins one reserved server
   per star; when it fills, `TeleportAsync` fails and the player gets `EnterDenied`.
   Needs a per-star server LIST, not a single access code.
