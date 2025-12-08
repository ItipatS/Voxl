-- ServerScriptService/ChunkServer.luau
--!optimize 2
--!native
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std = ReplicatedStorage.std

local blink = require(game:GetService("ServerScriptService").ServerNet)
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)

local scheduler = require(std.scheduler)
local phases = require(std.phases)

local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local BLOCK_SIZE = WorldGen.BLOCK_SIZE

local JOIN_BOOST_DURATION = 4

local FAST_BATCH = 32
local FAST_INTERVAL = 0.2

local NORMAL_BATCH = 16
local NORMAL_INTERVAL = 0.5

-- How many chunks of DATA we want per player
local REGION_RADIUS_CHUNKS = 24

local REGION_SHIFT_THRESHOLD = math.floor(REGION_RADIUS_CHUNKS * 0.5)

-- ===== World cache (server-wide) =====
local ChunkCache: { [string]: WorldGen.ChunkFull } = {}

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

local function decodeChunkKey(key: string): (number, number)
    local sx, sz = string.match(key, "([^:]+):([^:]+)")
    return tonumber(sx) :: number, tonumber(sz) :: number
end

local function getOrGenerateChunk(cx: number, cz: number): WorldGen.ChunkFull
    local key = chunkKey(cx, cz)
    local chunk = ChunkCache[key]
    if not chunk then
        chunk = WorldGen.generateChunkFull(cx, cz)
        ChunkCache[key] = chunk
    end
    return chunk
end

-- ===== Per-player streaming state =====
type PlayerState = {
    loaded: { [string]: boolean },
    pending: { string },
    backgroundPending: { string },
    centerCx: number?,
    centerCz: number?,
    joinedAt: number,
    timeAccum: number,
    lazyAccum: number,
}

local playerState: { [Player]: PlayerState } = {}

local function ensureState(plr: Player): PlayerState
    local st = playerState[plr]
    if st then return st end
    st = {
        loaded = {},
        pending = {},
        backgroundPending = {},
        centerCx = nil,
        centerCz = nil,
        joinedAt = os.clock(),
        timeAccum = 0,
        lazyAccum = 0,
    }
    playerState[plr] = st
    return st
end

local function worldToChunk(px: number, pz: number): (number, number)
    local blockX = px / BLOCK_SIZE
    local blockZ = pz / BLOCK_SIZE
    local cx = math.floor(blockX / CHUNK_SIZE)
    local cz = math.floor(blockZ / CHUNK_SIZE)
    return cx, cz
end

local function buildRegionDesired(rcx: number, rcz: number): { [string]: boolean }
    local desired: { [string]: boolean } = {}

    for dz = -REGION_RADIUS_CHUNKS, REGION_RADIUS_CHUNKS do
        for dx = -REGION_RADIUS_CHUNKS, REGION_RADIUS_CHUNKS do
            local cx = rcx + dx
            local cz = rcz + dz
            local key = chunkKey(cx, cz)
            desired[key] = true
        end
    end

    return desired
end

