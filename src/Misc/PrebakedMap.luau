-- ReplicatedStorage/Misc/PrebakedMap.luau
--!strict
--!optimize 2
--!native

-- Reader for a BAKED world — terrain that was imported rather than generated
-- (doc 23). `tools/mcimport` turns a Minecraft save into a VXM3 blob; this module
-- is the other end of that pipe, and exposes exactly the queries WorldGen needs,
-- so every consumer (mesher, block edits, spawn, locks) works unchanged:
--
--     map.columnTop(wx, wz)  -> highest non-air y, or -1 for void
--     map.blockAt(wx, y, wz) -> block id
--     map.chunkFloor(cx, cz) -> lowest y worth meshing
--
-- It has two modes, because the map is deliberately NOT shipped to clients:
--
--   open(source)   The SERVER side. Holds the whole blob (it lives in
--                  ServerStorage, which never replicates), answers queries, and
--                  hands out single still-compressed chunk records to forward.
--   receiver(meta) The CLIENT side. Starts empty; chunks arrive through feed()
--                  as the player walks. A client only ever holds what it visited.
--
-- Two things keep it cheap:
--   * Records are DEFLATE'd individually and decoded only when something asks for
--     that chunk. Nothing large is ever materialised — not on join, not ever.
--   * A column stores only its visible shell. Below the shell the island is
--     implicit Stone (never seen, never stored); above it, implicit Air.
--
-- VXM3 layout (see tools/mcimport/bake.js — the two must agree):
--   header  "VXM3" | i16 cx0 | i16 cz0 | u16 nx | u16 nz | u16 radius | u8 yFloor | u8 flags
--   index   nx*nz × { u32 offset, u32 compLen, u16 rawLen }   compLen 0 = void chunk
--   record  deflate-raw of 256 columns × { u8 yBot, u8 nRuns, nRuns × (u8 id, u8 len) }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Blocks = require(ReplicatedStorage.Misc.Blocks)
local Inflate = require(ReplicatedStorage.Misc.inflate)

local PrebakedMap = {}

local CHUNK_SIZE = 16
local STONE = Blocks.ID.Stone
local HEADER = 16
local IDX_ENTRY = 10
local MAX_CACHED_CHUNKS = 600 -- decoded chunks kept; a render radius of 8 needs ~290

export type Source = {
    name: string,
    radius: number,
    partLen: number,           -- base64 chars per part; a multiple of 4, so no
                               -- 4-char group ever straddles two parts
    spawn: { x: number, y: number, z: number }?, -- baked-in safe landing spot
    parts: { string },
}

-- The handful of numbers a client needs to make sense of chunks it is sent.
-- Small enough to ride on replicated attributes.
export type Meta = {
    name: string,
    cx0: number,
    cz0: number,
    nx: number,
    nz: number,
    radius: number,
    yFloor: number,
}

type Chunk = {
    span: number,     -- rows per column in `blocks`
    yTop: number,     -- highest y stored in this chunk
    yBottom: number,  -- lowest stored level; below it the chunk is solid island
    blocks: buffer,   -- 256 * span, index (ci * span + (y - yFloor))
    tops: buffer,     -- 256 column tops as (top - yFloor + 1); 0 = void column
}

export type Map = {
    name: string,
    radius: number,
    yFloor: number,
    meta: Meta,
    columnTop: (wx: number, wz: number) -> number,
    blockAt: (wx: number, y: number, wz: number) -> number,
    chunkFloor: (cx: number, cz: number) -> number,
    -- server only: the still-compressed record for a chunk, ready to forward
    record: (cx: number, cz: number) -> (buffer?, number),
    -- client only: accept a record, and forget one the server unloaded
    feed: (cx: number, cz: number, comp: buffer, rawLen: number) -> (),
    drop: (cx: number, cz: number) -> (),
}

-- ===== base64 =====
local B64 = buffer.create(256)
do
    local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    buffer.fill(B64, 0, 0, 256)
    for i = 1, 64 do
        buffer.writeu8(B64, string.byte(ALPHA, i), i - 1)
    end
end

