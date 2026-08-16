# 19 — UI Conventions & Feel

The house style for all UI. The point: every panel/sound/notice behaves consistently
so the game feels intentional, and new UI is cheap to add (wire into the framework,
don't reinvent). Built to the doc-16 rule: one writer for UI state, controllers drive
content only.

## One home + one facade (uniform in code)

**All UI code lives under `src/Client/UI/`** (previously split between `Client/` and the
ported `ClientServices.UI`). Consumers require the **facade** once:

```lua
local UI = require(script.Parent.UI)   -- StarterPlayerScripts.UI
UI.open("Inventory")            UI.sound("confirm")        UI.Notify.zone("Forest")
UI.grade(label, "ultimate")     UI.tooltip(itemData)       UI.hover(myElement)
```

Requiring `UI` also **bootstraps** the framework (registers panels + binds universal
button feedback + builds the notification layer). Submodules under `UI/`:

| `UI/` module | facade | role |
|---|---|---|
| `Registry` | *(auto)* | **THE declarative place**: registers every panel, wires open/close buttons by path, gives EVERY button under Interface uniform **hover (scale+sound) + click** — incl. future/dynamic buttons via `DescendantAdded`. |
| `Controller` | `UI.Controller` / `UI.open/close/toggle/register` | mechanism: multi-frame panels, exclusive **groups**, **toggle-to-close**, **modal** context (Esc + `gameplayBlocked()`), toggle **key**; bakes in pop + sound. |
| `Sound` | `UI.Sound` / `UI.sound` | named/semantic sound under `SoundService.SFX/<category>`, **recursive-by-name** (reorg-proof). Events: `open→OpenUI, close/cancel→Cancel, select→Select, hover→MouseHover, confirm→Confirm, error→Error, notify→Noti, zone→ZoneNoti, skill→SkillNoti`. |
| `Tween` | `UI.Tween` | motion: `popIn/popOut` (dot↔large via `UIScale`), `fadeIn/fadeOut`, `hover` (scale). |
| `Notifier` | `UI.Notify` | `zone(title,sub)` big scale+fade; `toast(text,kind)` stacked auto-dismiss. |
| `UIData`/`Effect`/`Tooltip` | `UI.Data`/`UI.Effect`/`UI.Tooltip` + `UI.grade`/`UI.tooltip` | grade→colour/animated-effect config, apply/clear on a label, tooltip text builder (moved from `ClientServices.UI`). |

`ZoneWatcher` (Lobby, `src/Client/`) is a *feature* using the framework, not part of it.

## The uniform model (why maintenance stays cheap)

Every GUI runs through the framework — there is no bespoke `.Visible` toggling anywhere.
- **Panels** (Inventory+Equipments, CreatePlanet, future Map/Quest/Settings) are declared in
  `UIRegistry.PANELS` (or self-registered by a controller if they need custom `onClose`, like
  CreatePlanet). Declared-but-absent panels are skipped, so you can list future ones now.
- **Buttons** are wired in `UIRegistry.BUTTONS` (path → panel + toggle/close). Everything else
  gets **hover + "select" click** automatically. A button opts out of the auto click sound with
  the `UISoundOwned` attribute (set on panel buttons + controller-owned buttons like Confirm/Cancel),
  checked at click time so registration order never matters.
- **HUD** frames (HotBar, Forcast, QuestTrack, Error) are left alone — not panels.
  `QuickMenu` IS a panel (group `main`), raised by the `Menu` button.

### Recipe: add a new panel (e.g. a Map)
1. Author `Interface.Map` in Studio (AnchorPoint `0.5,0.5` to pop from centre).
2. `UIRegistry.PANELS`: it's already listed → just make sure the frame exists. Add `key`/`modal` if wanted.
3. `UIRegistry.BUTTONS`: `QuickMenu.Map → Map` is already listed. **Mind the capital Q** — `FindFirstChild` is case-sensitive and a path that misses is a SILENT skip, which is exactly how Bag/Map/Quest sat dead for months. Done — it opens/closes/pops/sounds, is
   exclusive with the other `main` panels, and every button inside it gets feedback automatically.

## Rules (obey these for every new UI)

1. **Sound is name-based, never asset IDs in code.** Add a Sound to `SoundService.SFX/<category>`,
   play it by name. To re-skin an interaction globally, edit the semantic map in `UISound` —
   one line. (Confirmed direction: this is easier to iterate than juggling IDs.)
2. **All show/hide goes through the framework** — `UIController` for panels, `UITween` for
   ad-hoc HUD toggles. Never set `.Visible` raw (except a silent initial hide at load).
3. **Panels pop, overlays fade.** Panels grow dot→large from their **AnchorPoint** — set it to
   `0.5,0.5` to pop from centre (or a corner to emanate from there). Titles/tooltips fade.
4. **Exclusive + toggle-close.** Give panels a `group` so opening one closes its siblings;
   `toggle()` on an open panel closes it. Same button that opened it closes it.
5. **Modals own input.** Mark blocking prompts `modal=true`: Esc closes the top, and gameplay
   controllers check `UIController.gameplayBlocked()` (FlightController already freezes movement).
   Use `onClose` for state cleanup so a close from ANY path (Esc, exclusivity) is clean.
6. **Feedback is mandatory.** Buttons: `UISound.bind(btn)` (hover + click sound); `UIController.press(btn)`
   on action. Pending/awaiting-confirm state = **breathe** (bright↔dim). Errors = red + `error` sound.

## Contextual feedback & effects (built)

Applied uniformly by `Registry` to every button; also callable directly.

- **Button states** (`UITween.buttonFX`, auto on all buttons): hover = **brighter + bigger**
  (scale 1.06, colour lerped toward white), press = **dimmer + smaller** (scale 0.95, colour ×0.78),
  release → back to hover/idle. Non-destructive — the base colour is captured once into a
  `UIBaseColor` attribute so it always restores exactly.
- **Hover sound** (throttled) + **click sound** (`select`, unless `UISoundOwned`).
- **Breathe** — `UIController.breathe(obj, prop, a, b)` for pending/awaiting-confirm states.
- **Pop / fade** — `UITween.popIn/popOut/fadeIn/fadeOut` (see motion grammar above).

### 2D particle bursts (Emitter2D)

`UI.burst(target, name?, count?)` fires a one-shot burst of 2D particles inside a GuiObject.
It's **tag-based**: the running `StarterPlayerScripts.Emitter2D` engine auto-activates any object
tagged `"Emitter2D"`, so `burst` just clones a config, tags it, fires its `Emit`, and cleans up —
it never requires the module (which trips its plugin path).

- **Author configs** with the Emitter2D plugin and store them under `ReplicatedStorage.Assets.Emitters`
  (e.g. `ConfirmSparkle`, `RareGlow`). A **named** burst is a **safe no-op until that config exists**,
  then it lights up — so you can wire `UI.burst(el, "ConfirmSparkle")` now (CreatePlanet already does
  on its confirm state) and just author the template later. A **nil** name uses the plugin default config.
- The engine + `ReplicatedStorage.Emitter2D` are plugin-managed; don't Rojo-convert them (attributes
  don't survive). The readable copy lives at `src/Client/Emitter2D/` (the Rojo loader `init.client`
  + reference module) — leave it; it is the running engine.

