-- ServerScriptService/systems/ChunkServer.luau
--!optimize 2
--!native
--!strict

-- Procedural terrain is deterministic (WorldGen), so the server never generates or
-- sends block data — it just tells each client WHICH chunks to load (coordinates,
-- ~4 bytes each) and the client generates + meshes them locally. The server stays
-- authoritative over what a player streams (and, later, edit diffs) while the wire
-- cost drops from ~15 KB/chunk to ~4 bytes/chunk.
--
-- A BAKED star (doc 23) can't be derived from a seed, so those chunks DO carry
-- data — but only the ones a player actually reaches, and still compressed
-- (~540 B each). The map itself never leaves ServerStorage. Records are sent just
-- before the matching LoadChunks, in the same reliable flush, so the data is always
-- present by the time the client is told to build the chunk.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std = ReplicatedStorage.std

local blink = require(game:GetService("ServerScriptService").ServerNet)
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)

local scheduler = require(std.scheduler)
local phases = require(std.phases)

local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local BLOCK_SIZE = WorldGen.BLOCK_SIZE

-- How far out to keep each player's chunks loaded (chunks). Slightly beyond the
-- client's render radius so there's a prefetch margin.
local LOAD_RADIUS = 12
local UNLOAD_RADIUS = LOAD_RADIUS + 3
-- Coordinates are tiny, so we can send a lot per tick without any interval delay;
-- this is just a soft cap so a single packet stays sane.
local SEND_BATCH = 128
-- A baked chunk carries ~540 bytes of terrain, so the same batch size would mean a
-- 70 KB packet every Heartbeat. Cap it far lower and let the stream fill in over a
-- second or two — the client meshes nearest-first anyway.
local SEND_BATCH_BAKED = 16

type PlayerState = {
    sent: { [string]: boolean },
}

local playerState: { [Player]: PlayerState } = {}

local function ensureState(plr: Player): PlayerState
    local st = playerState[plr]
    if not st then
        st = { sent = {} }
        playerState[plr] = st
    end
    return st
end

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

local function decodeChunkKey(key: string): (number, number)
    local sx, sz = string.match(key, "([^:]+):([^:]+)")
    return tonumber(sx) :: number, tonumber(sz) :: number
end

local function worldToChunk(px: number, pz: number): (number, number)
    return math.floor(px / BLOCK_SIZE / CHUNK_SIZE), math.floor(pz / BLOCK_SIZE / CHUNK_SIZE)
end

type Candidate = { cx: number, cz: number, d: number }

local function streamForPlayer(plr: Player, st: PlayerState)
    local char = plr.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end
    local pcx, pcz = worldToChunk((root :: BasePart).Position.X, (root :: BasePart).Position.Z)

    -- 1) Unload chunks that have fallen outside the radius
    local toUnload: { string } = {}
    for key in st.sent do
        local cx, cz = decodeChunkKey(key)
        if math.max(math.abs(cx - pcx), math.abs(cz - pcz)) > UNLOAD_RADIUS then
            toUnload[#toUnload + 1] = key
            st.sent[key] = nil
        end
    end
    if #toUnload > 0 then
        blink.UnloadChunks.Fire(plr, toUnload)
    end

    -- 2) Collect not-yet-sent chunks in range, nearest first
    local candidates: { Candidate } = {}
    for dz = -LOAD_RADIUS, LOAD_RADIUS do
        for dx = -LOAD_RADIUS, LOAD_RADIUS do
            local key = chunkKey(pcx + dx, pcz + dz)
            if not st.sent[key] then
                candidates[#candidates + 1] = { cx = pcx + dx, cz = pcz + dz, d = dx * dx + dz * dz }
            end
        end
    end
    if #candidates == 0 then
        return
    end
    table.sort(candidates, function(a, b)
        return a.d < b.d
    end)

    -- 3) Send a batch of coordinates (nearest first). On a baked star each chunk
    --    also carries its compressed record — sent FIRST, so that when the client
    --    handles LoadChunks the terrain for it is already in hand.
    local map = WorldGen.bakedMap()
    local limit = if map then SEND_BATCH_BAKED else SEND_BATCH
    local batch = {}
    local records = if map then {} else nil
    for i = 1, math.min(#candidates, limit) do
        local c = candidates[i]
        batch[#batch + 1] = { cx = c.cx, cz = c.cz }
        st.sent[chunkKey(c.cx, c.cz)] = true
        if map then
            -- A void chunk (outside the island) simply has no record; the client
            -- reads "announced but never fed" as empty space.
            local data, raw = map.record(c.cx, c.cz)
            if data then
                (records :: any)[#(records :: any) + 1] =
                    { cx = c.cx, cz = c.cz, raw = raw, data = data }
            end
        end
    end
    if records and #records > 0 then
        blink.MapChunks.Fire(plr, records)
    end
    blink.LoadChunks.Fire(plr, batch)
end

local function chunkStreamer(_dt: number)
    for _, plr in ipairs(Players:GetPlayers()) do
        streamForPlayer(plr, ensureState(plr))
    end
end

local function PlayerRemoving(plr: Player)
    playerState[plr] = nil
end

scheduler.SYSTEM(chunkStreamer, phases.Heartbeat)
scheduler.SYSTEM(PlayerRemoving, phases.PlayerRemoving)

return 0
