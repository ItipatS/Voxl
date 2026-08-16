// Bake a disc-shaped crop of a Minecraft save into the Voxl prebaked-map format.
//
// The size win that makes this shippable: a Minecraft column is ~380 blocks tall
// and almost all of it is undifferentiated underground rock. We store only the
// VISIBLE SHELL — from a column's top down to the first run of solid natural rock
// — and let the runtime return Stone for everything below it. The island's insides
// are never seen, so they cost zero bytes. Everything above the shell is implicit
// air. What's left compresses again under per-column RLE.
//
// Output format (VXM3) — random-access per 16×16 chunk, and each chunk record is
// DEFLATE'd on its own. Per-chunk compression gets 21% (essentially what
// compressing the whole blob would), while keeping every chunk independently
// decodable — which is what lets the server hold the map privately and stream
// single chunks to a client as it walks:
//
//   header   "VXM3" | i16 cx0 | i16 cz0 | u16 nx | u16 nz | u16 radius
//            | u8 yFloor | u8 flags
//   index    nx*nz × { u32 offset, u32 compLen, u16 rawLen }  (compLen 0 = void)
//   records  per chunk: deflate-raw of
//                       256 columns × { u8 yBot, u8 nRuns, nRuns × (u8 id, u8 len) }
//
//   yBot is an ABSOLUTE Voxl y. Below yBot: Stone. Above the last run: Air.
//   nRuns == 0 means the column is void (outside the disc / no terrain).
//   Columns are indexed lz*16 + lx; chunk coords are Voxl chunk coords with the
//   crop centre at Voxl world (0,0).
//
// usage:
//   node bake.js --region <dir> --cx <mcX> --cz <mcZ> --radius <blocks>
//                [--out <dir>] [--name Foo] [--depth 160] [--dry] [--bin]

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { readRegion, chunkSections } = require("./anvil");
const { lookup, unknown } = require("./blockmap");
const { ID } = require("./voxlids");
const { shellBottom } = require("./shell");

// ---- args ----
const A = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith("--")) A[a.slice(2)] = process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[++i] : true;
}
const regionDir = A.region;
const CX = +A.cx, CZ = +A.cz, R = +A.radius;
const NAME = A.name || "Map";
const OUT = A.out || path.join(__dirname, "out");
// How far down a column may reach before we give up looking for solid rock. It
// defaults to "the whole world" on purpose: a floating structure (an airship, a
// cloud island) has nothing but air under it, and stopping early would make the
// runtime's implicit-stone floor start in mid-air — a rock pillar under every
// cloud. Air is one RLE run, so scanning to the bottom is nearly free.
const MAX_STORE = +(A.depth || 384);
const DRY = !!A.dry;
if (!regionDir || Number.isNaN(CX) || Number.isNaN(CZ) || Number.isNaN(R)) {
  console.error("usage: node bake.js --region <dir> --cx <n> --cz <n> --radius <n> [--out <dir>] [--name N] [--depth 160] [--dry]");
  process.exit(1);
}

const Y_FLOOR = 19;      // Voxl y the lowest stored level maps to (= Mesher's CAVE_FLOOR)
const Y_CEILING = 250;   // hard Voxl ceiling (u8 y, WORLD_HEIGHT 256)
const MC_Y_MIN = -64, MC_Y_MAX = 319, MC_H = MC_Y_MAX - MC_Y_MIN + 1;

const cx0 = Math.floor(-R / 16), cx1 = Math.floor((R - 1) / 16);
const cz0 = Math.floor(-R / 16), cz1 = Math.floor((R - 1) / 16);
const NX = cx1 - cx0 + 1, NZ = cz1 - cz0 + 1;
console.log(`crop: MC centre (${CX}, ${CZ}) radius ${R} → ${NX}×${NZ} Voxl chunks (${NX * 16}×${NZ * 16} blocks)`);

// ---- pass 1: MC chunk → truncated columns, keyed by Voxl chunk ----
const cols = new Map();          // voxl chunk key → Array(256) of {b: yBotMC, a: Uint8Array} | undefined
const idHist = new Map();
let yMinStored = 1e9, yMaxStored = -1e9, colsKept = 0;

const R2 = R * R;
const mcc0 = Math.floor((CX - R) / 16), mcc1 = Math.floor((CX + R - 1) / 16);
const mcd0 = Math.floor((CZ - R) / 16), mcd1 = Math.floor((CZ + R - 1) / 16);
const r0 = Math.floor(mcc0 / 32), r1 = Math.floor(mcc1 / 32);
const s0 = Math.floor(mcd0 / 32), s1 = Math.floor(mcd1 / 32);

