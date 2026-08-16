// True-colour top-down render of a crop (1 px = 1 block), so a crop centre can be
// chosen by looking at the map instead of guessing. Water is drawn as depth-tinted
// blue over the sea floor; everything else takes its block colour with slope shading.
// usage: node render.js <regionDir> <x0> <z0> <x1> <z1> <out.png> [yTop]

const fs = require("fs");
const path = require("path");
const { readRegion, chunkSections } = require("./anvil");
const { lookup, unknown } = require("./blockmap");
const png = require("./png");

const regionDir = process.argv[2];
const x0 = +process.argv[3], z0 = +process.argv[4], x1 = +process.argv[5], z1 = +process.argv[6];
const outFile = process.argv[7];
const yTop = process.argv[8] !== undefined ? +process.argv[8] : 319;

const W = x1 - x0 + 1, H = z1 - z0 + 1;
const topY = new Int16Array(W * H).fill(-9999);
const topC = new Uint8Array(W * H * 3);
const waterD = new Uint8Array(W * H);

const cx0 = Math.floor(x0 / 16), cx1 = Math.floor(x1 / 16);
const cz0 = Math.floor(z0 / 16), cz1 = Math.floor(z1 / 16);
const rx0 = Math.floor(cx0 / 32), rx1 = Math.floor(cx1 / 32);
const rz0 = Math.floor(cz0 / 32), rz1 = Math.floor(cz1 / 32);

const WATER = new Set(["minecraft:water", "minecraft:bubble_column"]);
const SKIP = new Set(["minecraft:air", "minecraft:cave_air", "minecraft:void_air", "minecraft:barrier", "minecraft:light"]);

for (let rz = rz0; rz <= rz1; rz++) {
  for (let rx = rx0; rx <= rx1; rx++) {
    const f = path.join(regionDir, `r.${rx}.${rz}.mca`);
    if (!fs.existsSync(f)) continue;
    const chunks = readRegion(f);
    for (let i = 0; i < 1024; i++) {
      const c = chunks[i];
      if (!c || c.error) continue;
      const cx = rx * 32 + (i & 31), cz = rz * 32 + (i >> 5);
      if (cx < cx0 || cx > cx1 || cz < cz0 || cz > cz1) continue;
      const secs = chunkSections(c.nbt).sort((a, b) => b.y - a.y); // top down
      const done = new Uint8Array(256);       // column finished (opaque top found)
      const wdep = new Uint8Array(256);
      let left = 256;
      for (const s of secs) {
        if (left === 0) break;
        if (s.y * 16 > yTop) continue;
        for (let ly = 15; ly >= 0; ly--) {
          const y = s.y * 16 + ly;
          if (y > yTop) continue;
          if (left === 0) break;
          for (let z = 0; z < 16; z++) {
            for (let x = 0; x < 16; x++) {
              const ci = z * 16 + x;
              if (done[ci]) continue;
              const name = s.states ? s.palette[s.states[ly * 256 + z * 16 + x]] : s.palette[0];
              if (SKIP.has(name)) continue;
              if (WATER.has(name)) { if (wdep[ci] < 40) wdep[ci]++; continue; }
              const r = lookup(name);
              if (!r.voxl && r.c[0] === 0 && r.c[1] === 0 && r.c[2] === 0) continue; // clutter → see through
              const gx = cx * 16 + x - x0, gz = cz * 16 + z - z0;
              if (gx >= 0 && gx < W && gz >= 0 && gz < H) {
                const gi = gx + gz * W;
                topY[gi] = y;
                topC[gi * 3] = r.c[0]; topC[gi * 3 + 1] = r.c[1]; topC[gi * 3 + 2] = r.c[2];
                waterD[gi] = wdep[ci];
              }
              done[ci] = 1; left--;
            }
          }
        }
      }
    }
  }
  process.stdout.write(`\r  region row ${rz - rz0 + 1}/${rz1 - rz0 + 1}`);
}
console.log("");

const rgb = new Uint8Array(W * H * 3);
for (let z = 0; z < H; z++) {
  for (let x = 0; x < W; x++) {
    const i = x + z * W;
    let r = topC[i * 3], g = topC[i * 3 + 1], b = topC[i * 3 + 2];
    const y = topY[i];
    if (y <= -9999) { rgb[i * 3] = 12; rgb[i * 3 + 1] = 12; rgb[i * 3 + 2] = 16; continue; }
    // slope shading against the neighbour to -x/-z (surface height incl. water top)
    const hy = y + waterD[i];
    const hl = x > 0 ? topY[i - 1] + waterD[i - 1] : hy;
    const hu = z > 0 ? topY[i - W] + waterD[i - W] : hy;
    let sh = 1 + Math.max(-0.35, Math.min(0.35, ((hy - hl) + (hy - hu)) * 0.10));
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
console.log(`wrote ${outFile} (${W}×${H})`);
if (unknown.size) {
  console.log(`unmapped block names (${unknown.size}):`);
  for (const [n] of [...unknown.entries()].slice(0, 60)) console.log(`  ${n}`);
}
