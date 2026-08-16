-- ReplicatedStorage/Misc/Mesher.luau
--!optimize 2
--!native

-- Greedy voxel mesher, fully client-side / generation-driven.
--   * Terrain is deterministic (WorldGen), so the mesher GENERATES what it needs
--     from a chunk's coordinates alone — no block data is transferred; the server
--     only sends which chunks to load.
--   * Within the meshed band the terrain is a heightmap (caves sit below the
--     surface and are internal), so we compute per-column surface heights and walk
--     only the thin visible shell, then 3D-greedy-merge exposed blocks into solid
--     boxes: one box per block, no overlaps, and each box is BOTH visual (material +
--     colour) and collision. Boxes are pooled.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local Blocks = require(ReplicatedStorage.Misc.Blocks)
local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local BLOCK = WorldGen.BLOCK
local BLOCK_SIZE = WorldGen.BLOCK_SIZE
local BlockDefs = Blocks.defs

export type ClientChunk = {
    cx: number,
    cz: number,
}

export type ClientWorld = {
    [string]: ClientChunk
}

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

-- Instances handed to the engine since load, so a caller can budget how much NEW
-- GEOMETRY it creates in one frame. See ChunkMesher.InstancesBuilt below.
--
-- It counts INSTANCES, not boxes, and that distinction is the whole point: a
-- textured box is a part plus up to six Texture children, so budgeting by box
-- silently costs ~4x more when textures are on than when they are off — and the
-- budget would appear to be doing its job the entire time.
local instancesBuilt = 0

-- ========== part pool ==========
local PartPool: { BasePart } = {}

local function getPooledPart(): BasePart
    local part = table.remove(PartPool)
    if not part then
        part = Instance.new("Part")
        part.Anchored = true
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.CanTouch = false
    end
    part.Parent = nil
    part.Transparency = 0
    part.CanCollide = true
    part.CanQuery = true
    return part
end

-- See-through blocks: they don't occlude neighbours (blocks behind them render).
-- The PART is fully transparent so its fill/colour never shows through the gaps
-- in the texture — only the texture (with its alpha cutout) draws, so leaves/glass
-- read as real cutouts with the blocks behind visible through the holes.
-- Face-culling + appearance come straight from the block registry. A cell hides
-- its neighbour's facing side only if it is opaque (solid & not transparent).
local isOpaque = Blocks.isOpaque

-- Does terrain cast shadows? Yes. This constant only survives as a knob.
--
-- It was turned off chasing a frame-time problem shadows had nothing to do with:
-- the real cause was the mesher handing the engine ~35,000 new parts in a single
-- frame (see INSTANCE_BUDGET in ChunkClient). With that fixed, shadows cost what they
-- always cost, and turning them off bought nothing while losing the thing that
-- makes a cliff read as a cliff.
--
-- Also not worth reviving: the "only boxes with sky above them cast" refinement.
-- Measured at 77% of boxes still casting — in a voxel world most exposed faces ARE
-- the top of the ground — so it was complexity for a quarter of a cost that turned
-- out not to matter.
local TERRAIN_CASTS_SHADOW = true

local MAGENTA = Color3.fromRGB(255, 0, 255)
local function applyBlockAppearance(part: BasePart, blockId: number, textured: boolean?)
    local d = BlockDefs[blockId]
    if d then
        part.Material = d.material
        -- A leaf is a fully transparent part whose texture IS the block. Drop the
        -- texture and it stops existing — so an untextured chunk draws it opaque in
        -- the texture's own mean colour instead. Nothing else needs this: every
        -- other block's colour already matches its texture.
        local lod = if textured == false then d.lodColor else nil
        if lod then
            part.Color = lod
            part.Transparency = 0
        else
            part.Color = d.color
            part.Transparency = d.alpha or 0
        end
        -- Non-solid blocks (water, lava) are swum through, and must not eat the
        -- raycast that block editing / the block preview fire at the world.
        local solid = d.solid ~= false
        part.CanCollide = solid
        part.CanQuery = solid
    else
        part.Material = Enum.Material.SmoothPlastic
        part.Color = MAGENTA
        part.Transparency = 0
    end
end

-- ========== textures (per-face Texture objects) ==========
-- Each block face is its own image (StudsPerTile = BLOCK_SIZE tiles one image per
-- block across greedy-merged faces). Sourced from the registry.
local BlockTextures = Blocks.BlockTextures