const scratch = new Uint8Array(256 * MC_H); // one MC chunk, reused

for (let rz = s0; rz <= s1; rz++) {
  for (let rx = r0; rx <= r1; rx++) {
    const f = path.join(regionDir, `r.${rx}.${rz}.mca`);
    if (!fs.existsSync(f)) continue;
    const chunks = readRegion(f);
    for (let i = 0; i < 1024; i++) {
      const c = chunks[i];
      if (!c || c.error) continue;
      const mccx = rx * 32 + (i & 31), mccz = rz * 32 + (i >> 5);
      if (mccx < mcc0 || mccx > mcc1 || mccz < mcd0 || mccz > mcd1) continue;

      // skip MC chunks whose nearest corner is already outside the disc
      const bx = mccx * 16 - CX, bz = mccz * 16 - CZ;
      const nearX = bx > 0 ? bx : (bx + 15 < 0 ? -(bx + 15) : 0);
      const nearZ = bz > 0 ? bz : (bz + 15 < 0 ? -(bz + 15) : 0);
      if (nearX * nearX + nearZ * nearZ > R2) continue;

      const secs = chunkSections(c.nbt);
      if (secs.length === 0) continue;
      scratch.fill(0);
      let any = false;
      for (const s of secs) {
        const pmap = new Uint8Array(s.palette.length);
        let anySolid = false;
        for (let p = 0; p < s.palette.length; p++) {
          const r = lookup(s.palette[p]);
          if (r.voxl && ID[r.voxl] === undefined) throw new Error(`blockmap → unknown Voxl id "${r.voxl}" for ${s.palette[p]}`);
          pmap[p] = r.voxl ? ID[r.voxl] : 0;
          if (pmap[p]) anySolid = true;
        }
        if (!anySolid) continue;
        any = true;
        const y0 = s.y * 16 - MC_Y_MIN;
        if (y0 < 0 || y0 + 15 >= MC_H) continue;
        if (!s.states) {
          const id = pmap[0];
          for (let ci = 0; ci < 256; ci++)
            for (let ly = 0; ly < 16; ly++) scratch[ci * MC_H + y0 + ly] = id;
          continue;
        }
        for (let ly = 0; ly < 16; ly++) {
          const base = ly * 256;
          for (let ci = 0; ci < 256; ci++) {
            const id = pmap[s.states[base + ci]];
            if (id) scratch[ci * MC_H + y0 + ly] = id;
          }
        }
      }
      if (!any) continue;

      for (let z = 0; z < 16; z++) {
        const vz = mccz * 16 + z - CZ;
        if (vz < -R || vz >= R) continue;
        for (let x = 0; x < 16; x++) {
          const vx = mccx * 16 + x - CX;
          if (vx < -R || vx >= R) continue;
          if (vx * vx + vz * vz > R2) continue;

          const ci = z * 16 + x;
          const off = ci * MC_H;
          // top-most non-air
          let top = -1;
          for (let k = MC_H - 1; k >= 0; k--) if (scratch[off + k]) { top = k; break; }
          if (top < 0) continue;
          // Where the column stops being scenery and becomes island interior
          // (shell.js owns the rule; the verification test reads it from there too).
          const bot = shellBottom((k) => scratch[off + k], top, Math.max(0, top - MAX_STORE + 1));
          const len = top - bot + 1;
          const arr = new Uint8Array(len);
          for (let k = 0; k < len; k++) {
            const id = scratch[off + bot + k];
            arr[k] = id;
            if (id) idHist.set(id, (idHist.get(id) || 0) + 1);
          }
          const botMC = bot + MC_Y_MIN, topMC = top + MC_Y_MIN;
          if (botMC < yMinStored) yMinStored = botMC;
          if (topMC > yMaxStored) yMaxStored = topMC;

          const vcx = Math.floor(vx / 16), vcz = Math.floor(vz / 16);
          const key = vcx + ":" + vcz;
          let arr256 = cols.get(key);
          if (!arr256) { arr256 = new Array(256); cols.set(key, arr256); }
          arr256[(vz - vcz * 16) * 16 + (vx - vcx * 16)] = { b: botMC, a: arr };
          colsKept++;
        }
      }
    }
  }
  process.stdout.write(`\r  region row ${rz - s0 + 1}/${s1 - s0 + 1}`);
}
console.log("");

if (colsKept === 0) { console.error("nothing in that crop — wrong coordinates?"); process.exit(1); }

