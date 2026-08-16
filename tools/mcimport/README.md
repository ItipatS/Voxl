# mcimport — Minecraft save → Voxl baked world

Turns a Minecraft Java save (Anvil `.mca`) into a **baked star world** under
`src/Misc/MapData/<Name>/`. Design + format: **`.claude/23-imported-maps.md`**.

Pure Node (zlib and NBT are enough — no dependencies) plus [Lune] for the tests.

## The loop

```bash
MC="/c/Users/You/Downloads/Some Map/region"

# 1. where is anything worth importing?  (relief + built-density, 1px = 1 block)
node survey.js "$MC" out/

# 2. look at a crop in true colour and pick a centre
node render.js "$MC" -448 -800 447 95 out/city.png

# 3. how big would it be?  (--dry writes nothing)
node bake.js --region "$MC" --cx 0 --cz -350 --radius 448 --dry

# 4. bake it  (→ ServerStorage: server-only, never replicated to a client)
node bake.js --region "$MC" --cx 0 --cz -350 --radius 448 \
     --name FantasyMedieval --out ../../src/ServerStorage/MapData

# 5. what blocks does it actually need, and what are we throwing away?
node inventory.js "$MC" 0 -350 448 ../../.claude/23a-block-coverage.md

# 6. prove it round-trips (runs the REAL PrebakedMap.luau against the REAL blob,
#    both server-side and through the streaming path a client sees)
node samples.js "$MC" 0 -350 448 ../../src/ServerStorage/MapData/FantasyMedieval /tmp/s.json
cd ../.. && lune run tools/mcimport/test_reader.luau \
     src/ServerStorage/MapData/FantasyMedieval /tmp/s.json
```

Then point a landmark at it in `src/std/universe.luau` (`LANDMARKS`): set `map` to
the folder name and `radius` to the bake radius.

## Tests

```bash
# block ids in Blocks.luau and voxlids.js must match exactly — baked data stores raw ids
node -e 'const {ID}=require("./tools/mcimport/voxlids");require("fs").writeFileSync("/tmp/ids.json",JSON.stringify(ID))'
lune run tools/mcimport/test_ids.luau /tmp/ids.json

# the DEFLATE decoder, against Node's zlib (every block type + all 10 levels)
node -e '/* see test_inflate.luau header for the case generator */'
lune run tools/mcimport/test_inflate.luau /tmp/inflate_cases.json

# compile-check Luau without Studio
lune run tools/mcimport/syntax.luau src/Misc/PrebakedMap.luau src/Misc/Blocks.luau
```

## Adding block mappings

`blockmap.js` maps by **rule**, not by exhaustive table: `<wood>_stairs`,
`<dye>_terracotta`, `polished_`/`deepslate_`/`stripped_` prefixes and the
shape suffixes all resolve to a base material. Unmapped names become air and are
listed at the end of a bake — if that list has anything you care about, add it to
`BASE` (and, if it needs a new Voxl block, to **both** `voxlids.js` and
`Blocks.luau`, appending only).

`shell.js` owns the rule for where a column stops being scenery. The baker and the
round-trip test both read it, so they cannot drift.

[Lune]: https://lune-uwu.dev
