-- ReplicatedStorage/ChunkMesher.luau
--!optimize 2
--!native
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local WORLD_HEIGHT = WorldGen.WORLD_HEIGHT
local BLOCK = WorldGen.BLOCK
local BLOCK_SIZE = WorldGen.BLOCK_SIZE

export type ClientChunk = {
    cx: number,
    cz: number,
    blocks: { [number]: number },
    heightfields: { [number]: number },
    minY: number,
    maxY: number,
}

export type ClientWorld = {
    [string]: ClientChunk
}

export type VisibleSet  = { [string]: boolean }
-- ========== simple part pool ==========

local PartPool: { BasePart } = {}

local CAVE_VIS_MIN_Y = 35

 
local debugSeen = {}

local function debugKey(part: BasePart): string
    local p = part.CFrame.Position
    local s = part.Size
    return string.format("%.2f,%.2f,%.2f|%.2f,%.2f,%.2f",
        p.X, p.Y, p.Z, s.X, s.Y, s.Z)
end

local function getPooledPart(): Part
    local part = table.remove(PartPool)
    if part then
        -- make sure it's detached from any old parent
        part.Parent = nil
    else
        part = Instance.new("Part")
        part.Anchored = true
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
    end

    -- common defaults; we’ll override size/cframe/color/material per use
    part.CanCollide = true
    part.CanQuery = true
    part.CanTouch = false
    part.Transparency = 0

    return part
end


-- ========== index helper ==========
local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

local function idx3(lx: number, y: number, lz: number): number
    -- 0-based indexing, same as WorldGen
    return lx + (y * CHUNK_SIZE) + (lz * CHUNK_SIZE * WORLD_HEIGHT)
end

-- ========== block access from sparse map ==========

local function getBlockGlobal(
    world: ClientWorld,
    visible: VisibleSet,
    cx: number,
    cz: number,
    lx: number,
    y: number,
    lz: number
): number
    if y < 0 or y >= WORLD_HEIGHT then
        return BLOCK.Air
    end

    local ncx, ncz = cx, cz
    local nlx, nlz = lx, lz

    -- handle X cross-chunk
    if nlx < 0 then
        ncx -= 1
        nlx += CHUNK_SIZE
    elseif nlx >= CHUNK_SIZE then
        ncx += 1
        nlx -= CHUNK_SIZE
    end

    -- handle Z cross-chunk
    if nlz < 0 then
        ncz -= 1
        nlz += CHUNK_SIZE
    elseif nlz >= CHUNK_SIZE then
        ncz += 1
        nlz -= CHUNK_SIZE
    end

    local key = chunkKey(ncx, ncz)
    local neighbor = world[key]
    if not neighbor then
        return BLOCK.Air
    end

    local blocks = neighbor.blocks
    local linear = idx3(nlx, y, nlz)
    return blocks[linear] or BLOCK.Air
end

local function isSolid(id: number): boolean
    return id ~= nil and id ~= BLOCK.Air and id ~= 0
end

-- ========== apply appearance for a merged Part ==========

local BlockColors: { [number]: Color3 } = {
    [BLOCK.Grass] = Color3.fromRGB(80, 160, 80),
    [BLOCK.Dirt]  = Color3.fromRGB(120, 72, 48),
    [BLOCK.Sand]  = Color3.fromRGB(235, 225, 180),
    [BLOCK.Stone] = Color3.fromRGB(120, 120, 120),
    [BLOCK.Snow] = Color3.fromRGB(255, 255, 255)
}

local BlockMaterials: { [number]: Enum.Material } = {
    [BLOCK.Grass] = Enum.Material.Grass,
    [BLOCK.Dirt]  = Enum.Material.Ground,
    [BLOCK.Sand]  = Enum.Material.Sand,
    [BLOCK.Stone] = Enum.Material.Slate,
    [BLOCK.Snow] = Enum.Material.Snow,
}

local function applyBlockAppearance(part: Part, blockId: number)
    part.Anchored = true
    part.CanCollide = true  -- using same mesh for collision
    part.CanQuery = true
    part.CanTouch = false

    local mat = BlockMaterials[blockId]
    if mat then
        part.Material = mat
    else
        part.Material = Enum.Material.SmoothPlastic
    end

    local col = BlockColors[blockId]
    if col then
        part.Color = col
    else
        part.Color = Color3.fromRGB(255, 0, 255) -- debug pink
    end
