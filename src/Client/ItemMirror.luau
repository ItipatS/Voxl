-- StarterPlayerScripts/ItemMirror.luau
-- Client mirror of the player's SLOT-based item inventory + weight (server-authoritative,
-- pushed via ItemSync). READ-ONLY. Slots 1-9 = hotbar, 10-54 = inventory (doc 20).
-- ItemHotbar, ItemInventory + ItemDrag read from here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local blink = require(ReplicatedStorage.std.ClientNet)
local itemdb = require(ReplicatedStorage.std.itemdb)

local ItemMirror = {}

type Slot = { key: string, count: number }
local slots: { [number]: Slot } = {} -- occupied slots only
local weight, capacity = 0, 0
local listeners: { () -> () } = {}

function ItemMirror.getSlot(i: number): Slot?
	return slots[i]
end

function ItemMirror.getWeight(): number
	return weight
end

function ItemMirror.getCapacity(): number
	return capacity
end

function ItemMirror.onChanged(fn: () -> ())
	table.insert(listeners, fn)
end

blink.ItemSync.On(function(inv)
	slots = {}
	for _, e in inv.slots do
		local def = itemdb.byId(e.item)
		if def then
			slots[e.slot] = { key = def.key, count = e.count }
		end
	end
	weight, capacity = inv.weight, inv.capacity
	for _, fn in listeners do
		task.spawn(fn)
	end
end)

return ItemMirror