// ---- Y compaction ----
// Minecraft's 384-level column is taller than the budget a u8 y leaves us, and this
// map spends it badly: a low island near y=20, ordinary terrain around y=62, and a
// wool-and-sea-lantern SKY layer at y≈265 with 40 completely empty levels beneath it.
// Rather than clip a layer off (which silently deletes whole islands), squash the
// vertical bands that contain no blocks at all. Empty means invisible, so nothing is
// lost — the sky just hangs lower. This is a bake-time remap: the runtime never knows.
const GAP_MIN = 8;  // an empty band this tall or taller gets squashed...
const GAP_KEEP = 4; // ...down to this many levels
const occupied = new Uint8Array(MC_H);
for (const arr256 of cols.values()) {
  for (const c of arr256) {
    if (!c) continue;
    for (let k = 0; k < c.a.length; k++) if (c.a[k]) occupied[c.b + k - MC_Y_MIN] = 1;
  }
}
const keep = new Uint8Array(MC_H).fill(1);
{
  let y = 0;
  let squashedLevels = 0, bands = 0;
  while (y < MC_H) {
    if (occupied[y]) { y++; continue; }
    let e = y;
    while (e < MC_H && !occupied[e]) e++;
    const len = e - y;
    if (len >= GAP_MIN) {
      // keep GAP_KEEP/2 levels at each end so the two layers don't touch
      for (let k = GAP_KEEP / 2; k < len - GAP_KEEP / 2; k++) keep[y + k] = 0;
      squashedLevels += len - GAP_KEEP;
      bands++;
    }
    y = e;
  }
  if (bands) console.log(`Y compaction: ${bands} empty band(s) squashed, ${squashedLevels} levels removed`);
}
const outY = new Int32Array(MC_H);
{
  let n = 0;
  for (let i = 0; i < MC_H; i++) { outY[i] = n; if (keep[i]) n++; }
}
const remapY = (mcY) => outY[mcY - MC_Y_MIN];

// apply to every column (dropped levels are globally empty, so only air disappears)
yMinStored = 1e9; yMaxStored = -1e9;
for (const arr256 of cols.values()) {
  for (let ci = 0; ci < 256; ci++) {
    const c = arr256[ci];
    if (!c) continue;
    const out = [];
    let newB = -1;
    for (let k = 0; k < c.a.length; k++) {
      const y = c.b + k - MC_Y_MIN;
      if (!keep[y]) continue;
      if (newB < 0) newB = outY[y];
      out.push(c.a[k]);
    }
    if (newB < 0) { arr256[ci] = undefined; colsKept--; continue; }
    c.b = newB;
    c.a = Uint8Array.from(out);
    if (c.b < yMinStored) yMinStored = c.b;
    const t = c.b + c.a.length - 1;
    if (t > yMaxStored) yMaxStored = t;
  }
}
void remapY;

// ---- Y mapping ----
// Prefer losing NOTHING: the floor is the true minimum. Only if the compacted world
// still overflows the u8 y ceiling do we raise the floor to a percentile of column
// bottoms — and then say so loudly, because that clips real terrain.
let yCut = yMinStored;
let span = yMaxStored - yCut + 1;
let clipped = 0;
if (Y_FLOOR + span - 1 > Y_CEILING) {
  const bottoms = [];
  for (const arr256 of cols.values()) for (const c of arr256) if (c) bottoms.push(c.b);
  bottoms.sort((a, b) => a - b);
  const need = Y_FLOOR + span - 1 - Y_CEILING;
  yCut = Math.max(yCut + need, bottoms[Math.floor(bottoms.length * 0.005)]);
  span = yMaxStored - yCut + 1;
  clipped = bottoms.filter((b) => b < yCut).length;
  console.log(`! world still ${need} levels too tall — floor raised, ${clipped} columns clipped`);
}
const toVoxlY = (y) => y - yCut + Y_FLOOR;
console.log(`compacted levels ${yCut}..${yMaxStored} → Voxl y ${Y_FLOOR}..${toVoxlY(yMaxStored)} (${span} levels)`);
console.log(`columns: ${colsKept}   chunks: ${cols.size}`);

