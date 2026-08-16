// Texture filename → (Voxl block, face).
//
// Real texture folders are named by hand: `coarseDirt.png`, `neterBricks.png`,
// `chiseledQurtz.png`, `oakplank.png`, `acaciatop.png`. A strict matcher rejects
// almost all of that, so this one works in four passes of decreasing confidence
// and REPORTS which pass matched, so anything shaky can be eyeballed:
//
//   exact  normalised name hits a block or a Minecraft name outright
//   alias  a hand-written rule (shorthand like "moss", "iron")
//   fuzzy  within 2 edits of a known name — catches the typos
//   —      no match; listed for a human to name properly
//
// Normalising = lowercase, drop everything that isn't a letter or digit. So
// `coarseDirt`, `coarse_dirt` and `COARSE-DIRT` are all `coarsedirt`.

const { lookup } = require("../mcimport/blockmap");
const { ID } = require("../mcimport/voxlids");
const { reverse } = require("./names");

const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

// Trailing face words. Order matters: "bottom" before "top" is irrelevant, but
// longer words must be tried before shorter ones they contain.
const FACES = [
  ["bottom", "bottom"], ["side", "side"], ["top", "top"],
  ["end", "top"], ["face", "side"], ["front", "side"], ["all", "all"],
];

// Shorthand a fuzzy match can't reach, and deliberate decisions.
// A `null` value means "known to be junk / not a block" — reported, never guessed at.
const ALIAS = {
  // bare wood name + a face = the LOG (planks say "planks")
  oak: "OakLog", birch: "BirchLog", spruce: "SpruceLog",
  jungle: "JungleLog", acacia: "AcaciaLog", darkoak: "DarkOakLog",
  oakplank: "OakPlanks", oakplanks: "OakPlanks",
  oakleave: "OakLeaves", birchleave: "BirchLeaves", spruceleave: "SpruceLeaves",
  jungleleaf: "JungleLeaves", acacialeaf: "AcaciaLeaves", darkoakleaf: "DarkOakLeaves",
  spruceleaf: "SpruceLeaves", birchleaf: "BirchLeaves", oakleaf: "OakLeaves",

  // shorthand for the metal/gem BLOCKS (the ores all say "ore")
  iron: "IronBlock", gold: "GoldBlock", diamond: "DiamondBlock",
  lapis: "LapisBlock", redstone: "RedstoneBlock", copper: "CopperBlock",
  emerald: "EmeraldBlock", coalblock: "CoalBlock", crystal: "Amethyst",
  coal: "CoalOre", // bare "coal" is the ore; the block is "coalblock"

  crystal: null, // amethyst.png already covers Amethyst — what is this one?
  moss: "MossBlock", ironbar: "IronBars", ironbars: "IronBars",
  hay: "HayBlock", pump: "Pumpkin", pumpkin: "Pumpkin",
  quartz: "Quartz", chiseledqurtz: "ChiseledQuartz",
  stonebrick: "StoneBricks", stonebricks: "StoneBricks",
  darkprismarine: "Prismarine", // we model one prismarine, not three
  netherack: "Netherrack", neterbricks: "NetherBricks",
  polishandesite: "PolishedAndesite", polishdiorite: "PolishedDiorite",
  polishgranite: "PolishedGranite",
  packedice: "PackedIce", smoothstone: "SmoothStone",
  terracotta: "Terracotta", // the plain (undyed) one
  concrete: null, // which colour? 16 of them — needs naming
  notexture: null, // the debug placeholder
  asdadad: null,
  sappire: null, // no sapphire block exists
};

// Faces one block borrows from another. Minecraft does this all over: a bookshelf
// is planks on the top and bottom, a grass block is plain dirt underneath.
const FACE_FROM = {
  Bookshelf: { top: "OakPlanks", bottom: "OakPlanks" },
  Grass: { bottom: "Dirt" },
  Podzol: { bottom: "Dirt" },
  // dark oak reuses the ordinary oak leaf
  DarkOakLeaves: { top: "OakLeaves", side: "OakLeaves", bottom: "OakLeaves" },
};

// ---------- index of every name we know ----------
const index = new Map(); // normalised → Voxl block name
function add(key, block) {
  const k = norm(key);
  if (k && !index.has(k)) index.set(k, block);
}
for (const block of Object.keys(ID)) {
  if (block === "Air") continue;
  add(block, block);
}
for (const [block, mcNames] of Object.entries(reverse)) {
  for (const mc of mcNames) add(mc, block);
}
// singular/plural of everything above
for (const [k, block] of [...index]) {
  if (k.endsWith("s")) add(k.slice(0, -1), block);
  else add(k + "s", block);
}

// ---------- fuzzy ----------
function editDistance(a, b, cap) {
  if (Math.abs(a.length - b.length) > cap) return cap + 1;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      cur[j] = a[i - 1] === b[j - 1]
        ? prev[j - 1]
        : 1 + Math.min(prev[j - 1], prev[j], cur[j - 1]);
      if (cur[j] < best) best = cur[j];
    }
    if (best > cap) return cap + 1;
    prev = cur;
  }
  return prev[b.length];
}

function fuzzy(key) {
  // Only worth trying on names long enough that 2 edits isn't most of the word.
  if (key.length < 5) return null;
  const cap = key.length <= 7 ? 1 : 2;
  let best = null, bestD = cap + 1;
  for (const [k, block] of index) {
    const d = editDistance(key, k, cap);
    if (d < bestD) { bestD = d; best = block; if (d === 0) break; }
  }
  return best && bestD <= cap ? { block: best, distance: bestD } : null;
}

// ---------- the resolver ----------
function resolveName(base) {
  let face = "all";
  let key = norm(base);

  // Trailing digits are almost always a duplicate marker or a version bump
  // ("stone1", "diamond (2)"), never part of a block name.
  const undigited = key.replace(/\d+$/, "");
  if (undigited && undigited !== key && (index.has(undigited) || ALIAS[undigited] !== undefined)) {
    key = undigited;
  }

  for (const [suffix, f] of FACES) {
    if (key.endsWith(suffix) && key.length > suffix.length) {
      // don't strip "top" out of a block that legitimately ends in it
      const stem = key.slice(0, -suffix.length);
      if (index.has(stem) || ALIAS[stem] !== undefined || stem.length >= 3) {
        face = f;
        key = stem;
        break;
      }
    }
  }

  if (ALIAS[key] !== undefined) {
    const block = ALIAS[key];
    return block === null
      ? { block: null, face, how: "rejected" }
      : { block, face, how: "alias" };
  }
  if (index.has(key)) return { block: index.get(key), face, how: "exact" };

  // the Minecraft mapping, for names the index didn't already cover
  const r = lookup(`minecraft:${key}`);
  if (r && r.voxl && ID[r.voxl] !== undefined) return { block: r.voxl, face, how: "exact" };

  const f = fuzzy(key);
  if (f) return { block: f.block, face, how: `fuzzy~${f.distance}` };

  return null;
}

module.exports = { resolveName, FACE_FROM, norm };
