// What blocks does an imported map actually NEED?
//
// Counts every Minecraft block inside the baked crop's VISIBLE SHELL (the part
// that survives the bake — deep underground is excluded, since it becomes Stone
// either way), resolves each through blockmap.js, and writes a markdown report:
// which Voxl blocks the map depends on, and what is being dropped and how visible
// that loss is. Meant to be read and argued with, not just generated.
//
// usage: node inventory.js <regionDir> <cx> <cz> <radius> <out.md>

const fs = require("fs");
const path = require("path");
const { readRegion, chunkSections } = require("./anvil");
const { lookup } = require("./blockmap");
const { ID } = require("./voxlids");
const { shellBottom } = require("./shell");

const [regionDir, CX, CZ, R, outFile] =
  [process.argv[2], +process.argv[3], +process.argv[4], +process.argv[5], process.argv[6]];

const MC_Y_MIN = -64, MC_H = 384;
const R2 = R * R;

// name id table (so a column can be scanned as integers)
const names = [""];
const nameIndex = new Map([["", 0]]);
function nameId(n) {
  let i = nameIndex.get(n);
  if (i === undefined) { i = names.length; names.push(n); nameIndex.set(n, i); }
  return i;
}

const counts = new Map();   // mc name → blocks inside the shell
const columnsWith = new Map(); // mc name → how many distinct columns contain it
let totalShell = 0, columnsSeen = 0;

const mcc0 = Math.floor((CX - R) / 16), mcc1 = Math.floor((CX + R - 1) / 16);
const mcd0 = Math.floor((CZ - R) / 16), mcd1 = Math.floor((CZ + R - 1) / 16);
const r0 = Math.floor(mcc0 / 32), r1 = Math.floor(mcc1 / 32);
const s0 = Math.floor(mcd0 / 32), s1 = Math.floor(mcd1 / 32);

const voxlCol = new Uint8Array(256 * MC_H);   // resolved Voxl ids (drives the shell rule)
const nameCol = new Uint16Array(256 * MC_H);  // the Minecraft names behind them

for (let rz = s0; rz <= s1; rz++) {
  for (let rx = r0; rx <= r1; rx++) {
    const f = path.join(regionDir, `r.${rx}.${rz}.mca`);
    if (!fs.existsSync(f)) continue;
    const chunks = readRegion(f);
    for (let i = 0; i < 1024; i++) {
      const c = chunks[i];
      if (!c || c.error) continue;
      const mccx = rx * 32 + (i & 31), mccz = rz * 32 + (i >> 5);
      if (mccx < mcc0 || mccx > mcc1 || mccz < mcd0 || mccz > mcd1) continue;
      const bx = mccx * 16 - CX, bz = mccz * 16 - CZ;
      const nearX = bx > 0 ? bx : (bx + 15 < 0 ? -(bx + 15) : 0);
      const nearZ = bz > 0 ? bz : (bz + 15 < 0 ? -(bz + 15) : 0);
      if (nearX * nearX + nearZ * nearZ > R2) continue;

      const secs = chunkSections(c.nbt);
      if (!secs.length) continue;
      voxlCol.fill(0);
      nameCol.fill(0);
      for (const s of secs) {
        const y0 = s.y * 16 - MC_Y_MIN;
        if (y0 < 0 || y0 + 15 >= MC_H) continue;
        const pv = new Uint8Array(s.palette.length);
        const pn = new Uint16Array(s.palette.length);
        let any = false;
        for (let p = 0; p < s.palette.length; p++) {
          const n = s.palette[p];
          if (n === "minecraft:air" || n === "minecraft:cave_air" || n === "minecraft:void_air") continue;
          const r = lookup(n);
          pv[p] = r.voxl ? ID[r.voxl] : 0;
          pn[p] = nameId(n);
          any = true;
        }
        if (!any) continue;
        for (let ly = 0; ly < 16; ly++) {
          for (let ci = 0; ci < 256; ci++) {
            const p = s.states ? s.states[ly * 256 + ci] : 0;
            if (!pn[p]) continue;
            voxlCol[ci * MC_H + y0 + ly] = pv[p];
            nameCol[ci * MC_H + y0 + ly] = pn[p];
          }
        }
      }

      for (let z = 0; z < 16; z++) {
        const vz = mccz * 16 + z - CZ;
        if (vz < -R || vz >= R) continue;
        for (let x = 0; x < 16; x++) {
          const vx = mccx * 16 + x - CX;
          if (vx < -R || vx >= R) continue;
          if (vx * vx + vz * vz > R2) continue;
          const ci = z * 16 + x;
          const off = ci * MC_H;
          let top = -1;
          for (let k = MC_H - 1; k >= 0; k--) if (nameCol[off + k]) { top = k; break; }
          if (top < 0) continue;
          columnsSeen++;
          const bot = shellBottom((k) => voxlCol[off + k], top, 0);
          const here = new Set();
          for (let y = bot; y <= top; y++) {
            const nid = nameCol[off + y];
            if (!nid) continue;
            const n = names[nid];
            counts.set(n, (counts.get(n) || 0) + 1);
            totalShell++;
            here.add(n);
          }
          for (const n of here) columnsWith.set(n, (columnsWith.get(n) || 0) + 1);
        }
      }
    }
  }
  process.stdout.write(`\r  region row ${rz - s0 + 1}/${s1 - s0 + 1}`);
}
console.log("");

