-- ReplicatedStorage/Misc/WorldDiff.luau
--!optimize 2
--!native

-- The player-edit overlay. The world is `base (WorldGen) ⊕ diff`: this module
-- stores only changed cells. A broken block is stored as Air; a placed block as
-- its id. Shared by the client (rendering) and the server (authority) — each VM
-- keeps its own copy, kept in sync by the network.
--
-- Storage is a nested table edits[wx][y][wz] = blockId to avoid per-cell string
-- keys in the mesher's hot loop. Per-chunk info (edit count + Y bounds) lets the
-- mesher skip the diff entirely for untouched chunks and grow its Y range to
-- cover blocks built above the surface or dug below.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)

local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local blockAt = WorldGen.blockAt

local WorldDiff = {}

local edits: { [number]: { [number]: { [number]: number } } } = {}
type ChunkInfo = { count: number, minY: number, maxY: number }
local chunkInfo: { [string]: ChunkInfo } = {}

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

-- Set (or clear) a cell. Returns true if it actually changed the overlay.
function WorldDiff.set(wx: number, y: number, wz: number, blockId: number)
    local col = edits[wx]
    if not col then
        col = {}
        edits[wx] = col
    end
    local row = col[y]
    if not row then
        row = {}
        col[y] = row
    end
    row[wz] = blockId

    local ck = chunkKey(math.floor(wx / CHUNK_SIZE), math.floor(wz / CHUNK_SIZE))
    local info = chunkInfo[ck]
    if not info then
        chunkInfo[ck] = { count = 1, minY = y, maxY = y }
    else
        info.count += 1
        if y < info.minY then info.minY = y end
        if y > info.maxY then info.maxY = y end
    end
end

-- Raw overlay value at a cell, or nil if unedited.
function WorldDiff.get(wx: number, y: number, wz: number): number?
    local col = edits[wx]
    if not col then return nil end
    local row = col[y]
    if not row then return nil end
    return row[wz]
end

-- Resolved block: overlay if present, else deterministic base. Same signature as
-- WorldGen.blockAt so the mesher can swap between them.
function WorldDiff.blockAt(wx: number, y: number, wz: number, surfaceY: number, biomeId: number): number
    local col = edits[wx]
    if col then
        local row = col[y]
        if row then
            local e = row[wz]
            if e ~= nil then
                return e
            end
        end
    end
    return blockAt(wx, y, wz, surfaceY, biomeId)
end

-- Does this chunk (or a 1-block border into its neighbors) have any edits? The
-- mesher uses this to keep untouched chunks on the pure fast path.
function WorldDiff.chunkHasEdits(cx: number, cz: number): boolean
    for dz = -1, 1 do
        for dx = -1, 1 do
            if chunkInfo[chunkKey(cx + dx, cz + dz)] then
                return true
            end
        end
    end
    return false
end

-- Edit Y bounds for a chunk (nil if none), so the mesher can extend its range.
function WorldDiff.chunkYBounds(cx: number, cz: number): (number?, number?)
    local info = chunkInfo[chunkKey(cx, cz)]
    if info then
        return info.minY, info.maxY
    end
    return nil, nil
end

return WorldDiff