-- Pooled PER IMAGE: a reused Texture already holds the right image, so its .Texture
-- is never reassigned on re-mesh — no image re-decode, no whole-chunk flash on edit.
local TexPools: { [string]: { Texture } } = {}

local function getPooledTexture(image: string): Texture
    local pool = TexPools[image]
    if pool then
        local t = table.remove(pool)
        if t then
            return t
        end
    end
    local t = Instance.new("Texture")
    t.Texture = image
    t.StudsPerTileU = BLOCK_SIZE -- one image per block; tiles across merged faces
    t.StudsPerTileV = BLOCK_SIZE
    return t
end

local function recycleTexture(t: Texture)
    t.Parent = nil
    local pool = TexPools[t.Texture]
    if not pool then
        pool = {}
        TexPools[t.Texture] = pool
    end
    table.insert(pool, t)
end

-- Attach a textured face to a box part.
local function addFace(part: BasePart, face: Enum.NormalId, image: string, tint: Color3?)
    local t = getPooledTexture(image) -- already has .Texture = image
    t.Face = face
    t.Color3 = tint or Color3.new(1, 1, 1)
    t.Parent = part
    instancesBuilt += 1
end

-- ========== 3D greedy on the generated surface shell ==========
type Emit = (
    blockId: number, size: Vector3, center: Vector3,
    ePX: boolean, eNX: boolean, ePY: boolean, eNY: boolean, ePZ: boolean, eNZ: boolean,
    biomeId: number
) -> ()

local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)

local V3 = Vector3.new
local getColumn = WorldGen.getColumn
local blockAt = WorldGen.blockAt
local diffBlockAt = WorldDiff.blockAt
-- Per-chunk: the lowest y worth meshing (everything under it is solid island /
-- bedrock and can never be seen). Procedurally that's the cave floor; a baked map
-- answers from its own data, which is where most of its meshing cost goes away.
local meshFloor = WorldGen.meshFloor
local TREE_MAX_H = WorldGen.TREE_MAX_H
local TREE_BIOMES = WorldGen.TREE_BIOMES -- biomes whose canopies need extra Y range
local biomeGrassColor = WorldGen.biomeGrassColor
local BLOCK_GRASS = BLOCK.Grass

-- Sub-block shapes (doc 23). A slab occupies the bottom (or top) half of its cell,
-- so it may merge across X and Z but NEVER up the Y axis — two stacked slabs are
-- two half blocks with a gap between them, not one two-high box.
local SLAB_H: { [number]: number } = {} -- id -> vertical centre offset, in cells
for id, d in BlockDefs do
    if d.shape == "slab" then
        SLAB_H[id] = if d.top then 0.75 else 0.25
    end
end

-- ========== water is Terrain, not parts ==========
-- Water was the worst-behaved block we had: transparent, so it can never batch and
-- every fragment behind it is redrawn, and an ocean is a wide flat sheet aimed
-- straight at the camera — the exact shape overdraw hurts most. It was 5.6% of the
-- boxes on the imported map and a good deal more than 5.6% of the cost.
--
-- Roblox already has water that is one render object for the whole world, with
-- waves, buoyancy, swimming and underwater fog attached to it. So the mesher emits
-- no water boxes at all; it writes the water cells into Terrain instead. This is
-- client-side, like the rest of meshing — nothing is replicated, each client fills
-- in the water for the chunks it has, and it is cleared again when the chunk
-- unloads.
local BLOCK_WATER = BLOCK.Water
local VOXEL = 4 -- Terrain's voxel size; fixed by Roblox, not ours to choose

local terrainCache: Terrain? = nil
local function terrain(): Terrain
    -- Resolved on first use, not at require time: the mesher's test harness loads
    -- this module with no DataModel and never reaches a terrain write.
    local t = terrainCache
    if not t then
        t = game:GetService("Workspace").Terrain
        terrainCache = t
    end
    return t :: Terrain
end

