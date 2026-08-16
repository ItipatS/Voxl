// Minecraft block name → (a) preview colour, (b) Voxl block id.
//
// Rules, not a 1000-row table: Minecraft names are compositional
// ("<wood>_stairs", "<dye>_terracotta"), so a modifier is stripped down to its
// base material and the base material is what carries colour + Voxl id.
//
// SLABS are real: a half-height block, bottom or top, per material (a double slab
// is just the full block). Stairs/fences/walls/panes still collapse to the FULL
// block of their base material — a stair's diagonal has nowhere to live in a cube
// grid — which is chunky, but keeps the silhouette.
// Decorative clutter (torches, flowers, rails, buttons…) maps to air.

// ---------- dye colours (wool / terracotta / concrete / glass share the set) ----------
const DYES = {
  white: [233, 236, 236], orange: [240, 118, 19], magenta: [189, 68, 179],
  light_blue: [58, 175, 217], yellow: [248, 198, 39], lime: [112, 185, 25],
  pink: [237, 141, 172], gray: [62, 68, 71], light_gray: [142, 142, 134],
  cyan: [21, 137, 145], purple: [121, 42, 172], blue: [53, 57, 157],
  brown: [114, 71, 40], green: [84, 109, 27], red: [160, 39, 34], black: [20, 21, 25],
};
const TERRACOTTA = {
  white: [209, 178, 161], orange: [161, 83, 37], magenta: [149, 88, 108],
  light_blue: [113, 108, 137], yellow: [186, 133, 35], lime: [103, 117, 53],
  pink: [161, 78, 78], gray: [57, 42, 35], light_gray: [135, 107, 98],
  cyan: [86, 91, 91], purple: [118, 70, 86], blue: [74, 59, 91],
  brown: [77, 51, 35], green: [76, 83, 42], red: [143, 61, 46], black: [37, 22, 16],
};
const WOODS = {
  oak: { plank: [162, 130, 78], log: [150, 120, 72], leaf: [60, 143, 40] },
  spruce: { plank: [114, 84, 48], log: [110, 85, 50], leaf: [47, 86, 47] },
  birch: { plank: [192, 175, 121], log: [216, 214, 205], leaf: [128, 167, 85] },
  jungle: { plank: [160, 115, 80], log: [150, 111, 74], leaf: [62, 148, 34] },
  acacia: { plank: [168, 90, 50], log: [148, 100, 60], leaf: [86, 152, 46] },
  dark_oak: { plank: [66, 43, 20], log: [60, 46, 26], leaf: [46, 110, 30] },
  mangrove: { plank: [117, 54, 48], log: [93, 45, 40], leaf: [60, 120, 45] },
  cherry: { plank: [226, 177, 168], log: [217, 158, 152], leaf: [237, 170, 200] },
  crimson: { plank: [101, 48, 70], log: [92, 25, 29], leaf: [123, 39, 43] },
  warped: { plank: [43, 104, 99], log: [58, 58, 88], leaf: [22, 119, 121] },
  bamboo: { plank: [193, 168, 71], log: [154, 164, 66], leaf: [102, 148, 42] },
  pale_oak: { plank: [223, 214, 199], log: [206, 199, 186], leaf: [180, 200, 175] },
};

