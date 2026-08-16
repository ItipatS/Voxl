// Quick sanity probe: read one region, dump chunk count, DataVersion, section Y
// range, and the top-30 block palette histogram (by occurrence, air excluded).
const path = require("path");
const { readRegion, chunkSections } = require("./anvil");

const file = process.argv[2];
const chunks = readRegion(file);

let ok = 0, err = 0, empty = 0;
let dv = null;
let minSecY = 99, maxSecY = -99;
const hist = new Map();
const errs = new Map();

for (const c of chunks) {
  if (!c) { empty++; continue; }
  if (c.error) { err++; errs.set(c.error, (errs.get(c.error) || 0) + 1); continue; }
  ok++;
  dv = dv ?? c.nbt.DataVersion;
  for (const s of chunkSections(c.nbt)) {
    if (s.y < minSecY) minSecY = s.y;
    if (s.y > maxSecY) maxSecY = s.y;
    if (!s.states) {
      const n = s.palette[0];
      if (n !== "minecraft:air") hist.set(n, (hist.get(n) || 0) + 4096);
      continue;
    }
    const counts = new Uint32Array(s.palette.length);
    for (let i = 0; i < 4096; i++) counts[s.states[i]]++;
    for (let i = 0; i < s.palette.length; i++) {
      if (counts[i] === 0) continue;
      const n = s.palette[i];
      if (n === "minecraft:air" || n === "minecraft:cave_air") continue;
      hist.set(n, (hist.get(n) || 0) + counts[i]);
    }
  }
}

console.log(`file: ${path.basename(file)}`);
console.log(`chunks: ${ok} ok, ${err} error, ${empty} absent`);
console.log(`DataVersion: ${dv}   sectionY: ${minSecY}..${maxSecY} (world y ${minSecY * 16}..${maxSecY * 16 + 15})`);
if (errs.size) console.log("errors:", [...errs.entries()]);
const top = [...hist.entries()].sort((a, b) => b[1] - a[1]);
console.log(`distinct blocks: ${top.length}`);
for (const [n, c] of top.slice(0, 30)) console.log(`  ${String(c).padStart(10)}  ${n}`);