-- Fill this chunk's water into Terrain. `isWater` is asked in WORLD block coords.
-- Returns the region written, so unloading the chunk can clear exactly it.
local function writeWaterTerrain(
    cx: number, cz: number, yLo: number, yHi: number,
    isWater: (number, number, number) -> boolean
): Region3
    local wide = CHUNK_SIZE * BLOCK_SIZE
    local x0, z0 = cx * wide, cz * wide
    -- A chunk is 16 x 3.5 = 56 studs, which is 14 whole terrain voxels, so the grid
    -- lands exactly on chunk edges and two chunks can never write the same voxel.
    -- Only Y grows here (blocks are 3.5 studs and voxels are 4).
    local region = Region3.new(
        Vector3.new(x0, yLo * BLOCK_SIZE, z0),
        Vector3.new(x0 + wide, (yHi + 1) * BLOCK_SIZE, z0 + wide)
    ):ExpandToGrid(VOXEL)

    local size = region.Size
    local origin = region.CFrame.Position - size * 0.5
    local nx = math.round(size.X / VOXEL)
    local ny = math.round(size.Y / VOXEL)
    local nz = math.round(size.Z / VOXEL)

    local AIR, WATER = Enum.Material.Air, Enum.Material.Water
    local mats, occ = table.create(nx), table.create(nx)
    for i = 1, nx do
        local mCol, oCol = table.create(ny), table.create(ny)
        -- each voxel takes the block its CENTRE falls in
        local wx = math.floor((origin.X + (i - 0.5) * VOXEL) / BLOCK_SIZE)
        for j = 1, ny do
            local mRow, oRow = table.create(nz), table.create(nz)
            local wy = math.floor((origin.Y + (j - 0.5) * VOXEL) / BLOCK_SIZE)
            for k = 1, nz do
                local wz = math.floor((origin.Z + (k - 0.5) * VOXEL) / BLOCK_SIZE)
                if isWater(wx, wy, wz) then
                    mRow[k], oRow[k] = WATER, 1
                else
                    mRow[k], oRow[k] = AIR, 0
                end
            end
            mCol[j], oCol[j] = mRow, oRow
        end
        mats[i], occ[i] = mCol, oCol
    end

    terrain():WriteVoxels(region, VOXEL, mats, occ)
    return region
end

-- Which chunk model owns which stretch of water, so unloading clears it.
local WaterRegions: { [Instance]: Region3 } = {}

local function clearWaterTerrain(model: Instance)
    local region = WaterRegions[model]
    if region then
        WaterRegions[model] = nil
        terrain():FillRegion(region, VOXEL, Enum.Material.Air)
    end
end

-- Called once per chunk that contains water, with the water's Y range and a probe.
type EmitWater = (yLo: number, yHi: number, isWater: (number, number, number) -> boolean) -> ()

