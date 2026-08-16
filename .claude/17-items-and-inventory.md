# 17 — Items & Inventory (the first subsystem rebuilt to the baseline)

Rebuilds the inventory to the doc-16 dependency rule. It **generalizes the healthy
block inventory** (doc 16 §4) into a shared item layer, and **retires the ported RPG
inventory** (`_graveyard`). Weight is the keystone constraint (design principle:
weight/hauling is the friction that makes geography matter), so weight is authoritative
and lives with the one profile owner.

## Layers (left requires right? never — data flows left→right)

```
ItemDB (std, static)     PlayerStore (server, authority)      ItemMirror (client)      Item UI (view)
  item defs: id, key,      owns ONE profile: blocks + items     caches ItemSync:         Interface GUI +
  grade, weight, stack,    + derived weight/capacity            {items, weight, cap}     UIData/TierEffect/
  usableIn, behavior       .item.add/consume/use, syncItems()   fires a change signal    TooltipBuilder
  + block→weight bridge     ItemSync (server→client)            reads mirror only        (pure view helpers)
                            MoveItem/UseSlot/EquipItem (client→server)
```

## Ownership (the anti-race rule, doc 16 §1/§6)

- **`PlayerStore` is the single owner of the `player_<UserId>` profile** — blocks AND
  items live in one ProfileStore session. **Never** open a second session on that key
  (session-lock conflict). This is why items are added *to PlayerStore*, not a rival store.
- **Weight is derived, never stored:** `weight = Σ blocks·blockWeight + Σ items·itemWeight`,
  computed by ItemDB. Derived state has no writer → no race. `capacity` comes from
  progression (constant for now, later scaled by skill/tier — one place to change).
- Client mirror is read-only; it renders `ItemSync`. The client asks to use/drop via
  events; the server validates and re-syncs. Same contract as `EditBlock`.

## Wiring fix this rebuild makes (a real baseline correction)

Today `PlayerStore` only loads in **ResourceStar** mode (it's required as a side effect
of `BlockEditServer`). But the **Star Seed is planted in the Lobby** → the inventory
authority must run in **both** modes. So `PlayerStore` is added to **both**
`LOBBY_SYSTEMS` and `RESOURCE_SYSTEMS` in `init.server`. It stays the same cached module
instance when `BlockEditServer` also requires it (Luau require cache) — hooks connect once.

## ItemDB (`src/std/itemdb.luau`) — the static registry

Every carriable thing (items now; blocks via a weight bridge) has one immutable def:

| field | meaning |
|---|---|
| `id` | stable `u16` network id (its own space; separate channel from block `u8`s) |
| `key` | string handle used in code/profile (`"star_seed"`) |
| `name` | display |
| `grade` | GDD grade → drives UI color/effect via `UIData:GetGradeTier` (`normal`…`ultimate`) |
| `weight` | studs of weight budget per unit (the keystone number, [TUNE]) |
| `stack` | max per stack (1 = unstackable) |
| `usableIn` | set of placemodes it can be *used* in (`{Lobby=true}` for the seed) |
| `behavior` | key into the server behavior registry, or nil (inert/material) |
| `desc` | tooltip lines |

Plus `blockWeight(blockId)` (the bridge — blocks cost weight too) and `capacity(profile)`
(progression hook). **The Star Seed** (`key="star_seed"`, grade `ultimate`, `usableIn`
Lobby, `behavior="plant_star"`) is the first entry — the doc-13/15 "plant a private star".

## Behavior registry (`src/Server/systems/ItemBehaviors.luau`)

`ItemBehaviors[key] = function(player, def) -> ok, reason`. Gated twice: the item's
`usableIn` must include the current `placemode.Mode` **and** the behavior runs
server-side with its own validation. `plant_star` → resolves the player's grid cell
(`std/planting`), checks `isPlantable` + occupancy, mints/plants via `PrivateStarStore`,
consumes one seed on success. Decoupled: PlayerStore calls the registry by key; it
doesn't know what planting is.

## Blocks are items

There is one inventory. A block is an ordinary `ItemDef`, generated from the block
registry rather than authored:

| | |
|---|---|
| `kind` | `"Block"` — the fourth kind (doc 20). Inert in the grid like a Material, but the only kind that can go back INTO the world |
| `key` | `block_<id>` — a block's NAME can be reworded, its id cannot, and the key is what lands in save data |
| `id` | `10000 + blockId`, clear of every other range (materials 1000+, tools 2000+, recipe placeholders 3000+) |
| `placesBlock` | the block id to place. **This field is the whole bridge** — before it, nothing could turn a block into an item, which is why the star place kept a second inventory |
| visual | neither `icon` nor `model`: the slot draws the actual cube via `BlockPreview`, which is free and always correct where 190 hand-made sprites would not be |

`itemdb.forBlock(blockId)` and `itemdb.blockOf(key)` are the two accessors.

Consequences worth knowing before you touch this:

- **Breaking can FAIL.** Slots are finite; the old `blockId -> count` map was not.
  `PlayerStore.add` returns leftover and `BlockEditServer` refuses the break, leaving
  the block in the world rather than mining it into nothing.
- **Old profiles are migrated once** on load (`onAdded` drains `Data.blocks` into
  slots and says how many moved). The field stays, always empty.
