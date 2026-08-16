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
local constellation = require(ReplicatedStorage.std.constellation)

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

	-- Auto-load goes back ON now that there is a world to spawn into. It is turned
	-- off at the top of this file so nobody lands in an unconfigured void — but it
	-- was never turned back on, so dying was permanent: the character never
	-- reloaded and the session was over. Deaths respawn normally from here.
	Players.CharacterAutoLoads = true

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

local function onPlayer(plr: Player)
	if not configured then
		local ok, data = pcall(function()
			return plr:GetJoinData().TeleportData
		end)
		configure(if ok then data else nil)
	end
	-- Once configure() has re-enabled auto-load, later joiners already have a
	-- character; loading a second one here would throw the first away mid-spawn.
	if not plr.Character then
		plr:LoadCharacter()
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, plr in Players:GetPlayers() do
	task.spawn(onPlayer, plr) -- Studio: players may already be here
end

return {}