// ---------- base materials: colour + Voxl block ----------
// voxl: a name from src/Misc/Blocks.luau ID (null = air / not rendered).
const BASE = {
  air: { c: [0, 0, 0], voxl: null },
  cave_air: { c: [0, 0, 0], voxl: null },
  void_air: { c: [0, 0, 0], voxl: null },

  stone: { c: [125, 125, 125], voxl: "Stone" },
  deepslate: { c: [80, 80, 84], voxl: "Deepslate" },
  tuff: { c: [108, 109, 101], voxl: "Tuff" },
  calcite: { c: [223, 225, 218], voxl: "Calcite" },
  granite: { c: [149, 103, 86], voxl: "Granite" },
  diorite: { c: [188, 185, 187], voxl: "Diorite" },
  andesite: { c: [136, 136, 136], voxl: "Andesite" },
  basalt: { c: [80, 78, 84], voxl: "Basalt" },
  smooth_basalt: { c: [72, 72, 79], voxl: "Basalt" },
  blackstone: { c: [42, 36, 41], voxl: "Blackstone" },
  netherrack: { c: [111, 54, 52], voxl: "Netherrack" },
  bedrock: { c: [85, 85, 85], voxl: "Bedrock" },
  obsidian: { c: [21, 18, 30], voxl: "Obsidian" },
  cobblestone: { c: [127, 127, 127], voxl: "Cobblestone" },
  mossy_cobblestone: { c: [110, 125, 100], voxl: "MossyCobblestone" },
  stone_bricks: { c: [122, 122, 122], voxl: "StoneBricks" },
  mossy_stone_bricks: { c: [112, 122, 105], voxl: "MossyStoneBricks" },
  cracked_stone_bricks: { c: [118, 117, 117], voxl: "CrackedStoneBricks" },
  chiseled_stone_bricks: { c: [119, 119, 119], voxl: "ChiseledStoneBricks" },
  smooth_stone: { c: [158, 158, 158], voxl: "SmoothStone" },
  polished_andesite: { c: [132, 134, 133], voxl: "PolishedAndesite" },
  polished_granite: { c: [154, 107, 90], voxl: "PolishedGranite" },
  polished_diorite: { c: [193, 192, 194], voxl: "PolishedDiorite" },
  polished_deepslate: { c: [72, 72, 73], voxl: "Deepslate" },
  deepslate_bricks: { c: [70, 70, 71], voxl: "DeepslateBricks" },
  deepslate_tiles: { c: [54, 54, 55], voxl: "DeepslateBricks" },
  bricks: { c: [150, 97, 83], voxl: "Bricks" },
  nether_bricks: { c: [44, 22, 26], voxl: "NetherBricks" },
  red_nether_bricks: { c: [69, 8, 11], voxl: "NetherBricks" },
  ender_chest: { c: [40, 55, 58], voxl: "Obsidian" },
  bee_nest: { c: [190, 158, 76], voxl: "OakPlanks" },
  quartz_block: { c: [235, 229, 222], voxl: "Quartz" },
  smooth_quartz: { c: [235, 229, 222], voxl: "Quartz" },
  chiseled_quartz_block: { c: [231, 226, 218], voxl: "ChiseledQuartz" },
  quartz_pillar: { c: [235, 229, 222], voxl: "Quartz" },
  quartz_bricks: { c: [235, 229, 222], voxl: "Quartz" },
  prismarine: { c: [99, 156, 151], voxl: "Prismarine" },
  prismarine_bricks: { c: [99, 171, 158], voxl: "Prismarine" },
  dark_prismarine: { c: [51, 91, 75], voxl: "Prismarine" },
  sea_lantern: { c: [172, 199, 190], voxl: "SeaLantern" },
  glowstone: { c: [249, 209, 120], voxl: "Glowstone" },
  shroomlight: { c: [240, 146, 70], voxl: "Glowstone" },
  froglight: { c: [240, 230, 180], voxl: "Glowstone" },
  magma_block: { c: [142, 62, 26], voxl: "MagmaBlock" },

  dirt: { c: [134, 96, 67], voxl: "Dirt" },
  rooted_dirt: { c: [144, 103, 76], voxl: "Dirt" },
  coarse_dirt: { c: [119, 85, 59], voxl: "CoarseDirt" },
  podzol: { c: [91, 63, 25], voxl: "Podzol" },
  mud: { c: [60, 52, 50], voxl: "Mud" },
  clay: { c: [160, 166, 179], voxl: "Clay" },
  grass_block: { c: [106, 150, 68], voxl: "Grass" },
  dirt_path: { c: [148, 120, 65], voxl: "CoarseDirt" },
  farmland: { c: [100, 68, 42], voxl: "CoarseDirt" },
  mycelium: { c: [111, 99, 96], voxl: "Podzol" },
  moss_block: { c: [89, 109, 45], voxl: "MossBlock" },
  gravel: { c: [131, 127, 126], voxl: "Gravel" },
  sand: { c: [219, 207, 163], voxl: "Sand" },
  red_sand: { c: [190, 102, 33], voxl: "RedSand" },
  sandstone: { c: [216, 203, 155], voxl: "Sandstone" },
  smooth_sandstone: { c: [219, 207, 163], voxl: "Sandstone" },
  cut_sandstone: { c: [216, 203, 155], voxl: "Sandstone" },
  chiseled_sandstone: { c: [216, 203, 155], voxl: "Sandstone" },
  red_sandstone: { c: [186, 99, 29], voxl: "RedSandstone" },
  smooth_red_sandstone: { c: [186, 99, 29], voxl: "RedSandstone" },
  cut_red_sandstone: { c: [186, 99, 29], voxl: "RedSandstone" },
  terracotta: { c: [152, 94, 67], voxl: "Terracotta" },

  // The snow LAYER, not the block — 55k of them across 55k columns, i.e. the
  // white on every snowy surface in the map. Voxl has no sub-block heights, so it
  // becomes a full Snow block: one block of extra height, versus losing every
  // snowfield on the map.
  snow: { c: [249, 254, 254], voxl: "Snow" },
  // Castle windows, railings, portcullises. A full opaque block would brick up
  // every window, so IronBars is see-through: it reads as a barred opening.
  iron_bars: { c: [110, 112, 116], voxl: "IronBars" },
  water: { c: [63, 118, 228], voxl: "Water" },
  bubble_column: { c: [63, 118, 228], voxl: "Water" },
  lava: { c: [216, 102, 25], voxl: "Lava" },
  ice: { c: [145, 183, 253], voxl: "Ice" },
  packed_ice: { c: [141, 180, 250], voxl: "PackedIce" },
  blue_ice: { c: [116, 167, 253], voxl: "PackedIce" },
  frosted_ice: { c: [145, 183, 253], voxl: "Ice" },
  snow_block: { c: [249, 254, 254], voxl: "Snow" },
  powder_snow: { c: [249, 254, 254], voxl: "Snow" },

  coal_ore: { c: [70, 70, 70], voxl: "CoalOre" },
  iron_ore: { c: [180, 150, 130], voxl: "IronOre" },
  copper_ore: { c: [190, 120, 90], voxl: "CopperOre" },
  gold_ore: { c: [220, 190, 90], voxl: "GoldOre" },
  diamond_ore: { c: [120, 220, 220], voxl: "DiamondOre" },
  emerald_ore: { c: [80, 200, 120], voxl: "EmeraldOre" },
  lapis_ore: { c: [70, 100, 170], voxl: "LapisOre" },
  redstone_ore: { c: [150, 70, 70], voxl: "RedstoneOre" },
  ancient_debris: { c: [95, 66, 60], voxl: "IronOre" },
  iron_block: { c: [220, 220, 220], voxl: "IronBlock" },
  gold_block: { c: [246, 208, 61], voxl: "GoldBlock" },
  diamond_block: { c: [98, 219, 214], voxl: "DiamondBlock" },
  emerald_block: { c: [81, 217, 117], voxl: "EmeraldBlock" },
  lapis_block: { c: [30, 67, 140], voxl: "LapisBlock" },
  redstone_block: { c: [175, 24, 5], voxl: "RedstoneBlock" },
  copper_block: { c: [192, 107, 79], voxl: "CopperBlock" },
  raw_iron_block: { c: [166, 135, 107], voxl: "IronBlock" },
  raw_copper_block: { c: [154, 96, 68], voxl: "CopperBlock" },
  coal_block: { c: [16, 15, 15], voxl: "CoalBlock" },
  amethyst_block: { c: [133, 97, 191], voxl: "Amethyst" },
  bone_block: { c: [209, 206, 179], voxl: "Quartz" },
  hay_block: { c: [165, 139, 12], voxl: "HayBlock" },
  glass: { c: [255, 255, 255], voxl: "Glass" },
  tinted_glass: { c: [70, 65, 70], voxl: "Glass" },
  bookshelf: { c: [162, 130, 78], voxl: "Bookshelf" },
  crafting_table: { c: [124, 90, 55], voxl: "OakPlanks" },
  furnace: { c: [110, 110, 110], voxl: "Cobblestone" },
  chest: { c: [162, 130, 78], voxl: "OakPlanks" },
  barrel: { c: [124, 90, 55], voxl: "OakPlanks" },
  dropper: { c: [110, 110, 110], voxl: "Cobblestone" },
  dispenser: { c: [110, 110, 110], voxl: "Cobblestone" },
  piston: { c: [124, 118, 103], voxl: "OakPlanks" },
  sticky_piston: { c: [124, 118, 103], voxl: "OakPlanks" },
  piston_head: { c: [162, 130, 78], voxl: "OakPlanks" },
  observer: { c: [98, 98, 98], voxl: "Stone" },
  note_block: { c: [98, 74, 45], voxl: "OakPlanks" },
  jukebox: { c: [98, 74, 45], voxl: "OakPlanks" },
  loom: { c: [124, 90, 55], voxl: "OakPlanks" },
  smoker: { c: [110, 110, 110], voxl: "Cobblestone" },
  blast_furnace: { c: [110, 110, 110], voxl: "Cobblestone" },
  cartography_table: { c: [98, 74, 45], voxl: "OakPlanks" },
  fletching_table: { c: [190, 175, 130], voxl: "BirchPlanks" },
  smithing_table: { c: [55, 44, 40], voxl: "DarkOakPlanks" },
  composter: { c: [124, 90, 55], voxl: "OakPlanks" },
  beehive: { c: [162, 130, 78], voxl: "OakPlanks" },
  melon: { c: [111, 145, 40], voxl: "MossBlock" },
  pumpkin: { c: [196, 118, 24], voxl: "Pumpkin" },
  carved_pumpkin: { c: [196, 118, 24], voxl: "Pumpkin" },
  jack_o_lantern: { c: [213, 154, 60], voxl: "Glowstone" },
  sponge: { c: [195, 192, 74], voxl: "HayBlock" },
  slime_block: { c: [111, 192, 91], voxl: "MossBlock" },
  honey_block: { c: [251, 179, 62], voxl: "Glowstone" },
  spawner: { c: [26, 39, 49], voxl: "Stone" },
  infested_stone: { c: [125, 125, 125], voxl: "Stone" },
  cobweb: { c: [220, 220, 220], voxl: null },
  cobbled_deepslate: { c: [77, 77, 80], voxl: "CobbledDeepslate" },
  budding_amethyst: { c: [133, 97, 191], voxl: "Amethyst" },
  redstone_lamp: { c: [186, 121, 66], voxl: "Glowstone" },
  soul_sand: { c: [81, 62, 50], voxl: "CoarseDirt" },
  soul_soil: { c: [76, 58, 47], voxl: "CoarseDirt" },
  netherite_block: { c: [66, 61, 63], voxl: "CoalBlock" },
  crying_obsidian: { c: [32, 10, 60], voxl: "Obsidian" },
  end_portal_frame: { c: [92, 118, 100], voxl: "Quartz" },
  end_stone: { c: [219, 222, 158], voxl: "Sandstone" },
  purpur_block: { c: [170, 126, 170], voxl: "Terracotta_magenta" },
  suspicious_sand: { c: [219, 207, 163], voxl: "Sand" },
  suspicious_gravel: { c: [131, 127, 126], voxl: "Gravel" },
  tnt: { c: [219, 62, 51], voxl: "RedstoneBlock" },
  cactus: { c: [85, 127, 45], voxl: "Cactus" },
  dried_kelp_block: { c: [50, 58, 42], voxl: "MossBlock" },
  mud_bricks: { c: [137, 105, 78], voxl: "Bricks" },
  packed_mud: { c: [142, 107, 80], voxl: "CoarseDirt" },
  sculk: { c: [12, 27, 32], voxl: "CoalBlock" },
  sculk_catalyst: { c: [22, 40, 45], voxl: "CoalBlock" },
  reinforced_deepslate: { c: [87, 92, 84], voxl: "Stone" },
};

