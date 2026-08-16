// Voxl block name → the Minecraft filenames that would resolve to it.
//
// blockmap.js maps Minecraft → Voxl; this runs it in reverse over every name
// blockmap knows about, so the texture shopping list can say "this is
// `oak_planks.png` in a resource pack" instead of leaving you to guess.
//
//   node tools/textures/names.js > names.json

const { lookup, DYES, WOODS } = require("../mcimport/blockmap");
const { ID } = require("../mcimport/voxlids");

// Everything blockmap could plausibly be asked about: its own BASE keys plus the
// compositional families it generates.
const candidates = new Set();
for (const k of Object.keys(require("../mcimport/blockmap").DYES)) void k; // (keeps DYES referenced)

// BASE isn't exported, so probe with the names we know the importer handles.
const PROBES = [
  "stone", "deepslate", "cobbled_deepslate", "deepslate_bricks", "bedrock", "tuff",
  "calcite", "basalt", "blackstone", "obsidian", "netherrack", "nether_bricks",
  "magma_block", "cactus", "granite", "diorite", "andesite", "polished_granite",
  "polished_diorite", "polished_andesite", "smooth_stone", "cobblestone",
  "mossy_cobblestone", "stone_bricks", "mossy_stone_bricks", "cracked_stone_bricks",
  "chiseled_stone_bricks", "bricks", "quartz_block", "chiseled_quartz_block",
  "prismarine", "sea_lantern", "glowstone", "sandstone", "red_sandstone",
  "terracotta", "dirt", "coarse_dirt", "podzol", "mud", "clay", "grass_block",
  "moss_block", "gravel", "sand", "red_sand", "snow_block", "ice", "packed_ice",
  "water", "lava", "glass", "iron_bars", "hay_block", "bookshelf", "pumpkin",
  "coal_ore", "iron_ore", "copper_ore", "gold_ore", "diamond_ore", "emerald_ore",
  "lapis_ore", "redstone_ore", "iron_block", "gold_block", "diamond_block",
  "emerald_block", "lapis_block", "redstone_block", "copper_block", "coal_block",
  "amethyst_block",
];
for (const p of PROBES) candidates.add(p);
for (const dye of Object.keys(DYES)) {
  candidates.add(`${dye}_wool`);
  candidates.add(`${dye}_terracotta`);
  candidates.add(`${dye}_concrete`);
  candidates.add(`${dye}_stained_glass`);
}
for (const wood of Object.keys(WOODS)) {
  candidates.add(`${wood}_planks`);
  candidates.add(`${wood}_log`);
  candidates.add(`${wood}_leaves`);
}

const out = {};
for (const name of candidates) {
  const r = lookup(`minecraft:${name}`);
  if (!r || !r.voxl || ID[r.voxl] === undefined) continue;
  if (!out[r.voxl]) out[r.voxl] = [];
  if (!out[r.voxl].includes(name)) out[r.voxl].push(name);
}
// shortest name first — it's the most likely resource-pack filename
for (const k of Object.keys(out)) out[k].sort((a, b) => a.length - b.length);

module.exports = { reverse: out };
if (require.main === module) process.stdout.write(JSON.stringify(out, null, 1));