end

-- ========== generic 2D greedy on a mask ==========

-- mask: 1D array of size (w*h), mask[i] = blockId or 0
-- onRect: callback(x, y, w, h, blockId)
local function greedy2D(mask: { number }, w: number, h: number, onRect: (number, number, number, number, number) -> ())
    local used = table.create(w * h, false)

    for j = 0, h - 1 do
        for i = 0, w - 1 do
            local idx = i + j * w + 1
            if not used[idx] then
                local id = mask[idx]
                if id ~= 0 then
                    -- expand width
                    local width = 1
                    while i + width < w do
                        local idx2 = (i + width) + j * w + 1
                        if used[idx2] or mask[idx2] ~= id then
                            break
                        end
                        width += 1
                    end

                    -- expand height
                    local height = 1
                    local done = false
                    while j + height < h do
                        for dx = 0, width - 1 do
                            local idx2 = (i + dx) + (j + height) * w + 1
                            if used[idx2] or mask[idx2] ~= id then
                                done = true
                                break
                            end
                        end
                        if done then break end
                        height += 1
                    end

                    -- mark used
                    for v = 0, height - 1 do
                        for u = 0, width - 1 do
                            local idx2 = (i + u) + (j + v) * w + 1
                            used[idx2] = true
                        end
                    end

                    onRect(i, j, width, height, id)
                end
            end
        end
    end
end

-- ========== Meshing faces in +Y, +X, +Z directions ==========

-- +Y faces: horizontal, facing up. 2D grid in (lx, lz) per y-layer
local function meshTopFaces(world: ClientWorld, visible: VisibleSet, chunk: ClientChunk, parent: Instance)
    local cx = chunk.cx
    local cz = chunk.cz

    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE

    local minY = chunk.minY
    local maxY = chunk.maxY

    for y = minY, maxY do
        local mask = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)

        for lz = 0, CHUNK_SIZE - 1 do
            for lx = 0, CHUNK_SIZE - 1 do
                local id      = getBlockGlobal(world, visible, cx, cz, lx, y, lz)
                if isSolid(id) then
                    local above = getBlockGlobal(world, visible, cx, cz, lx, y + 1, lz)
                    if not isSolid(above) then
                        local idx2 = lx + lz * CHUNK_SIZE + 1
                        mask[idx2] = id
                    end
                end
            end
        end

        greedy2D(mask, CHUNK_SIZE, CHUNK_SIZE, function(ix, iz, w, h, blockId)
            local sizeX = w * BLOCK_SIZE
            local sizeZ = h * BLOCK_SIZE
            local thickness = BLOCK_SIZE

            local centerX = baseX + (ix * BLOCK_SIZE) + sizeX * 0.5
            local centerY = (y + 1) * BLOCK_SIZE + thickness * 0.5
            local centerZ = baseZ + (iz * BLOCK_SIZE) + sizeZ * 0.5

            local part = getPooledPart()
            part.Size = Vector3.new(sizeX, thickness, sizeZ)
            part.CFrame = CFrame.new(centerX, centerY, centerZ)

            local key = debugKey(part)
            if debugSeen[key] then
                warn("Duplicate face at", key)
            else
                debugSeen[key] = true
            end

            part.Parent = parent
            applyBlockAppearance(part, blockId)
        end)
    end
end

