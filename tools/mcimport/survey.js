// Survey the whole save: where is the actual BUILD (vs plain vanilla terrain)?
//   * per-column surface height comes from the stored WORLD_SURFACE heightmap
//     (free — no section unpacking)
//   * per-chunk "built" score comes from scanning section PALETTES for man-made
//     block names (cheap: palettes are tiny) and unpacking only those sections
// Outputs two PNGs (relief + built-density overlay) and a text summary of the
// hottest 24×24-chunk windows, so the crop centre can be chosen by eye + number.
//
// usage: node survey.js <regionDir> <outDir>

const fs = require("fs");
const path = require("path");
const { readRegion, chunkSections } = require("./anvil");
const png = require("./png");

const regionDir = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, "out");
fs.mkdirSync(outDir, { recursive: true });

// A block counts as "built" if a player almost certainly placed it. Kept as
// substring rules so the 1.21 block list doesn't need enumerating.
const BUILT_PARTS = [
  "planks", "_stairs", "_slab", "_fence", "_wall", "bricks", "brick_",
  "glass", "_door", "_trapdoor", "lantern", "torch", "chiseled", "polished",
  "smooth_", "cut_", "cobblestone", "mossy_", "wool", "carpet", "terracotta",
  "concrete", "bookshelf", "barrel", "chest", "furnace", "crafting", "anvil",
  "ladder", "campfire", "banner", "sign", "bed", "hay_block", "path", "farmland",
  "stripped_", "log", "fletching", "smithing", "loom", "cauldron", "bell",
  "flower_pot", "candle", "scaffolding", "iron_bars", "lightning_rod",
];
const NOT_BUILT = ["mushroom", "azalea", "mangrove_log", "cherry_log"]; // natural-ish
function isBuilt(name) {
  const n = name.slice(10); // strip "minecraft:"
  if (NOT_BUILT.some((s) => n.includes(s))) return false;
  return BUILT_PARTS.some((s) => n.includes(s));
}

// WORLD_SURFACE heightmap: 256 entries × 9 bits, 7 per long, value = y + 65.
function readHeightmap(longs) {
  const out = new Int16Array(256);
  if (!longs) return out;
  for (let i = 0; i < 256; i++) {
    const li = (i / 7) | 0;
    const bit = (i % 7) * 9;
    const base = li * 8;
    if (base + 8 > longs.length) break;
    const hi = longs.readUInt32BE(base);
    const lo = longs.readUInt32BE(base + 4);
    let v;
    if (bit + 9 <= 32) v = (lo >>> bit) & 0x1ff;
    else if (bit >= 32) v = (hi >>> (bit - 32)) & 0x1ff;
    else v = ((lo >>> bit) | (hi << (32 - bit))) & 0x1ff;
    out[i] = v - 65;
  }
  return out;
}

const files = fs.readdirSync(regionDir).filter((f) => /^r\.-?\d+\.-?\d+\.mca$/.test(f));

// world extents in chunks
let minCX = 1e9, maxCX = -1e9, minCZ = 1e9, maxCZ = -1e9;
const regions = [];
for (const f of files) {
  const [, rx, rz] = f.match(/^r\.(-?\d+)\.(-?\d+)\.mca$/).map(Number);
  regions.push({ f, rx, rz });
  minCX = Math.min(minCX, rx * 32); maxCX = Math.max(maxCX, rx * 32 + 31);
  minCZ = Math.min(minCZ, rz * 32); maxCZ = Math.max(maxCZ, rz * 32 + 31);
}
const CW = maxCX - minCX + 1, CH = maxCZ - minCZ + 1;
const W = CW * 16, H = CH * 16;
console.log(`regions: ${regions.length}  chunk box: x ${minCX}..${maxCX}, z ${minCZ}..${maxCZ}  (${W}×${H} blocks)`);

const height = new Int16Array(W * H).fill(-999);
const built = new Int32Array(CW * CH);
const present = new Uint8Array(CW * CH);
const globalHist = new Map();

let done = 0;
for (const { f, rx, rz } of regions) {
  const chunks = readRegion(path.join(regionDir, f));
  for (let i = 0; i < 1024; i++) {
    const c = chunks[i];
    if (!c || c.error) continue;
    const cx = rx * 32 + (i & 31);
    const cz = rz * 32 + (i >> 5);
    const ci = (cx - minCX) + (cz - minCZ) * CW;
    present[ci] = 1;

    const hm = c.nbt.Heightmaps && (c.nbt.Heightmaps.WORLD_SURFACE || c.nbt.Heightmaps.MOTION_BLOCKING);
    const hs = readHeightmap(hm);
    for (let z = 0; z < 16; z++) {
      for (let x = 0; x < 16; x++) {
        height[(cx - minCX) * 16 + x + ((cz - minCZ) * 16 + z) * W] = hs[z * 16 + x];
      }
    }

    for (const s of chunkSections(c.nbt)) {
      if (s.y < 0 || s.y > 15) continue;
      const builtIdx = [];
      for (let p = 0; p < s.palette.length; p++) {
        const n = s.palette[p];
        if (n === "minecraft:air" || n === "minecraft:cave_air") continue;
        if (isBuilt(n)) builtIdx.push(p);
      }
      if (builtIdx.length === 0) continue;
      if (!s.states) { built[ci] += 4096; continue; }
      const want = new Uint8Array(s.palette.length);
      for (const p of builtIdx) want[p] = 1;
      let n = 0;
      for (let k = 0; k < 4096; k++) if (want[s.states[k]]) n++;
      built[ci] += n;
      for (const p of builtIdx) globalHist.set(s.palette[p], (globalHist.get(s.palette[p]) || 0) + 1);
    }
  }
  done++;
  process.stdout.write(`\r  scanned ${done}/${regions.length} regions`);
}
console.log("");

