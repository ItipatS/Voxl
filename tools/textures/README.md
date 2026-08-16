# textures — upload block textures, generate the id table

## API key or OAuth 2.0?

**API key.** Not a close call:

| | API key | OAuth 2.0 |
|---|---|---|
| who it acts as | **you** | *another user*, who clicks "allow" on a consent screen |
| built for | scripts, CI, tools you run yourself | third-party apps with users of their own |
| setup | make a key, paste it in an env var | register an app, host a redirect URL, handle a token exchange + refresh |

This is a script you run on your own machine against your own account. That's the
API-key case exactly. OAuth exists so *someone else's* app can act on *your*
behalf without you handing over credentials — irrelevant here, and it would mean
standing up a web server just to publish a PNG.

### Making the key

1. <https://create.roblox.com/dashboard/credentials> → **API Keys** → **Create API Key**
2. Name it (e.g. `voxl-textures`)
3. **Access Permissions** → add the **Assets** API
   - Operations: **read** and **write**
   - Pick your user (or the group, if the textures should be group-owned)
4. Leave the IP allowlist **empty** unless you have a static IP — a wrong entry
   here is the usual cause of a mystifying 403
5. Set an expiry, create, and **copy the key immediately** — it's shown once

### Where to paste it

Easiest, and it survives closing the terminal:

```bash
cp tools/textures/.env.example tools/textures/.env
# then edit that file:  ROBLOX_API_KEY=your-key-here
```

`.env` is gitignored (verified), so it can't be committed. Or, for one shell session:

```powershell
$env:ROBLOX_API_KEY = "your-key-here"     # PowerShell
```
```bash
export ROBLOX_API_KEY="your-key-here"     # bash / git-bash
```

The env var wins if both are set. Never commit the key, put it in a Luau file, or
paste it into chat — `manifest.json` (the id cache) *is* worth committing; the key
is not.

## The thing that makes "fetch all my block ids" impossible

Open Cloud's Assets API can **create** an asset, **read one by id**, and version
it. There is **no endpoint that lists the assets you own.** So you can't ask
Roblox "what did I upload?" — that question has no answer over Open Cloud.

The way out is to stop asking: **upload from here**, and keep the id the upload
returns. You never type an id, because the tool wrote it down at the moment it
existed. That is also why re-runs are cheap — `manifest.json` maps file content →
asset id, so only genuinely new images are uploaded.

### Already uploaded something by hand?

Put the id in **`known.json`**, keyed by block and face:

```json
{ "IronOre": { "all": "74691325001194" },
  "Grass":   { "top": "99956800911799", "side": "108714877040603" } }
```

Entries there win over everything, and a file whose block+face is covered is **not
re-uploaded** — which is the point: it's how you stop the tool duplicating assets
you already own.

### Where a texture id can come from

Three places, in order of precedence:

| | source | for |
|---|---|---|
| 1 | `known.json` | ids you uploaded by hand |
| 2 | `manifest.json` | ids this tool uploaded (keyed by file hash) |
| 3 | `TEX` in `Blocks.luau` | the handful predating all of this |

1 and 2 both feed the generated `BlockTextures`, which is applied **over** the defs
— so for any block that has a texture file, `TEX` is dead weight. Keep `TEX` only
for ids with no source file, and prefer `known.json` for anything new: it's
machine-readable, so the uploader can act on it.

## Decal ids

Uploading an image returns a **decal** id, and `rbxassetid://<decalId>` resolves
fine for assets **you** uploaded — which is every texture here. So that's what gets
written, and there's nothing to work around.

The caveat only bites across accounts: a decal id used by someone who doesn't own
it can fail to resolve. If that ever applies, `--resolve-image-id` digs the
underlying **image** id out of the decal instead (two extra requests per file). You
almost certainly don't need it.

## What still needs a texture

```bash
node tools/textures/names.js > /tmp/names.json
lune run tools/textures/coverage.luau /tmp/names.json
```

Reads the real `Blocks.luau` and writes **`WANTED.md`** — every block that's still
flat colour, with the filename to make and the Minecraft name that would also
resolve to it. Re-run after uploading to watch the list shrink.