-- +X faces: vertical walls facing +X. 2D grid in (lz, y) per lx-slice
local function meshPosXFaces(world: ClientWorld, visible:VisibleSet , chunk: ClientChunk, parent: Instance, renderCaves: boolean)
    local cx = chunk.cx
    local cz = chunk.cz

    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE

    local minY = chunk.minY
    local maxY = chunk.maxY

      if not renderCaves then
        if maxY < CAVE_VIS_MIN_Y then
            return -- nothing interesting in this chunk
        end
        if minY < CAVE_VIS_MIN_Y then
            minY = CAVE_VIS_MIN_Y
        end
    end

    local heightSpan = maxY - minY + 1
    if heightSpan <= 0 then return end

    for lx = 0, CHUNK_SIZE - 1 do
        local mask = table.create(CHUNK_SIZE * heightSpan, 0)

        for lz = 0, CHUNK_SIZE - 1 do
            for y = minY, maxY do
                local id = getBlockGlobal(world, visible, cx, cz, lx, y, lz)
                if isSolid(id) then
                    local neighbor = getBlockGlobal(world, visible, cx, cz, lx + 1, y, lz)
                    if not isSolid(neighbor) then
                        local localY = y - minY
                        local idx2 = lz + localY * CHUNK_SIZE + 1
                        mask[idx2] = id
                    end
                end
            end
        end

        greedy2D(mask, CHUNK_SIZE, heightSpan, function(iz, iy, w, h, blockId)
            -- w in lz, h in y
            local sizeZ = w * BLOCK_SIZE
            local sizeY = h * BLOCK_SIZE
            local thickness = BLOCK_SIZE

            local faceX = (lx + 1) * BLOCK_SIZE -- face between this block and air on +X
            local centerX = (baseX + faceX) + thickness * 0.5

            local worldY = minY + iy
            local centerY = (worldY + h * 0.5) * BLOCK_SIZE
            local centerZ = baseZ + (iz + w * 0.5) * BLOCK_SIZE

            local part = getPooledPart()
            part.Size = Vector3.new(thickness, sizeY, sizeZ)
            part.CFrame = CFrame.new(centerX, centerY, centerZ)

            local key = debugKey(part)
            if debugSeen[key] then
                warn("Duplicate face at", key)
            else
                debugSeen[key] = true
            end

            part.Parent = parent
            applyBlockAppearance(part, blockId)
        end)
    end
end

-- +Z faces: vertical walls facing +Z. 2D grid in (lx, y) per lz-slice
local function meshPosZFaces(world: ClientWorld, visible:VisibleSet, chunk: ClientChunk, parent: Instance, renderCaves: boolean)
    local cx = chunk.cx
    local cz = chunk.cz

    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE

    local minY = chunk.minY
    local maxY = chunk.maxY

    if not renderCaves then
        if maxY < CAVE_VIS_MIN_Y then
            return -- nothing interesting in this chunk
        end
        if minY < CAVE_VIS_MIN_Y then
            minY = CAVE_VIS_MIN_Y
        end
    end

    local heightSpan = maxY - minY + 1
    if heightSpan <= 0 then return end

    for lz = 0, CHUNK_SIZE - 1 do
        local mask = table.create(CHUNK_SIZE * heightSpan, 0)

        for lx = 0, CHUNK_SIZE - 1 do
            for y = minY, maxY do
                local id =  getBlockGlobal(world, visible, cx, cz, lx, y, lz)
                if isSolid(id) then
                    local neighbor = getBlockGlobal(world, visible, cx, cz, lx, y, lz + 1)
                    if not isSolid(neighbor) then
                        local localY = y - minY
                        local idx2 = lx + localY * CHUNK_SIZE + 1
                        mask[idx2] = id
                    end
                end
            end
        end

        greedy2D(mask, CHUNK_SIZE, heightSpan, function(ix, iy, w, h, blockId)
            -- w in lx, h in y
            local sizeX = w * BLOCK_SIZE
            local sizeY = h * BLOCK_SIZE
            local thickness = BLOCK_SIZE

            local faceZ = (lz + 1) * BLOCK_SIZE
            local centerZ = (baseZ + faceZ) + thickness * 0.5
            
            local worldY = minY + iy

            local centerY = (worldY + h * 0.5) * BLOCK_SIZE
            local centerX = baseX + (ix + w  * 0.5) * BLOCK_SIZE

            local part = getPooledPart()
            part.Size = Vector3.new(sizeX, sizeY, thickness)
            part.CFrame = CFrame.new(centerX, centerY, centerZ)

            local key = debugKey(part)
            if debugSeen[key] then
                warn("Duplicate face at", key)
            else
                debugSeen[key] = true
            end

            part.Parent = parent
            applyBlockAppearance(part, blockId)
        end)
    end
end

