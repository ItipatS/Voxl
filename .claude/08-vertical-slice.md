# 08 — The Vertical Slice (build THIS first)

> Enforcement of principle 8 (feel before systems) and principle 9 (balance is discovered). The design is coherent enough. The next real progress is a **playable prototype**, not more systems.

## What the slice tests

Exactly one question, in this order of importance:

1. **Does gather → place → craft feel good in the hand with ZERO goals?**
   Can a bored person who isn't you mine a block and place a block for ~10 minutes and not be bored? If no, nothing else matters yet.
2. **Does the biome node/normal split create a felt reason to specialize/trade?**
   Does the swamp player actually *feel* "wood is slow here" and want forest wood?
3. **Does weight feel like meaningful friction, not busywork?**

If (1) fails, stop and fix feel before building anything else. If (1) passes, the whole design has a floor to stand on.

## Scope — the minimum [DECIDED]

Deliberately tiny. Do **not** add anything not on this list.

| Include | Exclude (for now) |
|---|---|
| **2 biomes**: Forest + Swamp | all other biomes |
| **1 resource with node/normal split**: wood (Forest = fast tree *nodes*; Swamp = slow normal trees) | fiber, ore, stone tiers, rarity variants |
| **Gather → place block** | factories |
| **Gather → craft ONE tool** (e.g. a better axe that gathers faster) | markets, trading, currency |
| **Backpack weight, 2 tiers** (so the progression axis is testable) | skills tree, mastery, cosmetics |
| **One shared resource area per biome** | the full cluster lobby / star map |
| Server-authoritative gather + node renewal (timestamped) | persistence deltas (can regenerate for the test) |

## Concrete build order

1. **Player can gather wood** from tree sources; wood enters inventory with a `weight`.
2. **Node vs normal:** Forest trees renew fast + gather fast; Swamp trees renew slow + gather slow. Server-authoritative renewal timer (use the ready `Environment`/`Spawning` phase). [TUNE] the two ratios.
3. **Place/remove blocks** consuming inventory wood (place-block already exists via mesher — wire it to inventory consumption).
4. **Backpack weight:** cap carried weight; 2 tiers; over-cap = can't pick up. [TUNE] weight-per-wood and the two caps.
5. **Craft one tool:** a hand-craft recipe (wood → better axe) that increases gather speed. Proves the horizontal-progression feel.
6. **Two shared areas** (Forest, Swamp) players can move between.

## Placeholder values to start [TUNE — expect all to change]
- Forest tree: gather 1 unit / 0.5s, renews in 5s, node always full.
- Swamp tree: gather 1 unit / 2s, renews in 30s.
- Wood weight: 1 each. Backpack T1 cap: 40. T2 cap: 100.
- Better axe: wood gather speed ×1.5.

*(These numbers exist only to make the slice playable. The whole point is to change them based on what the playtest teaches.)*

## Success / fail criteria
- **PASS:** one real tester gathers, builds, and crafts for 10 minutes unprompted and says some version of "this is kinda satisfying."
- **FAIL:** they stop early, or say gathering/placing feels flat or fiddly. → fix feel (block-break feedback, sound, timing, camera) before ANY further system work.

## Reminder
Nobody reaches the deepest factory tree if minute-one gathering feels bad. This slice protects a year of your life.
