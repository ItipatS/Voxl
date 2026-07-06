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
local itemdb = require(ReplicatedStorage.std.itemdb)
local placemode = require(ReplicatedStorage.std.placemode)

local BLOCK = WorldGen.BLOCK

local PlayerStore = {}

-- One-time starter kit so building works before mining; mining refills it.
local STARTER: { [number]: number } = {
    [BLOCK.Grass] = 25, [BLOCK.Dirt] = 25, [BLOCK.Stone] = 25, [BLOCK.Sand] = 25,
    [BLOCK.Snow] = 25, [BLOCK.OakLog] = 25, [BLOCK.OakLeaves] = 25,
}

-- One profile owns blocks + items (doc 17); never open a second session on this key.
-- Items are stored SLOT-BASED (Minecraft/Terraria, doc 20): `slots` is a dense array
-- of SLOT_COUNT entries (1-9 = hotbar, 10-54 = inventory), each { item = key, count }
-- with item="" for empty. Dense + sequential so it round-trips DataStore as an array.
-- Weight is DERIVED from slots + blocks so it can't desync.
local SLOT_COUNT = 54
local HOTBAR = 9

local function emptySlots(): { any }
    local t = table.create(SLOT_COUNT)
    for i = 1, SLOT_COUNT do
        t[i] = { item = "", count = 0 }
    end
    return t
end

local store = ProfileStore.New("VoxlPlayer_v1", {
    blocks = {} :: { [number]: number },
    slots = emptySlots(),
    granted = false,
})
local profiles: { [Player]: any } = {}

-- ---- slot helpers (operate on a profile's slots array) ----------------------
local function countKey(slots, key: string): number
    local c = 0
    for _, s in slots do
        if s.item == key then
            c += s.count
        end
    end
    return c
end

local function removeKey(slots, key: string, n: number)
    for i = 1, SLOT_COUNT do
        local s = slots[i]
        if n <= 0 then
            break
        end
        if s.item == key then
            local t = math.min(s.count, n)
            s.count -= t
            n -= t
            if s.count <= 0 then
                s.item, s.count = "", 0
            end
        end
    end
end

-- Add n of key: merge into existing stacks first, then fill empties. Returns leftover.
local function place(slots, key: string, n: number): number
    local def = itemdb.byKey(key)
    local stack = if def then def.stack else 1
    for i = 1, SLOT_COUNT do
        local s = slots[i]
        if s.item == key and s.count < stack then
            local add = math.min(stack - s.count, n)
            s.count += add
            n -= add
            if n <= 0 then
                return 0
            end
        end
    end
    for i = 1, SLOT_COUNT do
        local s = slots[i]
        if s.item == "" then
            local add = math.min(stack, n)
            s.item, s.count = key, add
            n -= add
            if n <= 0 then
                return 0
            end
        end
    end
    return n
end

-- Block inventory push (unchanged channel).
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

-- Item inventory + weight push (occupied slots only; client fills the rest empty).
-- Weight includes block weight, so it's also called after block changes.
local function syncItems(player: Player)
    local profile = profiles[player]
    if not profile then
        return
    end
    local slots = profile.Data.slots
    local list = {}
    local itemWeight = 0
    for i = 1, SLOT_COUNT do
        local s = slots[i]
        if s.item ~= "" and s.count > 0 then
            local def = itemdb.byKey(s.item)
            if def then
                list[#list + 1] = { slot = i, item = def.id, count = s.count }
                itemWeight += itemdb.itemWeight(s.item) * s.count
            end
        end
    end
    local weight = itemWeight
    for block, count in profile.Data.blocks do
        weight += itemdb.blockWeight(block) * count
    end
    blink.ItemSync.Fire(player, {
        weight = math.floor(weight + 0.5),
        capacity = itemdb.capacity(profile.Data),
        slots = list,
    })
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
    -- [TEST] Always top up a Star Seed on join so the loop is testable while items
    -- have no real source yet. Remove once seeds come from progression/craft.
    if countKey(profile.Data.slots, "star_seed") < 1 then
        place(profile.Data.slots, "star_seed", 1)
    end
    profiles[player] = profile
    syncTo(player)
    syncItems(player)
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
    syncItems(player) -- blocks carry weight; refresh the bar
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
    syncItems(player)
    return true
end

-- ---- Items (slot-based) -----------------------------------------------------

-- Grant items into slots (progression/craft/testing). Unknown keys ignored.
function PlayerStore.giveItem(player: Player, key: string, n: number)
    local profile = profiles[player]
    if not profile or not itemdb.byKey(key) then
        return
    end
    place(profile.Data.slots, key, n)
    syncItems(player)
end

-- How many of an item the player holds across all slots.
function PlayerStore.itemCount(player: Player, key: string): number
    local profile = profiles[player]
    return if profile then countKey(profile.Data.slots, key) else 0
end

-- Consume items server-side (planting, etc.); false if they lack it.
function PlayerStore.consumeItem(player: Player, key: string, n: number): boolean
    local profile = profiles[player]
    if not profile or countKey(profile.Data.slots, key) < n then
        return false
    end
    removeKey(profile.Data.slots, key, n)
    syncItems(player)
    return true
end

-- Client drags a stack between slots (pick up + drop). Merge same-item stacks
-- (respecting the stack cap), else swap. Server is authoritative over the layout.
blink.MoveItem.On(function(player: Player, m: { from: number, to: number })
    local profile = profiles[player]
    if not profile then
        return
    end
    local from, to = m.from, m.to
    if from < 1 or from > SLOT_COUNT or to < 1 or to > SLOT_COUNT or from == to then
        return
    end
    local slots = profile.Data.slots
    local a, b = slots[from], slots[to]
    if a.item == "" then
        return
    end
    if b.item == a.item then
        local def = itemdb.byKey(a.item)
        local stack = if def then def.stack else 1
        local move = math.min(stack - b.count, a.count)
        b.count += move
        a.count -= move
        if a.count <= 0 then
            a.item, a.count = "", 0
        end
    else
        slots[from], slots[to] = b, a
    end
    syncItems(player)
end)

-- Right-click a slot to USE one (Consumables only). The behavior validates; we
-- consume one on success.
blink.UseSlot.On(function(player: Player, slot: number)
    local profile = profiles[player]
    if not profile or slot < 1 or slot > SLOT_COUNT then
        return
    end
    local s = profile.Data.slots[slot]
    if s.item == "" then
        return
    end
    local def = itemdb.byKey(s.item)
    if not def or def.kind ~= "Consumable" then
        return
    end
    local ok = true
    if def.behavior then
        local ItemBehaviors = require(script.Parent.ItemBehaviors)
        ok = ItemBehaviors.run(def.behavior, player)
    end
    if ok then
        s.count -= 1
        if s.count <= 0 then
            s.item, s.count = "", 0
        end
        syncItems(player)
    end
end)

return PlayerStore
