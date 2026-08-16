// Decode a baked VXM2 blob with exactly the rules PrebakedMap.luau uses, then
// render it top-down. If this image matches the source render, the encoder, the
// block mapping and the reader all agree. Also reports the column-top histogram,
// which is what the mesher's per-chunk Y span (and so its cost) is driven by.
//
// usage: node verify.js <Name.bin> <out.png>

const fs = require("fs");
const png = require("./png");
const { ID } = require("./voxlids");
const { DYES, TERRACOTTA, WOODS } = require("./blockmap");

const blob = fs.readFileSync(process.argv[2]);
const outFile = process.argv[3];

if (blob.toString("ascii", 0, 4) !== "VXM2") throw new Error("not a VXM2 blob");
const cx0 = blob.readInt16BE(4), cz0 = blob.readInt16BE(6);
const nx = blob.readUInt16BE(8), nz = blob.readUInt16BE(10);
const radius = blob.readUInt16BE(12), yFloor = blob.readUInt8(14);
const recordsBase = 16 + nx * nz * 8;
console.log(`VXM2: chunks ${nx}×${nz} from (${cx0},${cz0}), radius ${radius}, yFloor ${yFloor}`);

// ---- colour per Voxl id (mirrors Blocks.luau `color`) ----
const COL = {};
const set = (n, c) => { if (ID[n] !== undefined) COL[ID[n]] = c; };
set("Grass", [127, 178, 56]); set("Dirt", [140, 100, 70]); set("Sand", [235, 225, 180]);
set("Stone", [130, 130, 130]); set("Snow", [255, 255, 255]); set("OakLog", [150, 120, 72]);
set("OakLeaves", [60, 143, 40]); set("CoarseDirt", [120, 90, 64]); set("Podzol", [90, 64, 30]);
set("Mud", [60, 52, 50]); set("MossBlock", [90, 120, 60]); set("RedSand", [190, 100, 50]);
set("Sandstone", [220, 205, 160]); set("RedSandstone", [190, 100, 50]); set("Terracotta", [150, 90, 65]);
set("Cobblestone", [120, 120, 120]); set("Granite", [160, 110, 90]); set("Diorite", [200, 200, 200]);
set("Andesite", [140, 140, 140]); set("Gravel", [130, 125, 120]); set("Clay", [160, 165, 170]);
set("Ice", [200, 225, 255]); set("PackedIce", [180, 210, 245]); set("Glowstone", [255, 220, 140]);
set("Water", [60, 110, 200]); set("Lava", [216, 102, 25]);
set("StoneBricks", [122, 122, 122]); set("MossyStoneBricks", [112, 122, 105]);
set("MossyCobblestone", [110, 125, 100]); set("SmoothStone", [158, 158, 158]);
set("PolishedAndesite", [132, 134, 133]); set("Bricks", [150, 97, 83]); set("Quartz", [235, 229, 222]);
set("Prismarine", [99, 156, 151]); set("SeaLantern", [172, 199, 190]); set("Glass", [220, 240, 250]);
set("IronBlock", [220, 220, 220]); set("GoldBlock", [246, 208, 61]); set("DiamondBlock", [98, 219, 214]);
set("EmeraldBlock", [81, 217, 117]); set("LapisBlock", [30, 67, 140]); set("RedstoneBlock", [175, 24, 5]);
set("CopperBlock", [192, 107, 79]); set("CoalBlock", [24, 23, 23]); set("Amethyst", [133, 97, 191]);
set("LapisOre", [70, 100, 170]); set("RedstoneOre", [150, 70, 70]); set("HayBlock", [165, 139, 12]);
set("Bookshelf", [140, 110, 70]); set("Pumpkin", [196, 118, 24]);
set("CoalOre", [60, 60, 60]); set("IronOre", [180, 150, 130]); set("CopperOre", [190, 120, 90]);
set("GoldOre", [220, 190, 90]); set("DiamondOre", [120, 220, 220]); set("EmeraldOre", [80, 200, 120]);
for (const [w, c] of Object.entries(WOODS)) {
  const cap = w.split("_").map((s) => s[0].toUpperCase() + s.slice(1)).join("");
  set(`${cap}Log`, c.log); set(`${cap}Leaves`, c.leaf); set(`${cap}Planks`, c.plank);
}
for (const [d, c] of Object.entries(DYES)) {
  set(`Wool_${d}`, c); set(`Concrete_${d}`, c); set(`Glass_${d}`, c);
  set(`Terracotta_${d}`, TERRACOTTA[d]);
}

