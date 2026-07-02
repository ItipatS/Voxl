local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

local std = ReplicatedStorage.std

local blink = require(std.ClientNet)

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local ChunkMesher = require(ReplicatedStorage.Misc.Mesher)
local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)

local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local WORLD_HEIGHT = WorldGen.WORLD_HEIGHT

local chunkcount:number = 0

local MeshedChunks = {}   -- key -> greedy Model (untouched chunks)
local BlockChunks: { [string]: any } = {} -- key -> per-cell BlockChunk (edited chunks)

local NEAR_RADIUS = 8            -- render radius (chunks)
local UNLOAD_RADIUS = NEAR_RADIUS + 4
-- Per-frame meshing is bounded by TIME, not a fixed count. This is self-adapting:
-- cheap (flat/plains) chunks cost ~0.05 ms so we blast through ~100 in a frame,
-- while an expensive mountain chunk (~5 ms) simply consumes the whole budget on
-- its own — so plains never pay for the mountain worst case, and a mountain never
-- spikes beyond one chunk. Chunks are meshed NEAREST-FIRST so the ground under and
-- ahead of the player is always built first (no falling through when moving).
local MESH_TIME_BUDGET = 0.005  -- ~5 ms/frame
local MAX_CHUNK_PER_FRAME = 128 -- effectively "as many cheap chunks as fit"

