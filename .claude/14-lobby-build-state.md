# 14 — Lobby Build: Current State & Pickup

**Read this first to resume.** The Linear M1–M10 board is the *plan*; this is what's *actually built* in the lobby prototype (the flyable Cluster) as of the last session, plus the next step. Design rationale lives in doc 13 (constellations/plots), **doc 15 (data schema — DataStore + MemoryStore)**, + docs 06/07.

## ✅ Checkpoint (latest session) — BOUNDED-STAR GEN + ENTRY + CRAFTING FOUNDATION
The worlds become enterable + craftable; design canon for biomes/crafting written.
- **Bounded-star worldgen** (`src/Misc/WorldGen.luau` gains star mode): `applyStar/applyStarByTypes` = per-star seed + radial **island disc** (slopes into void beyond the rim) + **restricted rolled biome palette** (region field, lower tiers more area); legacy infinite continent still the fallback. `std/starconfig` publishes `{seed,radius,types}` via ReplicatedStorage attrs; server `systems/starworld` + client `Client/StarWorld` both `applyStarByTypes(get())` so terrain matches; spawn lands on the island centre; `CharacterAutoLoads` off until configured. TEST star for Studio/direct joins.
- **Real star entry**: `UniverseField` planets have an expressive **Enter** ProximityPrompt (`Style=Custom`) → Blink `EnterStar(slot)` → lobby `systems/starentry` recomputes the star (must exist this week) + checks proximity → `TeleportAsync(RESOURCE_PLACE_ID, {seed,radius,types})`. **Two places: Lobby + Star (= ResourceStar PlaceId), one live server per starId (MemoryStore routing later).**
- **Biome canon (doc 21)**: 25 biomes = 5 families (Flora/Stone/Sand/Frost/Bog) × 5-tier ladders; tier = terrain wildness × node richness × rarity; nodes = **meshes** (`Assets.Resources`), 3/biome, T1-varied → T2+-iconic, tiny hover overlay. Still coarse in code (`WorldGen.TYPE_BIOME` maps type→one biome, tier ignored).
- **Crafting canon (doc 22) + foundation BUILT**: three surfaces (3×3 pattern **table** / time **stations** furnace-sawmill-crusher-… / **factory** automates a pattern). **Two axes: TIER (unified material per tier) vs AESTHETIC (cosmetic stain-styling OFF the tier tree).** `std/materials` (75 raws + refined + stains), `std/recipes` (station chains generated per tier + table core + doc-11 tier-upgrade rule + `byId`/`inputsOf`). `itemdb` **generates** all craftables as placeholder-icon items (mats 1000+ / tools 2000+ / product placeholders 3000+). Server `systems/crafting` (both places): `Craft(recipeId)` → validate/consume/grant (MVP instant). `PlayerStore` `[TEST]`-grants mats. **NEXT: crafting UI + tree browser, station/time+factory gating, mesh-node placement (retire voxel trees).**
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
- **`CameraController.luau`** (already in prior checkpoint): scriptable over-shoulder shiftlock; scroll→hotbar, Alt+scroll→zoom, Alt / UI-open → free cursor + custom crosshair.
- **expressive-prompts wired (`Prompts.luau` = `Init()`+style):** star-catch `ProximityPrompt.Style=Custom` renders the styled billboard (`StarRenderer`). **ResourceStar entry stays an approach-countdown** (fly near → "Entering The <Biome>… 3" → `TeleportService`), NOT click-to-teleport — deliberate.
- **Random cluster spawn:** `FlightController` spawns you at a random angle in the residential annulus (outside the black hole, inside the ring), facing outward — far from resource stars.
- **Engine fixes:** (1) `lobby.luau` `Workspace.FallenPartsDestroyHeight = -1000000` — the default −500 kill-plane was instantly killing low-flying players. (2) `StarField` spread wider (`FIELD_RADIUS 300→1800`, `DUST_COUNT→900`, bigger size/wobble) so near dust parallaxes slower → travel stops looking too fast.

