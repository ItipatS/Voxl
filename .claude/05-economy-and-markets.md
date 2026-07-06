# 05 — Economy & Markets

> Reminder (principle 5): **the economy is connective tissue, not the core.** Everything here must degrade gracefully to "just go gather it yourself."

## Where markets live [DECIDED]

**Only public resource stars have marketplaces.** Player-owned stars do NOT. Markets sit at the biome gathering hubs, not on personal islands. This **localizes** the economy so scarcity stays *physical* and *regional*:

- Forest resource star's market: wood cheap, fiber expensive.
- Desert resource star's market: fiber cheap, wood expensive.
- The **price gap between regions is real and persistent**, because **weight** (doc 03) throttles anyone trying to arbitrage it away.

This is Albion's economic geography (regional markets + hauling friction) minus the PvP.

## Why regional markets don't collapse [DECIDED]

The Skyblock/Albion failure mode is "one global market flattens all prices and lets you buy past all content." We avoid it three ways:

1. **Regional, not global** — no single price; biome gaps persist.
2. **Weight throttles arbitrage** — you can't flatten gaps from your couch.
3. **Self-supply floor** — if a market is thin/empty, you just gather it yourself (principle 5). A dead market is a missing convenience, not a dead end. This is why our thin-market risk is low *even though* regional markets fracture liquidity: in Skyblock a dead market is fatal (market = the game); here it isn't (gathering = the game).

## The two-market split [RECOMMENDED — steal from Skyblock]

Within a resource star's marketplace, split by item type:

| Market type | For | Mechanic | Storage backend |
|---|---|---|---|
| **Bazaar** | bulk fungible materials (cotton, wood, ore, stone) | order-book, instant buy/sell | hot/transient → MemoryStore |
| **Auction** | unique crafted gear (durability, rolls) | listings / buy-it-now | durable records → DataStore |

The economic split and the **storage architecture line up cleanly** (doc 07): the bazaar is hot transient state, the auction is durable records.

## Sinks — what gets consumed forever [DECIDED]

A living economy needs continuous consumption or it inflates like late Growtopia. Voxl's sinks (all cozy-safe, no death):

- **Building** — every placed block is material spent, permanently. Builders are perpetual buyers.
- **Tool/equipment durability** — gear wears out and must be remade.
- **Machine/factory repairs** — factories consume materials to run *and* to repair (per-factory).
- **Consumables** — food/potions/buff items eaten each session.

Together these are a **perpetual, cozy sink** with zero loss-on-death mechanics. This closes the "fuse vs engine" problem: demand for materials never permanently ends.

### Sink/source balance [TUNE]
A sink only holds if `consumed_per_session ≈ gathered_per_session`. Too much gathering → inflation; too much consumption → economy freezes. **This ratio can only be found with real players.** Instrument it early.

## NPC / system sell = pressure valve, not the best deal [DECIDED]
Players can sell to the system/bazaar as a safety net (never stuck with junk). But **NPC buy prices are deliberately worse than player-to-player** (principle 3). If the system pays too well, players sell to it instead of each other and interdependence evaporates into vendor-clicking.

## What a rare item is worth that money can't replace [DESIGN INTENT]
Cubic Castles' flaw: a rare item was worth only cubits (fungible). Voxl's rare items should matter *as themselves*:
- They are the **actual material** a needy biome lacks (interdependence).
- They grant **expressive/functional** advantages (gathering bonuses, new build options).
- Weight means owning/hauling them has real cost.
This is what keeps the market from erasing the journey.

## Monetization [DECIDED — light]
- Game passes: extra factory space, passive generators (slowest tier — never optimal), cosmetic packs.
- All non-pass items/cosmetics are player-crafted.
- No pay-to-win against the guardrail chain: purchased convenience is always the *worse* path.

## Currency [OPEN]
Is there a single soft currency (cubits-style) *and* material barter, or primarily material/market pricing? Localized regional markets imply prices could be denominated in a currency or in reference materials. **Decide before building markets.**

## Player shops [DECIDED — mechanism]
Shops in *owned* stars (distinct from the resource-star regional markets above) use the **Crown zonal-permission** system (doc 06):
- A **Class-A public counter** (crafting/trade station) inside a **crown zone** lets customers interact, walled off from the owner's private Class-B storage.
- This is the proper version of Cubic Castles' cash-register shop — the counter is public, the back room isn't, enforced by zone + object class, not trust.
- Atomic trade (doc 12 L5) handles the actual value swap. Owners find/advertise shops via the Cluster (doc 06) discovery layer.
Note: owned-star shops are P2P storefronts; the **regional bazaar/auction** at resource stars is the bulk market. Both exist; they serve different scales.