// Named flowers/plants that don't contain a CLUTTER keyword.
const FLOWERS = [
  "dandelion", "poppy", "azure_bluet", "allium", "oxeye_daisy", "cornflower",
  "lily_of_the_valley", "blue_orchid", "wither_rose", "lilac", "peony",
  "rose_bush", "sunflower", "pitcher_plant", "torchflower", "melon_stem",
  "pumpkin_stem", "sea_pickle", "fire", "soul_fire", "nether_portal",
  "end_portal", "end_gateway",
  "light", // the invisible light source block — matched EXACTLY, never as a
           // substring, or it swallows light_gray_wool and light_blue_glass
];

// Modifiers that collapse to the base material (Voxl has no sub-block shapes).
const SHAPE_SUFFIX = ["_stairs", "_slab", "_wall", "_fence", "_fence_gate", "_pane", "_trapdoor", "_door", "_button", "_pressure_plate"];
// Prefixes that are pure surface finishes of the same material.
const FINISH_PREFIX = ["polished_", "smooth_", "cut_", "chiseled_", "cracked_", "mossy_", "stripped_", "waxed_", "exposed_", "weathered_", "oxidized_", "infested_", "petrified_", "deepslate_", "cobbled_"];

// Blocks that exist only as clutter — no cube, no collision worth keeping.
const CLUTTER = [
  "torch", "lantern", "flower", "sapling", "grass", "fern", "vine", "lily",
  "mushroom", "sign", "banner", "rail", "lever", "tripwire", "string", "candle",
  "cake", "carpet", "snow", "sugar_cane", "wheat", "carrots", "potatoes",
  "beetroots", "kelp", "seagrass", "coral", "bamboo", "pointed_dripstone",
  "amethyst_cluster", "amethyst_bud", "sculk_vein", "glow_lichen", "cave_vines",
  "hanging_roots", "spore_blossom", "azalea", "big_dripleaf", "small_dripleaf",
  "sweet_berry", "cocoa", "nether_wart", "chorus", "scaffolding", "ladder",
  "chain", "end_rod", "conduit", "bell", "cauldron", "brewing",
  "hopper", "comparator", "repeater", "redstone_wire", "redstone_torch",
  "tripwire_hook", "item_frame", "painting", "head", "skull", "pot", "decorated",
  "lightning_rod", "campfire", "lectern", "stonecutter", "grindstone", "anvil",
  "enchanting_table", "beacon", "target", "daylight_detector", "bed", "shulker",
  "turtle_egg", "dragon_egg", "sniffer_egg", "frogspawn", "sculk_shrieker",
  "sculk_sensor", "barrier", "structure", "jigsaw", "moving_piston",
  "petals", "hanging_sign", "trial_spawner", "vault", "copper_bulb", "crafter",
  "heavy_core", "creaking_heart", "resin_clump", "leaf_litter", "wildflowers",
  "bush", "firefly_bush", "cactus_flower", "dead_bush", "tall_", "roots", "tulip",
  "attached_", // attached_melon_stem etc. (NOT "_stem": crimson/warped stems are logs)
  "nylium", "sprouts", "fungus", "weeping", "twisting", "shroom", "eyeblossom",
];

