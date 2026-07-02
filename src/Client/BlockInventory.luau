-- StarterPlayerScripts/BlockInventory.luau
-- Client mirror of the player's block counts (server-authoritative, pushed via
-- InventorySync). The hotbar and inventory window read counts from here and
-- subscribe to changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local blink = require(ReplicatedStorage.std.ClientNet)

local BlockInventory = {}

local counts: { [number]: number } = {}
local listeners: { () -> () } = {}

function BlockInventory.getCount(block: number): number
    return counts[block] or 0
end

function BlockInventory.onChanged(fn: () -> ())
    table.insert(listeners, fn)
end

blink.InventorySync.On(function(list)
    counts = {}
    for _, entry in list do
        counts[entry.block] = entry.count
    end
    for _, fn in listeners do
        task.spawn(fn)
    end
end)

return BlockInventory