local function runGreedy3D(chunk: ClientChunk, emit: Emit, emitWater: EmitWater?)
    local cx, cz = chunk.cx, chunk.cz
    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE
    local CS = CHUNK_SIZE
    local layer = CS * CS

    -- Per-column surface height + biome for x,z in [-1, CS] (chunk + 1-block border
    -- into neighbors). Deterministic, so boundary faces are correct with no neighbor
    -- data. maxY comes from this chunk's own columns.
    local GW = CS + 2
    local slab = GW * GW
    local Hgrid = table.create(slab, 0)
    local Bgrid = table.create(slab, 0)
    local maxY = 0
    local hasGrass = false
    for z = -1, CS do
        for x = -1, CS do
            local h, b = getColumn(cx * CS + x, cz * CS + z)
            local i = (x + 1) + (z + 1) * GW + 1
            Hgrid[i] = h
            Bgrid[i] = b
            if TREE_BIOMES[b] then hasGrass = true end
            if x >= 0 and x < CS and z >= 0 and z < CS and h > maxY then
                maxY = h
            end
        end
    end
    -- Trees sit in the air above the surface; raise the range to fit their canopy.
    if hasGrass then
        maxY += TREE_MAX_H
    end

    -- Full 3D range: caves reach down to the mesh floor, so mesh [gLo, maxY].
    local gLo = meshFloor(cx, cz)

    -- Player edits may sit above the surface (built up) or below the cave floor
    -- (dug down); grow the range to cover them, and use the diff-aware sampler for
    -- edited chunks (untouched chunks stay on the pure fast path).
    local sample = blockAt
    if WorldDiff.chunkHasEdits(cx, cz) then
        sample = diffBlockAt
        local emin, emax = WorldDiff.chunkYBounds(cx, cz)
        if emax and emax > maxY then maxY = emax end
        if emin and emin < gLo then gLo = emin end
    end

    if gLo < 0 then gLo = 0 end
    local span = maxY - gLo + 1
    if span <= 0 then return end

    -- Cave-aware solidity grid over x,z in [-1, CS], y in [gLo, maxY] (blockId; 0 = air).
    --
    -- `span` is the whole chunk's height, so one cliff or spire makes EVERY column
    -- pay for it: a chunk spanning a valley floor and a clifftop sampled the empty
    -- sky above the valley hundreds of times. Each column stops at its own ceiling
    -- instead — its top, plus canopy room where trees can reach above it — and the
    -- rest of the grid stays air, which it already was. Same output, far less work,
    -- and the taller the cliff the more it saves.
    local grid = table.create(slab * span, 0)
    local canopy = if hasGrass then TREE_MAX_H else 0
    for z = -1, CS do
        for x = -1, CS do
            local i = (x + 1) + (z + 1) * GW + 1
            local h = Hgrid[i]
            if h >= 0 then
                local ceiling = math.min(maxY, h + canopy)
                local wx, wz = cx * CS + x, cz * CS + z
                local bh, bb = h, Bgrid[i]
                for y = gLo, ceiling do
                    grid[i + (y - gLo) * slab] = sample(wx, y, wz, bh, bb)
                end
            end
        end
    end
    -- Is the face between a cell of id `own` and its neighbour HIDDEN?
    -- Hidden when the neighbour is opaque, OR when it is the SAME block: two water
    -- cells (or two leaf cells) share no visible surface. Without the same-id rule
    -- an ocean would mesh its entire volume instead of just its skin.
    local function hidden(gx: number, gy: number, gz: number, own: number): boolean
        if gy > maxY then return false end
        if gy < gLo then return true end
        local n = grid[(gx + 1) + (gz + 1) * GW + (gy - gLo) * slab + 1]
        if isOpaque(n) then return true end
        -- Same-block culling does NOT apply to slabs: a slab stacked above another
        -- leaves a real gap between them, so culling on "same id" would punch a
        -- hole straight through the lower one.
        return n == own and SLAB_H[own] == nil
    end

    -- exposed = a cell with at least one face the player could see
    local exposed = table.create(layer * span, 0)
    -- Water never reaches `exposed`: it becomes Terrain instead. Collected here
    -- rather than in a second sweep because this loop already has the grid open.
    local water: { [number]: boolean } = {}
    local wLo, wHi = math.huge, -math.huge
    for ly = 0, span - 1 do
        local y = gLo + ly
        local sbase = ly * slab
        local ebase = ly * layer
        for z = 0, CS - 1 do
            for x = 0, CS - 1 do
                local id = grid[(x + 1) + (z + 1) * GW + sbase + 1]
                if id == BLOCK_WATER then
                    water[x + z * CS + ebase + 1] = true
                    if y < wLo then wLo = y end
                    if y > wHi then wHi = y end
                elseif id ~= 0
                    and (not hidden(x + 1, y, z, id) or not hidden(x - 1, y, z, id)
                        or not hidden(x, y + 1, z, id) or not hidden(x, y - 1, z, id)
                        or not hidden(x, y, z + 1, id) or not hidden(x, y, z - 1, id)) then
                    exposed[x + z * CS + ebase + 1] = id
                end
            end
        end
    end

    if emitWater and wHi >= wLo then
        local ox, oz = cx * CS, cz * CS
        emitWater(wLo, wHi, function(wx: number, wy: number, wz: number): boolean
            local lx, lz = wx - ox, wz - oz
            if lx < 0 or lx >= CS or lz < 0 or lz >= CS or wy < gLo or wy > maxY then
                return false
            end
            return water[lx + lz * CS + (wy - gLo) * layer + 1] == true
        end)
    end

    -- greedy grow +X, then +Z (whole row), then +Y (whole slab)
    local used = table.create(layer * span, false)
    for ly = 0, span - 1 do
        for z = 0, CS - 1 do
            for x = 0, CS - 1 do
                local i0 = x + z * CS + ly * layer + 1
                local mat = exposed[i0]
                if mat ~= 0 and not used[i0] then
                    local w = 1
                    while x + w < CS do
                        local ii = (x + w) + z * CS + ly * layer + 1
                        if used[ii] or exposed[ii] ~= mat then break end
                        w += 1
                    end

                    local d = 1
                    local grow = true
                    while grow and z + d < CS do
                        for xx = 0, w - 1 do
                            local ii = (x + xx) + (z + d) * CS + ly * layer + 1
                            if used[ii] or exposed[ii] ~= mat then grow = false break end
                        end
                        if grow then d += 1 end
                    end

                    local slabY = SLAB_H[mat]
                    local hgt = 1
                    grow = slabY == nil -- slabs never merge vertically
                    while grow and ly + hgt < span do
                        for zz = 0, d - 1 do
                            for xx = 0, w - 1 do
                                local ii = (x + xx) + (z + zz) * CS + (ly + hgt) * layer + 1
                                if used[ii] or exposed[ii] ~= mat then grow = false break end
                            end
                            if not grow then break end
                        end
                        if grow then hgt += 1 end
                    end

                    for yy = 0, hgt - 1 do
                        for zz = 0, d - 1 do
                            for xx = 0, w - 1 do
                                used[(x + xx) + (z + zz) * CS + (ly + yy) * layer + 1] = true
                            end
                        end
                    end

                    -- which of the box's 6 faces are exposed (touch air) — only
                    -- those get textured, so hidden internal faces cost nothing.
                    local yb, yt = gLo + ly, gLo + ly + hgt - 1
                    local ePX, eNX, ePY, eNY, ePZ, eNZ = false, false, false, false, false, false
                    for zz = z, z + d - 1 do
                        for yy = yb, yt do
                            if not hidden(x + w, yy, zz, mat) then ePX = true end
                            if not hidden(x - 1, yy, zz, mat) then eNX = true end
                        end
                    end
                    for xx = x, x + w - 1 do
                        for yy = yb, yt do
                            if not hidden(xx, yy, z + d, mat) then ePZ = true end
                            if not hidden(xx, yy, z - 1, mat) then eNZ = true end
                        end
                    end
                    for zz = z, z + d - 1 do
                        for xx = x, x + w - 1 do
                            if not hidden(xx, yt + 1, zz, mat) then ePY = true end
                            if not hidden(xx, yb - 1, zz, mat) then eNY = true end
                        end
                    end

                    -- A slab is half as tall and sits in the bottom or top half of
                    -- its cell; everything else fills the box it merged into.
                    local sizeY = if slabY then BLOCK_SIZE * 0.5 else hgt * BLOCK_SIZE
                    local midY = if slabY
                        then (gLo + ly + slabY) * BLOCK_SIZE
                        else (gLo + ly + hgt * 0.5) * BLOCK_SIZE

                    emit(mat,
                        V3(w * BLOCK_SIZE, sizeY, d * BLOCK_SIZE),
                        V3(baseX + (x + w * 0.5) * BLOCK_SIZE,
                            midY,
                            baseZ + (z + d * 0.5) * BLOCK_SIZE),
                        ePX, eNX, ePY, eNY, ePZ, eNZ,
                        Bgrid[(x + 1) + (z + 1) * GW + 1])
                end
            end
        end
    end
