-- ServerScriptService/systems/PlayerStore.luau
--!strict

-- Per-player block inventory (block id -> count), persisted with ProfileStore.
-- Mining a block adds one; placing consumes one. Synced to the owner on join and
-- after every change so the hotbar/inventory show live counts. Required directly
-- by BlockEditServer (a service, not a scheduler system).

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileStore = require(ServerScriptService.DevPackages.profilestore)
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local blink = require(ServerScriptService.ServerNet)

local BLOCK = WorldGen.BLOCK

local PlayerStore = {}

-- One-time starter kit so building works before mining; mining refills it.
local STARTER: { [number]: number } = {
    [BLOCK.Grass] = 25, [BLOCK.Dirt] = 25, [BLOCK.Stone] = 25, [BLOCK.Sand] = 25,
    [BLOCK.Snow] = 25, [BLOCK.OakLog] = 25, [BLOCK.OakLeaves] = 25,
}

local store = ProfileStore.New("VoxlPlayer_v1", { blocks = {} :: { [number]: number }, granted = false })
local profiles: { [Player]: any } = {}

local function syncTo(player: Player)
    local profile = profiles[player]
    if not profile then
        return
    end
    local list = {}
    for block, count in profile.Data.blocks do
        if count > 0 then
            list[#list + 1] = { block = block, count = count }
        end
    end
    blink.InventorySync.Fire(player, list)
end

local function onAdded(player: Player)
    local profile = store:StartSessionAsync("player_" .. player.UserId)
    if not profile then
        warn(`[PlayerStore] no session for {player.Name}; inventory won't persist`)
        return
    end
    profile:Reconcile()
    profile.OnSessionEnd:Connect(function()
        profiles[player] = nil
    end)
    if player.Parent ~= Players then
        profile:EndSession()
        return
    end
    if not profile.Data.granted then
        for block, n in STARTER do
            profile.Data.blocks[block] = (profile.Data.blocks[block] or 0) + n
        end
        profile.Data.granted = true
    end
    profiles[player] = profile
    syncTo(player)
end

Players.PlayerAdded:Connect(onAdded)
Players.PlayerRemoving:Connect(function(player)
    local profile = profiles[player]
    if profile then
        profile:EndSession()
    end
end)
for _, player in Players:GetPlayers() do
    task.spawn(onAdded, player)
end

-- Add mined blocks.
function PlayerStore.add(player: Player, block: number, n: number)
    local profile = profiles[player]
    if not profile then
        return
    end
    profile.Data.blocks[block] = (profile.Data.blocks[block] or 0) + n
    syncTo(player)
end

-- Consume for placing; returns false (and changes nothing) if the player lacks it.
function PlayerStore.consume(player: Player, block: number, n: number): boolean
    local profile = profiles[player]
    if not profile then
        return false
    end
    local have = profile.Data.blocks[block] or 0
    if have < n then
        return false
    end
    profile.Data.blocks[block] = have - n
    syncTo(player)
    return true
end

return PlayerStore