// ---- classify ----
const CATEGORY = [
  [/(_ore|ancient_debris|_block$|raw_)/, "Ore & metal"],
  [/(planks|_log|_wood|stem|hyphae|bookshelf|barrel|chest|crafting|loom|composter|beehive|_sign|ladder|scaffolding)/, "Wood & wooden furniture"],
  [/(_leaves|sapling|vine|moss|azalea)/, "Leaves & foliage"],
  [/(wool|carpet|concrete|terracotta|glazed|banner|bed$)/, "Dyed"],
  [/(glass|pane)/, "Glass"],
  [/(brick|stone|deepslate|andesite|diorite|granite|tuff|calcite|basalt|blackstone|cobble|quartz|prismarine|sandstone|purpur|obsidian|bedrock)/, "Stone & masonry"],
  [/(dirt|grass_block|podzol|mycelium|mud|clay|sand|gravel|farmland|path|soul_)/, "Ground"],
  [/(water|lava|ice|snow|powder)/, "Fluid, ice & snow"],
  [/(torch|lantern|lamp|campfire|candle|glowstone|sea_lantern|shroomlight|froglight|beacon|end_rod|fire)/, "Light"],
  [/(redstone|piston|observer|dispenser|dropper|hopper|comparator|repeater|lever|button|pressure_plate|tripwire|target|daylight|note_block|rail|tnt|command|jukebox|crafter)/, "Redstone & mechanisms"],
  [/(door|trapdoor|fence|wall$|_wall|gate|bars|chain)/, "Doors, fences & bars"],
  [/(flower|tulip|orchid|dandelion|poppy|allium|bluet|daisy|cornflower|lilac|peony|rose|sunflower|bush|fern|grass$|kelp|seagrass|coral|lily|mushroom|cactus|bamboo|sugar_cane|wheat|carrot|potato|beetroot|melon|pumpkin|berry|cocoa|nether_wart|sprouts|roots|dripleaf|vines|lichen|sculk|spore|pickle|pitcher|petals|litter|wildflower)/, "Plants & clutter"],
];
function categorise(n) {
  const s = n.slice(10);
  for (const [re, cat] of CATEGORY) if (re.test(s)) return cat;
  return "Other";
}

const rows = [...counts.entries()].map(([n, c]) => {
  const r = lookup(n);
  return {
    mc: n.slice(10),
    count: c,
    columns: columnsWith.get(n) || 0,
    voxl: r.voxl || null,
    cat: categorise(n),
  };
}).sort((a, b) => b.count - a.count);

const kept = rows.filter((r) => r.voxl);
const dropped = rows.filter((r) => !r.voxl);
const keptBlocks = kept.reduce((a, r) => a + r.count, 0);
const dropBlocks = dropped.reduce((a, r) => a + r.count, 0);

// Voxl blocks actually needed, with what feeds each
const byVoxl = new Map();
for (const r of kept) {
  if (!byVoxl.has(r.voxl)) byVoxl.set(r.voxl, { count: 0, sources: [] });
  const e = byVoxl.get(r.voxl);
  e.count += r.count;
  e.sources.push(r.mc);
}
const voxlRows = [...byVoxl.entries()].sort((a, b) => b[1].count - a[1].count);

const pct = (n) => ((n / totalShell) * 100).toFixed(2) + "%";
const num = (n) => n.toLocaleString("en-US");

