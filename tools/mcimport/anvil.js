// Anvil region reader (.mca) → per-chunk section block access.
// Region layout: 4KiB location table (1024 × [u24 sector offset, u8 sector count]),
// 4KiB timestamps, then chunk payloads at sector*4096 as [u32 length, u8 compression,
// data]. Compression: 1=gzip, 2=zlib, 3=raw, 4=LZ4 (unsupported here — vanilla
// singleplayer never writes it).

const fs = require("fs");
const zlib = require("zlib");
const { parse } = require("./nbt");

const SECTOR = 4096;

function readRegion(path) {
  const buf = fs.readFileSync(path);
  const chunks = new Array(1024).fill(null);
  if (buf.length < SECTOR * 2) return chunks;
  for (let i = 0; i < 1024; i++) {
    const off = (buf[i * 4] << 16) | (buf[i * 4 + 1] << 8) | buf[i * 4 + 2];
    const count = buf[i * 4 + 3];
    if (off === 0 || count === 0) continue;
    const at = off * SECTOR;
    if (at + 5 > buf.length) continue;
    const len = buf.readUInt32BE(at);
    const comp = buf[at + 4];
    const data = buf.subarray(at + 5, at + 4 + len);
    let raw;
    try {
      if (comp === 1) raw = zlib.gunzipSync(data);
      else if (comp === 2) raw = zlib.inflateSync(data);
      else if (comp === 3) raw = data;
      else throw new Error(`compression ${comp} unsupported`);
    } catch (e) {
      chunks[i] = { error: String(e.message || e) };
      continue;
    }
    try {
      chunks[i] = { nbt: parse(raw) };
    } catch (e) {
      chunks[i] = { error: String(e.message || e) };
    }
  }
  return chunks;
}

// Unpack a section's 4096 block-state indices. Post-1.16 packing: bits =
// max(4, ceil(log2(#palette))), entries never straddle a long, low bits first.
// Returns Uint16Array(4096) of palette indices, indexed y*256 + z*16 + x.
function unpackStates(longsBuf, paletteLen) {
  const out = new Uint16Array(4096);
  if (paletteLen <= 1 || !longsBuf || longsBuf.length === 0) return out; // uniform section
  let bits = 4;
  while ((1 << bits) < paletteLen) bits++;
  const perLong = Math.floor(64 / bits);
  const mask = (1 << bits) - 1;
  for (let i = 0; i < 4096; i++) {
    const li = (i / perLong) | 0;
    const bit = (i - li * perLong) * bits;
    const base = li * 8;
    if (base + 8 > longsBuf.length) break;
    // big-endian long → hi is the top 32 bits
    const hi = longsBuf.readUInt32BE(base);
    const lo = longsBuf.readUInt32BE(base + 4);
    let v;
    if (bit + bits <= 32) {
      v = (lo >>> bit) & mask;
    } else if (bit >= 32) {
      v = (hi >>> (bit - 32)) & mask;
    } else {
      const low = lo >>> bit;                 // bits available in lo
      const high = hi << (32 - bit);          // remainder from hi
      v = (low | high) & mask;
    }
    out[i] = v;
  }
  return out;
}

// Block-state properties worth carrying into the name. Almost every Minecraft
// property is irrelevant to us (facing, waterlogged, powered…), but a slab's
// `type` is the difference between a half block at the floor, one at the ceiling,
// and a full block — so it gets appended as "minecraft:oak_slab[type=top]".
// Keeping it in the NAME rather than a parallel structure means every consumer
// (histograms, renderers, the baker) keeps treating a palette entry as a string.
function decorate(name, props) {
  if (!props) return name;
  if (name.endsWith("_slab") && props.type) return `${name}[type=${props.type}]`;
  return name;
}

// A chunk's sections as { y, palette: [names], states: Uint16Array|null }.
// states === null means the whole section is palette[0] (usually air).
function chunkSections(nbt) {
  const secs = nbt.sections || nbt.Sections || [];
  const out = [];
  for (const s of secs) {
    const bs = s.block_states;
    if (!bs || !bs.palette) continue;
    const palette = bs.palette.map((e) =>
      typeof e === "string" ? e : decorate(e.Name, e.Properties)
    );
    const states = bs.data ? unpackStates(bs.data, palette.length) : null;
    out.push({ y: s.Y, palette, states });
  }
  return out;
}

module.exports = { readRegion, chunkSections, unpackStates };