// ---- spawn point: solid, dry, flat, as central as the map allows ----
const GROUND = new Set([
  ID.Grass, ID.Dirt, ID.CoarseDirt, ID.Podzol, ID.MossBlock, ID.Sand, ID.Gravel,
  ID.Stone, ID.Andesite, ID.Diorite, ID.Granite, ID.Cobblestone, ID.MossyCobblestone,
  ID.StoneBricks, ID.MossyStoneBricks, ID.SmoothStone, ID.PolishedAndesite,
  ID.Sandstone, ID.Bricks, ID.Clay, ID.Snow,
  ID.OakPlanks, ID.SprucePlanks, ID.BirchPlanks, ID.JunglePlanks, ID.AcaciaPlanks, ID.DarkOakPlanks,
]);
function columnAt(vx, vz) {
  const vcx = Math.floor(vx / 16), vcz = Math.floor(vz / 16);
  const arr = cols.get(vcx + ":" + vcz);
  if (!arr) return null;
  return arr[(vz - vcz * 16) * 16 + (vx - vcx * 16)] || null;
}
function topOf(vx, vz) {
  const c = columnAt(vx, vz);
  if (!c) return null;
  return { y: c.b + c.a.length - 1, id: c.a[c.a.length - 1] };
}
let spawn = null;
outer:
for (let ring = 0; ring < R && !spawn; ring += 2) {
  const steps = Math.max(8, ring * 2);
  for (let i = 0; i < steps; i++) {
    const a = (i / steps) * Math.PI * 2;
    const vx = Math.round(Math.cos(a) * ring), vz = Math.round(Math.sin(a) * ring);
    const t = topOf(vx, vz);
    if (!t || !GROUND.has(t.id)) continue;
    let flat = true;
    for (const [dx, dz] of [[2, 0], [-2, 0], [0, 2], [0, -2], [2, 2], [-2, -2]]) {
      const n = topOf(vx + dx, vz + dz);
      if (!n || Math.abs(n.y - t.y) > 2 || !GROUND.has(n.id)) { flat = false; break; }
    }
    if (!flat) continue;
    spawn = { x: vx, z: vz, y: toVoxlY(t.y) };
    break outer;
  }
}
if (spawn) console.log(`spawn: Voxl block (${spawn.x}, ${spawn.y}, ${spawn.z})`);
else console.log("! no flat dry spawn found — the star will fall back to its own search");

// ---- pass 2: encode ----
const records = [];
const index = new Map();
let maxRuns = 0, totalRuns = 0;

for (let cz = cz0; cz <= cz1; cz++) {
  for (let cx = cx0; cx <= cx1; cx++) {
    const key = cx + ":" + cz;
    const arr256 = cols.get(key);
    if (!arr256) continue;
    const parts = [];
    for (let ci = 0; ci < 256; ci++) {
      const col = arr256[ci];
      if (!col) { parts.push(Buffer.from([0, 0])); continue; }
      let yBot = toVoxlY(col.b);
      let a = col.a;
      if (yBot < Y_FLOOR) { a = a.subarray(Y_FLOOR - yBot); yBot = Y_FLOOR; }
      const runs = [];
      let cur = -1, n = 0;
      for (let k = 0; k < a.length; k++) {
        if (a[k] === cur && n < 255) { n++; continue; }
        if (cur >= 0) runs.push(cur, n);
        cur = a[k]; n = 1;
      }
      if (cur >= 0) runs.push(cur, n);
      while (runs.length >= 2 && runs[runs.length - 2] === 0) runs.length -= 2; // trailing air is implicit
      // NOTE: leading air is NOT folded away. It looks like free compression, but
      // the runtime reads "below yBot" as solid island — folding would turn a cave
      // mouth or an overhang sitting at the world floor into a wall of stone.
      const nRuns = runs.length / 2;
      if (nRuns > 255) throw new Error("column needs >255 runs");
      if (nRuns > maxRuns) maxRuns = nRuns;
      totalRuns += nRuns;
      if (yBot > 255) throw new Error(`yBot ${yBot} exceeds u8`);
      parts.push(Buffer.from([nRuns === 0 ? 0 : yBot, nRuns, ...runs]));
    }
    const buf = Buffer.concat(parts);
    index.set(key, { off: 0, raw: buf.length, comp: 0 });
    records.push({ key, buf, comp: null });
  }
}
// Compress each record on its own. Per-chunk deflate lands within a few percent of
// compressing the whole blob (a chunk's 256 columns are highly self-similar), and
// it is what keeps chunks independently decodable — the server can forward one
// compressed record to a client without touching, or even decompressing, the rest.
let off = 0, rawTotal = 0;
for (const r of records) {
  const comp = zlib.deflateRawSync(r.buf, { level: 9 });
  const e = index.get(r.key);
  e.off = off;
  e.raw = r.buf.length;
  e.comp = comp.length;
  if (e.raw > 65535) throw new Error(`chunk record ${r.key} is ${e.raw} bytes, over the u16 rawLen`);
  r.comp = comp;
  rawTotal += r.buf.length;
  off += comp.length;
}
const recordsBuf = Buffer.concat(records.map((r) => r.comp));

