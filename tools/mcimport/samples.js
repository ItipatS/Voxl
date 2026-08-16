// Dump reference samples straight from the Minecraft save, so the Luau reader can
// be checked against the SOURCE rather than against the baker's own opinion.
// (bake → blob → PrebakedMap must return what Minecraft actually had there.)
//
// usage: node samples.js <regionDir> <cx> <cz> <radius> <mapDir> <out.json>

const fs = require("fs");
const path = require("path");
const { readRegion, chunkSections } = require("./anvil");
const { lookup } = require("./blockmap");
const { ID } = require("./voxlids");
const { shellBottom } = require("./shell");

const [regionDir, CX, CZ, R, mapDir, outFile] =
  [process.argv[2], +process.argv[3], +process.argv[4], +process.argv[5], process.argv[6], process.argv[7]];

// The bake's Y mapping is recorded in the generated init.luau header comment.
const init = fs.readFileSync(path.join(mapDir, "init.luau"), "utf8");
const m = init.match(/MC y (-?\d+)\.\.(-?\d+) → Voxl y (\d+)\.\.(\d+)/u);
if (!m) throw new Error("cannot read the Y mapping out of init.luau");
console.log(`init.luau says: compacted ${m[1]}..${m[2]} → Voxl ${m[3]}..${m[4]}`);

// Sample columns: for each, record the SOURCE top block and its full top-down
// block sequence, expressed as (dy below top) → Voxl id. That's mapping-agnostic:
// it survives Y compaction, which shifts absolute y but never reorders a column.
const samples = [];
const step = 37; // coprime-ish stride so samples spread over chunks and regions
const wanted = [];
for (let vz = -R + 5; vz < R - 5; vz += step) {
  for (let vx = -R + 5; vx < R - 5; vx += step) {
    if (vx * vx + vz * vz > (R - 8) * (R - 8)) continue;
    wanted.push([vx, vz]);
  }
}
const byChunk = new Map();
for (const [vx, vz] of wanted) {
  const mcX = vx + CX, mcZ = vz + CZ;
  const k = Math.floor(mcX / 16) + ":" + Math.floor(mcZ / 16);
  if (!byChunk.has(k)) byChunk.set(k, []);
  byChunk.get(k).push([vx, vz, mcX, mcZ]);
}

const MC_Y_MIN = -64, MC_H = 384;
const regionsNeeded = new Set();
for (const k of byChunk.keys()) {
  const [cx, cz] = k.split(":").map(Number);
  regionsNeeded.add(`${Math.floor(cx / 32)}.${Math.floor(cz / 32)}`);
}
for (const rk of regionsNeeded) {
  const [rx, rz] = rk.split(".").map(Number);
  const f = path.join(regionDir, `r.${rx}.${rz}.mca`);
  if (!fs.existsSync(f)) continue;
  const chunks = readRegion(f);
  for (let i = 0; i < 1024; i++) {
    const c = chunks[i];
    if (!c || c.error) continue;
    const cx = rx * 32 + (i & 31), cz = rz * 32 + (i >> 5);
    const list = byChunk.get(cx + ":" + cz);
    if (!list) continue;
    const col = new Uint8Array(256 * MC_H);
    for (const s of chunkSections(c.nbt)) {
      const y0 = s.y * 16 - MC_Y_MIN;
      if (y0 < 0 || y0 + 15 >= MC_H) continue;
      const pmap = new Uint8Array(s.palette.length);
      for (let p = 0; p < s.palette.length; p++) {
        const r = lookup(s.palette[p]);
        pmap[p] = r.voxl ? ID[r.voxl] : 0;
      }
      for (let ly = 0; ly < 16; ly++) {
        for (let ci = 0; ci < 256; ci++) {
          const id = pmap[s.states ? s.states[ly * 256 + ci] : 0];
          if (id) col[ci * MC_H + y0 + ly] = id;
        }
      }
    }
    for (const [vx, vz, mcX, mcZ] of list) {
      const ci = (mcZ - cz * 16) * 16 + (mcX - cx * 16);
      const off = ci * MC_H;
      let top = -1;
      for (let k = MC_H - 1; k >= 0; k--) if (col[off + k]) { top = k; break; }
      if (top < 0) continue;
      // The column's SHELL as top-down RUNS. Runs (not a flat strip) are the right
      // unit because bake-time Y compaction may SHORTEN air gaps — it never
      // reorders blocks or changes how thick a solid layer is. So the test can
      // demand exact solid runs while tolerating shrunken air.
      const bot = shellBottom((k) => col[off + k], top, 0);
      const runs = [];
      for (let y = top; y >= bot; y--) {
        const id = col[off + y];
        const last = runs[runs.length - 1];
        if (last && last[0] === id) last[1]++;
        else runs.push([id, 1]);
      }
      samples.push({ x: vx, z: vz, runs });
    }
  }
}
fs.writeFileSync(outFile, JSON.stringify(samples));
console.log(`wrote ${samples.length} column samples → ${outFile}`);