let md = `# 23a — Block coverage for imported maps

*Generated by \`tools/mcimport/inventory.js\` from the actual crop
(MC centre ${CX}, ${CZ}, radius ${R}). Regenerate after changing \`blockmap.js\`.*

Counts cover the **visible shell** only — the part of each column that gets baked.
Deep underground is excluded, because it becomes plain \`Stone\` regardless.

| | |
|---|---|
| columns | ${num(columnsSeen)} |
| blocks in the shell | ${num(totalShell)} |
| distinct Minecraft blocks | ${rows.length} |
| **mapped** | ${kept.length} kinds, ${num(keptBlocks)} blocks (${pct(keptBlocks)}) |
| **dropped → air** | ${dropped.length} kinds, ${num(dropBlocks)} blocks (${pct(dropBlocks)}) |
| Voxl blocks required | **${voxlRows.length}** of ${Object.keys(ID).length - 1} defined |

---

## 0. The whole Voxl palette

Every block \`Blocks.luau\` defines, so "do we have X?" is answerable without
reading code. **used** is how many blocks of it this particular map contains —
\`0\` means the block exists and is placeable, this map just doesn't happen to use
it. (§1 lists only what the map uses, which is why it looks shorter.)

`;
{
  const used = new Map();
  for (const [v, e] of byVoxl) used.set(v, e.count);
  const FAMILIES = [
    ["Terrain & ground", /^(Grass|Dirt|CoarseDirt|Podzol|Mud|MossBlock|Sand|RedSand|Gravel|Clay|Snow)$/],
    ["Stone & deep rock", /^(Stone|Cobblestone|Granite|Diorite|Andesite|Deepslate|CobbledDeepslate|Bedrock|Tuff|Calcite|Basalt|Blackstone|Obsidian|Netherrack|SmoothStone|PolishedAndesite|PolishedGranite|PolishedDiorite|MossyCobblestone)$/],
    ["Masonry & bricks", /^(StoneBricks|MossyStoneBricks|CrackedStoneBricks|ChiseledStoneBricks|DeepslateBricks|Bricks|NetherBricks|Sandstone|CutSandstone|RedSandstone|Terracotta|Quartz|ChiseledQuartz|Prismarine)$/],
    ["Wood", /^(OakLog|BirchLog|SpruceLog|JungleLog|AcaciaLog|DarkOakLog|OakPlanks|BirchPlanks|SprucePlanks|JunglePlanks|AcaciaPlanks|DarkOakPlanks|Bookshelf)$/],
    ["Leaves", /Leaves$/],
    ["Ore & metal", /^(CoalOre|IronOre|CopperOre|GoldOre|DiamondOre|EmeraldOre|LapisOre|RedstoneOre|IronBlock|GoldBlock|DiamondBlock|EmeraldBlock|LapisBlock|RedstoneBlock|CopperBlock|CoalBlock|Amethyst|IronBars)$/],
    ["Fluid, ice & light", /^(Water|Lava|Ice|PackedIce|BlueIce|Glowstone|SeaLantern|MagmaBlock)$/],
    ["Wool", /^Wool_/],
    ["Terracotta (dyed)", /^Terracotta_/],
    ["Concrete (dyed)", /^Concrete_/],
    ["Stained glass", /^Glass_/],
    ["Slabs (half height)", /^Slab_/],
    ["Slabs, upside-down", /^SlabTop_/],
    ["Misc", /^(Glass|HayBlock|Pumpkin|Cactus)$/],
  ];
  const placed = new Set();
  for (const [label, re] of FAMILIES) {
    const list = Object.keys(ID).filter((k) => k !== "Air" && re.test(k)).sort((a, b) => ID[a] - ID[b]);
    if (!list.length) continue;
    for (const k of list) placed.add(k);
    const cells = list.map((k) => {
      const u = used.get(k) || 0;
      return u ? `**${k}** ${num(u)}` : k;
    });
    md += `**${label}** <sub>(${list.length})</sub>\n${cells.join(" · ")}\n\n`;
  }
  const rest = Object.keys(ID).filter((k) => k !== "Air" && !placed.has(k));
  if (rest.length) md += `**Other** <sub>(${rest.length})</sub>\n${rest.join(" · ")}\n\n`;
}