// ---- relief PNG (grey by height, red tint by built density) ----
const rgb = new Uint8Array(W * H * 3);
let maxBuilt = 1;
for (const v of built) if (v > maxBuilt) maxBuilt = v;
for (let z = 0; z < H; z++) {
  for (let x = 0; x < W; x++) {
    const i = x + z * W;
    const h = height[i];
    let r, g, b;
    if (h <= -999) { r = g = b = 0; }
    else {
      // relief: slope shading + banded height ramp
      const hl = x > 0 ? height[i - 1] : h;
      const hu = z > 0 ? height[i - W] : h;
      const slope = (h - hl) + (h - hu);
      let v = Math.max(0, Math.min(255, 40 + (h - 40) * 2.2 + slope * 14));
      if (h < 63) { r = v * 0.25; g = v * 0.45; b = 120 + v * 0.35; } // water-ish/low
      else { r = v * 0.75; g = v * 0.85; b = v * 0.6; }
    }
    const ci = ((x / 16) | 0) + (((z / 16) | 0)) * CW;
    const bd = built[ci] / 900; // ~900 built blocks in a chunk = fully hot
    if (bd > 0.02) {
      const t = Math.min(1, bd);
      r = r * (1 - t) + 255 * t;
      g = g * (1 - t) + 40 * t;
      b = b * (1 - t) + 40 * t;
    }
    rgb[i * 3] = r; rgb[i * 3 + 1] = g; rgb[i * 3 + 2] = b;
  }
}
fs.writeFileSync(path.join(outDir, "survey.png"), png.encode(W, H, rgb));
console.log(`wrote ${path.join(outDir, "survey.png")} (${W}×${H}, 1px = 1 block; red = player-built density)`);

// ---- hottest windows ----
// Integral image over the per-chunk built counts → best N×N chunk window.
const SS = new Float64Array((CW + 1) * (CH + 1));
for (let z = 0; z < CH; z++)
  for (let x = 0; x < CW; x++)
    SS[(x + 1) + (z + 1) * (CW + 1)] =
      built[x + z * CW] + SS[x + (z + 1) * (CW + 1)] + SS[(x + 1) + z * (CW + 1)] - SS[x + z * (CW + 1)];
function windowSum(x0, z0, n) {
  const x1 = x0 + n, z1 = z0 + n;
  return SS[x1 + z1 * (CW + 1)] - SS[x0 + z1 * (CW + 1)] - SS[x1 + z0 * (CW + 1)] + SS[x0 + z0 * (CW + 1)];
}
for (const n of [12, 24, 32]) {
  const cands = [];
  for (let z = 0; z + n <= CH; z++)
    for (let x = 0; x + n <= CW; x++)
      cands.push({ x, z, s: windowSum(x, z, n) });
  cands.sort((a, b) => b.s - a.s);
  const picked = [];
  for (const c of cands) {
    if (picked.some((p) => Math.abs(p.x - c.x) < n && Math.abs(p.z - c.z) < n)) continue;
    picked.push(c);
    if (picked.length === 5) break;
  }
  console.log(`\ntop ${n}×${n}-chunk windows (${n * 16} blocks across):`);
  for (const p of picked) {
    const bx = (minCX + p.x) * 16, bz = (minCZ + p.z) * 16;
    console.log(
      `  built=${String(Math.round(p.s)).padStart(8)}  blocks x ${bx}..${bx + n * 16 - 1}, z ${bz}..${bz + n * 16 - 1}  centre (${bx + n * 8}, ${bz + n * 8})`
    );
  }
}

let totalBuilt = 0, chunksPresent = 0;
for (let i = 0; i < built.length; i++) { totalBuilt += built[i]; chunksPresent += present[i]; }
console.log(`\nchunks present: ${chunksPresent}   total built blocks: ${totalBuilt}`);
const topBuilt = [...globalHist.entries()].sort((a, b) => b[1] - a[1]).slice(0, 25);
console.log("most widespread built blocks (by #sections containing them):");
for (const [n, c] of topBuilt) console.log(`  ${String(c).padStart(6)}  ${n}`);
