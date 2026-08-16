local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
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
local MeshedTextured: { [string]: boolean } = {} -- key -> was it built textured?
local BlockChunks: { [string]: any } = {} -- key -> per-cell BlockChunk (edited chunks)

-- RENDER RADIUS, in chunks. 8 = 17x17 = 289 chunks, ~351 boxes each, so roughly
-- 101,000 parts alive at once.
--
-- This is a GRAPHICS SETTING, not a performance bug: it is how much world exists
-- around the player, and what a machine can hold is a property of the machine.
-- Frustum culling happens after the engine's scene update, so these parts cost
-- something whether or not they are on screen — which is why this, and not
-- textures or shadows, is the dial to reach for on a weak client.
--
-- Live-tunable, no rebuild needed:
--   Workspace:SetAttribute("RenderRadius", 5)
local NEAR_RADIUS = 8
local nearRadius = NEAR_RADIUS
local function unloadRadius(): number
    return nearRadius + 4
end
-- Edited chunks go per-cell ("block mode") for instant editing, which costs many
-- more parts. You can only edit within reach (~1 chunk), so once a block-mode
-- chunk is this many chunks away it's demoted back to the cheap greedy mesh (it's
-- all client-side; the greedy build is diff-aware so it still shows your edits).
local ACTIVE_EDIT_RADIUS = 3
-- TEXTURE LOD. Chunks within this many chunks carry per-face Texture objects; past
-- it they fall back to flat block colour, which lets the renderer batch them (a part
-- with a Texture child is excluded from batching entirely).
--
-- OFF by default. It was added chasing a frame-time problem it did not cause — the
-- real one was PART_BUDGET below — and it costs real visual quality, so it is not
-- something to pay for by default. It stays because it is the right knob for a weak
-- client: the fallback is close to free visually, since tint.js normalises every
-- generated texture so its mean colour equals the block's declared colour.
--
-- Live-tunable, no rebuild needed:
--   Workspace:SetAttribute("TextureRadius", 3)   -- low-end rigs
local TEXTURE_RADIUS = math.huge
local textureRadius = TEXTURE_RADIUS
-- Per-frame meshing is bounded by TIME, not a fixed count. This is self-adapting:
-- cheap (flat/plains) chunks cost ~0.05 ms so we blast through ~100 in a frame,
-- while an expensive mountain chunk (~5 ms) simply consumes the whole budget on
-- its own — so plains never pay for the mountain worst case, and a mountain never
-- spikes beyond one chunk. Chunks are meshed NEAREST-FIRST so the ground under and
-- ahead of the player is always built first (no falling through when moving).
local MESH_TIME_BUDGET = 0.005  -- ~5 ms/frame
local MAX_CHUNK_PER_FRAME = 128 -- effectively "as many cheap chunks as fit"

-- ...but a Luau time budget measures the WRONG COST, and this is the number that
-- actually matters.
--
-- Meshing a cheap chunk is ~0.05 ms of Luau, so the 5 ms above would build ~100 of
-- them in one frame and hand the engine ~35,000 new parts at once. Ingesting new
-- geometry happens inside RenderViewUpdate, on the main thread, and no script timer
-- can see it — so the profile shows a 50 ms RenderViewUpdate with no Lua time
-- anywhere and looks like "the renderer is slow", when what actually happened is
-- that we dumped a world into it in a single frame. While you keep moving, new
-- chunks keep arriving and it never gets a quiet frame to catch up.
--
-- So cap NEW PARTS per frame, not milliseconds. ~1500 is roughly four average
-- chunks, or two of the 800-box cliff chunks.
local PART_BUDGET = 1500
local partBudget = PART_BUDGET

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

-- On a BAKED star (doc 23) terrain isn't derivable from a seed, so the server
-- streams each chunk's compressed record. It arrives just before the LoadChunks
-- that announces the chunk, and we hand it straight to the map.
local bakedMap = WorldGen.bakedMap()

-- Diagnostics. A baked star that renders nothing has several possible causes and
-- they are indistinguishable from inside the game, so the client says what it
-- believes: whether it has a map, how many chunks it was told to load, and how many
-- actually carried terrain. A silent client here costs an hour of guessing.
local fedChunks = 0
local announcedChunks = 0
local reported = false

blink.MapChunks.On(function(payloads)
    local map = bakedMap
    if not map then
        if not reported then
            reported = true
            warn("[ChunkClient] receiving baked chunks but this client has NO baked map — "
                .. "StarWorld fell back to procedural (StarMapMeta missing or malformed?)")
        end
        return
    end
    for _, entry in payloads do
        map.feed(entry.cx, entry.cz, entry.data, entry.raw)
        fedChunks += 1
    end
end)