-- -X faces: vertical walls facing -X. 2D grid in (lz, y) per lx-slice
local function meshNegXFaces(world: ClientWorld, visible: VisibleSet, chunk: ClientChunk, parent: Instance,  renderCaves: boolean)
    local cx = chunk.cx
    local cz = chunk.cz

    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE

    local minY = chunk.minY
    local maxY = chunk.maxY

    if not renderCaves then
        if maxY < CAVE_VIS_MIN_Y then
            return -- nothing interesting in this chunk
        end
        if minY < CAVE_VIS_MIN_Y then
            minY = CAVE_VIS_MIN_Y
        end
    end

    local heightSpan = maxY - minY + 1
     if heightSpan <= 0 then return end

    for lx = 0, CHUNK_SIZE - 1 do
        local mask = table.create(CHUNK_SIZE * heightSpan, 0)

        for lz = 0, CHUNK_SIZE - 1 do
            for y = minY, maxY do
                local id = getBlockGlobal(world, visible, cx, cz, lx, y, lz)
                if isSolid(id) then
                    local neighbor = getBlockGlobal(world, visible, cx, cz, lx - 1, y, lz)
                    if not isSolid(neighbor) then
                        local localY = y - minY
                        local idx2 = lz + localY * CHUNK_SIZE + 1
                        mask[idx2] = id
                    end
                end
            end
        end

        greedy2D(mask, CHUNK_SIZE, heightSpan, function(iz, iy, w, h, blockId)
            local sizeZ = w * BLOCK_SIZE
            local sizeY = h * BLOCK_SIZE
            local thickness = BLOCK_SIZE

            local faceX = lx * BLOCK_SIZE        -- face at the -X side of this column
            local centerX = (baseX + faceX) - thickness * 0.5

            local worldY = minY + iy
            local centerY = (worldY + h * 0.5) * BLOCK_SIZE
            local centerZ = baseZ + (iz + w * 0.5) * BLOCK_SIZE

            local part = getPooledPart()
            part.Size = Vector3.new(thickness, sizeY, sizeZ)
            part.CFrame = CFrame.new(centerX, centerY, centerZ)

            local key = debugKey(part)
            if debugSeen[key] then
                warn("Duplicate face at", key)
            else
                debugSeen[key] = true
            end

            part.Parent = parent
            applyBlockAppearance(part, blockId)
        end)
    end
end

-- -Z faces: vertical walls facing -Z. 2D grid in (lx, y) per lz-slice
local function meshNegZFaces(world: ClientWorld, visible: VisibleSet, chunk: ClientChunk, parent: Instance, renderCaves: boolean)
    local cx = chunk.cx
    local cz = chunk.cz

    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE

    local minY = chunk.minY
    local maxY = chunk.maxY

    if not renderCaves then
        if maxY < CAVE_VIS_MIN_Y then
            return -- nothing interesting in this chunk
        end
        if minY < CAVE_VIS_MIN_Y then
            minY = CAVE_VIS_MIN_Y
        end
    end

    local heightSpan = maxY - minY + 1
    if heightSpan <= 0 then return end

    for lz = 0, CHUNK_SIZE - 1 do
        local mask = table.create(CHUNK_SIZE * heightSpan, 0)

        for lx = 0, CHUNK_SIZE - 1 do
            for y = minY,maxY do
                local id = getBlockGlobal(world, visible, cx, cz, lx, y, lz)
                if isSolid(id) then
                    local neighbor = getBlockGlobal(world, visible, cx, cz, lx, y, lz - 1)
                    if not isSolid(neighbor) then
                        local localY = y - minY
                        local idx2 = lx + localY * CHUNK_SIZE + 1
                        mask[idx2] = id
                    end
                end
            end
        end

        greedy2D(mask, CHUNK_SIZE, heightSpan, function(ix, iy, w, h, blockId)
            local sizeX = w * BLOCK_SIZE
            local sizeY = h * BLOCK_SIZE
            local thickness = BLOCK_SIZE

            local faceZ = lz * BLOCK_SIZE        -- face at the -Z side of this column
            local centerZ = (baseZ + faceZ) - thickness * 0.5

            local worldY = minY + iy
            local centerY = (worldY + h * 0.5) * BLOCK_SIZE
            local centerX = baseX + (ix + w * 0.5) * BLOCK_SIZE

            local part = getPooledPart()
            part.Size = Vector3.new(sizeX, sizeY, thickness)
            part.CFrame = CFrame.new(centerX, centerY, centerZ)

            local key = debugKey(part)
            if debugSeen[key] then
                warn("Duplicate face at", key)
            else
                debugSeen[key] = true
            end

            part.Parent = parent
            applyBlockAppearance(part, blockId)
        end)
    end
