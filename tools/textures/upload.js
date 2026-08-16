// Upload block textures to Roblox and generate the block → texture table.
//
// WHY THIS UPLOADS RATHER THAN FETCHES
// ------------------------------------
// Open Cloud has no endpoint that LISTS the assets you own — it can create an
// asset, read one by id, and version one, but there is no "give me everything I
// uploaded". So "fetch all my block ids" isn't a thing you can ask for. What you
// CAN do is own the mapping from the start: upload each file from here, keep the
// id the upload hands back, and never type an id by hand again.
//
// DECAL IDS
// ---------
// An upload returns a DECAL id, and `rbxassetid://<decalId>` resolves fine for
// assets you uploaded yourself — which is every texture here. So that's what gets
// written. `--resolve-image-id` digs out the underlying IMAGE id instead (two extra
// requests per file); you only need it if these textures will be used by an account
// that doesn't own them.
//
// usage:
//   put the key in tools/textures/.env (gitignored) or $ROBLOX_API_KEY, then
//   node tools/textures/upload.js --dir <textureFolder> --user <userId> [options]
//
// options:
//   --group <id>         upload as a group instead of a user
//   --out <path>         generated Luau module (default src/Misc/BlockTextures.luau)
//   --manifest <path>    hash → id cache (default tools/textures/manifest.json)
//   --dry                resolve and report, upload nothing
//   --limit <n>          stop after n uploads (useful for a first trial run)
//   --resolve-image-id   also resolve decal → image id (cross-account use only)

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { ID } = require("../mcimport/voxlids");
const { resolveName, FACE_FROM } = require("./resolve");

const A = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith("--")) A[a.slice(2)] = process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[++i] : true;
}
const DIR = A.dir;
let USER = A.user, GROUP = A.group;
const OUT = A.out || "src/Misc/BlockTextures.luau";
const MANIFEST = A.manifest || path.join(__dirname, "manifest.json");
const DRY = !!A.dry;
const LIMIT = A.limit ? +A.limit : Infinity;
const RESOLVE_IMAGE_ID = !!A["resolve-image-id"];

