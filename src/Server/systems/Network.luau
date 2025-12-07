--!optimize 2
--!native
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local blink = require(game:GetService("ServerScriptService").ServerNet)
local std = ReplicatedStorage.std

local world = require(std.world)
local cts = require(std.components)
local scheduler = require(std.scheduler)
local phases = require(std.phases)
local mailbox = require(std.mailbox)

-- Network constants
local TICK_HZ = 12
local TICK = 1 / TICK_HZ
local MAX_BATCH_SIZE = 64

local lastFullSync = 0
local last_accum = 0
local ToSend = table.create(MAX_BATCH_SIZE)

local function flush(ev, arr)
    if #arr > 0 then 
        ev.FireAll(arr); 
        table.clear(arr) 
    end
end

-- Data store for movements
local function networkSystem(dt: number)
    lastFullSync += dt
    last_accum += dt

    if last_accum < TICK then return end

    last_accum = 0

    table.clear(ToSend)

    mailbox.drain(cts.PendingChunks, function(item)
        ToSend[#ToSend+1] = item
        if #ToSend >= MAX_BATCH_SIZE then
            flush(blink.ChunkFullStream, ToSend)
        end
    end)


    if #ToSend> 0 then
        blink.ChunkFullStream.FireAll(ToSend)
    end
end

--scheduler.SYSTEM(networkSystem, phases.NetworkDelta)

return {}