end

-- -Y faces: horizontal ceilings facing down. 2D grid in (lx, lz) per y-layer
local function meshCeilingFaces(world: ClientWorld, visible: VisibleSet, chunk: ClientChunk, parent: Instance,  renderCaves: boolean)
    local cx = chunk.cx
    local cz = chunk.cz

    local baseX = cx * CHUNK_SIZE * BLOCK_SIZE
    local baseZ = cz * CHUNK_SIZE * BLOCK_SIZE

    -- If you already have chunk.minY / chunk.maxY, use those instead of 0..WORLD_HEIGHT-1
    local minY = chunk.minY
    local maxY = chunk.maxY

    if not renderCaves then
        if maxY < CAVE_VIS_MIN_Y then
            return
        end
        if minY < CAVE_VIS_MIN_Y then
            minY = CAVE_VIS_MIN_Y
        end
    end

    if minY > maxY then return end

    for y = minY, maxY do
        local mask = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)

        for lz = 0, CHUNK_SIZE - 1 do
            for lx = 0, CHUNK_SIZE - 1 do
                local id = getBlockGlobal(world, visible, cx, cz, lx, y, lz)
                if isSolid(id) then
                    local below = getBlockGlobal(world, visible, cx, cz, lx, y - 1, lz)
                    if not isSolid(below) then
                        local idx2 = lx + lz * CHUNK_SIZE + 1
                        mask[idx2] = id
                    end
                end
            end
        end

        greedy2D(mask, CHUNK_SIZE, CHUNK_SIZE, function(ix, iz, w, h, blockId)
            local sizeX = w * BLOCK_SIZE
            local sizeZ = h * BLOCK_SIZE
            local thickness = BLOCK_SIZE

            local centerX = baseX + (ix * BLOCK_SIZE) + sizeX * 0.5
            -- Face is at the *bottom* of this layer
            local centerY = (y * BLOCK_SIZE) - thickness * 0.5
            local centerZ = baseZ + (iz * BLOCK_SIZE) + sizeZ * 0.5

            local part = getPooledPart()
            part.Size = Vector3.new(sizeX, thickness, sizeZ)
            -- face down: flip by 180° around X (or use CFrame.fromMatrix with -Y normal)
            part.CFrame = CFrame.new(centerX, centerY, centerZ) * CFrame.Angles(math.pi, 0, 0)

            local key = debugKey(part)
            if debugSeen[key] then
                warn("Duplicate face at", key)
            else
                debugSeen[key] = true
            end

            part.Parent = parent
            applyBlockAppearance(part, blockId)
        end)
    end
end



-- ========== PUBLIC API ==========

local ChunkMesher = {}

local MeshCount:number = 0

function ChunkMesher.BuildChunk(world: ClientWorld, visible: VisibleSet, chunk: ClientChunk, parent: Instance): Model
    local key = chunkKey(chunk.cx, chunk.cz)

    debugSeen = {} 

    local model = Instance.new("Model")
    model.Name = "chunk_" .. key
    model.Parent = parent

    local renderCaves = true


    -- mesh all visible faces:
    meshTopFaces(world, visible, chunk, model)

    meshPosXFaces(world, visible, chunk, model, renderCaves)
    meshNegXFaces(world, visible, chunk, model, renderCaves)
    meshPosZFaces(world, visible, chunk, model, renderCaves)
    meshNegZFaces(world, visible, chunk, model, renderCaves)
    meshCeilingFaces(world, visible, chunk, model, renderCaves)

    for k, v in pairs(model:GetChildren()) do
        MeshCount += 1
    end

    warn("estimate MeshCount: ", MeshCount)

    return model
end

function ChunkMesher.RecyclePart(part: BasePart)
    part.Parent = nil
    table.insert(PartPool, part)
end

function ChunkMesher.RecycleChunkModel(model: Model)
    -- detach & pool BaseParts, destroy non-part stuff, then destroy model
    for _, child in ipairs(model:GetChildren()) do
        if child:IsA("BasePart") then
            ChunkMesher.RecyclePart(child)
        else
            child:Destroy()
        end
    end
    model:Destroy()
end


return ChunkMesher
