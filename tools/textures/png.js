// A real PNG decoder/encoder — enough of the spec for texture files.
//
// tools/mcimport/png.js only WRITES the trivial case it needed (RGB, filter 0).
// Recolouring reads arbitrary PNGs from an art tool, so this handles every 8-bit
// colour type and all five scanline filters. Output is always RGBA, because
// stained glass has to keep its alpha.
//
// Not supported (and it says so rather than producing garbage): interlaced PNGs
// and 16-bit channels.

const zlib = require("zlib");

const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function crc32(buf) {
  let table = crc32.t;
  if (!table) {
    table = crc32.t = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

// → { width, height, rgba: Uint8Array(w*h*4) }
function decode(buf) {
  if (!buf.subarray(0, 8).equals(SIG)) throw new Error("not a PNG");
  let p = 8;
  let width = 0, height = 0, depth = 0, colorType = 0, interlace = 0;
  let palette = null, trns = null;
  const idat = [];

  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString("ascii", p + 4, p + 8);
    const data = buf.subarray(p + 8, p + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === "PLTE") palette = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    p += 12 + len;
  }

  if (depth !== 8) throw new Error(`${depth}-bit PNG not supported (need 8-bit)`);
  if (interlace) throw new Error("interlaced PNG not supported");

  const CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
  if (!CHANNELS) throw new Error(`unknown PNG colour type ${colorType}`);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * CHANNELS;
  const out = new Uint8Array(height * stride);

  // un-filter, scanline by scanline
  let src = 0;
  let prev = new Uint8Array(stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[src++];
    const line = raw.subarray(src, src + stride);
    src += stride;
    const cur = out.subarray(y * stride, (y + 1) * stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= CHANNELS ? cur[i - CHANNELS] : 0;
      const b = prev[i];
      const c = i >= CHANNELS ? prev[i - CHANNELS] : 0;
      const x = line[i];
      cur[i] =
        filter === 0 ? x
        : filter === 1 ? (x + a) & 0xff
        : filter === 2 ? (x + b) & 0xff
        : filter === 3 ? (x + ((a + b) >> 1)) & 0xff
        : filter === 4 ? (x + paeth(a, b, c)) & 0xff
        : (() => { throw new Error(`bad PNG filter ${filter}`); })();
    }
    prev = cur;
  }

  // → RGBA
  const rgba = new Uint8Array(width * height * 4);
  for (let i = 0, n = width * height; i < n; i++) {
    const s = i * CHANNELS, d = i * 4;
    if (colorType === 6) {
      rgba[d] = out[s]; rgba[d + 1] = out[s + 1]; rgba[d + 2] = out[s + 2]; rgba[d + 3] = out[s + 3];
    } else if (colorType === 2) {
      rgba[d] = out[s]; rgba[d + 1] = out[s + 1]; rgba[d + 2] = out[s + 2]; rgba[d + 3] = 255;
    } else if (colorType === 0) {
      rgba[d] = rgba[d + 1] = rgba[d + 2] = out[s]; rgba[d + 3] = 255;
    } else if (colorType === 4) {
      rgba[d] = rgba[d + 1] = rgba[d + 2] = out[s]; rgba[d + 3] = out[s + 1];
    } else if (colorType === 3) {
      const idx = out[s];
      rgba[d] = palette[idx * 3]; rgba[d + 1] = palette[idx * 3 + 1]; rgba[d + 2] = palette[idx * 3 + 2];
      rgba[d + 3] = trns && idx < trns.length ? trns[idx] : 255;
    }
  }
  return { width, height, rgba };
}

function chunk(type, data) {
  const out = Buffer.alloc(data.length + 12);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  Buffer.from(data).copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

// RGBA in, PNG out
function encode(width, height, rgba) {
  const stride = width * 4;
  const raw = Buffer.alloc(height * (stride + 1));
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // colour type: RGBA
  return Buffer.concat([
    SIG,
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

module.exports = { decode, encode };
