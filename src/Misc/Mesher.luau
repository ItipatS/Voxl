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
local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local BLOCK = WorldGen.BLOCK
local BLOCK_SIZE = WorldGen.BLOCK_SIZE

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

-- ========== appearance ==========
local BlockColors: { [number]: Color3 } = {
    [BLOCK.Grass] = Color3.fromRGB(80, 160, 80),
    [BLOCK.Dirt]  = Color3.fromRGB(120, 72, 48),
    [BLOCK.Sand]  = Color3.fromRGB(235, 225, 180),
    [BLOCK.Stone] = Color3.fromRGB(120, 120, 120),
    [BLOCK.Snow]  = Color3.fromRGB(255, 255, 255),
}

local BlockMaterials: { [number]: Enum.Material } = {
    [BLOCK.Grass] = Enum.Material.Grass,
    [BLOCK.Dirt]  = Enum.Material.Ground,
    [BLOCK.Sand]  = Enum.Material.Sand,
    [BLOCK.Stone] = Enum.Material.Slate,
    [BLOCK.Snow]  = Enum.Material.Snow,
}

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

local function applyBlockAppearance(part: BasePart, blockId: number)
    part.Material = BlockMaterials[blockId] or Enum.Material.SmoothPlastic
    part.Color = BlockColors[blockId] or Color3.fromRGB(255, 0, 255)
end

-- ========== textures (per-face Texture objects) ==========
-- Each block face is its own image, upscaled to ~1600px so bilinear filtering stays
-- crisp (3D Textures can't be point-filtered). A Texture tiles ONE image per block
-- (StudsPerTile = BLOCK_SIZE), so it works across greedy-merged box faces and stays
-- far lighter than SurfaceGuis.
local TEX = {
    stone    = "rbxassetid://84046704582684",
    oakTop   = "rbxassetid://105200585443073", -- oak log top & bottom
    oakSide  = "rbxassetid://120664114630276",
    oakLeaf  = "rbxassetid://104131890534229",
    debug    = "rbxassetid://78128038044643",  -- placeholder for unmapped blocks
    grassTop = "rbxassetid://99956800911799",
    grassSide= "rbxassetid://108714877040603",
    dirt     = "rbxassetid://112826071106637", -- also grass bottom
    snow     = "rbxassetid://121040441244210",
    sand     = "rbxassetid://75605206965672",
}

local BlockTextures: { [number]: { top: string, bottom: string, side: string } } = {
    [BLOCK.Grass]     = { top = TEX.grassTop, bottom = TEX.dirt,   side = TEX.grassSide },
    [BLOCK.Dirt]      = { top = TEX.dirt,     bottom = TEX.dirt,   side = TEX.dirt },
    [BLOCK.Sand]      = { top = TEX.sand,     bottom = TEX.sand,   side = TEX.sand },
    [BLOCK.Stone]     = { top = TEX.stone,    bottom = TEX.stone,  side = TEX.stone },
    [BLOCK.Snow]      = { top = TEX.snow,     bottom = TEX.snow,   side = TEX.snow },
    [BLOCK.OakLog]    = { top = TEX.oakTop,   bottom = TEX.oakTop, side = TEX.oakSide },
    [BLOCK.OakLeaves] = { top = TEX.oakLeaf,  bottom = TEX.oakLeaf, side = TEX.oakLeaf },
}

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
end

-- ========== 3D greedy on the generated surface shell ==========
type Emit = (
    blockId: number, size: Vector3, center: Vector3,
    ePX: boolean, eNX: boolean, ePY: boolean, eNY: boolean, ePZ: boolean, eNZ: boolean
) -> ()

local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)

local V3 = Vector3.new
local getColumn = WorldGen.getColumn
local blockAt = WorldGen.blockAt
local diffBlockAt = WorldDiff.blockAt
local CAVE_FLOOR = WorldGen.CAVE_START_Y - 1

