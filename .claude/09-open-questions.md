# 09 — Open Questions

Everything not yet locked. Do not invent answers to these — flag and propose options.

## Technical forks (the "crazy part" — discuss next)
See doc 07 for detail.
- **FORK A** — Is a "star" a Roblox place, a server instance, or an in-memory world context in a shared server? (Decides everything downstream.)
- **FORK B** — Delta persistence granularity: per-chunk deltas vs whole-world blob; compaction strategy; edit replication/merge.
- **FORK C** — Backend-swappable storage API shape (DataStore / MemoryStore / future AWS).
- **FORK D** — Regional market service: order matching, anti-exploit, how "unified regional market behind sharded presence" is actually implemented.
- **FORK E** — Factory offline sim: where factory state lives (ECS vs blob) and how it touches the delta store.
- **FORK F** — Resource nodes as ECS entities with server renewal — component design + phase placement.
- **Scale of `ChunkServer`** — migrating from infinite streaming to bounded worlds + resource stars.
- **Thumbnail pipeline** — how/when world thumbnails are rendered to cached images without live ViewportFrames.

## Design questions
- **Currency** (doc 05): single soft currency + barter, or material-referenced pricing? Decide before markets.
- **Player-made items scope** (doc 04): craft *instances* of dev-defined types (assumed) vs true UGC item authoring (huge moderation/tooling + Roblox UGC rules). **Confirm which.**
- **Biome roster** (doc 03): final list beyond the current five; where Swamp fits; each biome's abundant/scarce/bonus table.
- **Skill list & XP curves** (doc 04): exact skills; whether market access is gated behind encountering content (the Skyblock lesson).
- **Over-weight behavior** (doc 03): hard "can't pick up" vs heavy slow.
- **Cluster name** (doc 06): "The Cluster" / "The Expanse" / other — pick something that means something.
- **Rating/moderation** for player stars (5-star system): anti-abuse, discovery ranking.

## Balance targets to discover with players [TUNE]
- Node vs normal: gather-speed ratio, renew-rate ratio, spawn density.
- **Weight**: per-resource weight, backpack caps per tier, number of tiers. *(Most sensitive value in the game.)*
- Sink/source ratio: material consumed vs gathered per session.
- Inter-biome price gap: must exceed haul cost enough that traders emerge, without being exploitable.
- Offline factory caps per tier.
- Crafting tier costs / XP gating.

## Risks to watch
- **Thin regional markets** — mitigated by self-supply floor, but still want population concentrated at resource stars.
- **Arbitrage flattening** — the entire reason weight exists; if weight is too loose, regional economy collapses to global.
- **Idle beating active** — offline caps must hold.
- **Scope/burnout** — the whole reason the vertical slice (doc 08) comes before everything.
- **Lobby rot at scale** — cull + discovery layer are mandatory, not optional.
