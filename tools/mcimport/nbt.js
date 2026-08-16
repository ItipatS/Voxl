// Minimal NBT reader (Java Edition, big-endian) — no dependencies.
// Enough to read Anvil chunk NBT: every tag type, LongArray kept as raw bytes
// so block_states.data can be unpacked without BigInt churn.

const TAG = {
  END: 0, BYTE: 1, SHORT: 2, INT: 3, LONG: 4, FLOAT: 5, DOUBLE: 6,
  BYTE_ARRAY: 7, STRING: 8, LIST: 9, COMPOUND: 10, INT_ARRAY: 11, LONG_ARRAY: 12,
};

class Reader {
  constructor(buf) {
    this.b = buf;
    this.p = 0;
  }
  u8() { return this.b[this.p++]; }
  i8() { const v = this.b.readInt8(this.p); this.p += 1; return v; }
  i16() { const v = this.b.readInt16BE(this.p); this.p += 2; return v; }
  i32() { const v = this.b.readInt32BE(this.p); this.p += 4; return v; }
  i64() { const v = this.b.readBigInt64BE(this.p); this.p += 8; return v; }
  f32() { const v = this.b.readFloatBE(this.p); this.p += 4; return v; }
  f64() { const v = this.b.readDoubleBE(this.p); this.p += 8; return v; }
  str() {
    const n = this.b.readUInt16BE(this.p); this.p += 2;
    const s = this.b.toString("utf8", this.p, this.p + n);
    this.p += n;
    return s;
  }
  payload(type) {
    switch (type) {
      case TAG.BYTE: return this.i8();
      case TAG.SHORT: return this.i16();
      case TAG.INT: return this.i32();
      case TAG.LONG: return this.i64();
      case TAG.FLOAT: return this.f32();
      case TAG.DOUBLE: return this.f64();
      case TAG.BYTE_ARRAY: {
        const n = this.i32();
        const v = this.b.subarray(this.p, this.p + n);
        this.p += n;
        return v;
      }
      case TAG.STRING: return this.str();
      case TAG.LIST: {
        const et = this.u8();
        const n = this.i32();
        const out = new Array(n < 0 ? 0 : n);
        for (let i = 0; i < n; i++) out[i] = this.payload(et);
        out._elemType = et;
        return out;
      }
      case TAG.COMPOUND: {
        const out = {};
        for (;;) {
          const t = this.u8();
          if (t === TAG.END) break;
          const name = this.str();
          out[name] = this.payload(t);
        }
        return out;
      }
      case TAG.INT_ARRAY: {
        const n = this.i32();
        const v = new Int32Array(n);
        for (let i = 0; i < n; i++) { v[i] = this.b.readInt32BE(this.p); this.p += 4; }
        return v;
      }
      case TAG.LONG_ARRAY: {
        // Kept as a raw big-endian byte view: 8 bytes per long. Unpacking block
        // indices from BigInt is ~10x slower than reading two u32 halves.
        const n = this.i32();
        const v = this.b.subarray(this.p, this.p + n * 8);
        this.p += n * 8;
        v._longs = n;
        return v;
      }
      default: throw new Error(`bad NBT tag ${type} at ${this.p}`);
    }
  }
}

// Parse a whole NBT document (root is an unnamed/named compound).
function parse(buf) {
  const r = new Reader(buf);
  const t = r.u8();
  if (t !== TAG.COMPOUND) throw new Error(`NBT root is tag ${t}, expected compound`);
  r.str(); // root name (usually "")
  return r.payload(TAG.COMPOUND);
}

module.exports = { parse, TAG };
