// Box-downscale a PNG written by png.js (RGB8, filter 0, single IDAT) so a huge
// survey render can be eyeballed. usage: node shrink.js in.png out.png maxDim
const fs = require("fs");
const zlib = require("zlib");
const png = require("./png");

function decode(buf) {
  let p = 8, w = 0, h = 0, idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString("ascii", p + 4, p + 8);
    const data = buf.subarray(p + 8, p + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); }
    else if (type === "IDAT") idat.push(data);
    p += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const rgb = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    const off = y * (w * 3 + 1);
    if (raw[off] !== 0) throw new Error("only filter 0 supported");
    raw.copy(rgb, y * w * 3, off + 1, off + 1 + w * 3);
  }
  return { w, h, rgb };
}

const [inF, outF, maxDim] = [process.argv[2], process.argv[3], Number(process.argv[4] || 1000)];
const { w, h, rgb } = decode(fs.readFileSync(inF));
const f = Math.max(1, Math.ceil(Math.max(w, h) / maxDim));
const W = Math.ceil(w / f), H = Math.ceil(h / f);
const out = new Uint8Array(W * H * 3);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    let r = 0, g = 0, b = 0, n = 0;
    for (let dy = 0; dy < f; dy++) {
      const sy = y * f + dy;
      if (sy >= h) break;
      for (let dx = 0; dx < f; dx++) {
        const sx = x * f + dx;
        if (sx >= w) break;
        const i = (sx + sy * w) * 3;
        r += rgb[i]; g += rgb[i + 1]; b += rgb[i + 2]; n++;
      }
    }
    const o = (x + y * W) * 3;
    out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n;
  }
}
fs.writeFileSync(outF, png.encode(W, H, out));
console.log(`${w}×${h} → ${W}×${H} (÷${f})  ${outF}`);