end

-- ========== PUBLIC API ==========
local ChunkMesher = {}

-- Instances (parts AND their Textures) handed to the engine since load.
--
-- A caller budgets against this because a TIME budget around the mesher measures
-- the wrong thing entirely. Meshing a cheap chunk costs ~0.05 ms of Luau, so a 5 ms
-- script budget happily builds a hundred of them in one frame — and then the engine
-- has to ingest tens of thousands of new instances, which it does inside
-- RenderViewUpdate, on the main thread, where no script timer can see it. The
-- symptom is a profile with a 50 ms RenderViewUpdate and no Lua time anywhere,
-- which reads as "the renderer is slow" when it is really "we shoved a world at it
-- in one frame".
function ChunkMesher.InstancesBuilt(): number
    return instancesBuilt
end

-- `textured` (default true) decides whether this chunk gets per-face Texture
-- objects or is left as flat block colour.
--
-- It is not a quality knob, it is THE performance knob. Roblox batches parts that
-- share a material and colour — but a part carrying a Decal or Texture is excluded
-- from batching entirely, and we hang up to six on every box. That is why a
-- profile shows ~10 triangles per batch: nothing merges, and the main thread walks
-- every box and every Texture separately. Untextured chunks fall back into the
-- engine's batched path.
--
-- The cost of turning it off is close to nothing, because the textures were
-- generated to match: tint.js normalises each one so its mean colour equals the
-- block's declared colour in Blocks.luau (that is also why a block looks right
-- before its texture streams in). At distance, flat colour and texture are the
-- same handful of pixels.
function ChunkMesher.BuildChunk(chunk: ClientChunk, parent: Instance, textured: boolean?): Model
    local model = Instance.new("Model")
    model.Name = "chunk_" .. chunkKey(chunk.cx, chunk.cz)
    if textured == nil then
        textured = true
    end

    runGreedy3D(chunk, function(id, size, center, ePX, eNX, ePY, eNY, ePZ, eNZ, biomeId)
        local part = getPooledPart()
        part.Size = size
        part.CFrame = CFrame.new(center)
        applyBlockAppearance(part, id, textured)
        part.CastShadow = TERRAIN_CASTS_SHADOW
        part.Parent = model
        instancesBuilt += 1

        local tex = if textured then BlockTextures[id] else nil
        if tex then
            -- Tint the grass TOP by the biome (sides keep the dirt fringe untinted).
            local topTint = if id == BLOCK_GRASS then biomeGrassColor(biomeId) else nil
            if ePY then addFace(part, Enum.NormalId.Top, tex.top, topTint) end
            if eNY then addFace(part, Enum.NormalId.Bottom, tex.bottom) end
            if ePX then addFace(part, Enum.NormalId.Right, tex.side) end
            if eNX then addFace(part, Enum.NormalId.Left, tex.side) end
            if ePZ then addFace(part, Enum.NormalId.Back, tex.side) end
            if eNZ then addFace(part, Enum.NormalId.Front, tex.side) end
        end
    end, function(yLo, yHi, isWater)
        WaterRegions[model] = writeWaterTerrain(chunk.cx, chunk.cz, yLo, yHi, isWater)
    end)

    model.Parent = parent
    return model
