#Current Design (Major Pivot) — SUPERSEDES parts of docs 03/05/06

> This doc captures a significant direction change. Where it conflicts with 03/05/06, **this wins**. The core soul (docs 01/02) and progression (10/11) are unchanged. Read this as the current truth for the world model.

## The one-line shift
Voxl is now an **explore-and-claim** game, not a haul-between-fixed-regions game. There is **one kind of star**, procedurally generated across an **unlimited** universe (proxy-rendered, so map size is no longer a constraint). You explore to find a world worth living in, then **claim it as your home**.

---

## World model [DECIDED — replaces doc 06's fixed resource/private split]

**One star type.** Every star is a public, procedurally-generated world (random biome mix, tier, quality). Anyone can visit and gather in an unclaimed star.

- **Claiming:** plant a **Starseed** to claim a star and name it → it becomes **your private star instantly**. Others can still *visit* but cannot edit / pick up / drop items (crown/role system, doc 06) unless the owner opts them in.
- **Starseeds are rare** — one from finishing the tutorial, then via grinding / milestones / spending money. Not spammable. **Max 2 claims per week** (base).
- **Claimed stars are permanent.** They do NOT despawn on the weekly reset. A player's built home is kept — this is a **values decision** (someone builds with love; years later it's still there). Free-scaling database makes dead stars costless to keep, so there is **no inactivity decay**.
- **Unclaimed stars refresh weekly:** unclaimed stars despawn each week; an equal count respawns randomly within range (spatially balanced — never too clustered or too spread). This is the **renewing frontier** — fresh biome rolls, including new high-tier stars, always appearing. Land supply comes from *new spawns*, never from recycling homes.
- **Star size:** bounded, ~Terraria-small-world scale in 3D (not tiny like Growtopia). Each star's biome is randomly generated: mostly T1, some T2 (rare), T3 (epic-rare), T4 (very rare), and **exactly one T5 biome** on stars that roll it. With 5 resource types × 5 biomes, the roll is balanced and makes claiming a *meaningful decision* (Terraria "check your seed" energy applied to ownership).

### Anti-exploit rules on claiming [DECIDED]
- **3-day reclaim lock:** a planted Starseed can't be reclaimed until 3 days pass (may get more aggressive). Kills the plant→deplant→strip→hop exploit.
- **Unclaimed-expired stars:** once past expiry, a star has 1 day before it disappears → people **transfer star keys** for ownership instead. (This creates a secondary **real-estate market** — worlds as tradeable assets. Intended.)
- **Empty-storage-to-move still applies** (doc 06): a star can only be repacked/transferred with empty storage — no free bulk-material teleport.

---

## Starter stars (the on-ramp) [DECIDED — new]

New players have no Starseed, so they need a home base. **Starter stars** = communal hub-towns.

- Located at the **five pentagram points** (where the old resource stars were — familiar central geography). Black hole remains the **universe-center hazard + discovery anchor** (doc 06). Two different "middles": black hole = universe center; each starter star has its own central plaza.
- **Named hub-towns** — pick fancy names (NOT "Forest"/"Swamp"; biomes are per-explored-star now). Each starter star has **its own named marketplace** and is the social/economic constant.
- **Resources: mostly T1, trace T2 only.** Deliberately capped — enough to learn the loop, not enough to nest in.
- **Free client-side crafting stations + one simple shared factory** in the central plaza (Class-A, free-use).
- **No permanent building on starter stars** — building is the reward that *owning a star* unlocks. Starter star is a **trailhead, not a home**.
- **Players spawn scattered around the starter/tutorial range, facing outward** — already in the field, doorstep looking out, not exit-behind-them.
- **Tutorial ends with an explicit "go explore the universe" indicator.** Exploration is the main point; the design must actively push players out so they don't nest and call it a "noob game." Make the *first* explore trip pay off fast (a visibly better star within ~1 min of flight) so "leaving = good" lands before boredom.

---

## Weight → REMOVED, replaced by inventory slots [DECIDED — replaces doc 03 weight]

Weight existed to throttle **cross-region arbitrage**. There are no fixed regions anymore, so weight's main job is gone. Replaced by:

- **Slot-based inventory: 45 slots to start**, expandable via journal milestones.
- **New throttle = travel time.** Weight also secretly did anti-dump-hop / anti-alt work. That job now falls to **zero-G flight time between stars** — moving 45 slots per trip, and each trip costs real seconds of flight. The travel *is* the friction now: felt, honest, thematic, already in the game. (Confirm travel-time is the intended brake; without it, dump-and-repeat has no limit.)
- **Note for docs 03/05/12:** any rule that leaned on weight (regional price-gap persistence, L1 alt-transport defense) now leans on **travel time + slot caps** instead. Re-derive those defenses against the new throttle.

---

## Star-approach UX [DECIDED — new]
When a player nears a star, show **the 3 resource *types* it contains** — but NOT which are nodes, nor their tier/quality. This creates a "should I go?" decision without spoiling the "glad I went" discovery.
- Types = the hook; quality/tier/node = the payoff. Never collapse them.
- **Optional:** use proxy **glow intensity/color** as a soft difficulty/reward hint (brighter/stranger = spicier, higher-tier world) so the star map is *legible to explore* and pulls ambitious players outward — without revealing exactly which resource is high-tier.

---

## What is UNCHANGED (still canon from earlier docs)
- **Soul & principles** (01/02): cozy builder-gatherer, social gravity, horizontal progression, convenient-stays-worse, feel-before-systems, "never ask for time without attention."
- **Core invariant** (03/11): everything is crafted; natural/terrain blocks don't drop; only man-made/factory blocks drop.
- **Progression** (10/11): journal (cumulative, whole-ladder-visible), per-material gather+craft skills, tool→speed / armor→yield+rarity split, rarity both hunt+grind, milestone rewards routed not invented.
- **Crafting** (04): hand-craft fast, factory = active management + capped offline sim, guardrail chain (gather > hand > factory).
- **Ownership/permissions** (06): Owner/Co-owner/User/Visitor + Class-A/B objects + Crown zonal permission + shops. Applies to claimed stars.
- **Death rule** (universal): durability loss only, no item loss, respawn at last star (owned or starter).
- **Hosting** (06/07): single-live datastore-key stars, teleport-to-visit, debounced+on-leave save, session lock w/ TTL.
- **Viewport thumbnails** (data-first portraits of any world — the moat).

## Now-OPEN because of the pivot (update doc 09)
- **Travel-time throttle values** [TUNE] — must actually brake dump-hopping and preserve some price friction.
- **Where the market lives now:** starter-star named markets are hubs. Is there still a unified cross-hub market, or is each hub its own? (Doc 05's regional model assumed biome regions that no longer exist — re-decide.)
- **Resource distribution across the procedural universe:** how tier rolls are seeded per star so the frontier stays balanced (mostly T1, scarce T5) at scale.
- **Node vs normal (doc 03)** still applies *within* a star's resources — confirm it survives the pivot (it should: it's per-resource, not per-region).
- **Starter-star sharding:** communal single vs sharded ~15-30 (lean sharded-but-populated).