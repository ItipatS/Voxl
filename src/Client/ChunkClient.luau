local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local std = ReplicatedStorage.std

local blink = require(std.ClientNet)

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local ChunkMesher = require(ReplicatedStorage.Misc.Mesher)

local CHUNK_SIZE = WorldGen.CHUNK_SIZE
local WORLD_HEIGHT = WorldGen.WORLD_HEIGHT

local MAX_MESH_PER_FRAME = 10

local chunkcount:number = 0

local MeshQueue = {}
local MeshedChunks = {}

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

local Chunks = Instance.new("Folder")
Chunks.Name = "Chunks"
Chunks.Parent = workspace

local function idx3(x: number, y: number, z: number): number
    return x + (y * CHUNK_SIZE) + (z * CHUNK_SIZE * WORLD_HEIGHT)
end

blink.ChunkFullStream.On(function(payloads)
    for _, entry in payloads do
        local cx = entry.cx
        local cz = entry.cz
        local key = chunkKey(cx, cz)

         local chunk: ChunkMesher.ClientChunk = {
            cx = cx,
            cz = cz,
            blocks = entry.blocks,
            heightfields = entry.heightfields
        }

        ClientWorld[key] = chunk

        MeshQueue[#MeshQueue+1] = key
    end
    chunkcount += #payloads
    print("Chunks received: ", chunkcount)
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

RunService.RenderStepped:Connect(function()
    for i = 1, MAX_MESH_PER_FRAME do
        local key = table.remove(MeshQueue, 1)
        if not key then return end

        local chunk = ClientWorld[key]
        local model = ChunkMesher.BuildChunk(chunk, Chunks)
        MeshedChunks[key] = model
    end
end)

return ClientWorld