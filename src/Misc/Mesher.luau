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

-- ========== 3D greedy on the generated surface shell ==========
type Emit = (blockId: number, size: Vector3, center: Vector3) -> ()

local V3 = Vector3.new
local getColumn = WorldGen.getColumn
local blockAt = WorldGen.blockAt
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
                grid[i + base] = blockAt(cx * CS + x, y, cz * CS + z, Hgrid[i], Bgrid[i])
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

                    emit(mat,
                        V3(w * BLOCK_SIZE, hgt * BLOCK_SIZE, d * BLOCK_SIZE),
                        V3(baseX + (x + w * 0.5) * BLOCK_SIZE,
                            (gLo + ly + hgt * 0.5) * BLOCK_SIZE,
                            baseZ + (z + d * 0.5) * BLOCK_SIZE))
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

    runGreedy3D(chunk, function(id, size, center)
        local part = getPooledPart()
        part.Size = size
        part.CFrame = CFrame.new(center)
        applyBlockAppearance(part, id)
        part.Parent = model
    end)

    model.Parent = parent
    return model
end

local function recyclePart(part: BasePart)
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

return ChunkMesher