-- Decode `len` bytes of the blob starting at byte `from`. Parts are sliced at a
-- multiple of 4 base64 chars, so a 4-char group never straddles two parts.
local function decodeRange(src: Source, from: number, len: number): buffer
    local parts, partLen = src.parts, src.partLen
    local firstGroup = from // 3
    local skip = from - firstGroup * 3
    local lastGroup = (from + len - 1) // 3
    local nGroups = lastGroup - firstGroup + 1

    local raw = buffer.create(nGroups * 3)
    for g = 0, nGroups - 1 do
        local ci = (firstGroup + g) * 4              -- 0-based char index
        local p = ci // partLen
        local s = parts[p + 1]
        if not s then
            break -- past the end of the blob; the tail stays zeroed
        end
        local o = ci - p * partLen + 1               -- 1-based within the part
        local a, b, c, d = string.byte(s, o, o + 3)
        local v = buffer.readu8(B64, a) * 262144
            + buffer.readu8(B64, b) * 4096
            + buffer.readu8(B64, c or 65) * 64
            + buffer.readu8(B64, d or 65)
        local at = g * 3
        buffer.writeu8(raw, at, v // 65536)
        buffer.writeu8(raw, at + 1, (v // 256) % 256)
        buffer.writeu8(raw, at + 2, v % 256)
    end

    local out = buffer.create(len)
    buffer.copy(out, 0, raw, skip, len)
    return out
end

-- ===== big-endian readers (Node wrote the blob; Luau's buffer reads little) =====
local function u16at(b: buffer, at: number): number
    return buffer.readu8(b, at) * 256 + buffer.readu8(b, at + 1)
end
local function i16at(b: buffer, at: number): number
    local u = u16at(b, at)
    return if u >= 32768 then u - 65536 else u
end
local function u32at(b: buffer, at: number): number
    return bit32.byteswap(buffer.readu32(b, at))
end

-- ===== record → dense chunk =====
-- Expands one decompressed record into a flat buffer the mesher can index in O(1),
-- filling the island interior below each column's stored shell with Stone.
local function decodeRecord(rec: buffer, yFloor: number): Chunk
    local tops = buffer.create(256)
    local yTop = yFloor
    local yBottom = 255
    local p = 0
    local starts = table.create(256)

    for ci = 0, 255 do
        starts[ci + 1] = p
        local yBot = buffer.readu8(rec, p)
        local nRuns = buffer.readu8(rec, p + 1)
        p += 2
        if nRuns > 0 then
            if yBot < yBottom then
                yBottom = yBot
            end
            local total = 0
            for r = 0, nRuns - 1 do
                total += buffer.readu8(rec, p + r * 2 + 1)
            end
            p += nRuns * 2
            local top = yBot + total - 1
            buffer.writeu8(tops, ci, math.clamp(top - yFloor + 1, 0, 255))
            if top > yTop then
                yTop = top
            end
        end
    end

    local span = yTop - yFloor + 1
    local blocks = buffer.create(256 * span)
    for ci = 0, 255 do
        local q = starts[ci + 1]
        local yBot = buffer.readu8(rec, q)
        local nRuns = buffer.readu8(rec, q + 1)
        if nRuns > 0 then
            local base = ci * span
            buffer.fill(blocks, base, STONE, yBot - yFloor) -- island interior
            local y = yBot - yFloor
            for r = 0, nRuns - 1 do
                local id = buffer.readu8(rec, q + 2 + r * 2)
                local n = buffer.readu8(rec, q + 3 + r * 2)
                if id ~= 0 then
                    buffer.fill(blocks, base + y, id, n)
                end
                y += n
            end
        end
    end

    return { span = span, yTop = yTop, yBottom = yBottom, blocks = blocks, tops = tops }
end

-- ===== the shared query surface =====
-- `fetch` is the only difference between the two modes: it returns a decoded chunk
-- or nil (void / not here yet).
local function makeMap(
    meta: Meta,
    fetch: (cx: number, cz: number) -> Chunk?,
    record: (cx: number, cz: number) -> (buffer?, number),
    feed: (cx: number, cz: number, comp: buffer, rawLen: number) -> (),
    drop: (cx: number, cz: number) -> ()
): Map
    local yFloor = meta.yFloor

    local function columnTop(wx: number, wz: number): number
        local cx = wx // CHUNK_SIZE
        local cz = wz // CHUNK_SIZE
        local c = fetch(cx, cz)
        if not c then
            return -1
        end
        local ci = (wz - cz * CHUNK_SIZE) * CHUNK_SIZE + (wx - cx * CHUNK_SIZE)
        local t = buffer.readu8(c.tops, ci)
        return if t == 0 then -1 else t + yFloor - 1
    end

    local function blockAt(wx: number, y: number, wz: number): number
        local cx = wx // CHUNK_SIZE
        local cz = wz // CHUNK_SIZE
        local c = fetch(cx, cz)
        if not c then
            return 0
        end
        local ci = (wz - cz * CHUNK_SIZE) * CHUNK_SIZE + (wx - cx * CHUNK_SIZE)
        if buffer.readu8(c.tops, ci) == 0 then
            return 0 -- void column
        end
        if y < yFloor then
            return STONE -- island interior
        end
        if y > c.yTop then
            return 0
        end
        return buffer.readu8(c.blocks, ci * c.span + (y - yFloor))
    end

    local function chunkFloor(cx: number, cz: number): number
        local c = fetch(cx, cz)
        return if c then c.yBottom else yFloor
    end

    return {
        name = meta.name,
        radius = meta.radius,
        yFloor = yFloor,
        meta = meta,
        columnTop = columnTop,
        blockAt = blockAt,
        chunkFloor = chunkFloor,
        record = record,
        feed = feed,
        drop = drop,
    }
end

-- A bounded cache of decoded chunks. Decoding is cheap enough that a hard reset
-- beats tracking recency; the cap is set well above what a render radius needs, so
-- it effectively never fires during normal play.
-- Only the SERVER may evict. Its chunks are a cache in front of the blob, so a
-- discarded one is re-decoded on the next query and nothing is lost.
--
-- The CLIENT's are not a cache — they are the only copy of terrain it will ever
-- receive, because nothing re-requests a chunk. Evicting there deletes the world:
-- with the server streaming 625 chunks and the cap at 600, the client was throwing
-- away almost everything it had been sent, which showed up as a map full of holes
-- and a spawn column that turned to void once the wipe reached it. The client's
-- bound is UnloadChunks calling drop(), which is driven by where the player is.
local function newCache(evictable: boolean)
    local map: { [number]: Chunk } = {}
    local n = 0
    return map, function()
        if evictable and n >= MAX_CACHED_CHUNKS then
            table.clear(map)
            n = 0
        end
        n += 1
    end
end

-- ===== SERVER: the whole blob, held privately =====
function PrebakedMap.open(src: Source): Map
    local head = decodeRange(src, 0, HEADER)
    local magic = buffer.readstring(head, 0, 4)
    if magic ~= "VXM3" then
        error(`PrebakedMap: "{src.name}" is not a VXM3 blob (got "{magic}") — re-bake it`)
    end

    local meta: Meta = {
        name = src.name,
        cx0 = i16at(head, 4),
        cz0 = i16at(head, 6),
        nx = u16at(head, 8),
        nz = u16at(head, 10),
        radius = u16at(head, 12),
        yFloor = buffer.readu8(head, 14),
    }

    local index = decodeRange(src, HEADER, meta.nx * meta.nz * IDX_ENTRY)
    local recordsBase = HEADER + meta.nx * meta.nz * IDX_ENTRY

    local function slot(cx: number, cz: number): number?
        local gx, gz = cx - meta.cx0, cz - meta.cz0
        if gx < 0 or gx >= meta.nx or gz < 0 or gz >= meta.nz then
            return nil
        end
        return (gx + gz * meta.nx) * IDX_ENTRY
    end

    -- The compressed record, exactly as stored — the server forwards these bytes
    -- untouched, so streaming a chunk costs it no decompression at all.
    local function record(cx: number, cz: number): (buffer?, number)
        local at = slot(cx, cz)
        if not at then
            return nil, 0
        end
        local comp = u32at(index, at + 4)
        if comp == 0 then
            return nil, 0 -- void chunk
        end
        return decodeRange(src, recordsBase + u32at(index, at), comp), u16at(index, at + 8)
    end

    local cache, touch = newCache(true) -- server: re-decodable from the blob
    local function fetch(cx: number, cz: number): Chunk?
        local at = slot(cx, cz)
        if not at then
            return nil
        end
        local key = at
        local c = cache[key]
        if c ~= nil then
            return c
        end
        local comp, rawLen = record(cx, cz)
        if not comp then
            return nil
        end
        c = decodeRecord(Inflate.raw(comp, rawLen), meta.yFloor)
        touch()
        cache[key] = c
        return c
    end

    return makeMap(meta, fetch, record, function() end, function() end)
end

-- ===== CLIENT: chunks arrive as the player walks =====
function PrebakedMap.receiver(meta: Meta): Map
    local cache, touch = newCache(false) -- client: this IS the terrain, never evict

    local function key(cx: number, cz: number): number
        -- meta.nx is the grid width, so this is unique across the whole map
        return (cx - meta.cx0) + (cz - meta.cz0) * meta.nx
    end

    local function feed(cx: number, cz: number, comp: buffer, rawLen: number)
        local ok, decoded = pcall(function()
            return decodeRecord(Inflate.raw(comp, rawLen), meta.yFloor)
        end)
        if not ok then
            warn(`PrebakedMap: chunk {cx},{cz} failed to decode — {decoded}`)
            return
        end
        touch()
        cache[key(cx, cz)] = decoded :: any
    end

    local function drop(cx: number, cz: number)
        cache[key(cx, cz)] = nil
    end

    local function fetch(cx: number, cz: number): Chunk?
        return cache[key(cx, cz)]
    end

    return makeMap(meta, fetch, function()
        return nil, 0
    end, feed, drop)
end

-- Meta ⇄ string, so the server can publish it on one replicated attribute.
function PrebakedMap.encodeMeta(m: Meta): string
    return `{m.name}|{m.cx0}|{m.cz0}|{m.nx}|{m.nz}|{m.radius}|{m.yFloor}`
end

function PrebakedMap.decodeMeta(s: string): Meta?
    local name, cx0, cz0, nx, nz, radius, yFloor =
        string.match(s, "([^|]+)|(-?%d+)|(-?%d+)|(%d+)|(%d+)|(%d+)|(%d+)")
    if not name then
        return nil
    end
    return {
        name = name,
        cx0 = tonumber(cx0) :: number,
        cz0 = tonumber(cz0) :: number,
        nx = tonumber(nx) :: number,
        nz = tonumber(nz) :: number,
        radius = tonumber(radius) :: number,
        yFloor = tonumber(yFloor) :: number,
    }
end

return PrebakedMap