Slabs don't appear: they inherit their material's texture, so texturing `Quartz`
also textures `Slab_Quartz` and `SlabTop_Quartz`.

## Usage

```bash
node tools/textures/upload.js --dir ./my-textures --user <id> --dry     # look first
node tools/textures/upload.js --dir ./my-textures --user <id> --limit 3 # trial
node tools/textures/upload.js --dir ./my-textures --user <id>           # the rest

# --dir takes a comma-separated list, so several folders process as one set
node tools/textures/upload.js --dir ./uploaded,./unuploaded --user <id>
```

`--dry` resolves every filename and prints the mapping without touching the
network. **Always run it first** — you'd rather find a mis-name before uploading
200 images than after.

### Filenames

Names don't have to be tidy. Matching runs in four passes of decreasing
confidence, and the report says which one hit:

| pass | example |
|---|---|
| `exact` | `oak_planks.png`, `OakPlanks.png`, `coarseDirt.png` |
| `alias` | `moss.png` → MossBlock, `iron.png` → IronBlock, `oakplank.png` |
| `fuzzy` | `neterBricks.png`, `chiseledQurtz.png`, `polishedAndisite.png` (≤2 edits) |
| — | unmatched; listed so you can rename it |

Everything is lowercased with punctuation stripped first, and a trailing digit is
treated as a duplicate marker (`stone1`, `diamond (2)`). Faces come from a trailing
`top` / `side` / `bottom` / `face` / `end`; no suffix means all faces.

**Check the `fuzzy` list every run.** It is the pass that can be confidently wrong.

Minecraft names go through the same `blockmap.js` the world importer uses, so a
resource pack drops straight in.

### Faces borrowed from other blocks

Minecraft reuses textures across blocks — a bookshelf is planks top and bottom, a
grass block is plain dirt underneath. `FACE_FROM` in `resolve.js` encodes that; add
to it rather than making duplicate image files. A block with a `top` and a `side`
but no `bottom` defaults its bottom to the **top** (log end grain), not the side.

Output: **`src/Misc/BlockTextures.luau`** — generated, block name → per-face asset
ids. `Blocks.luau` applies it over its defs *before* slabs clone their parents, so
slabs inherit their material's texture automatically. A block with no entry keeps
its flat colour.

This is **purely additive**: textures are appearance, and baked map data stores
block *ids*, so adding textures never needs a re-bake and never changes an id.

## Notes

- Fresh uploads are **moderation-pending** for a few minutes and may render blank
  until approved. That's Roblox, not the tool.
- Asset creation is rate-limited; the tool backs off on 429/5xx and saves the
  manifest after every success, so an interrupted run resumes where it stopped.
- `--group <id>` uploads as a group instead of a user. Match this to whatever the
  API key was scoped to, or you'll get a 403.

## Dyed families: generate, don't paint

Wool, terracotta, concrete and stained glass are 16 colours each — 64 textures that
are one image in different colours.

```bash
node tools/textures/tint.js --src <textureRoot> --out <textureRoot>/generated \
     --sheet /tmp/sheet.png
```

It looks for one base per family (`wool_white.png`, `concrete.png`, `glass.png`,
`terracotta.png`, in the folder or any immediate subfolder) and writes all 64.
`--sheet` renders a contact sheet on a checkerboard so the colours — and the
transparency — can be judged by eye.

The tint is luminance-based and normalised so **the output's mean colour equals the
block's declared colour in `Blocks.luau`**. A block therefore looks the same whether
or not its texture has loaded, and it works on a base with its own hue (plain
terracotta is orange-brown; luminance strips that before recolouring).

Then upload with the generated folder **last**, so it wins any name collision:

```bash
node tools/textures/upload.js --dir <root>/uploaded,<root>/unuploaded,<root>/generated --user <id>
```

### Why not tint at runtime?

The mesher *can* tint a face (grass does it), but the tint would have to be plumbed
through the mesher, the hotbar and the block preview, and the texture pool is keyed
by image. Generating real PNGs costs zero runtime code and gives exact control per
colour.
