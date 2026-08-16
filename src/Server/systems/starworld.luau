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
local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)
local starconfig = require(ReplicatedStorage.std.starconfig)

local SPAWN_CLEARANCE = 5

Players.CharacterAutoLoads = false

local configured = false

-- The island heart is (by design) the star's rarest, often tallest/wildest biome — a bad place
-- to drop a player. Scan the centre + a couple of rings and pick the LOWEST solid (non-void)
-- column: safe, flat ground on the island, from which the exotic core reads as a landmark to
-- walk toward. Returns world-block (wx, wz, surfaceY).
local function findSpawnColumn(radiusBlocks: number): (number, number, number)
	local bestX, bestZ, bestY = 0, 0, WorldGen.getSurfaceHeight(0, 0)
	for _, ring in { 0.25, 0.45 } do
		local rr = radiusBlocks * ring
		for i = 0, 7 do
			local a = (i / 8) * math.pi * 2
			local wx = math.floor(math.cos(a) * rr)
			local wz = math.floor(math.sin(a) * rr)
			local y = WorldGen.getSurfaceHeight(wx, wz)
			if y >= 0 and (bestY < 0 or y < bestY) then
				bestX, bestZ, bestY = wx, wz, y
			end
		end
	end
	if bestY < 0 then
		bestY = 0 -- everything void (shouldn't happen) → sit at the disc floor
	end
	return bestX, bestZ, bestY
end

local function positionSpawn(baked: any)
	local wx, wz, surfaceY
	if baked and baked.spawn then
		-- A baked map ships its own landing spot (picked at bake time: dry, flat,
		-- as central as the map allows). Its own geography beats any ring scan.
		wx, wz, surfaceY = baked.spawn.x, baked.spawn.z, baked.spawn.y
	else
		wx, wz, surfaceY = findSpawnColumn(WorldGen.isStar() and (starconfig.get().radius) or 96)
	end
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation")
	if not spawn then
		-- A procedural star has no authored scene, so guarantee a spawn anchor exists (functional
		-- infrastructure, not decorative content) — else players drop into the void on join.
		spawn = Instance.new("SpawnLocation")
		spawn.Name = "StarSpawn"
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Transparency = 1
		spawn.CanCollide = false
		spawn.Neutral = true
		spawn.Parent = Workspace
	end
	spawn.Anchored = true
	spawn.CFrame = CFrame.new(
		wx * WorldGen.BLOCK_SIZE,
		(surfaceY + 1) * WorldGen.BLOCK_SIZE + SPAWN_CLEARANCE,
		wz * WorldGen.BLOCK_SIZE
	)
end

local function configure(data: any)
	local seed = (data and data.starSeed) or starconfig.TEST.seed
	local radius = (data and data.starRadius) or starconfig.TEST.radius
	-- Prefer the full biome MIX (per-type tier) from the entry; fall back to tier-less types,
	-- then the TEST star. tier is what selects the ladder rung, so keep it if we have it.
	local biomes: { starconfig.StarBiome }
	if data and data.starBiomes then
		biomes = data.starBiomes
	elseif data and data.starTypes then
		biomes = {}
		for _, t in data.starTypes do
			biomes[#biomes + 1] = { type = t, tier = 2 }
		end
	else
		biomes = starconfig.TEST.biomes
	end
	-- A star may be BAKED instead of rolled (doc 23): `starMap` names an imported
	-- world under ServerStorage.MapData and replaces generation wholesale. The blob
	-- stays here; clients are sent single chunks by ChunkServer as they walk.
	local map: string? = data and data.starMap

	local baked, bakedMap = starconfig.applyServer({ seed = seed, radius = radius, biomes = biomes, map = map })
	if baked then
		radius = baked.radius -- the blob's own footprint wins over whatever we were told
	end
	-- Publish the config, plus (for a baked star) the few numbers a client needs to
	-- make sense of the chunks it will be sent.
	starconfig.set(seed, radius, biomes, map, if bakedMap then PrebakedMap.encodeMeta(bakedMap.meta) else nil)
	positionSpawn(baked)
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