local function runGreedy3D(chunk: ClientChunk, emit: Emit)
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
    for z = -1, CS do
        for x = -1, CS do
            local h, b = getColumn(cx * CS + x, cz * CS + z)
            local i = (x + 1) + (z + 1) * GW + 1
            Hgrid[i] = h
            Bgrid[i] = b
            if x >= 0 and x < CS and z >= 0 and z < CS and h > maxY then
                maxY = h
            end
        end
    end

    -- Full 3D range: caves reach down to CAVE_START_Y, so mesh [caveFloor, maxY].
    local gLo = CAVE_FLOOR

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
    local grid = table.create(slab * span, 0)
    for ly = 0, span - 1 do
        local y = gLo + ly
        local base = ly * slab
        for z = -1, CS do
            for x = -1, CS do
                local i = (x + 1) + (z + 1) * GW + 1
                grid[i + base] = sample(cx * CS + x, y, cz * CS + z, Hgrid[i], Bgrid[i])
            end
        end
    end
    local function solid(gx: number, gy: number, gz: number): boolean
        if gy > maxY then return false end -- above surface = air
        if gy < gLo then return true end   -- below the cave floor = solid rock
        return grid[(gx + 1) + (gz + 1) * GW + (gy - gLo) * slab + 1] ~= 0
    end

    -- exposed = solid cell with any air neighbor (surface shell AND cave walls)
    local exposed = table.create(layer * span, 0)
    for ly = 0, span - 1 do
        local y = gLo + ly
        local sbase = ly * slab
        local ebase = ly * layer
        for z = 0, CS - 1 do
            for x = 0, CS - 1 do
                local id = grid[(x + 1) + (z + 1) * GW + sbase + 1]
                if id ~= 0
                    and (not solid(x + 1, y, z) or not solid(x - 1, y, z)
                        or not solid(x, y + 1, z) or not solid(x, y - 1, z)
                        or not solid(x, y, z + 1) or not solid(x, y, z - 1)) then
                    exposed[x + z * CS + ebase + 1] = id
                end
            end
        end
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

                    local hgt = 1
                    grow = true
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
                            if not solid(x + w, yy, zz) then ePX = true end
                            if not solid(x - 1, yy, zz) then eNX = true end
                        end
                    end
                    for xx = x, x + w - 1 do
                        for yy = yb, yt do
                            if not solid(xx, yy, z + d) then ePZ = true end
                            if not solid(xx, yy, z - 1) then eNZ = true end
                        end
                    end
                    for zz = z, z + d - 1 do
                        for xx = x, x + w - 1 do
                            if not solid(xx, yt + 1, zz) then ePY = true end
                            if not solid(xx, yb - 1, zz) then eNY = true end
                        end
                    end

                    emit(mat,
                        V3(w * BLOCK_SIZE, hgt * BLOCK_SIZE, d * BLOCK_SIZE),
                        V3(baseX + (x + w * 0.5) * BLOCK_SIZE,
                            (gLo + ly + hgt * 0.5) * BLOCK_SIZE,
                            baseZ + (z + d * 0.5) * BLOCK_SIZE),
                        ePX, eNX, ePY, eNY, ePZ, eNZ)
                end
            end
        end
    end
end

-- ========== PUBLIC API ==========
local ChunkMesher = {}