## ✅ Checkpoint (item system) — still current
Item system + UI framework are built (docs 17/19/20). Highlights & recent fixes:
- **Items are SLOT-based** (server-authoritative, `PlayerStore.slots`: 1-9 hotbar, 10-54 inventory). `ItemInventory` (45 static slots, Minecraft cursor pick/drop = **clone of the slot frame**, right-click consume, full-spec tooltip), `ItemHotbar` (1-9/scroll/click → equip; gray "held" dim + `HotBarText`), `ItemDrag`. Blink: `ItemSync`(slots)/`MoveItem`/`UseSlot`/`EquipItem` (regen done).
- **Held tools:** server spawns only a bare **Handle** (`EquipService`); each client clones the mesh + LODs particles (`HeldTools`); tool `Activated` → behavior (seed → `PlantingController` → `PlantService`; name+cell unique via `PlanetRegistry`). **Star Seed granted every join `[TEST]`.**
- **`tier` (numeric item level) vs `grade` (rarity common→mythical)** are separate. Grade visuals in one table `UIData.Grade` (+ effect flags colorLoop/gradient/glow; border tiles via `UIData.Border` index). **All UI text = `UIData.Font` Silkscreen** (UIRegistry stamps it).
- **Custom camera** (`CameraController`, lobby): over-shoulder shiftlock, scroll→hotbar, Alt+scroll→zoom, Alt/UI→free cursor. Roblox backpack CoreGui disabled.
- **Server cold-start FIXED (was 30s):** `lobby.luau` blocked on `WaitForChild("ForestStar",30)` (star is in Assets now, not Workspace) — removed. `players.playersRemoved` jecs error fixed. `start()` logs per-module boot timing. Collectables use spatial buckets (scales to 10k+ stars).
- **NEXT:** make Forest resource star real (biome+seed in ResourceStar, `ResourceStarEntry`→TeleportService); replicated render of planted stars + fly-near ViewportFrame preview; mobile flight thumbstick; FX presets (doc 20 §9).


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
**Next (doc 20 §5):** inventory 45-slot fixed grid + Consumable-click use; grade *border* polish.

Earlier foundation (still current): `PrivateStarStore` (per-player `star_<UserId>`),
`std/starsize`, `RegionSeed` (MemoryStore daily seed), `std/planting` (grid). Schema in doc 15.
After the item UI: `WorldGen` seed param, then the fly-near ViewportFrame preview.

## Architecture (decided — doc 13)
- **One codebase, two published places.** `std/placemode.luau` resolves `Mode` from `game.PlaceId` (`LOBBY_PLACE_ID` / `RESOURCE_PLACE_ID`, now filled) with a `STUDIO_OVERRIDE` for testing.
- **Lobby place** = The Cluster (zero-g flight, stars, black hole, collectables; private planets live here later, co-resident, loaded from DataStore).
- **ResourceStar place** = the voxel gathering "wild" — ONE place, biome chosen via `TeleportData.biome` + a fixed regional seed. NOT one place per biome.
- `main.client` + `init.server` branch on `placemode.Mode`.

## Lobby — client (`src/Client/`)
- **FlightController** — zero-g jet flight (WASD + Space/LCtrl), rig faces travel (R6/R15 anim sets), **random cluster spawn** (annulus, facing out), movement frozen while a modal UI is up. Speed ×`FlightBoost.mult()`. **Black-hole event horizon**: inside `BLACKHOLE.radius` you can't escape → dragged to `coreRadius` → consumed → respawn.
- **FlightBoost** — Hold LeftShift boost (stamina + deplete-lock, feet/camera particles, pitch-rising SFX). Feet plume is `LockedToPart` so it doesn't chase the camera. See top checkpoint.
- **CameraController** — scriptable over-shoulder shiftlock (scroll→hotbar, Alt+scroll→zoom, Alt/UI→free cursor).
- **Prompts** — `ExpressivePrompts.Init()` + style config; any `ProximityPromptStyle.Custom` renders the styled billboard (star catch uses it).
- **SpaceProxies** — parallax proxies for all landmarks (black hole + 5 resource stars), cloned from `ReplicatedStorage.Assets[template]`, kept close + scaled to fake distance, **spins ring `Union`s** in-frame. Driven by `constellation.LANDMARKS`. *Replaces the retired `BlackHoleProxy` + `StarRings` — delete those two files.* ⚠️ **Runs at `BindToRenderStep(RenderPriority.Camera+1)`, NOT `RenderStepped:Connect`** — a proxy is rendered close to the camera so its position is hyper-sensitive to the camera; it MUST update after `CameraController` (which binds at `RenderPriority.Camera`) or it reads a stale camera and shakes at high speed. Keep this ordering.
- **StarField** — client-only dust (camera-wrapped toroidal field, random firefly colors, wobble). Spread wide (`FIELD_RADIUS 1800`) so near dust parallaxes slowly = travel doesn't read too fast.
- **StarRenderer** — renders the STREAMED collectable stars (Blink `StarStream`/`StarUnload`), interpolates, dims by distance, catch prompt → `StarCatch`, `StarCaught` → burst + sound.
- **ResourceStarEntry** — proximity countdown HUD ("Entering The <Biome>… 3") → `TeleportService:TeleportAsync(RESOURCE_PLACE_ID, {plr}, {TeleportData={biome}})` (guarded pcall). Deliberately approach-based, not click-to-teleport.
- **Music** — shuffled BGM from `SoundService.Musics`.