-- A chunk is just a coordinate now: the client generates its terrain from the
-- deterministic WorldGen, so no block data is stored or transferred.
export type ClientChunk = {
    cx: number,
    cz: number,
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

local Chunks = Instance.new("Folder")
Chunks.Name = "Chunks"
Chunks.Parent = workspace

-- Server tells us which chunks to load (coordinates only); we generate + mesh them.
blink.LoadChunks.On(function(payloads)
    for _, entry in payloads do
        ClientWorld[chunkKey(entry.cx, entry.cz)] = { cx = entry.cx, cz = entry.cz }
    end
    chunkcount += #payloads
end)

blink.UnloadChunks.On(function(payloads)
    for _, key in ipairs(payloads) do
        local model = MeshedChunks[key]
        if model then
            ChunkMesher.RecycleChunkModel(model)
            MeshedChunks[key] = nil
        end
        local bc = BlockChunks[key]
        if bc then
            ChunkMesher.RecycleBlockChunk(bc)
            BlockChunks[key] = nil
        end
        ClientWorld[key] = nil
    end
end)

-- Edited chunks switch to per-cell "block mode" so edits are incremental (touch
-- only the changed cell + neighbors) — no whole-chunk rebuild, no blink, and
-- break/place are both instant. Untouched chunks stay on the greedy mesh.
local function ensureBlockMode(cx: number, cz: number): ChunkMesher.BlockChunk?
    local key = chunkKey(cx, cz)
    local bc = BlockChunks[key]
    if bc then
        return bc
    end
    if not ClientWorld[key] then
        return nil -- not loaded; the edit is in the diff and will show on load
    end
    local greedy = MeshedChunks[key]
    if greedy then
        ChunkMesher.RecycleChunkModel(greedy)
        MeshedChunks[key] = nil
    end
    bc = ChunkMesher.BuildBlockChunk(ClientWorld[key], Chunks)
    BlockChunks[key] = bc
    return bc
end

-- Apply server-confirmed edits into the overlay, then incrementally update the
-- edited cell + its 6 neighbors (each in whatever chunk it belongs to).
blink.BlockEdited.On(function(list)
    for _, e in list do
        WorldDiff.set(e.wx, e.y, e.wz, e.block)
        local neighbors = {
            { e.wx, e.y, e.wz },
            { e.wx + 1, e.y, e.wz }, { e.wx - 1, e.y, e.wz },
            { e.wx, e.y + 1, e.wz }, { e.wx, e.y - 1, e.wz },
            { e.wx, e.y, e.wz + 1 }, { e.wx, e.y, e.wz - 1 },
        }
        for _, c in neighbors do
            local bc = ensureBlockMode(math.floor(c[1] / CHUNK_SIZE), math.floor(c[3] / CHUNK_SIZE))
            if bc then
                ChunkMesher.UpdateBlockCell(bc, c[1], c[2], c[3])
            end
        end
    end
end)

local candidates = {} -- reused each frame: unmeshed chunks to build

local function distToPlayer(key: string, pcx: number, pcz: number): number
    local chunk = ClientWorld[key]
    return chunk and math.max(math.abs(chunk.cx - pcx), math.abs(chunk.cz - pcz)) or math.huge
end

local function unloadFarChunks(pcx: number, pcz: number)
    for key, model in pairs(MeshedChunks) do
        if distToPlayer(key, pcx, pcz) > UNLOAD_RADIUS then
            ChunkMesher.RecycleChunkModel(model)
            MeshedChunks[key] = nil
        end
    end
    for key, bc in pairs(BlockChunks) do
        if distToPlayer(key, pcx, pcz) > UNLOAD_RADIUS then
            ChunkMesher.RecycleBlockChunk(bc)
            BlockChunks[key] = nil
        end
    end
end

RunService.RenderStepped:Connect(function()
    local character = localPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end
    local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)

    unloadFarChunks(pcx, pcz)

    -- Collect chunks the server has told us to load but that aren't meshed yet,
    -- tagged by squared distance to the player. Faces at chunk boundaries are
    -- generated deterministically, so no neighbor data is needed (no seams).
    table.clear(candidates)
    for dz = -NEAR_RADIUS, NEAR_RADIUS do
        for dx = -NEAR_RADIUS, NEAR_RADIUS do
            local key = chunkKey(pcx + dx, pcz + dz)
            if ClientWorld[key] and not MeshedChunks[key] and not BlockChunks[key] then
                candidates[#candidates + 1] = { key = key, d = dx * dx + dz * dz }
            end
        end
    end
    if #candidates == 0 then
        return
    end

    -- Nearest-first: the chunk under (and closest ahead of) the player builds
    -- before distant scenery, so collision is always ready where it matters.
    table.sort(candidates, function(a, b)
        return a.d < b.d
    end)

    -- Mesh within a time budget so a run of expensive (tall) chunks can't spike
    -- the frame; the closest one always builds (at least 1 per frame).
    local deadline = os.clock() + MESH_TIME_BUDGET
    for n = 1, math.min(#candidates, MAX_CHUNK_PER_FRAME) do
        local c = candidates[n]
        MeshedChunks[c.key] = ChunkMesher.BuildChunk(ClientWorld[c.key], Chunks)
        if os.clock() >= deadline then
            break
        end
    end
end)

-- ===== Spawn on the terrain (freeze until the local chunk is meshed) =====
-- The character is network-owned by this client and collides against the
-- client-only mesh, so spawning is handled entirely here. WorldGen is
-- deterministic, so we know the exact ground height with zero data transfer.
local SPAWN_CLEARANCE = 5 -- studs above the surface block's top face

local function surfaceCFrameAt(x: number, z: number): CFrame
    local wx = math.floor(x / WorldGen.BLOCK_SIZE)
    local wz = math.floor(z / WorldGen.BLOCK_SIZE)
    local surfaceY = WorldGen.getSurfaceHeight(wx, wz)
    local topY = (surfaceY + 1) * WorldGen.BLOCK_SIZE
    return CFrame.new(x, topY + SPAWN_CLEARANCE, z)
end

local function setupSpawn(char: Model)
    local root = char:WaitForChild("HumanoidRootPart") :: BasePart

    -- Place on the ground immediately (deterministic) and freeze so we never
    -- fall through terrain that hasn't meshed yet.
    root.Anchored = true
    root.CFrame = surfaceCFrameAt(root.Position.X, root.Position.Z)

    task.spawn(function()
        local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)
        local key = chunkKey(pcx, pcz)

        -- wait for the chunk under the spawn point to mesh (parts are collision)
        local t0 = os.clock()
        while not MeshedChunks[key] and os.clock() - t0 < 15 do
            task.wait(0.1)
        end

        -- Re-seat on the exact surface (in case the spawn XZ moved) and release.
        if root.Parent then
            root.CFrame = surfaceCFrameAt(root.Position.X, root.Position.Z)
            task.wait()
            root.Anchored = false
        end
    end)
end

localPlayer.CharacterAdded:Connect(setupSpawn)
if localPlayer.Character then
    setupSpawn(localPlayer.Character)
end


return ClientWorld