function ChunkMesher.BuildChunk(chunk: ClientChunk, parent: Instance): Model
    local model = Instance.new("Model")
    model.Name = "chunk_" .. chunkKey(chunk.cx, chunk.cz)

    runGreedy3D(chunk, function(id, size, center, ePX, eNX, ePY, eNY, ePZ, eNZ)
        local part = getPooledPart()
        part.Size = size
        part.CFrame = CFrame.new(center)
        applyBlockAppearance(part, id)
        part.Parent = model

        local tex = BlockTextures[id]
        if tex then
            if ePY then addFace(part, Enum.NormalId.Top, tex.top) end
            if eNY then addFace(part, Enum.NormalId.Bottom, tex.bottom) end
            if ePX then addFace(part, Enum.NormalId.Right, tex.side) end
            if eNX then addFace(part, Enum.NormalId.Left, tex.side) end
            if ePZ then addFace(part, Enum.NormalId.Back, tex.side) end
            if eNZ then addFace(part, Enum.NormalId.Front, tex.side) end
        end
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

local function makeCellPart(wx, y, wz, id, ePX, eNX, ePY, eNY, ePZ, eNZ): BasePart
    local part = getPooledPart()
    part.Size = V3(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
    part.CFrame = CFrame.new((wx + 0.5) * BLOCK_SIZE, (y + 0.5) * BLOCK_SIZE, (wz + 0.5) * BLOCK_SIZE)
    applyBlockAppearance(part, id)
    local tex = BlockTextures[id]
    if tex then
        if ePY then addFace(part, NID_TOP, tex.top) end
        if eNY then addFace(part, NID_BOTTOM, tex.bottom) end
        if ePX then addFace(part, NID_RIGHT, tex.side) end
        if eNX then addFace(part, NID_LEFT, tex.side) end
        if ePZ then addFace(part, NID_BACK, tex.side) end
        if eNZ then addFace(part, NID_FRONT, tex.side) end
    end
    return part
end

-- Re-evaluate one cell: create / update / remove its part based on the current
-- world. Called for the edited cell and each of its 6 neighbors.
function ChunkMesher.UpdateBlockCell(bc: BlockChunk, wx: number, y: number, wz: number)
    local key = cellKey(wx, y, wz)
    local existing = bc.cells[key]

    local id = worldBlockAt(wx, wz, y)
    local ePX, eNX, ePY, eNY, ePZ, eNZ = false, false, false, false, false, false
    local exposed = false
    if id ~= BLOCK_AIR then
        ePX = worldBlockAt(wx + 1, wz, y) == BLOCK_AIR
        eNX = worldBlockAt(wx - 1, wz, y) == BLOCK_AIR
        ePY = worldBlockAt(wx, wz, y + 1) == BLOCK_AIR
        eNY = worldBlockAt(wx, wz, y - 1) == BLOCK_AIR
        ePZ = worldBlockAt(wx, wz + 1, y) == BLOCK_AIR
        eNZ = worldBlockAt(wx, wz - 1, y) == BLOCK_AIR
        exposed = ePX or eNX or ePY or eNY or ePZ or eNZ
    end

    if not exposed then
        if existing then
            recyclePart(existing)
            bc.cells[key] = nil
        end
        return
    end

    if existing then
        recyclePart(existing)
    end
    local part = makeCellPart(wx, y, wz, id, ePX, eNX, ePY, eNY, ePZ, eNZ)
    part.Parent = bc.model
    bc.cells[key] = part
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
    for z = -1, CS do
        for x = -1, CS do
            local h, b = getColumn(cx * CS + x, cz * CS + z)
            local i = (x + 1) + (z + 1) * GW + 1
            Hgrid[i] = h
            Bgrid[i] = b
            if x >= 0 and x < CS and z >= 0 and z < CS and h > maxY then
                maxY = h
            end
        end
    end
    local gLo = CAVE_FLOOR
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
    local function solid(gx, gy, gz): boolean
        if gy > maxY then return false end
        if gy < gLo then return true end
        return grid[(gx + 1) + (gz + 1) * GW + (gy - gLo) * slab + 1] ~= 0
    end

    for ly = 0, span - 1 do
        local y = gLo + ly
        local sbase = ly * slab
        for z = 0, CS - 1 do
            for x = 0, CS - 1 do
                local id = grid[(x + 1) + (z + 1) * GW + sbase + 1]
                if id ~= 0 then
                    local ePX = not solid(x + 1, y, z)
                    local eNX = not solid(x - 1, y, z)
                    local ePY = not solid(x, y + 1, z)
                    local eNY = not solid(x, y - 1, z)
                    local ePZ = not solid(x, y, z + 1)
                    local eNZ = not solid(x, y, z - 1)
                    if ePX or eNX or ePY or eNY or ePZ or eNZ then
                        local wx, wz = cx * CS + x, cz * CS + z
                        local part = makeCellPart(wx, y, wz, id, ePX, eNX, ePY, eNY, ePZ, eNZ)
                        part.Parent = model
                        cells[cellKey(wx, y, wz)] = part
                    end
                end
            end
        end
    end

    model.Parent = parent
    return { model = model, cells = cells }
end

function ChunkMesher.RecycleBlockChunk(bc: BlockChunk)
    for _, part in bc.cells do
        recyclePart(part)
    end
    bc.model:Destroy()
end

return ChunkMesher