// The key can live in the environment or in a gitignored .env next to this tool
// (or at the repo root). A file is the friendlier home: it survives closing the
// terminal, and it can't end up in shell history.
function loadEnvKey() {
  if (process.env.ROBLOX_API_KEY) return process.env.ROBLOX_API_KEY.trim();
  for (const p of [path.join(__dirname, ".env"), path.join(process.cwd(), ".env")]) {
    if (!fs.existsSync(p)) continue;
    for (const line of fs.readFileSync(p, "utf8").split(/\r?\n/)) {
      const m = line.match(/^\s*(?:export\s+)?ROBLOX_API_KEY\s*=\s*(.*)$/);
      if (m) {
        const v = m[1].trim().replace(/^["']|["']$/g, "");
        if (v) {
          console.log(`using ROBLOX_API_KEY from ${path.relative(process.cwd(), p)}`);
          return v;
        }
      }
    }
  }
  return null;
}
const KEY = loadEnvKey();

// --user may also live in .env, so the command line stays short.
function envUserId() {
  for (const p of [path.join(__dirname, ".env"), path.join(process.cwd(), ".env")]) {
    if (!fs.existsSync(p)) continue;
    const m = fs.readFileSync(p, "utf8").match(/^\s*(?:export\s+)?ROBLOX_USER_ID\s*=\s*(\d+)/m);
    if (m) return m[1];
  }
  return undefined;
}

if (USER === undefined && GROUP === undefined) USER = envUserId();

if (!DIR) {
  console.error("usage: node upload.js --dir <folder> --user <userId> [--group <id>] [--dry]");
  process.exit(1);
}
// A flag given without a value parses as boolean true. Sending that as a creator
// id is a 400 on every single file, so refuse it here with a legible message.
for (const [flag, v] of [["--user", USER], ["--group", GROUP]]) {
  if (v !== undefined && !/^\d+$/.test(String(v))) {
    console.error(`${flag} needs a numeric id (got ${v === true ? "no value" : v}).`);
    process.exit(1);
  }
}
if (!DRY && !USER && !GROUP) {
  console.error(
    "Need --user <yourRobloxUserId> (or --group <id>).\n\n" +
    "Your user id is the number in your profile URL:\n" +
    "  https://www.roblox.com/users/<THIS NUMBER>/profile\n\n" +
    "Or add it to tools/textures/.env:\n" +
    "  ROBLOX_USER_ID=1234567"
  );
  process.exit(1);
}
if (!DRY && !KEY) {
  console.error(
    "No API key found.\n\n" +
    "Put it in a file (easiest — it's gitignored, and stays put):\n" +
    `  ${path.join("tools", "textures", ".env")}\n` +
    "    ROBLOX_API_KEY=your-key-here\n\n" +
    "…or in the environment for this shell only:\n" +
    '  PowerShell:  $env:ROBLOX_API_KEY = "your-key-here"\n' +
    '  bash:        export ROBLOX_API_KEY="your-key-here"\n\n' +
    "Create one at https://create.roblox.com/dashboard/credentials with the\n" +
    "Assets API enabled (read + write). Never commit it or paste it into chat."
  );
  process.exit(1);
}

const API = "https://apis.roblox.com";

// ---------- scan ----------
// `--dir` may be a comma-separated list, so an "uploaded" and an "unuploaded"
// folder can be processed as one set (the manifest decides what actually uploads).
const DIRS = String(DIR).split(",").map((d) => d.trim()).filter(Boolean);
const files = [];
for (const d of DIRS) {
  for (const f of fs.readdirSync(d)) {
    if (/\.(png|jpg|jpeg)$/i.test(f)) files.push({ name: f, dir: d });
  }
}

const resolved = [];
const unmatched = [];
const rejected = [];
for (const { name, dir } of files) {
  const base = name.replace(/\.(png|jpg|jpeg)$/i, "");
  const r = resolveName(base);
  if (!r) { unmatched.push(name); continue; }
  if (!r.block) { rejected.push(name); continue; }
  const full = path.join(dir, name);
  const buf = fs.readFileSync(full);
  resolved.push({
    file: name, full, block: r.block, face: r.face, how: r.how,
    hash: crypto.createHash("sha256").update(buf).digest("hex"), bytes: buf.length,
  });
}

console.log(`${files.length} image(s) across ${DIRS.length} folder(s)`);
console.log(`  matched a block: ${resolved.length}`);
const fuzzyOnes = resolved.filter((r) => r.how.startsWith("fuzzy"));
if (fuzzyOnes.length) {
  console.log(`  FUZZY (${fuzzyOnes.length}) — matched by spelling distance, check these:`);
  for (const r of fuzzyOnes) console.log(`    ${r.file.padEnd(28)} → ${r.block} (${r.face}) [${r.how}]`);
}
if (rejected.length) {
  console.log(`  NOT A BLOCK (${rejected.length}) — skipped on purpose: ${rejected.join(", ")}`);
}
if (unmatched.length) {
  console.log(`  UNMATCHED (${unmatched.length}) — need naming, nothing will be uploaded for them:`);
  for (const f of unmatched) console.log(`    ${f}`);
}

const blocks = new Map();
for (const r of resolved) {
  if (!blocks.has(r.block)) blocks.set(r.block, {});
  blocks.get(r.block)[r.face] = r;
}
console.log(`  covering ${blocks.size} distinct blocks`);

// dedupe by content: the same PNG reused by several blocks uploads once
const byHash = new Map();
for (const r of resolved) if (!byHash.has(r.hash)) byHash.set(r.hash, r);
console.log(`  ${byHash.size} unique image(s) to upload (after de-duplicating identical files)`);

// ---------- manifest (hash → image id) ----------
let manifest = {};
if (fs.existsSync(MANIFEST)) manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));

