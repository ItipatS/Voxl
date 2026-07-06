# 10 — Progression System

The remaining core design. Built explicitly *against* the Cubic Castles failures the human named: "no point leveling, don't know what perk to pick, too grindy, too empty."

## Rule zero [DECIDED]
**No exclusive spend-with-regret perk trees.** Everything is *earned by doing* and *shown as a concrete objective*. If there's ever a choice, it's additive (you get the others eventually), never mutually exclusive. This kills the Cubic Castles paralysis at the root.

## Four interlocking systems

Progression is NOT one ladder. It's four systems, each **per-path**, with a **thin global summary** on top. The player learns the "per-path + global summary" pattern once and it repeats everywhere (skills, gear, journal).

---

## 1. Skills — per material, gather + craft, independent [DECIDED]

- Skills split **per material**: wood, fiber, stone, ore, rock — each has a **gathering** skill and a **crafting** skill.
- Plus **equipment-crafting** and **factory-building** as their own crafting tracks.
- **Gathering and crafting skills are independent.** You do NOT have to gather to craft — you can buy materials off the market instead. Your choice. (Pure crafters are viable.)
- You level a skill by **doing that thing**, so a level is never an abstract number — it's "I mine → mining improves → I reach the next thing."
- **Crafting skill gates tier ascension** (can't craft Tier-2 cloth until wood/fiber crafting ≥ N). This is the secondary backbone gate.
- **First biome = head start, not a lock** [DECIDED]. Your starting biome is rich in one resource type, so you naturally level its skills first — but nothing is locked; you can go level any other skill later, just slower. **Generalist is viable; specialist is optimal** ("specialize is always better when the resource is already specialist").

See `docs/11` for the full matrix.

---

## 2. Gear — tool vs armor split, field-specific [DECIDED — keystone]

Two equipment roles, opposite jobs:

- **Tool → gather SPEED** (how fast). Axe, pickaxe, skinning knife, etc.
- **Armor/robe → YIELD + RARITY** (how much per gather, and chance of higher rarity). Lumberer robe, hunter robe, miner garb, etc.

**Field-specific:** each field has its own tool and robe, so the speed-vs-yield decision is made **per activity**, not once globally. A player can run high-yield skinning gear *and* fast wood tools simultaneously. This multiplies meaningful build decisions with zero menus.

**Why this beats perk trees:** two viable playstyles fall out of two equipment slots — speed-heavy (raw volume for bulk trade/build) vs yield/rarity-heavy (fewer actions, richer returns, good for hunting variants). No wrong answer, no regret.

**Synergy with the sink [DECIDED]:** armor is *also* the durability sink (doc 05). The gear that boosts gathering **wears out from gathering** — so heavy gatherers burn armor faster, tying the sink directly to the activity that benefits from it. Self-balancing.

**Tool tiers** are the tactile per-resource gate (primary-3 of the backbone): a better axe is the felt "I upgraded" moment per material.

---

## 3. Rarity — both hunt and grind [DECIDED]

Rare variants (e.g. fiber: Cotton → Flax → Hemp → Sky Flower → Star Flax) come from **two sources at once**, covering two player types with one field:

- **Field spawns (the hunt):** rare variants spawn rarely in the infinite resource field. Explorers roam to find them. (Terraria DNA.)
- **Yield/rarity chance (the grind):** better skill + armor gives a chance to yield higher rarity even from normal common sources. Grinders farm a good spot with good gear. (Skyblock DNA.)

Neither playstyle is wrong; the same field serves both.

---

## 4. The Journal — the main "level" system [DECIDED]

Milestones, framed as a **journal** (keep this word — warmer than "milestones," and it tells the player what it is: a log of done + ahead, not a quest-nag).

- **Per-path pages** (Wood, Fiber, Stone, Ore, Rock, Hunting, Crafting, Equipment, Factory...). Each page pulls the player toward the next thing *in the lane they enjoy* — the anti-emptiness cure aimed precisely.
- **Objective type = cumulative counters** [DECIDED] (e.g. "gather 100 wood, ever"), plus **a few discovery beats** ("reach a tier-3 biome for the first time"). Cumulative counters need no NPC/turn-in UI, reward what you're already doing, and never interrupt play. **No delivery/turn-in friction** — wrong for a cozy builder.
- **Whole ladder visible** [DECIDED] ("see everything is better"). A cozy builder has no time pressure, so overwhelm isn't the risk — *aimlessness* is. Showing the full journal turns "what now?" into "I'm 60/100 toward the Sawmill, and I can see the backpack tier past that." The visible ladder IS the anti-emptiness engine.
- **Account-wide unlocks** [DECIDED] — complete a page objective once, unlocked forever, everywhere. NOT per-star (re-grinding per world would be punishing). **Exception:** star-size expansion is naturally per-star.
- **Thin account-level** = sum of all path progress. A single prestige number for the star profile (Skyblock-Level style). Gates nothing; it's the flex stat.

### Rewards are ROUTED, not invented [DECIDED]
Every reward already exists elsewhere in the design. The journal is just the **delivery gate**. Distribute these across pages:

| Reward | Type | Source doc |
|---|---|---|
| Backpack tier (carry more) | functional | 03 |
| Factory space expansion | functional | 04 |
| New machine types | functional | 04 |
| Access to deeper/higher-tier biomes | functional | 03 |
| Star-size expansion (toward 1000³) | expressive | 06 |
| New block sets / colors / decor / build tools | expressive | 02 (principle 2) |
| Cosmetic / title / **star-badge** (seen mastery) | expressive/social | 02 (principle 1) |

**Balance rule:** every path's page must mix **functional** (for optimizer/grinder) and **expressive** (for builder) rewards, so no player type ever hits a dead stretch. Completed pages/badges are *visible on your star profile* — mastery must be seen (principle 1).

---

## The full backbone [DECIDED]
```
Journal (cumulative milestones)   = PRIMARY   → the "what next" engine + all unlocks
  Skill-gates (crafting level)    = SECONDARY → gates tier ascension
    Tool tiers (per resource)     = TACTILE   → the felt per-material upgrade
```
Recipes come from the crafting paths themselves — NOT from levels — which frees the journal to be pure direction + reward.
