# 02 — Design Principles (the hard rules)

Every system in Voxl must obey these. If a feature breaks one, the feature is wrong, not the rule.

## 1. Social gravity: anything a player makes should be seen, wanted, or used by someone else.
A rare crafted item that is *only* a trophy on your own shelf is dead weight. Give every craftable a job: it is worn, traded, needed to build something, or gates access. **This is the rule Cubic Castles and that childhood builder both broke** — deep crafting trees whose outputs had no social pull, producing emptiness.

## 2. Progression is horizontal first, vertical second.
In a builder, "+10% mining speed" is close to meaningless because there is nothing to be *stronger for*. Prefer unlocks that add **new expressive options**: new blocks, colors, tools, recipes, bigger buildable space. Vertical power exists only where it feeds an activity (gather faster, haul more), never as an end in itself.

## 3. The convenient option must stay the worse option.
The universal guardrail. Applies everywhere:
- Gathering yourself **> faster than >** hand-crafting **> faster than >** factory output.
- Buying from market **< worse value than <** gathering yourself.
- NPC/bazaar sell price **< worse than <** player-to-player.
If the lazy path ever becomes optimal, active play becomes pointless and the game hollows out.

## 4. Interdependence is opt-in (gradient scarcity), never forced (hard walls).
Growtopia's "you literally cannot proceed without X" breeds resentment. Albion's "you *could* self-supply, but specializing + trading is smarter" breeds a healthy economy. **Every biome can eventually get every material** — just faster or slower. Nobody is locked out; specialization is the *smart* choice, not the *forced* one. (Mechanism: node vs normal spawns — doc 03.)

## 5. Economy is connective tissue, not the spine.
The game must be fun with a thin or empty market. Self-sufficiency is the floor: if no one is selling fiber, you go gather it. This makes regional markets robust to low population — an empty market is a missing convenience, not a dead end.

## 6. Friction is logistics, not loss.
Our version of Albion's "risk" is **weight/hauling and distance**, not death. No dropping items, no gank. The tax on arbitrage is that you can only carry so much, so far. (See weight, doc 03.)

## 7. Cap the idle. Never reward logging off.
Offline/factory production is a *convenience*, capped so storage fills and stops. It must never be more efficient than playing. (Doc 04.)

## 8. Feel before systems.
No amount of system depth rescues a loop that isn't fun in the hand. The default gather→place→craft loop must feel good at the smallest scale before anything else is built. (Doc 08 is the enforcement of this rule.)

## 9. Balance is discovered, not designed.
Weight values, node/spawn rates, price gaps, sink/source ratios — these cannot be armchair-tuned once systems interconnect. Ship placeholders marked **[TUNE]**, then watch real players. Design the systems so these numbers are *config*, not hardcoded.

## 10. Server-authoritative, always.
The client renders and predicts; the server owns truth. Timestamps come from the server (offline calc, cooldowns, market orders). This is already the repo's posture — keep it.
