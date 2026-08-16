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

local Lighting = game:GetService("Lighting")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local Blocks = require(ReplicatedStorage.Misc.Blocks)
local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)
local starconfig = require(ReplicatedStorage.std.starconfig)
local constellation = require(ReplicatedStorage.std.constellation)

local SPAWN_CLEARANCE = 5

-- Characters ALWAYS auto-load. This used to switch auto-load off and hand-load one
-- character per join, so that nobody landed in an unconfigured void — but the cure
-- was worse: nothing ever reloaded a character, so dying was permanent, and a spawn
-- that failed for any reason left you with no character at all.
--
-- The wait belongs on the client instead, where the terrain actually is: ChunkClient
-- anchors the character on spawn and only releases it once the chunk under it has
-- meshed, holding the loading screen up meanwhile. Freezing is recoverable; not
-- spawning is not.
Players.CharacterAutoLoads = true

-- DAYLIGHT. The lobby is deep space, so its Lighting is permanent night — and the
-- star place inherits that same authored Lighting, which is why the ground world
-- is pitch black. A star is a place with a sun in the sky, so set day on arrival.
-- Server-side Lighting replicates, so this is one place to change. A real
-- day/night cycle can drive ClockTime later; this just stops it being unplayable.
local function setDaylight()
	Lighting.ClockTime = 14 -- early afternoon: long enough shadows to read depth
	Lighting.GeographicLatitude = 20
	Lighting.Brightness = 2.5
	Lighting.Ambient = Color3.fromRGB(90, 95, 105)
	Lighting.OutdoorAmbient = Color3.fromRGB(130, 140, 155)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.GlobalShadows = true
end
setDaylight()

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

-- Is this column somewhere a player can actually stand? A column top of -1 is void,
-- and a top made of water or lava is a drowning, not a landing.
local function standable(wx: number, wz: number): (boolean, number)
	local top, biome = WorldGen.getColumn(wx, wz)
	if top < 0 then
		return false, top
	end
	local block = WorldGen.blockAt(wx, top, wz, top, biome)
	if block == 0 or not Blocks.isSolid(block) then
		return false, top
	end
	return true, top
end

-- Spiral out from a starting column until we find ground. The bake picks a spawn
-- from the SOURCE data, but the world that ships has been clipped at the y floor
-- and disc-cropped since, so the picked column can end up void — and a spawn in
-- void is a fall to your death before you can even look around.
local function nearestStandable(sx: number, sz: number, limit: number): (number?, number?, number?)
	local ok, top = standable(sx, sz)
	if ok then
		return sx, sz, top
	end
	for r = 2, limit, 2 do
		for i = 0, 11 do
			local a = (i / 12) * math.pi * 2
			local wx = sx + math.floor(math.cos(a) * r)
			local wz = sz + math.floor(math.sin(a) * r)
			local good, t = standable(wx, wz)
			if good then
				return wx, wz, t
			end
		end
	end
	return nil
end

local function positionSpawn(baked: any)
	local wx, wz, surfaceY
	if baked and baked.spawn then
		-- A baked map ships its own landing spot (picked at bake time: dry, flat,
		-- as central as the map allows) — but verify it before trusting it.
		local fx, fz, ft = nearestStandable(baked.spawn.x, baked.spawn.z, 160)
		if fx and fz and ft then
			wx, wz, surfaceY = fx, fz, ft
			if fx ~= baked.spawn.x or fz ~= baked.spawn.z then
				warn(
					`[starworld] baked spawn ({baked.spawn.x},{baked.spawn.z}) is not standable — `
						.. `moved to ({fx},{fz}) top {ft}`
				)
			end
		else
			warn("[starworld] no standable ground near the baked spawn — falling back to a ring scan")
			wx, wz, surfaceY = findSpawnColumn(baked.radius or 96)
		end
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

-- A direct or Studio join has no TeleportData, which used to mean the mapless TEST
-- star — so pressing Play could never show you an imported world. It now falls back
-- to a HUB instead, which is both a real destination and the thing you most want to
-- look at. Set to nil for the old procedural TEST star.
local STUDIO_HUB: number? = 1

local function fallbackData(): any
	local hub = if STUDIO_HUB then constellation.hub(STUDIO_HUB) else nil
	if not hub then
		return nil
	end
	local types = {}
	for i, b in hub.biomes do
		types[i] = b.type
	end
	print(`[starworld] no teleport data — falling back to hub "{hub.name}"{if hub.map then ` (baked map "{hub.map}")` else ""}`)
	return {
		starSeed = 1000 + hub.index,
		starRadius = starconfig.TEST.radius,
		starName = hub.name,
		starTypes = types,
		starBiomes = hub.biomes,
		starMap = hub.map,
	}
end

local function configure(data: any)
	if not data then
		data = fallbackData()
	end
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

	-- Say out loud which world this is. "Nothing renders" has too many possible
	-- causes to guess at from the client alone, and the first question is always
	-- whether the server even loaded a map.
	if bakedMap then
		local m = bakedMap.meta
		print(
			`[starworld] BAKED "{m.name}": {m.nx}x{m.nz} chunks from ({m.cx0},{m.cz0}), `
				.. `radius {m.radius}, yFloor {m.yFloor}`
		)
	else
		local names = {}
		for i, b in biomes do
			names[i] = `{b.type}T{b.tier}`
		end
		print(`[starworld] PROCEDURAL seed {seed}, radius {radius}, biomes {table.concat(names, " ")}`)
		if map then
			warn(`[starworld] wanted baked map "{map}" but it did not load — check ServerStorage.MapData`)
		end
	end
end

-- Configure from the FIRST joiner's teleport data. This runs on PlayerAdded, which
-- fires before their character finishes loading, and configuring is only a header +
-- index decode — so the world is normally ready before anyone can see it. If it
-- ever isn't, the client's freeze covers the gap rather than a missing character.
local function onPlayer(plr: Player)
	if configured then
		return
	end
	local ok, data = pcall(function()
		return plr:GetJoinData().TeleportData
	end)
	configure(if ok then data else nil)
end

Players.PlayerAdded:Connect(onPlayer)
for _, plr in Players:GetPlayers() do
	task.spawn(onPlayer, plr) -- Studio: players may already be here
end

return {}
