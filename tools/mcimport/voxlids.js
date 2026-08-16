// The Voxl block id table, mirrored from src/Misc/Blocks.luau.
// APPEND-ONLY and generated the SAME way on both sides: the base list is explicit,
// then the four dyed families are appended in a fixed dye order. If this file and
// Blocks.luau ever disagree, baked map data decodes to the wrong blocks — so both
// build the dyed ids from the same ordered DYE_ORDER list.

const BASE_IDS = {
  Air: 0,
  Grass: 1, Dirt: 2, Sand: 3, Stone: 4, Snow: 5, OakLog: 6, OakLeaves: 7,
  CoarseDirt: 8, Podzol: 9, Mud: 10, MossBlock: 11,
  RedSand: 12, Sandstone: 13, RedSandstone: 14, Terracotta: 15,
  Cobblestone: 16, Granite: 17, Diorite: 18, Andesite: 19, Gravel: 20, Clay: 21,
  Ice: 22, PackedIce: 23,
  BirchLog: 24, BirchLeaves: 25, SpruceLog: 26, SpruceLeaves: 27,
  JungleLog: 28, JungleLeaves: 29, AcaciaLog: 30, AcaciaLeaves: 31,
  CoalOre: 32, IronOre: 33, CopperOre: 34, GoldOre: 35, DiamondOre: 36, EmeraldOre: 37,
  Glowstone: 38,

  // ===== added for the imported map (doc 23) =====
  Water: 39, Lava: 40,
  StoneBricks: 41, MossyStoneBricks: 42, MossyCobblestone: 43, SmoothStone: 44,
  PolishedAndesite: 45, Bricks: 46, Quartz: 47, Prismarine: 48, SeaLantern: 49,
  OakPlanks: 50, SprucePlanks: 51, BirchPlanks: 52, JunglePlanks: 53,
  AcaciaPlanks: 54, DarkOakPlanks: 55,
  DarkOakLog: 56, DarkOakLeaves: 57,
  Glass: 58,
  IronBlock: 59, GoldBlock: 60, DiamondBlock: 61, EmeraldBlock: 62, LapisBlock: 63,
  RedstoneBlock: 64, CopperBlock: 65, CoalBlock: 66, Amethyst: 67,
  LapisOre: 68, RedstoneOre: 69,
  HayBlock: 70, Bookshelf: 71, Pumpkin: 72,
};

// Fixed order — ids depend on it. Never reorder.
const DYE_ORDER = [
  "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
  "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black",
];
const DYED_FAMILIES = ["Wool", "Terracotta", "Concrete", "Glass"]; // → Wool_white … Glass_black

const ID = { ...BASE_IDS };
let next = 73;
for (const fam of DYED_FAMILIES) {
  for (const dye of DYE_ORDER) {
    ID[`${fam}_${dye}`] = next++;
  }
}
// New ids append here, after the dyed families (73..136). Never renumber.
ID.IronBars = 137;

// Just more ordinary blocks. This list only exists to hand out ids in a FIXED
// ORDER (138..155); each is a block exactly like Stone. Grouped only because each
// had been collapsing onto something else and losing its character.
// No chest/barrel/crafting table/furnace — those are FUNCTIONAL blocks that doc 22
// will build as real crafting stations; a decorative lookalike now would just be in
// the way. They map to their material instead, so a furnace built into a wall still
// leaves a wall rather than a hole.
const BATCH_138 = [
  "Deepslate", "CobbledDeepslate", "DeepslateBricks", "Bedrock", "Tuff", "Calcite",
  "Basalt", "Blackstone", "Obsidian", "MagmaBlock", "Cactus",
  "CrackedStoneBricks", "ChiseledStoneBricks", "ChiseledQuartz",
  "Netherrack", "NetherBricks", "PolishedGranite", "PolishedDiorite",
];
let idn = 138;
for (const name of BATCH_138) ID[name] = idn++;

// Half-height slabs. Voxl has no sub-block shapes, so "a slab of X" has to be its
// own block id — one for a slab sitting on the floor and one for the ceiling
// (Minecraft's type=bottom/top). A type=double slab is just the full block.
// ORDER IS LOAD-BEARING, same as the dyed families.
const SLAB_MATERIALS = [
  "Stone", "Cobblestone", "StoneBricks", "SmoothStone", "Sandstone", "Quartz",
  "Bricks", "NetherBricks", "Diorite", "Andesite", "Granite",
  "OakPlanks", "SprucePlanks", "BirchPlanks", "JunglePlanks", "AcaciaPlanks",
  "DarkOakPlanks",
];
for (const mat of SLAB_MATERIALS) {
  ID[`Slab_${mat}`] = idn++;
  ID[`SlabTop_${mat}`] = idn++;
}

const MAX_ID = idn - 1;

module.exports = { ID, DYE_ORDER, DYED_FAMILIES, BASE_IDS, SLAB_MATERIALS, BATCH_138, MAX_ID };