// Ids for textures uploaded by hand, outside the tool. They win over the manifest,
// and their files are not re-uploaded.
const KNOWN_FILE = A.known || path.join(__dirname, "known.json");
let known = {};
if (fs.existsSync(KNOWN_FILE)) {
  known = JSON.parse(fs.readFileSync(KNOWN_FILE, "utf8"));
  for (const k of Object.keys(known)) if (k.startsWith("_")) delete known[k]; // notes
  const n = Object.keys(known).length;
  if (n) console.log(`  ${n} block(s) have hand-entered ids in ${path.basename(KNOWN_FILE)}`);
}
const knownId = (block, face) => {
  const e = known[block];
  if (!e) return null;
  return e[face] || e.all || null;
};
const cached = [...byHash.keys()].filter((h) => manifest[h]).length;
const handEntered = [...byHash.values()].filter((e) => !manifest[e.hash] && knownId(e.block, e.face)).length;
const todo = byHash.size - cached - handEntered;
console.log(`  ${cached} cached in ${path.relative(process.cwd(), MANIFEST)}, ${handEntered} already uploaded by hand, ${todo} to upload`);

if (DRY) {
  console.log("\n--dry: nothing uploaded. Resolved mapping:");
  for (const [block, faces] of [...blocks.entries()].sort()) {
    console.log(`  ${block.padEnd(24)} ${Object.entries(faces).map(([f, r]) => `${f}=${r.file}`).join(" ")}`);
  }
  process.exit(0);
}

// ---------- Open Cloud ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function apiFetch(url, init = {}, tries = 5) {
  for (let attempt = 1; ; attempt++) {
    const res = await fetch(url, { ...init, headers: { "x-api-key": KEY, ...(init.headers || {}) } });
    if (res.status === 429 || res.status >= 500) {
      if (attempt >= tries) throw new Error(`${url} → ${res.status} after ${tries} tries`);
      const wait = Math.min(30000, 1000 * 2 ** attempt);
      console.log(`    ${res.status}, backing off ${wait / 1000}s`);
      await sleep(wait);
      continue;
    }
    if (!res.ok) throw new Error(`${url} → ${res.status} ${await res.text()}`);
    return res;
  }
}

async function uploadImage(entry) {
  const form = new FormData();
  form.append("request", JSON.stringify({
    assetType: "Decal", // the Open Cloud value for a 2D image
    displayName: `voxl_${entry.block}_${entry.face}`,
    description: `Voxl block texture (${entry.file})`,
    creationContext: { creator: GROUP ? { groupId: String(GROUP) } : { userId: String(USER) } },
  }));
  form.append("fileContent", new Blob([fs.readFileSync(entry.full)], { type: "image/png" }), entry.file);

  const res = await apiFetch(`${API}/assets/v1/assets`, { method: "POST", body: form });
  const op = await res.json();
  const opId = String(op.path || op.operationId || "").replace(/^operations\//, "");
  if (!opId) throw new Error(`no operation id in response: ${JSON.stringify(op)}`);

  // Poll. Moderation can take a moment; the id exists as soon as done is true.
  for (let i = 0; i < 60; i++) {
    await sleep(i < 5 ? 1000 : 3000);
    const r = await apiFetch(`${API}/assets/v1/operations/${opId}`);
    const body = await r.json();
    if (body.done) {
      if (body.error) throw new Error(`upload failed: ${JSON.stringify(body.error)}`);
      const id = body.response && (body.response.assetId || body.response.id);
      if (!id) throw new Error(`operation done but no assetId: ${JSON.stringify(body)}`);
      return String(id);
    }
  }
  throw new Error("operation never completed");
}

// Dig the underlying IMAGE id out of a decal (the decal is a tiny XML document
// pointing at it). Only needed when an account that doesn't own the asset will use
// it — for your own uploads the decal id resolves fine on its own.
async function imageIdOf(decalId) {
  try {
    const r = await apiFetch(`${API}/asset-delivery-api/v1/assetId/${decalId}`);
    const meta = await r.json();
    const loc = meta.location || (meta.locations && meta.locations[0] && meta.locations[0].location);
    if (!loc) return null;
    const xml = await (await fetch(loc)).text();
    const m = xml.match(/id=(\d+)/);
    return m ? m[1] : null;
  } catch (e) {
    console.log(`    could not resolve image id for decal ${decalId}: ${e.message}`);
    return null;
  }
}

(async () => {
  let done = 0, failed = 0, attempts = 0, consecutiveFailures = 0;
  for (const [hash, entry] of byHash) {
    if (manifest[hash]) continue;
    if (knownId(entry.block, entry.face)) continue; // already uploaded by hand
    // Count ATTEMPTS, not successes: a run where everything fails must still stop.
    if (attempts >= LIMIT) { console.log(`\nstopping at --limit ${LIMIT}`); break; }
    // And a misconfiguration should not hammer the API 100 times with one error.
    if (consecutiveFailures >= 3) {
      console.log("\n3 failures in a row - stopping. Fix the error above and re-run;");
      console.log("anything already uploaded is in the manifest and will not repeat.");
      break;
    }
    attempts++;
    process.stdout.write(`  uploading ${entry.file} … `);
    try {
      const decalId = await uploadImage(entry);
      const imageId = RESOLVE_IMAGE_ID ? await imageIdOf(decalId) : null;
      manifest[hash] = {
        decalId,
        imageId,
        file: entry.file,
        block: entry.block,
        face: entry.face,
      };
      fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2)); // save as we go
      console.log(`${decalId}${imageId ? ` (image ${imageId})` : ""}`);
      done++;
      consecutiveFailures = 0;
    } catch (e) {
      failed++;
      consecutiveFailures++;
      console.log(`FAILED: ${e.message}`);
    }
  }
  console.log(`\nuploaded ${done}, failed ${failed}, ${Object.keys(manifest).length} in the manifest`);
  writeLuau();
})();

