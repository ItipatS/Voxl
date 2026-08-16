-- ServerScriptService/systems/devspawn.luau  (Lobby)
-- TESTING AFFORDANCE: start the player parked next to a landmark star instead of
-- at the authored lobby spawn, so reaching a specific world doesn't mean flying
-- across the constellation every time.
--
-- Set TARGET to nil to switch it off and leave the authored spawn alone. This is
-- the only thing in the file that should ever need changing.
--
-- It moves the SpawnLocation rather than teleporting characters: respawns, the
-- client's own spawn handling and anything else that reads the spawn point all
-- stay consistent, and turning it off restores the authored position on the next
-- server start.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local universe = require(ReplicatedStorage.std.universe)

-- Name of a landmark from std/universe LANDMARKS, or nil for the authored spawn.
local TARGET: string? = "Aldermoor"

-- Where to stand relative to the star. Inside starentry's ENTER_RADIUS (1600) so
-- the enter prompt is live the moment you spawn, and above the star so it reads as
-- "hanging over it" rather than "buried in it".
local OFFSET = Vector3.new(0, 250, 1100)

local function landmarkPos(name: string): Vector3?
	for _, L in universe.LANDMARKS do
		if L.name == name then
			local star = universe.landmarkAt(L.slot[1], L.slot[2], L.slot[3])
			return star and star.pos or nil
		end
	end
	return nil
end

if TARGET then
	local pos = landmarkPos(TARGET)
	if not pos then
		warn(`[devspawn] no landmark named "{TARGET}" — leaving the authored spawn alone`)
	else
		local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation")
		if not spawn then
			-- Same call starworld makes: a spawn anchor is functional infrastructure,
			-- not scene content, and without one players drop into the void.
			spawn = Instance.new("SpawnLocation")
			spawn.Name = "DevSpawn"
			spawn.Size = Vector3.new(12, 1, 12)
			spawn.Transparency = 1
			spawn.CanCollide = false
			spawn.Neutral = true
			spawn.Parent = Workspace
		end
		spawn.Anchored = true
		spawn.CFrame = CFrame.new(pos + OFFSET, pos) -- facing the star
		print(`[devspawn] spawning beside "{TARGET}" at {pos + OFFSET} (star at {pos})`)

		-- Anyone already in (Studio play solo starts before this runs) gets moved too.
		for _, plr in Players:GetPlayers() do
			local char = plr.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				root.CFrame = spawn.CFrame + Vector3.new(0, 5, 0)
			end
		end
	end
end

return {}
