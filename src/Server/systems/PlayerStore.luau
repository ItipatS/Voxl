-- ServerScriptService/systems/PlayerStore.luau
--!strict

-- THE inventory: one 54-slot array per player, persisted with ProfileStore, holding
-- everything they carry — materials, tools, and blocks alike. Mining a block adds
-- one; placing consumes one. Synced to the owner on join and after every change.
-- Required directly by BlockEditServer (a service, not a scheduler system).
--
-- Blocks used to be a SECOND inventory living beside this one: `Data.blocks`, a
-- blockId -> count map with no slots and no stack caps, its own sync event, and its
-- own client UI — so the star place and the lobby disagreed about what a player was
-- carrying. Blocks are now ordinary items keyed `block_<id>` (itemdb), which is
-- what doc 20 called for. onAdded drains any old map into slots once.

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

-- Item inventory + weight push (occupied slots only; client fills the rest empty).
-- This is now the ONLY inventory channel: blocks are items, so the separate
-- InventorySync push (and the client-side BlockInventory that consumed it) is gone.
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
    -- Blocks are items now, so their weight is already in itemWeight above; the
    -- profile's legacy `blocks` map is drained to empty on load.
    local weight = itemWeight
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
    -- MIGRATION: blocks used to be their own map on the profile. Drain whatever a
    -- returning player still has in it into real slots and empty it, once. Losing
    -- someone's mined blocks to a refactor is not acceptable, and the profile keeps
    -- the (now always empty) field so an old server build could still read it.
    local legacy = profile.Data.blocks
    if legacy and next(legacy) ~= nil then
        local moved, lost = 0, 0
        for block, n in legacy do
            if n > 0 then
                local key = itemdb.forBlock(block)
                local left = if key then place(profile.Data.slots, key.key, n) else n
                moved += n - left
                lost += left
            end
        end
        table.clear(legacy)
        if lost > 0 then
            -- 54 slots cannot always hold an unbounded map. Say so rather than
            -- silently eating it.
            warn(`[PlayerStore] {player.Name}: migrated {moved} blocks into slots, `
                .. `{lost} did not fit and were dropped`)
        else
            print(`[PlayerStore] {player.Name}: migrated {moved} blocks into slots`)
        end
    end

    if not profile.Data.granted then
        for block, n in STARTER do
            local def = itemdb.forBlock(block)
            if def then
                place(profile.Data.slots, def.key, n)
            end
        end
        profile.Data.granted = true
    end
    -- [TEST] Always top up a Star Seed on join so the loop is testable while items
    -- have no real source yet. Remove once seeds come from progression/craft.
    if countKey(profile.Data.slots, "star_seed") < 1 then
        place(profile.Data.slots, "star_seed", 1)
    end
    -- [TEST] top up basic crafting materials so the craft loop is testable before node
    -- gathering exists (placeholder-iconed items). Remove once nodes drop raws.
    local TEST_MATS: { [string]: number } = {
        wood_1 = 32, rock_1 = 32, fiber_1 = 16, sap_1 = 8,
        ore_1 = 16, silica_1 = 16, salt_1 = 8, charcoal = 16,
    }
    for key, n in TEST_MATS do
        if countKey(profile.Data.slots, key) < 1 then
            place(profile.Data.slots, key, n)
        end
    end
    profiles[player] = profile
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

-- ---- Blocks, stored as items ------------------------------------------------
-- Blocks used to live in their own `Data.blocks` map: blockId -> count, unbounded,
-- no slots, no stacks, and a separate sync channel and a separate client UI. They
-- are now ordinary items in the same 54 slots as everything else, keyed
-- `block_<id>` (itemdb). This is what makes ONE inventory possible across both
-- places — see the migration in onAdded for what happens to old profiles.

local function blockKey(block: number): string?
    local def = itemdb.forBlock(block)
    return if def then def.key else nil
end

-- Add mined blocks. Returns how many did NOT fit, so the caller can refuse the
-- break rather than deleting the block: slots are finite, which the old unbounded
-- map never had to think about.
function PlayerStore.add(player: Player, block: number, n: number): number
    local profile = profiles[player]
    local key = blockKey(block)
    if not profile or not key then
        return n
    end
    local left = place(profile.Data.slots, key, n)
    syncItems(player)
    return left
end

-- Consume for placing; returns false (and changes nothing) if the player lacks it.
function PlayerStore.consume(player: Player, block: number, n: number): boolean
    local profile = profiles[player]
    local key = blockKey(block)
    if not profile or not key or countKey(profile.Data.slots, key) < n then
        return false
    end
    removeKey(profile.Data.slots, key, n)
    syncItems(player)
    return true
end

-- How many of a block the player is carrying (across all slots).
function PlayerStore.blockCount(player: Player, block: number): number
    local profile = profiles[player]
    local key = blockKey(block)
    if not profile or not key then
        return 0
    end
    return countKey(profile.Data.slots, key)
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