end

local function recyclePart(part: BasePart)
    -- return the box's textured faces to the pool, then the part itself
    for _, ch in ipairs(part:GetChildren()) do
        if ch:IsA("Texture") then
            recycleTexture(ch)
        end
    end
    part.Parent = nil
    table.insert(PartPool, part)
end

function ChunkMesher.RecycleChunkModel(model: Model)
    clearWaterTerrain(model)
    for _, child in ipairs(model:GetChildren()) do
        if child:IsA("BasePart") then
            recyclePart(child)
        else
            child:Destroy()
        end
    end
    model:Destroy()
end

-- ========== block mode (per-cell, for edited chunks) ==========
-- Once a chunk is edited it switches to one Part PER visible cell, indexed by
-- world cell. Edits then only add/remove/update the touched cell + its neighbors
-- (incremental), so breaking never rebuilds the big greedy parts that cause the
-- ~0.5s render blink — break and place are both instant. Untouched chunks stay on
-- the cheap greedy mesh.
export type BlockChunk = { model: Model, cells: { [string]: BasePart } }

local BLOCK_AIR = BLOCK.Air

local function cellKey(wx: number, y: number, wz: number): string
    return wx .. "," .. y .. "," .. wz
end

-- Size + place a single-cell part, honouring sub-block shapes. Called on every
-- update, not just on creation, because an edit can turn a slab cell into a full
-- block (or the reverse) and the part is reused.
local function sizeCell(part: BasePart, id: number, wx: number, y: number, wz: number)
    local slabY = SLAB_H[id]
    if slabY then
        part.Size = V3(BLOCK_SIZE, BLOCK_SIZE * 0.5, BLOCK_SIZE)
        part.CFrame = CFrame.new((wx + 0.5) * BLOCK_SIZE, (y + slabY) * BLOCK_SIZE, (wz + 0.5) * BLOCK_SIZE)
    else
        part.Size = V3(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
        part.CFrame = CFrame.new((wx + 0.5) * BLOCK_SIZE, (y + 0.5) * BLOCK_SIZE, (wz + 0.5) * BLOCK_SIZE)
    end
end

-- Resolved block id at a world cell (diff over deterministic base).
local function worldBlockAt(wx: number, wz: number, y: number): number
    local surfaceY, biome = getColumn(wx, wz)
    return diffBlockAt(wx, y, wz, surfaceY, biome)
end

local NID_TOP = Enum.NormalId.Top
local NID_BOTTOM = Enum.NormalId.Bottom
local NID_RIGHT = Enum.NormalId.Right
local NID_LEFT = Enum.NormalId.Left
local NID_BACK = Enum.NormalId.Back
local NID_FRONT = Enum.NormalId.Front

local function findFaceTexture(part: BasePart, face: Enum.NormalId): Texture?
    for _, t in part:GetChildren() do
        if t:IsA("Texture") and t.Face == face then
            return t
        end
    end
    return nil
end

-- Ensure a face has (or doesn't have) a texture, without recreating the part —
-- so revealing a neighbor's face never flashes.
local function setFaceTexture(part: BasePart, face: Enum.NormalId, image: string?)
    local t = findFaceTexture(part, face)
    if image then
        if not t then
            addFace(part, face, image)
        elseif t.Texture ~= image then
            t.Texture = image
        end
    elseif t then
        recycleTexture(t)
    end
end

-- Set a cell part's visible faces to match exposure (all six; block mode wants
-- bottoms so overhangs/undersides read correctly once the terrain is de-greedied).
local function applyCellFaces(part: BasePart, id: number, ePX, eNX, ePY, eNY, ePZ, eNZ)
    local tex = BlockTextures[id]
    local side = tex and tex.side or nil
    setFaceTexture(part, NID_TOP, (ePY and tex) and tex.top or nil)
    setFaceTexture(part, NID_BOTTOM, (eNY and tex) and tex.bottom or nil)
    setFaceTexture(part, NID_RIGHT, ePX and side or nil)
    setFaceTexture(part, NID_LEFT, eNX and side or nil)
    setFaceTexture(part, NID_BACK, ePZ and side or nil)
    setFaceTexture(part, NID_FRONT, eNZ and side or nil)
end

-- Re-evaluate one cell: create / update-in-place / remove its part. Called for
-- the edited cell and each of its neighbors. Updates faces incrementally so an
-- existing part never gets rebuilt (no flash on reveal).
function ChunkMesher.UpdateBlockCell(bc: BlockChunk, wx: number, y: number, wz: number)
    local key = cellKey(wx, y, wz)
    local part = bc.cells[key]

    local id = worldBlockAt(wx, wz, y)
    local ePX, eNX, ePY, eNY, ePZ, eNZ = false, false, false, false, false, false
    local exposed = false
    if id ~= BLOCK_AIR then
        -- same rule as the greedy path: a face against an identical block is hidden,
        -- unless it's a slab (stacked slabs don't touch)
        local isSlab = SLAB_H[id] ~= nil
        local function shows(nid: number): boolean
            return not isOpaque(nid) and (nid ~= id or isSlab)
        end
        ePX = shows(worldBlockAt(wx + 1, wz, y))
        eNX = shows(worldBlockAt(wx - 1, wz, y))
        ePY = shows(worldBlockAt(wx, wz, y + 1))
        eNY = shows(worldBlockAt(wx, wz, y - 1))
        ePZ = shows(worldBlockAt(wx, wz + 1, y))
        eNZ = shows(worldBlockAt(wx, wz - 1, y))
        exposed = ePX or eNX or ePY or eNY or ePZ or eNZ
    end

    if not exposed then
        if part then
            recyclePart(part)
            bc.cells[key] = nil
        end
        return
    end

    if not part then
        part = getPooledPart()
        part.Parent = bc.model
        bc.cells[key] = part
    end
    sizeCell(part, id, wx, y, wz)
    applyBlockAppearance(part, id)
    part.CastShadow = TERRAIN_CASTS_SHADOW
    applyCellFaces(part, id, ePX, eNX, ePY, eNY, ePZ, eNZ)
