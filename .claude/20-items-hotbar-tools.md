# 20 — Items, Hotbar & Held Tools

The interaction model for items, made **explicit up front** (not retrofitted). Builds on
the item layer (doc 17) + UI framework (doc 19).

## Item kinds (explicit in `itemdb`)

Every item has a `kind` that decides HOW it's used — decided now so tools/weapons and
consumables never get tangled:

| `kind` | where | how used | examples |
|---|---|---|---|
| **`Tool`** | **hotbar** (9 slots) | select slot (1–9 / click) → **equipped as a Roblox Tool in hand**; **activate** (click) runs its behavior | Star Seed (plant), future weapons/tools |
| **`Consumable`** | **inventory** | click the inventory slot → behavior runs immediately | potions, food |
| **`Material`** | inventory | inert — just stored | ores, crafting mats |

Rule: **only hotbar (Tool) items get held in-hand**; **inventory-click is for Consumables
only**. This keeps input contexts clean (a held tool owns click/activation; the inventory
owns consumable use). The Star Seed is a **Tool** (`model = "StarSeed"`, behavior `plant_star`).

## Equip = server owns state, CLIENTS clone the mesh, particles LOD

Decided (user): the server owns *who holds what* but spawns only a **bare invisible Handle +
`item` attribute** on the character (Tool tagged `HeldTool`). The server **never clones meshes** —
each CLIENT clones `Assets.Items[model]` into the tool locally (`HeldTools`) and welds it to the
Handle, so all clients see the same held item while the server replicates one tiny part. The
**expensive part is particles** — off by default, each client **LODs them by distance**:

```
select hotbar slot ─Blink EquipItem(id)→ server EquipService
   validates ownership + kind==Tool → builds Tool from Assets.Items[model]
   (Handle = model's main part, rest welded, all UNANCHORED + CanCollide off + Massless)
   ParticleEmitters set Enabled=FALSE (no default spam) → parents Tool to the character
        │ replicates to everyone (model visible to all)
        ▼
each client's HeldTools LOD loop: for every held Tool, enable its ParticleEmitters ONLY
   when the holder is within LOD_DIST of you, else keep them off → near = full FX, far = model only
```

Local player's own Tool `Activated` → runs the item's client action (`ItemUse`), e.g. Star
Seed → `PlantingController.begin()`. The actual plant is still the validated `PlantStar` flow.

*Future:* the server can also cull equip broadcasts / send LOD hints by proximity; for now the
Tool's replicated presence is the signal and the client does the distance LOD.

## Hotbar + inventory UI

- **Hotbar** (`Interface.HotBar`, Slot1–9): shows the player's Tool items. **1–9 or click** to
  select (empty slots selectable → unequip). Selected slot **scales up** (+ `select` sound).
  **Quantity hidden** unless the item is stackable AND count > 1.
- **Inventory** (`Interface.Inventory.ItemSlots`): a fixed **45-slot** grid (9×5) using
  `ItemTemplate`. Consumables used by click. Grade visuals per slot.
- **Grade visuals** (doc 17 `Effect`): each slot's name/border reflects the item's grade — the
  Star Seed (grade `ultimate`) gets the animated **rainbow running-name + special border**. It's
  the game's first showcase item, so it should look unmistakably special.

## Grade (rarity) vs tier (level) — two separate axes

- **`tier`** (`itemdb` number) = the item's **level through progression** (1..N) — a stat for
  crafting/stats, NOT a visual.
- **`grade`** (`itemdb.Grade`) = **rarity**: `common → uncommon → rare → epic → legendary → mythical`
  (extensible). Grade is the ONLY thing that drives visuals. e.g. a *tier-2 mythical* item.
- Visuals live in **one table**, `UIData.Grade` (client), keyed by grade name → a static `Color3`
  or an animated effect table `{colorSequence, direction, duration}`. `UIData:GetGradeLook(grade)`
  returns it; `UI.grade` (text) / `UI.borderFX` (slot border) / `UI.Effect` consume it generically —
  no more legacy `Tier` one…nine / demon / test remap. Add fancier grades by adding a row.
- `mythical` = the cosmic-starlight animation (the Star Seed); `legendary` = animated iridescent;
  the rest are static colours.

## Slot-based storage (Minecraft/Terraria)

Items are stored **by slot**, server-authoritative: the profile holds `slots`, a dense
54-entry array (**1–9 hotbar, 10–54 inventory**), each `{item = key, count}` (empty = `item=""`).
Weight is derived from slots + blocks. Client mirror (`ItemMirror`) reflects occupied slots.

- **`ItemDrag`** — the cursor: left-click a slot → pick the stack onto the cursor (a "ghost"
  the renderers hide), click another → `MoveItem(from,to)` (server swaps/merges), right-click →
  `UseSlot` (Consumables). **Only active while the inventory is open** — that's the "hotbar drag
  only when open" context. Closing while holding just returns the stack (nothing moved server-side).
- **`ItemInventory`** — 45 STATIC slots (10–54), grade shown on a `UIStroke` border (ImageColor3 is
  owned by buttonFX), grade name + weight on hover tooltip, weight bar.
- **`ItemHotbar`** — slots 1–9; **1–9 / scroll / click** selects (when inventory closed) → equip;
  selected slot scales up + **dims its item image**; clicks become drag when inventory is open.
- Blocks stay their own channel (`InventorySync`), Resource-place only, for now.

## Build status
1. [x] `itemdb.kind` + Star Seed as `Tool` (`model="StarSeed"`).
2. [x] Blink `EquipItem`; server `EquipService` (equip authority + Tool builder + spawn).
3. [x] `HeldTools` (own-tool Activated → behavior; particle distance-LOD).
4. [x] Slot-based `PlayerStore` + Blink `ItemSync`(slots)/`MoveItem`/`UseSlot`; `ItemMirror`, `ItemDrag`.
5. [x] Static 45-slot `ItemInventory` (cursor pick/drop, right-click consume) + `ItemHotbar` (scroll/dim/drag-context).
6. [x] [TEST] Star Seed granted (topped up) every join until items have a real source.
7. [x] `HotBarText` (selected item name + desc + icon, grade text effect); `DragableLayer` cursor;
   slot tileset image (`rbxassetid://111907724412912`, rect 64×64 @ 384,0) + `UI.borderFX`
   grade border (animated for ultimate); server Handle-only + client mesh clone.
8. [x] Inventory slots have **no selection FX** (the pick-up-to-cursor IS the feedback). Hotbar's
   **held** slot (renamed from "selected") shows only a **gray dim** + `HotBarText` (name + what it
   does). Border tiles wired: `UI.borderFX` sets a static tile per grade (`UIData.Border[grade] =
   {col,row}` on the 10×8 / 64px "Ram Border All" tileset) and **random-cycles tile + colour** for
   the ultimate grade (offsets capped at 576×448). Fill `UIData.Border` per tier.
9. [ ] **Design next: FX presets.** Text + border effects driven by DB metadata + named presets
   (reuse the Emitter2D approach) — an item/grade names an FX preset; a registry maps preset → the
   text effect / border animation / 2D emitter. (`UI.Effect`/`borderFX` are the current building blocks.)
10. [ ] Polish: place-one on right-click-while-holding; unify blocks into the slot model; tune the
    held-tool grip/scale in Studio.