const memo = new Map();

// Materials that have a half-height slab block. Anything else falls back to its
// full block — chunkier, but never a hole.
const SLAB_OF = new Set(require("./voxlids").SLAB_MATERIALS);

function resolve(name) {
  let n = name.startsWith("minecraft:") ? name.slice(10) : name;
  // Block-state text, e.g. "oak_slab[type=top]". Only slabs carry any (anvil.js
  // decides what's worth keeping), but capture it before stripping.
  let props = "";
  const br = n.indexOf("[");
  if (br >= 0) {
    props = n.slice(br);
    n = n.slice(0, br);
  }

  // SLABS, before anything else — "_slab" is in SHAPE_SUFFIX, so the generic
  // rules below would flatten them into full blocks.
  if (n.endsWith("_slab")) {
    const type = (props.match(/type=(\w+)/) || [, "bottom"])[1];
    const parent = resolve(n.slice(0, -5)) || resolve(n.slice(0, -5) + "s");
    if (parent && parent.voxl) {
      if (type === "double") return { ...parent, base: n }; // a double slab IS the block
      if (SLAB_OF.has(parent.voxl)) {
        const prefix = type === "top" ? "SlabTop" : "Slab";
        return { c: parent.c, voxl: `${prefix}_${parent.voxl}`, base: n };
      }
      return { ...parent, base: n }; // no slab variant for this material
    }
  }

  if (BASE[n]) return { ...BASE[n], base: n };

  if (FLOWERS.includes(n)) return { c: [0, 0, 0], voxl: null, base: n };

  // Dye families FIRST. Several dye names contain a CLUTTER substring — "light" in
  // light_gray/light_blue most damagingly — so resolving them after the clutter
  // scan silently deleted the map's whole light-grey cloud layer. A dyed thing we
  // don't model (banner, bed, carpet, candle) falls through to the rules below.
  for (const [dye, col] of Object.entries(DYES)) {
    if (!n.startsWith(dye + "_")) continue;
    let rest = n.slice(dye.length + 1);
    for (const s of SHAPE_SUFFIX) {
      if (rest.endsWith(s)) { rest = rest.slice(0, -s.length); break; }
    }
    if (rest === "terracotta" || rest === "glazed_terracotta")
      return { c: TERRACOTTA[dye], voxl: `Terracotta_${dye}`, base: n };
    if (rest === "stained_glass") return { c: col, voxl: `Glass_${dye}`, base: n };
    if (rest === "wool") return { c: col, voxl: `Wool_${dye}`, base: n };
    if (rest === "concrete") return { c: col, voxl: `Concrete_${dye}`, base: n };
    if (rest === "concrete_powder") return { c: col, voxl: `Wool_${dye}`, base: n };
    break;
  }

  // clutter → air (checked before shape stripping so "oak_sign" doesn't become oak_planks)
  for (const k of CLUTTER) {
    if (n.includes(k)) {
      // ...but snow_block / grass_block / moss_block are real cubes
      if (BASE[n]) return { ...BASE[n], base: n };
      return { c: [0, 0, 0], voxl: null, base: n };
    }
  }

  // <wood>_planks / _log / _wood / _leaves (+ any shape suffix already stripped below)
  let stripped = n;
  for (const s of SHAPE_SUFFIX) {
    if (stripped.endsWith(s)) { stripped = stripped.slice(0, -s.length); break; }
  }
  // "<x>_stairs" for a material whose block name has no suffix: oak_stairs → oak_planks,
  // stone_brick_stairs → stone_bricks, cobblestone_stairs → cobblestone
  const tryNames = [stripped, stripped + "s", stripped + "_block", stripped + "_planks"];
  for (const t of tryNames) if (BASE[t]) return { ...BASE[t], base: t };

  // wood families
  for (const [wood, cols] of Object.entries(WOODS)) {
    if (!stripped.startsWith(wood + "_") && stripped !== wood) continue;
    const rest = stripped.slice(wood.length + 1);
    if (rest.includes("leaves")) return { c: cols.leaf, voxl: leafOf(wood), base: stripped };
    if (rest.includes("log") || rest.includes("wood") || rest.includes("stem") || rest.includes("hyphae"))
      return { c: cols.log, voxl: logOf(wood), base: stripped };
    return { c: cols.plank, voxl: plankOf(wood), base: stripped }; // planks + everything built from them
  }
  // stripped_<wood>_log etc.
  for (const p of FINISH_PREFIX) {
    if (stripped.startsWith(p)) return resolve(stripped.slice(p.length));
  }

  return null; // unknown — caller decides (report it)
}

