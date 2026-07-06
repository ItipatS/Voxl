-- ServerScriptService/systems/crafting.luau
-- Server-authoritative crafting (doc 22). Client sends a recipe id (Craft); we look it up,
-- verify the player holds all inputs in their item slots, consume them, and grant the output.
-- MVP: instant + station/fuel/time NOT yet enforced (that + factories are the next layer) —
-- this unblocks the whole gather→craft loop for testing. Runs in both places (you can craft
-- wherever you have materials).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local recipes = require(ReplicatedStorage.std.recipes)
local PlayerStore = require(script.Parent.PlayerStore)

blink.Craft.On(function(plr: Player, recipeId: string)
	local r = recipes.byId[recipeId]
	if not r then
		return -- unknown recipe → ignore (anti-cheat)
	end
	local needs = recipes.inputsOf(r)

	-- 1) verify the player has everything (all-or-nothing)
	for _, ing in needs do
		if PlayerStore.itemCount(plr, ing.key) < ing.count then
			return
		end
	end
	-- 2) consume, then grant (consume is guarded, but we already checked)
	for _, ing in needs do
		PlayerStore.consumeItem(plr, ing.key, ing.count)
	end
	PlayerStore.giveItem(plr, r.out.key, r.out.count)
end)

return {}