md += `---

## 1. The Voxl blocks this map needs

The ${voxlRows.length} of them this map actually leans on, ordered by how much
depends on each. Everything here already exists in \`Blocks.luau\` — see §0 for the
full palette, including the blocks defined but unused here.

| Voxl block | blocks | share | fed by |
|---|---:|---:|---|
`;
for (const [v, e] of voxlRows) {
  const src = e.sources.length <= 4
    ? e.sources.join(", ")
    : `${e.sources.slice(0, 3).join(", ")} +${e.sources.length - 3} more`;
  md += `| \`${v}\` | ${num(e.count)} | ${pct(e.count)} | ${src} |\n`;
}

md += `
---

## 2. What's dropped, and whether it matters

Dropped blocks become air. That is fine for a torch and not fine for a staircase,
so they're ranked by how many blocks are lost. **\`columns\`** is the more useful
number: a block appearing in many columns is spread across the map (visible
everywhere), while a big count in few columns is one dense structure.

| Minecraft block | blocks | columns | category | verdict |
|---|---:|---:|---|---|
`;
// Raw count is a bad judge on its own: 46k kelp is invisible under an ocean, while
// a few thousand iron bars are every window in a castle. Weight by what the thing
// actually is, and by how thinly it's spread.
const NEVER_WORTH = new Set(["Plants & clutter", "Redstone & mechanisms"]);
const UNDERWATER = /(kelp|seagrass|coral|sea_pickle|lily_pad|bubble)/;
function verdict(r) {
  if (UNDERWATER.test(r.mc)) return "ignore — underwater, never seen";
  if (NEVER_WORTH.has(r.cat)) return "ignore — clutter, no cube to build from";
  if (r.cat === "Light") return "later — re-add when lighting lands";
  if (r.count >= 2000 && r.columns >= 1000) return "**cover** — spread across the map";
  if (r.count >= 2000) return "**cover** — dense enough to leave a hole";
  if (r.count >= 500) return "borderline";
  return "ignore";
}
for (const r of dropped.slice(0, 60)) {
  md += `| \`${r.mc}\` | ${num(r.count)} | ${num(r.columns)} | ${r.cat} | ${verdict(r)} |\n`;
}
if (dropped.length > 60) {
  const rest = dropped.slice(60);
  md += `\n…plus ${rest.length} more, ${num(rest.reduce((a, r) => a + r.count, 0))} blocks total — all below the noise floor.\n`;
}

md += `
### Dropped, by category

| category | kinds | blocks | share of shell |
|---|---:|---:|---:|
`;
const dropCat = new Map();
for (const r of dropped) {
  if (!dropCat.has(r.cat)) dropCat.set(r.cat, { kinds: 0, count: 0 });
  const e = dropCat.get(r.cat);
  e.kinds++; e.count += r.count;
}
for (const [cat, e] of [...dropCat.entries()].sort((a, b) => b[1].count - a[1].count)) {
  md += `| ${cat} | ${e.kinds} | ${num(e.count)} | ${pct(e.count)} |\n`;
}

md += `
---

## 3. Full mapping, by category

Every Minecraft block found in the crop. \`—\` means dropped to air.

`;
const cats = [...new Set(rows.map((r) => r.cat))]
  .sort((a, b) => rows.filter((r) => r.cat === b).reduce((s, r) => s + r.count, 0)
    - rows.filter((r) => r.cat === a).reduce((s, r) => s + r.count, 0));
for (const cat of cats) {
  const list = rows.filter((r) => r.cat === cat);
  md += `### ${cat}  <sub>${list.length} kinds, ${num(list.reduce((a, r) => a + r.count, 0))} blocks</sub>\n\n`;
  md += `| Minecraft | blocks | → Voxl |\n|---|---:|---|\n`;
  for (const r of list) {
    md += `| \`${r.mc}\` | ${num(r.count)} | ${r.voxl ? `\`${r.voxl}\`` : "—"} |\n`;
  }
  md += `\n`;
}

fs.writeFileSync(outFile, md);
console.log(`wrote ${outFile}`);
console.log(`${rows.length} distinct blocks: ${kept.length} mapped (${pct(keptBlocks)}), ${dropped.length} dropped (${pct(dropBlocks)})`);
console.log(`Voxl blocks required: ${voxlRows.length}`);
console.log(`\nbiggest drops:`);
for (const r of dropped.slice(0, 12)) console.log(`  ${String(r.count).padStart(7)}  ${r.mc}  (${r.columns} columns, ${r.cat})`);