function logOf(w) { return { oak: "OakLog", birch: "BirchLog", spruce: "SpruceLog", jungle: "JungleLog", acacia: "AcaciaLog", dark_oak: "DarkOakLog" }[w] || "SpruceLog"; }
function leafOf(w) { return { oak: "OakLeaves", birch: "BirchLeaves", spruce: "SpruceLeaves", jungle: "JungleLeaves", acacia: "AcaciaLeaves", dark_oak: "DarkOakLeaves" }[w] || "OakLeaves"; }
function plankOf(w) { return { oak: "OakPlanks", birch: "BirchPlanks", spruce: "SprucePlanks", jungle: "JunglePlanks", acacia: "AcaciaPlanks", dark_oak: "DarkOakPlanks" }[w] || "OakPlanks"; }

const unknown = new Map();
function lookup(name) {
  let r = memo.get(name);
  if (r !== undefined) return r;
  r = resolve(name);
  if (!r) {
    unknown.set(name, (unknown.get(name) || 0) + 1);
    r = { c: [255, 0, 255], voxl: null, base: "?" };
  }
  memo.set(name, r);
  return r;
}

module.exports = {
  lookup,
  colorOf: (n) => lookup(n).c,
  voxlOf: (n) => lookup(n).voxl,
  unknown,
  DYES, TERRACOTTA, WOODS,
};
