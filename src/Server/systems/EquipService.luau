--!strict
-- Server-authoritative "held item" (doc 20). The client picks a hotbar Tool item via
-- Blink EquipItem; the server validates ownership + kind==Tool and spawns a REPLICATED
-- Tool on the character (everyone sees it). Particles are set OFF here so clients can
-- LOD them by distance (HeldTools). Everything is unanchored + massless so a held item
-- never sticks the player.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local blink = require(ServerScriptService.ServerNet)
local itemdb = require(ReplicatedStorage.std.itemdb)
local PlayerStore = require(script.Parent.PlayerStore)

local ITEMS = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Items")

local equipped: { [Player]: string } = {} -- player -> itemdb key currently held

-- Build the Tool with ONLY a bare Handle + an `item` attribute. The server never
-- clones the mesh — each CLIENT clones the model itself into the tool (HeldTools),
-- so the server holds/replicates one tiny part per held item, not meshes (doc 20).
local function buildTool(def): Tool
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = def.name
	tool:AddTag("HeldTool") -- HeldTools (client) renders the model + LODs particles
	tool:SetAttribute("item", def.id)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1 -- invisible; the visible model is client-cloned
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.Massless = true
	handle.Parent = tool
	return tool
end

local function clearTools(player: Player)
	local char = player.Character
	if char then
		for _, t in char:GetChildren() do
			if t:IsA("Tool") then
				t:Destroy()
			end
		end
	end
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _, t in bp:GetChildren() do
			if t:IsA("Tool") then
				t:Destroy()
			end
		end
	end
end

local function equip(player: Player, def)
	local char = player.Character
	if not char or not char:FindFirstChildOfClass("Humanoid") then
		return
	end
	clearTools(player)
	local tool = buildTool(def)
	if tool then
		tool.Parent = char -- parenting a Tool to the character equips it (held in hand)
	end
end

blink.EquipItem.On(function(player: Player, itemId: number)
	if itemId == 0 then
		equipped[player] = nil
		clearTools(player)
		return
	end
	local def = itemdb.byId(itemId)
	if not def or def.kind ~= "Tool" then
		return
	end
	if PlayerStore.itemCount(player, def.key) < 1 then
		equipped[player] = nil
		clearTools(player)
		return
	end
	equipped[player] = def.key
	equip(player, def)
end)

-- Re-equip on respawn.
local function hookChar(player: Player)
	player.CharacterAdded:Connect(function()
		task.wait(0.3)
		local key = equipped[player]
		local def = key and itemdb.byKey(key)
		if def then
			equip(player, def)
		end
	end)
end
Players.PlayerAdded:Connect(hookChar)
Players.PlayerRemoving:Connect(function(player)
	equipped[player] = nil
end)
for _, p in Players:GetPlayers() do
	hookChar(p)
end

return {}
