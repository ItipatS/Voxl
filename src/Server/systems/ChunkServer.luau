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

local FAST_BATCH = 128
local FAST_INTERVAL = 0.1

local NORMAL_BATCH = 24
local NORMAL_INTERVAL = 0.5

-- How many chunks of DATA we want per player
local MAX_CHUNKS_PER_PLAYER = 3000

local DATA_RADIUS_CHUNKS = 12

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
    loaded: { [string]: boolean }, -- chunks this player already has in ClientWorld
    pending: { string },           -- queue of chunk keys to send
    centerCx: number?,
    centerCz: number?,
    joinedAt: number,
    timeAccum: number,
}

local playerState: { [Player]: PlayerState } = {}

local function ensureState(plr: Player): PlayerState
    local st = playerState[plr]
    if st then return st end
    st = {
        loaded = {},
        pending = {},
        centerCx = nil,
        centerCz = nil,
        joinedAt = os.clock(),
        timeAccum = 0
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

-- Rebuild desired chunk set around player center and update pending list
local function rebuildDesiredChunks(plr: Player, st: PlayerState, pcx: number, pcz: number)
    st.centerCx = pcx
    st.centerCz = pcz

    local desired: { [string]: boolean } = {}
    local count = 0

    for dz = -DATA_RADIUS_CHUNKS, DATA_RADIUS_CHUNKS do
        for dx = -DATA_RADIUS_CHUNKS, DATA_RADIUS_CHUNKS do
            local cx = pcx + dx
            local cz = pcz + dz
            local key = chunkKey(cx, cz)

            desired[key] = true
            count += 1

            if count >= MAX_CHUNKS_PER_PLAYER then
                break
            end
        end
        if count >= MAX_CHUNKS_PER_PLAYER then
            break
        end
    end

    -- Build a fresh pending queue = desired - already loaded
    local newPending = table.create(count)

    for key, _ in pairs(desired) do
        if not st.loaded[key] then
            newPending[#newPending + 1] = key
        end
    end


    --[[local toUnload = {}
    for key, _ in pairs(st.loaded) do
         if not desired[key] then
             toUnload[#toUnload+1] = key
             st.loaded[key] = nil
         end
     end
    if #toUnload > 0 then blink.UnloadChunks.Fire(plr, toUnload) end]]

    st.pending = newPending
end

-- Update player's center chunk if they moved far enough, and rebuild pending
local function updatePlayerCenterAndDesired(plr: Player, st: PlayerState)
    local char = plr.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)

    if st.centerCx == pcx and st.centerCz == pcz then
        return -- still inside same chunk => keep current desired/pending
    end

    rebuildDesiredChunks(plr, st, pcx, pcz)
end

-- ===== Background streamer =====
local function backgroundChunkStreamer(dt: number)
    for _, plr in ipairs(Players:GetPlayers()) do
        local st = ensureState(plr)

        -- per-player timer
        st.timeAccum += dt

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

        updatePlayerCenterAndDesired(plr, st)
        local pending = st.pending
        if #pending == 0 then
            continue
        end

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
end


-- Cleanup when players leave
local function PlayerRemoving(plr : Player)
    playerState[plr] = nil
end

scheduler.SYSTEM(backgroundChunkStreamer, phases.Heartbeat)
scheduler.SYSTEM(PlayerRemoving, phases.PlayerRemoving)

return 0
