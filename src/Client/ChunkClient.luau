local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

local std = ReplicatedStorage.std

local blink = require(std.ClientNet)

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local ChunkMesher = require(ReplicatedStorage.Misc.Mesher)

local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local WORLD_HEIGHT = WorldGen.WORLD_HEIGHT

local chunkcount:number = 0

local MeshedChunks = {}

local MeshQueue = {}
local Queued: { [string]: boolean } = {}

local CurrentVisibleSet: { [string]: boolean } = {}

local NEAR_RADIUS = 10
local FAR_RADIUS  = 12 
local UNLOAD_RADIUS  = NEAR_RADIUS + 4

local BUILD_INTERVAL = 1 / 60
local MAX_CHUNK_PER_FRAME = 5

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

local ClientWorld: ClientWorld = {}

local function worldToChunk(px: number, pz: number): (number, number)
    local blockX = px / WorldGen.BLOCK_SIZE
    local blockZ = pz / WorldGen.BLOCK_SIZE
    local cx = math.floor(blockX / CHUNK_SIZE)
    local cz = math.floor(blockZ / CHUNK_SIZE)
    return cx, cz
end

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

local function buildVisibleSet(): { [string]: boolean }
    return CurrentVisibleSet
end

local Chunks = Instance.new("Folder")
Chunks.Name = "Chunks"
Chunks.Parent = workspace

local function idx3(x: number, y: number, z: number): number
    return x + (y * CHUNK_SIZE) + (z * CHUNK_SIZE * WORLD_HEIGHT)
end

local function enqueueChunkForMeshing(cx: number, cz: number)
    local key = chunkKey(cx, cz)
    -- only if we have data, no mesh yet, and not already queued
    if ClientWorld[key] and not MeshedChunks[key] and not Queued[key] then
        table.insert(MeshQueue, key)
        Queued[key] = true
    end
end

blink.ChunkFullStream.On(function(payloads)
    for _, entry in payloads do
        local cx = entry.cx
        local cz = entry.cz
        local key = chunkKey(cx, cz)

        local heightfields = entry.heightfields

         local minY = WORLD_HEIGHT - 1
        local maxY = 0
        for _, h in ipairs(heightfields) do
            if h < minY then minY = h end
            if h > maxY then maxY = h end
        end

        local chunk: ChunkMesher.ClientChunk = {
            cx = cx,
            cz = cz,
            blocks = entry.blocks,
            heightfields = entry.heightfields,
            minY = minY,
            maxY = maxY,
        }

        ClientWorld[key] = chunk

        local offsets = {
            {  1,  0 },
            { -1,  0 },
            {  0,  1 },
            {  0, -1 },
        }

        for _, off in ipairs(offsets) do
            local ncx = chunk.cx + off[1]
            local ncz = chunk.cz + off[2]
            local nkey = chunkKey(ncx, ncz)
            if MeshedChunks[nkey] then
                enqueueChunkForMeshing(ncx, ncz)
            end
        end
    end
    chunkcount += #payloads
    print("Chunks received: ", chunkcount)
end)

blink.UnloadChunks.On(function(payloads)
    for _, key in ipairs(payloads) do
        -- destroy model if present
        local model = MeshedChunks[key]
        if model then
            ChunkMesher.RecycleChunkModel(model)
            MeshedChunks[key] = nil
        end

        -- drop voxel data (server will resend if needed later)
        ClientWorld[key] = nil
        Queued[key] = nil

        -- clean from mesh queue
        for i = #MeshQueue, 1, -1 do
            if MeshQueue[i] == key then
                table.remove(MeshQueue, i)
            end
        end
    end
end)

-- helper: get blockId or Air if nil
function ClientWorld.getBlock(cx: number, cz: number, lx: number, y: number, lz: number): number
    local key = chunkKey(cx, cz)
    local chunk = ClientWorld[key]
    if not chunk then
        return 0
    end

    local linear = idx3(lx, y, lz)
    return chunk.blocks[linear] or WorldGen.BLOCK.Air
end

local function updateRenderedChunks()
    local character = localPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end

    local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)


    -- 1) Build desired render set around player
    local desired: { [string]: boolean } = {}

    for dz = -NEAR_RADIUS, NEAR_RADIUS do
        for dx = -NEAR_RADIUS, NEAR_RADIUS do
            local cx = pcx + dx
            local cz = pcz + dz
            local key = chunkKey(cx, cz)
            desired[key] = true

            -- If we have data but no mesh yet, queue it
            if ClientWorld[key] and not MeshedChunks[key] then
                enqueueChunkForMeshing(cx, cz)
            end
        end
    end

    CurrentVisibleSet = desired

    -- 2) Destroy models that are no longer in render radius
    for key, model in pairs(MeshedChunks) do
        local chunk = ClientWorld[key]
        if chunk then
            local dist = math.max(
                math.abs(chunk.cx - pcx),
                math.abs(chunk.cz - pcz)
            ) -- Chebyshev distance in chunk space

            if dist > UNLOAD_RADIUS then
                if model then
                    ChunkMesher.RecycleChunkModel(model)
                end
                MeshedChunks[key] = nil
                Queued[key] = nil

                for i = #MeshQueue, 1, -1 do
                    if MeshQueue[i] == key then
                        table.remove(MeshQueue, i)
                    end
                end
            end
        else
            -- no data anymore, just clean up
            if model then
                ChunkMesher.RecycleChunkModel(model)
            end
            MeshedChunks[key] = nil
            Queued[key] = nil
        end
    end
end

RunService.RenderStepped:Connect(function()

    updateRenderedChunks()

     local visibleSet = buildVisibleSet()

     for i = 1, MAX_CHUNK_PER_FRAME do
        -- mesh a few per frame
        local key = table.remove(MeshQueue, 1)
        if not key then break end

        local chunk = ClientWorld[key]
        
        if chunk then
            local model = ChunkMesher.BuildChunk(ClientWorld, visibleSet, chunk, Chunks)
            MeshedChunks[key] = model
        end
        Queued[key] = nil
    end

end)


return ClientWorld