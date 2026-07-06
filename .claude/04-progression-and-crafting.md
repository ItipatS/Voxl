# 04 — Progression & Crafting

## Philosophy

Crafting must be **meaningful**, which per principle 2 means mostly **horizontal** (new recipes, new expressive options) with vertical power only where it feeds an activity. The model combines **Satisfactory (active factory management)** with **Cubic Castles / Growtopia / Hypixel (crafting hierarchy)** — but explicitly rejects timer-crafting and RNG-break crafting.

## Rarity × Tier crafting [DECIDED]

Two orthogonal axes:

### Rarity variants (per base material)
Each base material has rarity variants found/gathered at different rates. Example (fiber):

`Common: Cotton → Uncommon: Flax → Rare: Hemp → Epic: Sky Flower → Legendary: Star Flax`

### Tier ascension (vertical, gated by crafting level)
Climbing tiers costs *disproportionately* more and is gated by crafting skill level. Example (cloth):

- 1 × Tier-1 cloth = 10 × fiber
- 1 × Tier-2 cloth = 5 × Tier-1 cloth (and requires crafting level ≥ N)
- ...

A full set (e.g. **cloth armor granting woodcutting speed + gathering bonus**) across all tiers is a deliberately long grind — the Hypixel-style ladder players opt into. **Keep this; it is the long-session retention engine.** Just remember (principle 1) the output must *do* something socially — here it grants a gathering bonus, so it feeds the loop.

> Note: the rarity ladder is a **grind ladder, not an economic sink.** It keeps a solo player busy; it does not by itself keep the market alive. The sink is in doc 05.

## Skills & mastery [DECIDED, detail OPEN]

- Separate skills per activity (mining, woodcutting/foraging, farming, combat/hunting, crafting, fishing — align with biome resources).
- Skill/mastery raises **base gather/craft speed** and unlocks recipes/options.
- Hand-craft speed = `base + hammer/tool level + skill/mastery`. This is why **hand-crafting stays faster than factories** (guardrail, principle 3).
- [OPEN] exact skill list, XP curves, and whether skills gate market access (see the Skyblock lesson in doc 05).

## Crafting methods: hand vs factory [DECIDED]

### Hand-crafting
- **Fastest per-item** (base + tool + skill).
- Requires you to be present and doing it.
- The default; always viable.

### Factories (the timer-crafting replacement)
Instead of "wait 6 hours for one rare item," you **build a factory** and manage it:

- You get free **limited space** for factories (expandable via milestones/game passes — see monetization, doc 05).
- You lay out machines to produce higher-tier goods efficiently — **the Satisfactory fun is in the management/layout**, not in waiting.
- **Offline production [DECIDED]:** factories run while you're offline. Implementation: on rejoin, compute `elapsed = now - lastSeen` (server timestamp), then **fast-forward production in a single Heartbeat pass** ("speed up everything in one loop, boom").
- **Capped [DECIDED]:** offline output is capped — storage fills and production **stops**. Cap raised by skill/equipment. This enforces principle 7 (never reward logging off) and keeps "gathering is fastest" true.
- Machines/factories **need inputs to run and repairs over time** — this is a major economic sink (doc 05). Repairs are per-factory (not per-machine one-by-one).

### The full guardrail chain [DECIDED]
```
gather yourself   (fastest)
  > hand-craft    (fast, requires presence)
    > factory     (slow-but-passive, capped, needs upkeep)
```
Passive generators (from game passes/milestones) exist but are the **slowest** — convenience, never optimal (principle 3).

## Player-made items [DECIDED, scope OPEN]
All items and cosmetics are **player-crafted** (except game-pass items). Interpretation: players craft *instances* of dev-defined item types — NOT authoring new item designs/art (that would be a UGC pipeline with heavy moderation/tooling; explicitly OPEN in doc 09). Confirm before building either.
