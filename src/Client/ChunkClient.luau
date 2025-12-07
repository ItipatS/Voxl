local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std = ReplicatedStorage.std

local blink = require(std.ClientNet)

local ClientWorld: {
    [string]: {
        cx: number,
        cz: number,
        blocks: { [number]: number },
    }
} = {}

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

local CHUNK_SIZE = 16
local WORLD_HEIGHT = 256

local function idx3(x: number, y: number, z: number): number
    return x + (y * CHUNK_SIZE) + (z * CHUNK_SIZE * WORLD_HEIGHT)
end

blink.ChunkFullStream.On(function(payloads)
    for _, entry in payloads do
        local key = chunkKey(entry.cx, entry.cz)
        ClientWorld[key] = {
            cx = entry.cx,
            cz = entry.cz,
            blocks = entry.blocks, -- map<u32,u8>
        }
        print("[ChunkClient] Received chunk", entry.cx, entry.cz, "entries", #entry.blocks)
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
    return chunk.blocks[linear] or 0
end

return ClientWorld