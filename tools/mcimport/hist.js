// Block histogram for a rectangular crop, above a Y cutoff (i.e. the part a
// player actually sees — not the 26M blocks of deepslate under it).
// usage: node hist.js <regionDir> <x0> <z0> <x1> <z1> [yMin] [top]
const fs = require("fs");
const path = require("path");
const { readRegion, chunkSections } = require("./anvil");

const [regionDir, x0, z0, x1, z1] = [process.argv[2], +process.argv[3], +process.argv[4], +process.argv[5], +process.argv[6]];
const yMin = process.argv[7] !== undefined ? +process.argv[7] : 50;
const topN = +(process.argv[8] || 120);

const cx0 = Math.floor(x0 / 16), cx1 = Math.floor(x1 / 16);
const cz0 = Math.floor(z0 / 16), cz1 = Math.floor(z1 / 16);
const rx0 = Math.floor(cx0 / 32), rx1 = Math.floor(cx1 / 32);
const rz0 = Math.floor(cz0 / 32), rz1 = Math.floor(cz1 / 32);

const hist = new Map();
let total = 0;
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
      for (const s of chunkSections(c.nbt)) {
        if (s.y * 16 + 15 < yMin) continue;
        if (!s.states) {
          const n = s.palette[0];
          if (n !== "minecraft:air" && n !== "minecraft:cave_air") {
            hist.set(n, (hist.get(n) || 0) + 4096); total += 4096;
          }
          continue;
        }
        const counts = new Uint32Array(s.palette.length);
        for (let k = 0; k < 4096; k++) counts[s.states[k]]++;
        for (let p = 0; p < s.palette.length; p++) {
          if (!counts[p]) continue;
          const n = s.palette[p];
          if (n === "minecraft:air" || n === "minecraft:cave_air") continue;
          hist.set(n, (hist.get(n) || 0) + counts[p]); total += counts[p];
        }
      }
    }
  }
}
const sorted = [...hist.entries()].sort((a, b) => b[1] - a[1]);
console.log(`crop x ${x0}..${x1}, z ${z0}..${z1}, y>=${yMin}`);
console.log(`distinct: ${sorted.length}   total non-air: ${total}`);
let acc = 0;
for (const [n, c] of sorted.slice(0, topN)) {
  acc += c;
  console.log(`${String(c).padStart(9)}  ${((acc / total) * 100).toFixed(2).padStart(6)}%  ${n}`);
}
const tail = sorted.slice(topN);
console.log(`... ${tail.length} more, ${tail.reduce((a, b) => a + b[1], 0)} blocks`);