## Lobby — server (`src/Server/systems/`)
- **collectables** — STREAMED collectable star field: stars are DATA (no Instances), simulated + streamed only near players in Blink batches, catch validated server-side → `leaderstats.Stars`. Tunables: `STAR_COUNT`/`FIELD_RADIUS`/`STREAM_RADIUS` (visible ≈ COUNT·(STREAM/FIELD)³).
- **constellation** — invisible warp anchors at resource-star positions (future server-authoritative warp validation).
- **lobby** — `Workspace.Gravity = 0` + `FallenPartsDestroyHeight = -1000000` (drop the −500 kill-plane so low flight doesn't insta-kill). No more `WaitForChild` blocking boot.

## Config: `src/std/constellation.luau`
`CENTER` (0,500,0), **`RING_RADIUS=30000`** (one knob → the 5-point `RESOURCE_STARS` ring, with `Y_JITTER`), `NO_PLANT_RADIUS` 6000, `WARP_RADIUS` 2200, `BLACKHOLE {radius=12000, pull=600, coreRadius=700}`, `LANDMARKS` (per-landmark proxy `template`/`pos`/`baseScale=6`/`proxyDist`; BlackHole `baseScale=20`), `canPlantAt()`. Sibling radii that must track it: `planting.ZONE_RADIUS=24000`, `collectables.FIELD_RADIUS=22000`.

## Studio scene / assets (in the lobby place)
- Landmark **models must be templates in `ReplicatedStorage.Assets`** named to match `LANDMARKS`: `BlackHole`, `ForestStar`, `DesertStar`, `MountainStar`, `HillStar`, `SwampStar`. SpaceProxies clones them; a missing one skips (warn). **Move them out of Workspace** or you double-render.
- `Assets.Star` (collectable template), `Assets.crown`. `SoundService.Musics` + `SoundService.SFX` (Star Catch/Flee, Magic).
- Persistent landmark models need `ModelStreamingMode = Persistent` (spawn is ~5000 from center or they stream out).

## ⚠️ Must-dos / gotchas
- **Blink is regenerated.** `ServerNet`/`ClientNet` now include the star events and the item events (`ItemStack`/`ItemInv`/`ItemSync`/`UseItem`/`DropItem`). After any future `Net.blink` edit, run `blink Net.blink` (the CLI works directly in Bash — don't ask the user to do it).
- **Never playtest via MCP** — inspect only ([[no-playtest-inspect-instead]]).

## NEXT — make Forest real (PlaceIds are set)
1. **WorldGen**: force `biome = Forest` + a fixed regional seed in ResourceStar mode; read `TeleportData.biome` so one place serves all biomes.
2. **Warp**: `ResourceStarEntry` stub → `TeleportService:TeleportAsync(RESOURCE_PLACE_ID, {plr}, {TeleportData = {biome = "Forest"}})`; ResourceStar bootstrap reads it.
3. **ResourceStar place scene**: a `SpawnLocation` on terrain + normal gravity.
4. Then the actual gather loop inside the wild: nodes/normal spawns, weight, market (M2/M3 systems).