## Notice taxonomy (what shows where)

- **Zone title** (`Notifier.zone`) — big centre text that scales up + fades: entering a biome
  ("Forest"), the black hole ("The Maw"), open Cluster. One at a time. *(built — ZoneWatcher)*
- **Toast** (`Notifier.toast`) — small corner stack, auto-dismiss: pickups, skill-ups, warnings.
  Kinds: `notify` (default), `skill`, `error`. *(built)*
- **Countdown HUD** — *(gone)* `ResourceStarEntry` is in `_graveyard`; entry is the `UniverseField` prompt → `EnterHub`/`EnterStar` → `starentry`, wrapped in the iris transition.
- **Modal prompt** — `CreatePlanet` (name a star). *(built)*

## Z-order layers (keep panels from fighting)

`Interface` (HUD + panels + modals, one ScreenGui) < `Notifications` (DisplayOrder 50) <
future `Tooltips`/`Cursor` (top). Modals sit above HUD within Interface via the pop + a dim
scrim (scrim = TODO).

## Ideas to add next (the polish menu — cheap now, high aesthetic ROI)

- **Place-transition fade** — teleport Lobby↔ResourceStar behind a black fade + `Effect.Teleport`
  sound (hides the load, feels deliberate). A `ScreenFade` helper on the Notifications layer.
- **Rarity flourish** — mining/looting a rare item → gold toast + `Effect.RareItem` + a brief
  screen-edge shimmer. Ties the `grade` ladder (doc 17) to a felt moment.
- **Skill-up popup** — `Notifier.zone`-style but smaller, bottom-centre, `SkillNoti` sound.
- **Low-durability / weight-full warning** — pulsing red toast + `UI.LowDurability`; the weight
  bar flashes red when a pickup would exceed capacity.
- **Modal scrim** — dim + slightly blur the world behind a modal (focus + readability).
- **Hover-scale on slots/buttons** — 1.0→1.06 on MouseEnter (pairs with the hover sound).
- **Context hint bar** — bottom strip showing current controls ("[F] place · [X] cancel"),
  driven by whatever mode is active (planting already has an ad-hoc one — generalise it).
- **First-touch tips** — one-time toasts the first time a player enters a zone/opens a panel.
- **Button press → ripple/particle** for confirms (the "juice" layer).

Follow the same pattern for each: a small controller that calls `UIController`/`Notifier`/`UISound`
— never bespoke visibility or ID-based sound.