end

-- Build the whole chunk as per-cell parts (used when a chunk first gets edited).
function ChunkMesher.BuildBlockChunk(chunk: ClientChunk, parent: Instance): BlockChunk
    local cx, cz = chunk.cx, chunk.cz
    local CS = CHUNK_SIZE
    local GW = CS + 2
    local slab = GW * GW

    local Hgrid = table.create(slab, 0)
    local Bgrid = table.create(slab, 0)
    local maxY = 0
    local hasGrass = false
    for z = -1, CS do
        for x = -1, CS do
            local h, b = getColumn(cx * CS + x, cz * CS + z)
            local i = (x + 1) + (z + 1) * GW + 1
            Hgrid[i] = h
            Bgrid[i] = b
            if TREE_BIOMES[b] then hasGrass = true end
            if x >= 0 and x < CS and z >= 0 and z < CS and h > maxY then
                maxY = h
            end
        end
    end
    -- Trees sit in the air above the surface; raise the range to fit their canopy.
    if hasGrass then
        maxY += TREE_MAX_H
    end
    local gLo = meshFloor(cx, cz)
    local emin, emax = WorldDiff.chunkYBounds(cx, cz)
    if emax and emax > maxY then maxY = emax end
    if emin and emin < gLo then gLo = emin end
    if gLo < 0 then gLo = 0 end
    local span = maxY - gLo + 1

    local model = Instance.new("Model")
    model.Name = "bchunk_" .. cx .. ":" .. cz
    local cells: { [string]: BasePart } = {}
    if span <= 0 then
        model.Parent = parent
        return { model = model, cells = cells }
    end

    local grid = table.create(slab * span, 0)
    for ly = 0, span - 1 do
        local y = gLo + ly
        local base = ly * slab
        for z = -1, CS do
            for x = -1, CS do
                local i = (x + 1) + (z + 1) * GW + 1
                grid[i + base] = diffBlockAt(cx * CS + x, y, cz * CS + z, Hgrid[i], Bgrid[i])
            end
        end
    end
    local function hidden(gx: number, gy: number, gz: number, own: number): boolean
        if gy > maxY then return false end
        if gy < gLo then return true end
        local n = grid[(gx + 1) + (gz + 1) * GW + (gy - gLo) * slab + 1]
        if isOpaque(n) then return true end
        return n == own and SLAB_H[own] == nil -- stacked slabs don't touch
    end

    -- Same deal as the greedy path: water is Terrain, never a cell part. Without
    -- this an edited chunk would sprout back the water boxes its neighbours don't
    -- have, on top of the Terrain water already there.
    local layer = CS * CS
    local water: { [number]: boolean } = {}
    local wLo, wHi = math.huge, -math.huge

    for ly = 0, span - 1 do
        local y = gLo + ly
        local sbase = ly * slab
        for z = 0, CS - 1 do
            for x = 0, CS - 1 do
                local id = grid[(x + 1) + (z + 1) * GW + sbase + 1]
                if id == BLOCK_WATER then
                    water[x + z * CS + ly * layer + 1] = true
                    if y < wLo then wLo = y end
                    if y > wHi then wHi = y end
                elseif id ~= 0 then
                    local ePX = not hidden(x + 1, y, z, id)
                    local eNX = not hidden(x - 1, y, z, id)
                    local ePY = not hidden(x, y + 1, z, id)
                    local eNY = not hidden(x, y - 1, z, id)
                    local ePZ = not hidden(x, y, z + 1, id)
                    local eNZ = not hidden(x, y, z - 1, id)
                    if ePX or eNX or ePY or eNY or ePZ or eNZ then
                        local wx, wz = cx * CS + x, cz * CS + z
                        local part = getPooledPart()
                        sizeCell(part, id, wx, y, wz)
                        applyBlockAppearance(part, id)
                        part.CastShadow = TERRAIN_CASTS_SHADOW
                        applyCellFaces(part, id, ePX, eNX, ePY, eNY, ePZ, eNZ)
                        part.Parent = model
                        instancesBuilt += 1
                        cells[cellKey(wx, y, wz)] = part
                    end
                end
            end
        end
    end

    if wHi >= wLo then
        local ox, oz = cx * CS, cz * CS
        WaterRegions[model] = writeWaterTerrain(cx, cz, wLo, wHi, function(wx, wy, wz)
            local lx, lz = wx - ox, wz - oz
            if lx < 0 or lx >= CS or lz < 0 or lz >= CS or wy < gLo or wy > maxY then
                return false
            end
            return water[lx + lz * CS + (wy - gLo) * layer + 1] == true
        end)
    end

    model.Parent = parent
    return { model = model, cells = cells }
end

function ChunkMesher.RecycleBlockChunk(bc: BlockChunk)
    clearWaterTerrain(bc.model)
    for _, part in bc.cells do
        recyclePart(part)
    end
    bc.model:Destroy()
end

-- Per-face textures per block id, for UI (hotbar previews) etc.
ChunkMesher.BlockTextures = BlockTextures

-- Exposed for tools/mcimport/test_mesher.luau, which runs the REAL greedy pass
-- against a synthetic voxel field to count boxes and assert none of them overlap.
-- Overlapping boxes are invisible in game except as doubled parts and a frame rate
-- that makes no sense, so they need a test rather than an eye.
ChunkMesher._runGreedy3D = runGreedy3D

return ChunkMesher
