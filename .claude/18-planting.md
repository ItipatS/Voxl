# 18 — Planting a Private Star

How a Star Seed becomes a planted planet on the constellation grid. Built to the
doc-16 rules: the client only *proposes*; the server *commits*; one writer per fact;
UI runs through a single controller. Grid math is `std/planting` (doc 13); storage is
`PrivateStarStore` (doc 15); the item is `star_seed` (doc 17).

## Flow

```
inventory click (Star Seed, Lobby)
  └─ ItemUse → PlantingController.begin()
       overlay = ghost Assets.Planet, snaps to nearest grid cell each frame
       green = plantable · red = too close to a star/black hole
  [F] on a green cell → lock cell → CreatePlanetController.open()
       INPUT   type name → Confirm validates locally (3–18, [%w %-'])
                 bad → Log red + SFX.Error, stay
                 ok  → CONFIRM
       CONFIRM Log green "Plant \"name\"?", Confirm breathes, SFX.Confirm
                 Confirm → PlantStar{name,cx,cz} ─────────────┐
                 Cancel  → back to INPUT (keeps prompt open)  │
  [X] / INPUT-Cancel → back out                               │
                                                              ▼
  server PlantService (authoritative, re-validates EVERYTHING):
     already planted? · holds a seed? · name sane? · cell rebuilt from indices
     plantable? · name+cell globally unclaimed (PlanetRegistry, atomic DataStore)
       → commit: PrivateStarStore.plant(plot,biome,name) + consume seed
     PlantStarResult{ok,reason} ──────────────────────────────┐
                                                               ▼
  client: ok → overlay goes solid (local placeholder) + exit
          fail → prompt Log shows reason (name/spot taken) → back to INPUT
```

## Modules

**Client (`src/Client/`)**
- `UIController` — the one UI manager: panel open/close (+ exclusive groups), `sound(sfx)`,
  `breathe(obj,prop,a,b)`, `press(obj)`. All future UI should route through it.
- `CreatePlanetController` — the `Interface.CreatePlanet` prompt (INPUT↔CONFIRM state machine
  on the shared Confirm/Cancel buttons; log colors; sounds; breathing). Exposes
  `open{onSubmit(name, report), onCancel}` — the owner does the async commit and calls
  `report(ok, message)` to close on success or show the failure in the log.
- `PlantingController` — the overlay + placement mode; owns the `PlantStar`/`PlantStarResult`
  round-trip; registers itself into `ItemUse` for the `plant_star` behavior.
- `ItemUse` — client interaction registry (behavior key → handler). Placement items register;
  instant items fall through to Blink `UseSlot` (server-side `ItemBehaviors`). Keeps `ItemInventory` ignorant of planting.

**Server (`src/Server/systems/`)**
- `PlantService` — the authoritative handler; re-validates and commits (see flow).
- `PlanetRegistry` — global atomic reservation of NAMES + CELLS (plain DataStores,
  `UpdateAsync`). Fails **open** in Studio without API access (warn) so it's testable.
- Extends `PrivateStarStore` (`isPlanted`, `plant`) and `PlayerStore` (`itemCount`, `consumeItem`).

**Blink:** `PlantStar{name,cx,cz}` (client→server), `PlantStarResult{ok,reason}` (server→client).

## Why it can't be cheated
Client sends only a name + integer cell indices. The server rebuilds the cell centre from
indices (never trusts a position), re-checks `isPlantable`, re-checks seed ownership + not-
already-planted, and reserves name+cell atomically across all servers — so racing clients or a
forged `PlantStar` can't double-claim a name/cell or plant without a seed. The seed is consumed
only after the commit succeeds.

## Follow-ups
- **Authoritative render:** success currently leaves a *local* solid planet. Replicated rendering
  of planted stars (so neighbours see them) + the fly-near **ViewportFrame thumbnail** (the
  `Assets.Planet` model rendering the stored world) is the next feature (doc 14 preview step).
- **Occupancy source of truth:** `PlanetRegistry` (DataStore) is the durable claim; a per-
  constellation manifest (doc 15 `constellation_<name>`) can cache it for fast in-server checks.
- CreatePlanet-cancel returns to overlay-follow (re-pick); `X` fully exits. [TUNE].