- **Ids are permanent.** `tools/mcimport/test_itemdb.luau` checks every block
  round-trips both ways, that no id or key collides, and that block ids stay above
  every other range. Run it after touching `Blocks.luau` or `itemdb`.
## Blink events (in `Net.blink`, generated)

```
struct SlotEntry { slot: u8, item: u16, count: u32 }
struct ItemInv   { weight: u32, capacity: u32, slots: SlotEntry[] }   -- full push
event ItemSync   { From: Server,  Reliable, Data: ItemInv }           -- after every change
event MoveItem   { From: Client,  Reliable, Data: MovePair }          -- drag a stack between slots
event UseSlot    { From: Client,  Reliable, Data: u8 }                -- right-click a slot (Consumables)
event EquipItem  { From: Client,  Reliable, Data: u16 }               -- hold a Tool (0 = unequip)
-- NOTE: UseItem / DropItem were designed here and never built. Dropping to the world
-- is still an open follow-up; there is no world-pickup entity yet.
```
**Blocks ride in here too.** They are items keyed `block_<id>` (see "Blocks are items" below), so `ItemSync` is the ONLY inventory channel — `InventorySync`/`BlockCount` are deleted.

## Client (`src/Client/ItemMirror.luau`) + UI

- `ItemMirror` — listens to `ItemSync`, holds `{items, weight, capacity}`, fires a change
  signal, exposes getters. **No UI, no writes.** The mirror the whole client reads.
- Item UI (rebuilt, replacing `_graveyard/InventoryManager`) — drives the authored
  `PlayerGui.Interface` (Inventory/Equipments, a registered panel on **E**; the Bag button is `QuickMenu.Bag` — note the capital Q, doc 19)
  from `ItemMirror`: one slot per stack, grade color/effect via `UIData:GetGradeTier` +
  `TierEffectManager.ApplyEffects`, tooltip via `TooltipBuilder`, a **weight bar**
  (`weight/capacity`). Drag a stack → `MoveItem`; right-click a Consumable → `UseSlot`;
  select a Tool in the hotbar → `EquipItem`. **View only** — it never mutates counts.

## Build order / status

1. [x] Quarantine `_graveyard` inventory graft (doc 16 §5).
2. [x] `ItemDB` + Star Seed + block-weight bridge + capacity.
3. [x] Blink item events (regen pending).
4. [x] `PlayerStore` extended to items + weight + `ItemSync` + `MoveItem`/`UseSlot`; wired in both modes.
5. [x] `ItemBehaviors` registry + `plant_star`.
6. [x] `ItemMirror` client cache.
7. [x] `blink Net.blink` regenerated — item + star events live in `ServerNet`/`ClientNet`.
8. [x] **Item UI** — `Client/ItemInventory.luau` renders `Interface.Inventory.ItemSlots` from
   `ItemMirror` using the authored `StarterGui.ItemTemplate` slot + `InformationFrame` tooltip
   and the salvaged `UIData`/`TierEffectManager`/`TooltipBuilder` helpers. Left-click = USE
   (server-gated by `usableIn × placemode`), right-click = DROP one. Adds a **weight bar**
   (`weight/capacity`, red when over). Wired into `main.client` for both places, plus
   the Inventory panel on **E** / the Bag button, in BOTH places (doc 19 registry).

**GUI facts (from Studio inspection):** slots go in `Interface.Inventory.ItemSlots`
(ScrollingFrame + UIGridLayout); slot template is `StarterGui.ItemTemplate.ItemTemplate`
(ImageButton → `ViewportFrame` + `Quantity`); tooltip is `StarterGui.ItemTemplate.InformationFrame`
(→ `TextLabel` + `NameLabel`). The `ItemTemplate` Folder lives under StarterGui (a template shelf,
not copied to PlayerGui) — reference it directly on the client.

**Slot visuals are hybrid** (`ItemDef.icon` / `ItemDef.model`, doc-17 schema): a flat 2D
sprite (`icon = "rbxassetid://…"` — the default; itch.io-style icon packs), or a 3D
`ReplicatedStorage.Models` child auto-framed in the ViewportFrame (voxel items like a tree/tool),
or — if neither is set (or the model is missing) — the **debug placeholder texture**
`itemdb.DEBUG_ICON` (`rbxassetid://78128038044643`), so a missing visual is obvious not blank.
That constant is shared, so block visuals can use the same fallback. World-drop representation
(2D billboard vs 3D) is a *separate* concern for the drop-pickup feature (still TODO).

**One renderer, not two.** `Inventory.ItemSlots` used to be filled by BOTH
`InventoryRender` (blocks, `Block_<id>` frames, star place only) and `ItemInventory`
(items, 45 static slots) — a "shared grid contract" that only held because the two
places never loaded both. Blocks are items now, so `ItemInventory` owns the grid
outright and `InventoryRender` is in `_graveyard`.

**Follow-ups (minor, [TUNE]):** (a) the weight bar lives inside the Inventory window (visible when
open) — promote to an always-on HUD element if weight should be glanceable during flight/gathering.
(b) E toggles the inventory in the Lobby; if private-star "press E to enter" is added later, rebind one.
(c) Dropping to the world does not exist at all — no `DropItem` event, no world pickup entity. Still open.