const header = Buffer.alloc(16);
header.write("VXM3", 0, "ascii");
header.writeInt16BE(cx0, 4); header.writeInt16BE(cz0, 6);
header.writeUInt16BE(NX, 8); header.writeUInt16BE(NZ, 10);
header.writeUInt16BE(R, 12);
header.writeUInt8(Y_FLOOR, 14);
header.writeUInt8(0, 15);

const IDX_ENTRY = 10;
const idx = Buffer.alloc(NX * NZ * IDX_ENTRY);
for (let z = 0; z < NZ; z++) {
  for (let x = 0; x < NX; x++) {
    const e = index.get((cx0 + x) + ":" + (cz0 + z));
    const at = (x + z * NX) * IDX_ENTRY;
    idx.writeUInt32BE(e ? e.off : 0, at);
    idx.writeUInt32BE(e ? e.comp : 0, at + 4);
    idx.writeUInt16BE(e ? e.raw : 0, at + 8);
  }
}
const blob = Buffer.concat([header, idx, recordsBuf]);
const b64 = blob.toString("base64");

const kb = (n) => (n / 1024).toFixed(0) + " KB";
const avgComp = records.length ? recordsBuf.length / records.length : 0;
console.log(`\nrecords ${kb(rawTotal)} raw → ${kb(recordsBuf.length)} deflated (${((recordsBuf.length / rawTotal) * 100).toFixed(0)}%)`);
console.log(`blob ${kb(blob.length)} (index ${kb(idx.length)}) → base64 ${kb(b64.length)}`);
console.log(`per chunk on the wire: ${Math.round(avgComp)} B avg — a 17×17 view is ~${kb(avgComp * 289)}`);
console.log(`runs: ${totalRuns} total, ${(totalRuns / colsKept).toFixed(1)} avg/column, ${maxRuns} max`);

const byId = Object.fromEntries(Object.entries(ID).map(([k, v]) => [v, k]));
console.log("top blocks: " + [...idHist.entries()].sort((a, b) => b[1] - a[1]).slice(0, 14).map(([i, c]) => `${byId[i]}×${c}`).join(", "));
if (unknown.size) console.log(`unmapped MC names → air (${unknown.size}): ${[...unknown.keys()].slice(0, 25).join(", ")}`);

if (DRY) process.exit(0);

// ---- emit Luau ----
const dir = path.join(OUT, NAME);
fs.mkdirSync(dir, { recursive: true });
for (const f of fs.readdirSync(dir)) fs.unlinkSync(path.join(dir, f));

const PART = 200000;
const nParts = Math.ceil(b64.length / PART);
for (let i = 0; i < nParts; i++) {
  fs.writeFileSync(
    path.join(dir, `p${i + 1}.luau`),
    `-- GENERATED by tools/mcimport/bake.js — do not edit\nreturn [==[${b64.slice(i * PART, (i + 1) * PART)}]==]\n`
  );
}
const requires = Array.from({ length: nParts }, (_, i) => `\t\trequire(script.p${i + 1}),`).join("\n");
fs.writeFileSync(path.join(dir, "init.luau"),
  `--!strict\n` +
  `-- GENERATED by tools/mcimport/bake.js — do not edit by hand.\n` +
  `-- Baked Minecraft crop "${NAME}": MC centre (${CX}, ${CZ}), radius ${R} blocks,\n` +
  `-- MC y ${yCut}..${yMaxStored} → Voxl y ${Y_FLOOR}..${toVoxlY(yMaxStored)}.\n` +
  `--\n` +
  `-- SERVER-ONLY (ServerStorage): this never replicates to a client. The star server\n` +
  `-- forwards single deflated chunk records over Blink as players walk (doc 23), so\n` +
  `-- the lobby ships none of it and a star client only ever receives what it visits.\n` +
  `--\n` +
  `-- Base64 of a VXM3 blob (format documented in tools/mcimport/bake.js), split so no\n` +
  `-- single Luau source string is absurd.\n\n` +
  `return {\n` +
  `\tname = "${NAME}",\n` +
  `\tradius = ${R},\n` +
  `\tpartLen = ${PART},\n` +
  (spawn ? `\tspawn = { x = ${spawn.x}, y = ${spawn.y}, z = ${spawn.z} },\n` : "") +
  `\tparts = {\n${requires}\n\t},\n}\n`);

const total = fs.readdirSync(dir).reduce((a, f) => a + fs.statSync(path.join(dir, f)).size, 0);
console.log(`\nwrote ${nParts + 1} files → ${dir} (${kb(total)})`);
if (A.bin) { fs.writeFileSync(path.join(OUT, `${NAME}.bin`), blob); console.log(`wrote ${path.join(OUT, NAME + ".bin")}`); }