const W = nx * 16, H = nz * 16;
const topId = new Uint8Array(W * H);
const topYa = new Int16Array(W * H).fill(-9999);
const waterD = new Uint8Array(W * H);
const WATER = ID.Water;
const tops = [];
let voidCols = 0;

for (let gz = 0; gz < nz; gz++) {
  for (let gx = 0; gx < nx; gx++) {
    const at = (gx + gz * nx) * 8;
    const off = blob.readUInt32BE(recordsBase - nx * nz * 8 + at + 0 - 0 + 0) ;
    void off;
    const o = blob.readUInt32BE(16 + at), len = blob.readUInt32BE(16 + at + 4);
    if (len === 0) continue;
    let p = recordsBase + o;
    for (let ci = 0; ci < 256; ci++) {
      const yBot = blob[p], nRuns = blob[p + 1];
      p += 2;
      if (nRuns === 0) { voidCols++; continue; }
      // walk runs to the top, remembering the highest non-air and the water depth
      let y = yBot, last = 0, lastY = -1, wd = 0;
      for (let r = 0; r < nRuns; r++) {
        const id = blob[p + r * 2], n = blob[p + r * 2 + 1];
        if (id !== 0) { last = id; lastY = y + n - 1; }
        y += n;
      }
      // water column depth: count water in the runs above the last solid
      let yy = yBot, seenSolidTop = false, depth = 0;
      for (let r = nRuns - 1; r >= 0; r--) {
        const id = blob[p + r * 2], n = blob[p + r * 2 + 1];
        if (id === WATER && !seenSolidTop) depth += n;
        else if (id !== 0) { seenSolidTop = true; }
      }
      void yy;
      wd = Math.min(40, depth);
      p += nRuns * 2;

      // surface block = the highest non-water solid, else the water
      let surf = last, surfY = lastY;
      if (last === WATER) {
        let y2 = yBot, best = 0, bestY = -1;
        let q = p - nRuns * 2;
        for (let r = 0; r < nRuns; r++) {
          const id = blob[q + r * 2], n = blob[q + r * 2 + 1];
          if (id !== 0 && id !== WATER) { best = id; bestY = y2 + n - 1; }
          y2 += n;
        }
        if (best) { surf = best; surfY = bestY; }
      }
      const px = gx * 16 + (ci % 16), pz = gz * 16 + Math.floor(ci / 16);
      const i = px + pz * W;
      topId[i] = surf; topYa[i] = surfY; waterD[i] = wd;
      tops.push(lastY);
    }
  }
}

const rgb = new Uint8Array(W * H * 3);
for (let z = 0; z < H; z++) {
  for (let x = 0; x < W; x++) {
    const i = x + z * W;
    if (topYa[i] <= -9999) { rgb[i * 3] = 12; rgb[i * 3 + 1] = 12; rgb[i * 3 + 2] = 16; continue; }
    const c = COL[topId[i]] || [255, 0, 255];
    let [r, g, b] = c;
    const hy = topYa[i] + waterD[i];
    const hl = x > 0 && topYa[i - 1] > -9999 ? topYa[i - 1] + waterD[i - 1] : hy;
    const hu = z > 0 && topYa[i - W] > -9999 ? topYa[i - W] + waterD[i - W] : hy;
    let sh = 1 + Math.max(-0.35, Math.min(0.35, ((hy - hl) + (hy - hu)) * 0.1));
    if (waterD[i] > 0) {
      const t = Math.min(0.82, 0.28 + waterD[i] * 0.06);
      r = r * (1 - t) + 48 * t; g = g * (1 - t) + 96 * t; b = b * (1 - t) + 200 * t;
      sh = 1;
    }
    rgb[i * 3] = Math.max(0, Math.min(255, r * sh));
    rgb[i * 3 + 1] = Math.max(0, Math.min(255, g * sh));
    rgb[i * 3 + 2] = Math.max(0, Math.min(255, b * sh));
  }
}
fs.writeFileSync(outFile, png.encode(W, H, rgb));
console.log(`wrote ${outFile} (${W}×${H})   columns ${tops.length}, void ${voidCols}`);

tops.sort((a, b) => a - b);
const pct = (q) => tops[Math.floor(tops.length * q)];
console.log(`column tops (Voxl y): min ${tops[0]}  p50 ${pct(0.5)}  p99 ${pct(0.99)}  p99.9 ${pct(0.999)}  max ${tops[tops.length - 1]}`);
const above = (y) => tops.filter((t) => t > y).length;
for (const y of [120, 150, 180, 200, 220]) console.log(`  columns above y=${y}: ${above(y)}`);
