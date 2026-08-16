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

local constellation = require(ReplicatedStorage.std.constellation)

-- Name of a hub-town from std/constellation HUBS, or nil for the normal spawn.
local TARGET: string? = "Aldermoor"

-- Where to stand relative to the star CENTRE. The orb is STAR_SIZE 2047 across, so
-- its surface is ~1024 out — this parks you a few hundred studs off it, still inside
-- the client's 1500-stud prompt range, rather than inside the glow.
local OFFSET = Vector3.new(0, 400, 1350)

local function hubPos(name: string): Vector3?
	for _, h in constellation.HUBS do
		if h.name == name then
			return h.pos
		end
	end
	return nil
end

if TARGET then
	local pos = hubPos(TARGET)
	if not pos then
		warn(`[devspawn] no hub named "{TARGET}" — leaving the normal spawn alone`)
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
		local target = CFrame.new(pos + OFFSET, pos) -- facing the star
		spawn.CFrame = target
		print(
			`[devspawn] "{TARGET}" is at {pos}; spawning at {pos + OFFSET} `
				.. `({math.round(OFFSET.Magnitude)} studs out)`
		)

		-- THE PART THAT ACTUALLY DECIDES WHERE YOU END UP.
		-- The client owns the character, and FlightController deliberately scatters
		-- you around the residential annulus on spawn — so a server-side placement
		-- gets overwritten a frame later. Publish the intent instead and let the
		-- client honour it, the same way starconfig publishes a star's world.
		ReplicatedStorage:SetAttribute("DevSpawnPos", pos + OFFSET)
		ReplicatedStorage:SetAttribute("DevSpawnLook", pos)

		-- Moving the SpawnLocation is NOT enough on its own: if the place has another
		-- SpawnLocation (authored, or nested somewhere FindFirstChildWhichIsA won't
		-- reach) Roblox picks between them at random, and you land wherever it felt
		-- like. So pin it two ways — RespawnLocation takes precedence over the random
		-- pick, and the character is placed outright once it exists.
		local function place(plr: Player, char: Model)
			plr.RespawnLocation = spawn :: SpawnLocation
			-- A rig is parented before it is fully assembled, so the root is often
			-- not there for the first few frames; waiting is the only reliable read.
			local root = char:WaitForChild("HumanoidRootPart", 10)
			if root and root:IsA("BasePart") then
				char:PivotTo(target + Vector3.new(0, 5, 0))
			else
				warn(`[devspawn] {plr.Name} has no HumanoidRootPart after 10s — not placed`)
			end
		end

		local function hook(plr: Player)
			plr.RespawnLocation = spawn :: SpawnLocation
			plr.CharacterAdded:Connect(function(char)
				place(plr, char)
			end)
			if plr.Character then
				place(plr, plr.Character)
			end
		end

		Players.PlayerAdded:Connect(hook)
		for _, plr in Players:GetPlayers() do
			hook(plr) -- Studio play-solo joins before this system runs
		end
	end
end

return {}
