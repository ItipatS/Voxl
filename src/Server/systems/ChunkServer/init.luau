-- ServerScriptService/ChunkServer.luau
--!optimize 2
--!native
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std = ReplicatedStorage.std
local cts = require(std.components)
local world = require(std.world)
local Player = cts.Player
local scheduler = require(std.scheduler)
local phases = require(std.phases)

local blink = require(game:GetService("ServerScriptService").ServerNet)
local WorldGen = require(script.WorldGen)

-- Pre-generate 12 chunks: 3 in X, 4 in Z => cx=0..2, cz=0..3
local ChunkCache: { [string]: WorldGen.ChunkFull } = {}

local function chunkKey(cx: number, cz: number): string
    return tostring(cx) .. ":" .. tostring(cz)
end

local function preGenerateInitialChunks()
    for cz = 0, 3 do
        for cx = 0, 2 do
            local key = chunkKey(cx, cz)
            local chunk = WorldGen.generateChunkFull(cx, cz)
            ChunkCache[key] = chunk
        end
    end
end

preGenerateInitialChunks()

local function sendInitialChunksTo(player: Player)

    local batch = table.create(128)
    for _, chunk in pairs(ChunkCache)do
        batch[#batch+1] = {
            cx = chunk.cx,
            cz = chunk.cz,
            blocks = chunk.blocks,
        }
    end

    if #batch > 0 then
        blink.ChunkFullStream.Fire(player, batch)
    end
end

scheduler.SYSTEM(sendInitialChunksTo, phases.PlayerAdded)

-- Later you’ll add:
-- - movement-based chunk generation
-- - send new chunks when player moves far enough.
return 0