// ---------- generated Luau ----------
function writeLuau() {
  const rows = [];
  for (const block of Object.keys(FACE_FROM)) {
    if (!blocks.has(block)) blocks.set(block, {});
  }
  for (const block of Object.keys(known)) {
    if (!blocks.has(block)) blocks.set(block, {});
  }

  const idOf = (r) => {
    const m = r && manifest[r.hash];
    return m ? (m.imageId || m.decalId) : null;
  };
  // A face may be borrowed from another block — Minecraft does this for bookshelves
  // (planks top and bottom), hay bales and pumpkins.
  const borrow = (block, face) => {
    const from = FACE_FROM[block] && FACE_FROM[block][face];
    if (!from) return null;
    // The donor may itself be hand-entered rather than uploaded, so check
    // known.json too — otherwise borrowing from a known-id block silently fails.
    const donor = blocks.get(from) || {};
    return knownId(from, face) || knownId(from, "all")
      || idOf(donor[face]) || idOf(donor.all) || idOf(donor.top) || idOf(donor.side);
  };

  for (const [block, faces] of [...blocks.entries()].sort()) {
    const all = knownId(block, "all") || idOf(faces.all);
    const top = knownId(block, "top") || borrow(block, "top") || idOf(faces.top) || all;
    const side = knownId(block, "side") || borrow(block, "side") || idOf(faces.side) || all;
    const bottom = knownId(block, "bottom") || borrow(block, "bottom") || idOf(faces.bottom) || top || all;
    if (!top && !side && !bottom) continue;
    const asset = (v) => (v ? `"rbxassetid://${v}"` : "nil");
    rows.push(`\t${block} = { top = ${asset(top)}, side = ${asset(side)}, bottom = ${asset(bottom)} },`);
  }

  const src = `--!strict
-- GENERATED by tools/textures/upload.js — do not edit by hand.
-- Block name -> per-face texture asset ids. Blocks.luau applies this over its
-- defs, so a block with no entry here simply stays flat-coloured. Re-run the
-- uploader after adding texture files; ids already in the manifest are reused,
-- so it only ever uploads what's new.

return {
${rows.join("\n")}
}
`;
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, src);
  console.log(`wrote ${OUT} — ${rows.length} block(s) textured`);
}