-- Server tells us which chunks to load (coordinates only); we generate + mesh them.
blink.LoadChunks.On(function(payloads)
    for _, entry in payloads do
        ClientWorld[chunkKey(entry.cx, entry.cz)] = { cx = entry.cx, cz = entry.cz }
    end
    chunkcount += #payloads
    announcedChunks += #payloads
end)

-- One-shot report a few seconds in: enough time for the stream to have started, so
-- the numbers mean something.
task.delay(6, function()
    local meshed = 0
    for _ in MeshedChunks do
        meshed += 1
    end
    print(
        `[ChunkClient] baked={bakedMap ~= nil}  announced={announcedChunks}  `
            .. `terrain received={fedChunks}  meshed={meshed}`
    )
    if bakedMap and announcedChunks > 0 and fedChunks == 0 then
        warn("[ChunkClient] the server is streaming chunk COORDS but no chunk DATA — "
            .. "it thinks this star is procedural while the client thinks it is baked")
    elseif meshed == 0 and announcedChunks > 0 then
        warn("[ChunkClient] chunks arrived but none meshed — every column read as void "
            .. "(wrong map meta, or terrain for a different part of the world)")
    end
end)

blink.UnloadChunks.On(function(payloads)
    for _, key in ipairs(payloads) do
        local model = MeshedChunks[key]
        if model then
            ChunkMesher.RecycleChunkModel(model)
            MeshedChunks[key] = nil
        end
        MeshedTextured[key] = nil
        local bc = BlockChunks[key]
        if bc then
            ChunkMesher.RecycleBlockChunk(bc)
            BlockChunks[key] = nil
        end
        local chunk = ClientWorld[key]
        if chunk and bakedMap then
            bakedMap.drop(chunk.cx, chunk.cz) -- stop holding terrain we can't see
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
        MeshedTextured[key] = nil
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

-- Bulk-apply the persisted world diff sent on join. Unlike live edits this stays
-- greedy: update the overlay and drop the touched chunks' meshes so they rebuild
-- diff-aware (nearest-first, within the frame budget).
blink.SyncDiff.On(function(list)
    local dirty: { [string]: boolean } = {}
    local function mark(cx: number, cz: number)
        dirty[chunkKey(cx, cz)] = true
    end
    for _, e in list do
        WorldDiff.set(e.wx, e.y, e.wz, e.block)
        local cx = math.floor(e.wx / CHUNK_SIZE)
        local cz = math.floor(e.wz / CHUNK_SIZE)
        mark(cx, cz)
        local lx = e.wx - cx * CHUNK_SIZE
        local lz = e.wz - cz * CHUNK_SIZE
        if lx == 0 then mark(cx - 1, cz) end
        if lx == CHUNK_SIZE - 1 then mark(cx + 1, cz) end
        if lz == 0 then mark(cx, cz - 1) end
        if lz == CHUNK_SIZE - 1 then mark(cx, cz + 1) end
    end
    for key in dirty do
        local m = MeshedChunks[key]
        if m then
            ChunkMesher.RecycleChunkModel(m)
            MeshedChunks[key] = nil -- RenderStepped rebuilds it diff-aware
            MeshedTextured[key] = nil
        end
    end
end)

-- The mesher reads one block into each neighbouring chunk to get boundary faces
-- right. Procedural terrain is deterministic, so a neighbour needs nothing to be
-- "known"; a baked one has to have ARRIVED, or the chunk would mesh against
-- non-existent terrain and grow a wall along the streaming frontier. A chunk the
-- server announced but sent no record for is genuinely empty, and counts as known.
local function neighboursKnown(cx: number, cz: number): boolean
    if not bakedMap then
        return true
    end
    for dz = -1, 1 do
        for dx = -1, 1 do
            if not ClientWorld[chunkKey(cx + dx, cz + dz)] then
                return false
            end
        end
    end
    return true
end

local candidates = {} -- reused each frame: unmeshed chunks to build
local failedChunks: { [string]: boolean } = {}
local meshErrorReported = false

local function distToPlayer(key: string, pcx: number, pcz: number): number
    local chunk = ClientWorld[key]
    return chunk and math.max(math.abs(chunk.cx - pcx), math.abs(chunk.cz - pcz)) or math.huge
end

local function unloadFarChunks(pcx: number, pcz: number)
    for key, model in pairs(MeshedChunks) do
        if distToPlayer(key, pcx, pcz) > unloadRadius() then
            ChunkMesher.RecycleChunkModel(model)
            MeshedChunks[key] = nil
            MeshedTextured[key] = nil
        end
    end
    for key, bc in pairs(BlockChunks) do
        if distToPlayer(key, pcx, pcz) > unloadRadius() then
            ChunkMesher.RecycleBlockChunk(bc)
            BlockChunks[key] = nil
        end
    end
end

-- Demote block-mode chunks that drifted out of edit range back to the cheap
-- greedy mesh (diff-aware, so edits still show). One per frame to avoid a spike
-- when leaving a large built-up area.
local function demoteFarBlockChunks(pcx: number, pcz: number)
    for key, bc in pairs(BlockChunks) do
        local d = distToPlayer(key, pcx, pcz)
        if d > ACTIVE_EDIT_RADIUS and d <= unloadRadius() then
            ChunkMesher.RecycleBlockChunk(bc)
            BlockChunks[key] = nil
            local chunk = ClientWorld[key]
            if chunk then
                local tex = d <= textureRadius
                MeshedChunks[key] = ChunkMesher.BuildChunk(chunk, Chunks, tex)
                MeshedTextured[key] = tex
            end
            return -- at most one demotion per frame
        end
    end
end

-- Rebuild chunks whose texture tier no longer matches their distance. Walking away
-- drops a chunk to flat colour, walking back restores it. One per frame, like
-- demotion: a rebuild dirties the renderer's batches, so doing a ring of them in a
-- single frame is exactly the spike this whole change exists to avoid.
local function retextureChunks(pcx: number, pcz: number)
    for key, model in pairs(MeshedChunks) do
        local d = distToPlayer(key, pcx, pcz)
        local want = d <= textureRadius
        if d <= unloadRadius() and MeshedTextured[key] ~= want then
            local chunk = ClientWorld[key]
            if not chunk then
                MeshedTextured[key] = want -- nothing to rebuild from; stop retrying
                return
            end
            ChunkMesher.RecycleChunkModel(model)
            MeshedChunks[key] = ChunkMesher.BuildChunk(chunk, Chunks, want)
            MeshedTextured[key] = want
            return
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

    -- Live knobs, so all three can be A/B'd against the MicroProfiler in one
    -- session without a rebuild. Each moves a different bar: TextureRadius ->
    -- DefaultPass (batching), RenderRadius -> Scene (parts alive), PartBudget ->
    -- RenderViewUpdate while moving (new geometry per frame).
    local attr = Workspace:GetAttribute("TextureRadius")
    if type(attr) == "number" then
        textureRadius = attr
    end
    attr = Workspace:GetAttribute("RenderRadius")
    if type(attr) == "number" and attr >= 1 then
        nearRadius = attr
    end
    attr = Workspace:GetAttribute("PartBudget")
    if type(attr) == "number" and attr >= 1 then
        partBudget = attr
    end

    unloadFarChunks(pcx, pcz)
    demoteFarBlockChunks(pcx, pcz)
    retextureChunks(pcx, pcz)

    -- Collect chunks the server has told us to load but that aren't meshed yet,
    -- tagged by squared distance to the player. Faces at chunk boundaries are
    -- generated deterministically, so no neighbor data is needed (no seams).
    table.clear(candidates)
    for dz = -nearRadius, nearRadius do
        for dx = -nearRadius, nearRadius do
            local key = chunkKey(pcx + dx, pcz + dz)
            if ClientWorld[key] and not MeshedChunks[key] and not BlockChunks[key]
                and neighboursKnown(pcx + dx, pcz + dz) then
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

    -- Mesh within a budget so a run of expensive (tall) chunks can't spike the
    -- frame; the closest one always builds (at least 1 per frame). The PART budget
    -- is the one that binds — see PART_BUDGET — and the time budget stays as a
    -- second guard for a chunk that is slow to mesh without being large.
    local deadline = os.clock() + MESH_TIME_BUDGET
    local partsAtStart = ChunkMesher.PartsBuilt()
    for n = 1, math.min(#candidates, MAX_CHUNK_PER_FRAME) do
        local c = candidates[n]
        -- One bad chunk must not take the renderer with it. This runs inside a
        -- RenderStepped connection, and an error here DISCONNECTS it — so a single
        -- malformed chunk would stop all meshing permanently, which reads exactly
        -- like "it renders a few chunks near spawn and then stops forever".
        local ok, err = pcall(function()
            local tex = distToPlayer(c.key, pcx, pcz) <= textureRadius
            MeshedChunks[c.key] = ChunkMesher.BuildChunk(ClientWorld[c.key], Chunks, tex)
            MeshedTextured[c.key] = tex
        end)
        if not ok then
            failedChunks[c.key] = true
            ClientWorld[c.key] = nil -- don't retry it every frame
            if not meshErrorReported then
                meshErrorReported = true
                warn(`[ChunkClient] chunk {c.key} failed to mesh: {err}`)
            end
        end
        if ChunkMesher.PartsBuilt() - partsAtStart >= partBudget or os.clock() >= deadline then
            break
        end
    end
end)

-- ===== Spawn on the terrain (freeze until the local chunk is meshed) =====
-- The character is network-owned by this client and collides against the
-- client-only mesh, so spawning is handled entirely here. WorldGen is
-- deterministic, so we know the exact ground height with zero data transfer.
local SPAWN_CLEARANCE = 5 -- studs above the surface block's top face

-- Ground CFrame at an XZ, or nil if we don't know yet. On a baked star the local
-- column is only known once its chunk has streamed in, and guessing would drop the
-- player at y=0 under the island; the server already spawned them in the right
-- place, so "don't know" means "don't move".
local function surfaceCFrameAt(x: number, z: number): CFrame?
    local wx = math.floor(x / WorldGen.BLOCK_SIZE)
    local wz = math.floor(z / WorldGen.BLOCK_SIZE)
    local surfaceY = WorldGen.getSurfaceHeight(wx, wz)
    if surfaceY < 0 then
        return nil
    end
    local topY = (surfaceY + 1) * WorldGen.BLOCK_SIZE
    return CFrame.new(x, topY + SPAWN_CLEARANCE, z)
end

-- The character ALWAYS auto-loads; it is held still here until the ground under it
-- exists. That is the opposite of switching CharacterAutoLoads off, which made
-- death permanent (nothing ever reloaded the character) and put the whole spawn on
-- a knife edge. Freezing is recoverable; not spawning is not.
--
-- `WorldReady` on the local player is how the loading screen knows to stay up. It
-- goes false on every spawn, including respawns, so a death mid-flight through
-- unmeshed terrain gets the same treatment as a join.
local SPAWN_TIMEOUT = 45 -- generous: a baked star streams its terrain over the wire

local function setupSpawn(char: Model)
    localPlayer:SetAttribute("WorldReady", false)

    -- WaitForChild, not FindFirstChild: on a fresh spawn the rig is assembled a
    -- piece at a time and the root is frequently not there yet, which is what made
    -- the old placement silently do nothing.
    local root = char:WaitForChild("HumanoidRootPart", 20) :: BasePart?
    if not root then
        warn("[ChunkClient] character has no HumanoidRootPart — releasing without seating")
        localPlayer:SetAttribute("WorldReady", true)
        return
    end

    root.Anchored = true

    task.spawn(function()
        local t0 = os.clock()

        -- 1) Wait until this column is KNOWN. On a baked star that means its chunk
        --    has streamed in; on a procedural one it is known immediately.
        local seat = surfaceCFrameAt(root.Position.X, root.Position.Z)
        while not seat and root.Parent and os.clock() - t0 < SPAWN_TIMEOUT do
            task.wait(0.1)
            seat = surfaceCFrameAt(root.Position.X, root.Position.Z)
        end
        if seat and root.Parent then
            root.CFrame = seat
        end

        -- 2) Wait for the chunk under us to actually MESH — the mesh parts are the
        --    collision, so releasing before it exists drops you through the world.
        local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)
        local key = chunkKey(pcx, pcz)
        while not MeshedChunks[key] and not BlockChunks[key] and root.Parent and os.clock() - t0 < SPAWN_TIMEOUT do
            task.wait(0.1)
        end

        if root.Parent then
            local ground = surfaceCFrameAt(root.Position.X, root.Position.Z)
            if ground then
                root.CFrame = ground
            end
            task.wait()
            root.Anchored = false
            if not MeshedChunks[key] and not BlockChunks[key] then
                warn(
                    `[ChunkClient] released after {math.round(os.clock() - t0)}s with no mesh under `
                        .. `chunk {key} — expect a fall. Terrain never arrived.`
                )
            end
        end
        localPlayer:SetAttribute("WorldReady", true)
    end)
end

localPlayer.CharacterAdded:Connect(setupSpawn)
if localPlayer.Character then
    setupSpawn(localPlayer.Character)
end


return ClientWorld