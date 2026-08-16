// Generate the dyed colour variants from one base texture per family.
//
// Wool, terracotta, concrete and stained glass are 16 colours each — 64 textures
// that are the same image in different colours. Painting all 64 by hand is silly,
// and tinting at RUNTIME is worse: the greedy mesher pools textures by image, so a
// per-block tint would have to be threaded through the mesher, the hotbar preview
// and the block preview. Generating real PNGs costs zero runtime code.
//
// The tint is luminance-based, normalised so the OUTPUT'S MEAN COLOUR EQUALS THE
// BLOCK'S DECLARED COLOUR in Blocks.luau. That keeps a block's texture and its
// flat-colour fallback in agreement — the same block whether or not the texture
// has loaded — and it works on a base with its own hue (plain terracotta is
// orange-brown; using luminance strips that before recolouring).
//
// usage:
//   node tools/textures/tint.js --src <folder> --out <folder> [--sheet <png>]

const fs = require("fs");
const path = require("path");
const png = require("./png");
const { DYES, TERRACOTTA } = require("../mcimport/blockmap");

const A = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith("--")) A[a.slice(2)] = process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[++i] : true;
}
const SRC = A.src, OUT = A.out;
if (!SRC || !OUT) {
  console.error("usage: node tint.js --src <folder> --out <folder> [--sheet <png>]");
  process.exit(1);
}

// family → { base filename, Voxl block prefix, colour table }
const FAMILIES = [
  { base: "wool_white.png", prefix: "Wool", colours: DYES },
  { base: "concrete.png", prefix: "Concrete", colours: DYES },
  { base: "glass.png", prefix: "Glass", colours: DYES },
  { base: "terracotta.png", prefix: "Terracotta", colours: TERRACOTTA },
];

function findBase(name) {
  // look in the folder and any immediate subfolder (uploaded/ unuploaded/ …)
  const direct = path.join(SRC, name);
  if (fs.existsSync(direct)) return direct;
  for (const d of fs.readdirSync(SRC, { withFileTypes: true })) {
    if (!d.isDirectory()) continue;
    const p = path.join(SRC, d.name, name);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

// Recolour, preserving alpha and relative brightness.
function tint(img, [tr, tg, tb]) {
  const { width, height, rgba } = img;
  const n = width * height;

  // mean luminance over the pixels that are actually visible — for glass that's
  // just the frame, and averaging in the transparent middle would skew it dark
  let sum = 0, count = 0;
  const lum = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const l = 0.2126 * rgba[i * 4] + 0.7152 * rgba[i * 4 + 1] + 0.0722 * rgba[i * 4 + 2];
    lum[i] = l;
    if (rgba[i * 4 + 3] > 0) { sum += l; count++; }
  }
  const mean = count ? sum / count : 128;

  const out = new Uint8Array(n * 4);
  for (let i = 0; i < n; i++) {
    const k = mean > 0 ? lum[i] / mean : 1;
    out[i * 4] = Math.max(0, Math.min(255, Math.round(tr * k)));
    out[i * 4 + 1] = Math.max(0, Math.min(255, Math.round(tg * k)));
    out[i * 4 + 2] = Math.max(0, Math.min(255, Math.round(tb * k)));
    out[i * 4 + 3] = rgba[i * 4 + 3];
  }
  return { width, height, rgba: out };
}

fs.mkdirSync(OUT, { recursive: true });
const made = [];
const sheetCells = [];

for (const fam of FAMILIES) {
  const basePath = findBase(fam.base);
  if (!basePath) {
    console.log(`! ${fam.prefix}: base "${fam.base}" not found under ${SRC} — skipped`);
    continue;
  }
  const img = png.decode(fs.readFileSync(basePath));
  console.log(`${fam.prefix}: ${path.basename(basePath)} ${img.width}×${img.height}`);
  for (const [dye, rgb] of Object.entries(fam.colours)) {
    const tinted = tint(img, rgb);
    const file = `${fam.prefix}_${dye}.png`;
    fs.writeFileSync(path.join(OUT, file), png.encode(tinted.width, tinted.height, tinted.rgba));
    made.push(file);
    sheetCells.push({ label: `${fam.prefix}_${dye}`, img: tinted });
  }
}

console.log(`\nwrote ${made.length} textures → ${OUT}`);

// ---- contact sheet, so the colours can be judged by eye rather than by number ----
if (A.sheet && sheetCells.length) {
  const CELL = 64, COLS = 16;
  const rows = Math.ceil(sheetCells.length / COLS);
  const W = COLS * CELL, H = rows * CELL;
  const sheet = new Uint8Array(W * H * 4);
  // checkerboard, so transparency is visible
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const v = ((x >> 3) + (y >> 3)) & 1 ? 90 : 130;
      const d = (x + y * W) * 4;
      sheet[d] = sheet[d + 1] = sheet[d + 2] = v;
      sheet[d + 3] = 255;
    }
  }
  sheetCells.forEach((cell, i) => {
    const cx = (i % COLS) * CELL, cy = Math.floor(i / COLS) * CELL;
    const { width, height, rgba } = cell.img;
    for (let y = 0; y < CELL; y++) {
      for (let x = 0; x < CELL; x++) {
        const sx = Math.floor((x / CELL) * width), sy = Math.floor((y / CELL) * height);
        const s = (sx + sy * width) * 4, d = (cx + x + (cy + y) * W) * 4;
        const a = rgba[s + 3] / 255;
        sheet[d] = Math.round(rgba[s] * a + sheet[d] * (1 - a));
        sheet[d + 1] = Math.round(rgba[s + 1] * a + sheet[d + 1] * (1 - a));
        sheet[d + 2] = Math.round(rgba[s + 2] * a + sheet[d + 2] * (1 - a));
      }
    }
  });
  fs.writeFileSync(A.sheet, png.encode(W, H, sheet));
  console.log(`wrote ${A.sheet} — ${COLS} colours per row, one row per family`);
}