local function initRegionForPlayer(plr: Player, st: PlayerState, pcx: number, pcz: number)
    st.centerCx = pcx
    st.centerCz = pcz

    local desired = buildRegionDesired(pcx, pcz)

    -- initial pending list = entire region
    local pending = {}

    for key, _ in pairs(desired) do
        if not st.loaded[key] then
            pending[#pending + 1] = key
        end
    end

    st.pending = pending
    -- st.loaded will be filled as we send chunks in the streamer
end

local function maybeShiftRegion(plr: Player, st: PlayerState, pcx: number, pcz: number)
    -- if no region yet, this is effectively "init"
    if not st.centerCx or not st.centerCz then
        initRegionForPlayer(plr, st, pcx, pcz)
        return
    end

    local rcx = st.centerCx
    local rcz = st.centerCz

    -- Chebyshev distance from region center
    local dist = math.max(math.abs(pcx - rcx), math.abs(pcz - rcz))

    -- if player is still within threshold, do nothing
    if dist < REGION_SHIFT_THRESHOLD then
        return
    end

    -- Player has walked "far enough": shift region center
    st.centerCx = pcx
    st.centerCz = pcz

    local newDesired = buildRegionDesired(pcx, pcz)

    -- new pending = chunks in newDesired we don't have yet
    local newPending = {}
    for key, _ in pairs(newDesired) do
        if not st.loaded[key] then
            newPending[#newPending + 1] = key
        end
    end

    -- chunks we no longer want in this region => unload
    local toUnload = {}
    for key, _ in pairs(st.loaded) do
        if not newDesired[key] then
            toUnload[#toUnload + 1] = key
            st.loaded[key] = nil
        end
    end

    st.backgroundPending = newPending

    if #toUnload > 0 then
        blink.UnloadChunks.Fire(plr, toUnload)
    end
end

local function updateRegionForPlayer(plr: Player, st: PlayerState)
    local char = plr.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)

    -- init or maybe shift the region
    maybeShiftRegion(plr, st, pcx, pcz)
end

-- ===== Background streamer =====
local function backgroundChunkStreamer(dt: number)
    for _, plr in ipairs(Players:GetPlayers()) do
        local st = ensureState(plr)

        -- per-player timer
        st.timeAccum += dt
        st.lazyAccum += dt

        -- determine mode
        local timeSinceJoin = os.clock() - st.joinedAt
        local isFast = timeSinceJoin < JOIN_BOOST_DURATION

        local interval = isFast and FAST_INTERVAL or NORMAL_INTERVAL
        local batchSize = isFast and FAST_BATCH or NORMAL_BATCH

        -- wait until this player's timer passes their interval
        if st.timeAccum < interval then
            continue
        end
        st.timeAccum = 0 -- reset for this player only

        updateRegionForPlayer(plr, st)

        local pending = st.pending
        if #pending > 0 then
            local batch = table.create(batchSize)

            for i = 1, batchSize do
                local key = pending[#pending]
                if not key then break end
                pending[#pending] = nil

                local cx, cz = decodeChunkKey(key)
                local chunk = getOrGenerateChunk(cx, cz)

                batch[#batch + 1] = {
                    cx = chunk.cx,
                    cz = chunk.cz,
                    blocks = chunk.blocks,
                    heightfields = chunk.heightfields,
                }

                st.loaded[key] = true
            end

            if #batch > 0 then
                blink.ChunkFullStream.Fire(plr, batch)
            end
        end

        -- ===== 2) Send backgroundPending at a slower rate =====
        local lazyInterval = 0.5
        local lazyBatch = 16

        -- Only start background streaming once we actually HAVE a region center
        if st.centerCx and st.centerCz and st.lazyAccum >= lazyInterval then
            st.lazyAccum = 0

            local backgroundPending = st.backgroundPending
            if #backgroundPending > 0 then
                local batch = table.create(lazyBatch)

                for i = 1, lazyBatch do
                    local key = backgroundPending[#backgroundPending]
                    if not key then break end
                    backgroundPending[#backgroundPending] = nil

                    local cx, cz = decodeChunkKey(key)
                    local chunk = getOrGenerateChunk(cx, cz)

                    batch[#batch + 1] = {
                        cx = chunk.cx,
                        cz = chunk.cz,
                        blocks = chunk.blocks,
                        heightfields = chunk.heightfields,
                    }

                    st.loaded[key] = true
                end

                if #batch > 0 then
                    blink.ChunkFullStream.Fire(plr, batch)
                end
            end
        end
    end
end


-- Cleanup when players leave
local function PlayerRemoving(plr : Player)
    playerState[plr] = nil
end

scheduler.SYSTEM(backgroundChunkStreamer, phases.Heartbeat)
scheduler.SYSTEM(PlayerRemoving, phases.PlayerRemoving)

return 0
