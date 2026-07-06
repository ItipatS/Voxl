-- ServerScriptService/systems/starworld.luau  (Star place = ResourceStar PlaceId)
-- Configure the bounded world for the star the player ENTERED (its config rides in
-- TeleportData: starSeed / starRadius / starTypes), publish it so clients generate the same
-- terrain, position the spawn on the island, then load characters. Characters DON'T auto-load
-- (we wait until the world is configured, so nobody spawns into the void). Direct/Studio joins
-- with no teleport data fall back to the TEST star.
--
-- One star per server (single-live per starId). The MemoryStore reserved-server routing —
-- sending every visitor of a starId to the SAME server — layers on top of this later; for now
-- each entry configures this server from the joiner's data.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local starconfig = require(ReplicatedStorage.std.starconfig)

local SPAWN_CLEARANCE = 5

Players.CharacterAutoLoads = false

local configured = false

local function positionSpawn()
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation")
	if spawn then
		local surfaceY = WorldGen.getSurfaceHeight(0, 0) -- island centre
		spawn.CFrame = CFrame.new(0, (surfaceY + 1) * WorldGen.BLOCK_SIZE + SPAWN_CLEARANCE, 0)
		spawn.Anchored = true
	end
end

local function configure(data: any)
	local seed = (data and data.starSeed) or starconfig.TEST.seed
	local radius = (data and data.starRadius) or starconfig.TEST.radius
	local types = (data and data.starTypes) or starconfig.TEST.types
	WorldGen.applyStarByTypes(seed, radius, types)
	starconfig.set(seed, radius, types) -- replicate so clients generate the identical world
	positionSpawn()
	configured = true
end

local function onPlayer(plr: Player)
	if not configured then
		local ok, data = pcall(function()
			return plr:GetJoinData().TeleportData
		end)
		configure(if ok then data else nil)
	end
	plr:LoadCharacter()
end

Players.PlayerAdded:Connect(onPlayer)
for _, plr in Players:GetPlayers() do
	task.spawn(onPlayer, plr) -- Studio: players may already be here
end

return {}
