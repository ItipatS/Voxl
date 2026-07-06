-- StarterPlayerScripts/HeldTools.luau  (Lobby)
-- The server spawns held Tools with only a bare Handle + an `item` attribute; the
-- MESH is cloned here, per client, so the server never replicates meshes (doc 20):
--   1. RENDER — for every "HeldTool" (anyone's), clone Assets.Items[model] into the
--      tool locally and weld it to the Handle. All clients clone the same model → all
--      see the same thing; the server holds one tiny part.
--   2. ACTIVATION — YOUR tool's Activated → the item's client action (ItemUse).
--   3. PARTICLE LOD — cloned particles start OFF; enabled only for holders near you.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local itemdb = require(ReplicatedStorage.std.itemdb)
local ItemUse = require(script.Parent.ItemUse)

local ITEMS = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Items")
local player = Players.LocalPlayer
local LOD_DIST = 120

-- ---- render the model into a tool (client-local) ----------------------------
local rendered = setmetatable({}, { __mode = "k" }) -- tool -> true (weak; auto-clears)

local function renderTool(tool: Instance)
	if not tool:IsA("Tool") or rendered[tool] then
		return
	end
	local def = itemdb.byId(tool:GetAttribute("item") :: number)
	if not def or not def.model then
		return
	end
	local asset = ITEMS:FindFirstChild(def.model)
	if not asset then
		return
	end
	local handle = tool:WaitForChild("Handle", 3) :: BasePart?
	if not handle then
		return
	end
	rendered[tool] = true

	local m = asset:Clone()
	local main = if m:IsA("Model") then (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")) elseif m:IsA("BasePart") then m else nil
	if not main then
		m:Destroy()
		return
	end
	main.CFrame = handle.CFrame
	local parts = {}
	if m:IsA("Model") then
		for _, p in m:GetDescendants() do
			if p:IsA("BasePart") then
				table.insert(parts, p)
			end
		end
		for _, c in m:GetChildren() do
			c.Parent = tool -- local clone, parented into the replicated tool → client-only
		end
		m:Destroy()
	else
		m.Parent = tool
		table.insert(parts, m)
	end
	for _, p in parts do
		p.Anchored, p.CanCollide, p.CanQuery, p.Massless = false, false, false, true
		if p ~= handle then
			local w = Instance.new("WeldConstraint")
			w.Part0, w.Part1 = handle, p
			w.Parent = handle
		end
	end
	for _, e in tool:GetDescendants() do
		if e:IsA("ParticleEmitter") or e:IsA("Beam") or e:IsA("Trail") then
			e.Enabled = false -- LOD turns these on when near
		end
	end
end

CollectionService:GetInstanceAddedSignal("HeldTool"):Connect(renderTool)
for _, tool in CollectionService:GetTagged("HeldTool") do
	task.spawn(renderTool, tool)
end

-- ---- activation (local player's own tools) ----------------------------------
local function hookTool(tool: Tool)
	if tool:GetAttribute("item") == nil then
		return
	end
	tool.Activated:Connect(function()
		local def = itemdb.byId(tool:GetAttribute("item") :: number)
		if def and def.behavior and ItemUse.has(def.behavior) then
			ItemUse.run(def.behavior, def)
		end
	end)
end

local function watchChar(char: Model)
	char.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then
			hookTool(c)
		end
	end)
	for _, c in char:GetChildren() do
		if c:IsA("Tool") then
			hookTool(c)
		end
	end
end
player.CharacterAdded:Connect(watchChar)
if player.Character then
	watchChar(player.Character)
end

-- ---- particle LOD (all held tools) ------------------------------------------
task.spawn(function()
	while true do
		local myChar = player.Character
		local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart") :: BasePart?
		if myRoot then
			for _, tool in CollectionService:GetTagged("HeldTool") do
				if tool:IsA("Tool") then
					local root = tool.Parent and tool.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?
					local near = root ~= nil and (root.Position - myRoot.Position).Magnitude < LOD_DIST
					for _, e in tool:GetDescendants() do
						if e:IsA("ParticleEmitter") or e:IsA("Beam") or e:IsA("Trail") then
							e.Enabled = near
						end
					end
				end
			end
		end
		task.wait(0.35)
	end
end)

return {}
