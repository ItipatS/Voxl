-- ServerScriptService/systems/starworld.luau  (Star place = ResourceStar PlaceId)
-- Configure the bounded world for the star the player ENTERED (its config rides in
-- TeleportData: starSeed / starRadius / starTypes), publish it so clients generate the same
-- terrain, position the spawn on the island, then load characters. Characters DON'T auto-load
-- (we wait until the world is configured, so nobody spawns into the void). Direct/Studio joins
-- with no teleport data fall back to the TEST star.
--
-- One star per server (single-live per starId). `StarRouting` in the lobby pins each
-- star to a reserved server, so everyone entering the same world arrives HERE — which
-- is what makes "configure from the first joiner" correct rather than a race. This
-- server keeps its own MemoryStore mapping alive while anyone is home, and says so
-- loudly if a player ever turns up for a different star.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Lighting = game:GetService("Lighting")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local Blocks = require(ReplicatedStorage.Misc.Blocks)
local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)
local starconfig = require(ReplicatedStorage.std.starconfig)
local constellation = require(ReplicatedStorage.std.constellation)
local StarRouting = require(script.Parent.StarRouting)

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
-- Server-side Lighting replicates, so this is one place to change.
--
-- ClockTime is NOT set here any more: `systems/daynight` owns it, and every client
-- recomputes it per frame from the replicated clock. Pinning it to 14 would be
-- overwritten within a frame on the client and fought over forever on the server.
local function setDaylight()
	Lighting.GeographicLatitude = 20
	Lighting.Brightness = 2.5
	Lighting.Ambient = Color3.fromRGB(90, 95, 105)
	Lighting.OutdoorAmbient = Color3.fromRGB(130, 140, 155)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.GlobalShadows = true
end
setDaylight()

-- SKY. Both places are published from one file, so the star inherits the LOBBY's
-- authored Sky — deep space, which is a strange thing to see from the ground.
--
-- Done on the SERVER, and the ordering worry that suggests doing it client-side
-- does not apply: this runs at boot, before any client exists, and Lighting's
-- children replicate. A joining client therefore receives the right Sky in its
-- FIRST replication — there is no frame where the wrong one is up, and nothing to
-- wait for. Client-side would mean every client deleting and re-adding its own,
-- with the server unable to see which ones got it wrong; that is the reconcile
-- problem, and this avoids having it.
local SKY_FOR_STAR = { "Planet", "Forest" } -- tried in order

local function setSky()
	local box = ReplicatedStorage:FindFirstChild("Skybox")
	if not box then
		warn("[starworld] ReplicatedStorage.Skybox is missing — keeping the lobby sky")
		return
	end

	-- Find the Sky to install before destroying anything, so a bad name leaves the
	-- old sky up rather than leaving the star with no sky at all.
	local found: Sky? = nil
	local usedName = ""
	for _, name in SKY_FOR_STAR do
		local entry = box:FindFirstChild(name)
		local sky = if entry and entry:IsA("Sky") then entry
			elseif entry then entry:FindFirstChildOfClass("Sky")
			else nil
		if sky then
			found, usedName = sky, name
			break
		end
	end

	if not found then
		local have = {}
		for _, child in box:GetChildren() do
			have[#have + 1] = child.Name
		end
		warn(`[starworld] no star sky in ReplicatedStorage.Skybox — wanted one of `
			.. `{table.concat(SKY_FOR_STAR, "/")}, found: {table.concat(have, ", ")}`)
		return
	end

	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") then
			child:Destroy() -- the lobby's, shipped in the place file
		end
	end
	local clone = found:Clone()
	clone.Parent = Lighting
	print(`[starworld] sky set to Skybox.{usedName}`)
end
setSky()

-- WATER. The mesher no longer builds water out of transparent parts; it writes the
-- water cells into Terrain, which is one render object for the whole world and
-- brings swimming, buoyancy and underwater fog with it. What it does NOT bring is
-- a look — default Terrain water is a flat blue-grey. These are Terrain properties,
-- so setting them on the server replicates to every client that fills water in.
local function setWater()
	local terrain = Workspace.Terrain
	terrain.WaterColor = Color3.fromRGB(28, 92, 140)
	terrain.WaterTransparency = 0.72 -- you can see the seabed, but not to the horizon
	terrain.WaterReflectance = 0.08 -- a little sky, not a mirror
	terrain.WaterWaveSize = 0.08 -- blocks are 3.5 studs; big waves swallow the shore
	terrain.WaterWaveSpeed = 6
end
setWater()

local configured = false
-- Which star this server IS, once someone has arrived for one. Used to notice a
-- player who was routed here for a different world.
local liveStarId: string? = nil

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

-- A procedural star has no authored scene, so guarantee a spawn anchor exists
-- (functional infrastructure, not decorative content) — else players drop into the
-- void on join.
local function ensureSpawnPart(): SpawnLocation
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation")
	if not spawn then
		spawn = Instance.new("SpawnLocation")
		spawn.Name = "StarSpawn"
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Transparency = 1
		spawn.CanCollide = false
		spawn.Neutral = true
		spawn.Parent = Workspace
	end
	spawn.Anchored = true
	return spawn :: SpawnLocation
end

local function positionSpawn(baked: any, mapName: string?)
	-- An authored spawn (starconfig.MAP_SPAWN) is a spot someone stood on and liked,
	-- so it is taken as given — no standable scan, no ring fallback. Those exist to
	-- rescue a MECHANICAL guess; second-guessing a human one just moves them off it.
	local authored = if mapName then starconfig.MAP_SPAWN[mapName] else nil
	if authored then
		local spawn = ensureSpawnPart()
		spawn.CFrame = CFrame.new(authored)
		print(`[starworld] spawn at the authored point for "{mapName}" ({authored})`)
		return
	end

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
	local spawn = ensureSpawnPart()
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

-- What keys a rejected teleport payload actually had — the one fact that turns
-- "why am I in the test star" into a one-line diagnosis.
local function shapeOf(data: any): string
	local keys = {}
	if type(data) == "table" then
		for k in data do
			keys[#keys + 1] = tostring(k)
		end
		table.sort(keys)
	end
	return if #keys > 0 then table.concat(keys, ", ") else "<none>"
end

local function configure(data: any)
	-- `if not data` is not enough, and the difference cost a real bug.
	--
	-- A client-side entry path used to teleport with SetTeleportData({ biome = "Forest" }).
	-- That table is truthy, so the fallback was skipped, and then every field it
	-- read was nil: seed fell to TEST, radius fell to TEST, biomes fell to TEST,
	-- and `starMap` was nil so no baked map loaded at all. You pressed enter on
	-- Aldermoor and arrived in the procedural test star, with nothing in the log
	-- saying so — the "wanted baked map" warning below is inside `if map then`,
	-- and map was nil.
	--
	-- So validate the SHAPE. Teleport data without a starSeed is not teleport data,
	-- whatever else is in it.
	if data and not data.starSeed then
		warn(`[starworld] teleport data has no starSeed (keys: {shapeOf(data)}) — `
			.. "treating it as a direct join. Whoever teleported this player is not "
			.. "using the EnterHub/EnterStar path in starentry.")
		data = nil
	end
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
	local starName: string = (data and data.starName) or "?"

	local baked, bakedMap = starconfig.applyServer({ seed = seed, radius = radius, biomes = biomes, map = map })
	if baked then
		radius = baked.radius -- the blob's own footprint wins over whatever we were told
	end
	-- Publish the config, plus (for a baked star) the few numbers a client needs to
	-- make sense of the chunks it will be sent.
	starconfig.set(seed, radius, biomes, map, if bakedMap then PrebakedMap.encodeMeta(bakedMap.meta) else nil)
	positionSpawn(baked, map)
	configured = true

	-- Say out loud which world this is. "Nothing renders" has too many possible
	-- causes to guess at from the client alone, and the first question is always
	-- whether the server even loaded a map.
	if bakedMap then
		local m = bakedMap.meta
		print(
			`[starworld] {starName} (seed {seed}) — BAKED "{m.name}": {m.nx}x{m.nz} chunks from ({m.cx0},{m.cz0}), `
				.. `radius {m.radius}, yFloor {m.yFloor}`
		)
	else
		local names = {}
		for i, b in biomes do
			names[i] = `{b.type}T{b.tier}`
		end
		print(`[starworld] {starName} — PROCEDURAL seed {seed}, radius {radius}, biomes {table.concat(names, " ")}`)
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
	local ok, data = pcall(function()
		return plr:GetJoinData().TeleportData
	end)
	if not ok then
		-- A failed read and a direct Studio join both end up at the fallback, and
		-- they are very different situations: one means the handoff broke.
		warn(`[starworld] could not read teleport data for {plr.Name}: {data}`)
		data = nil
	end

	if configured then
		-- Routing (StarRouting) pins each star to one reserved server, so everyone
		-- who lands here should be here for the SAME world. If they are not, the
		-- routing failed and this player is about to spend the session in someone
		-- else's star with no way to tell — the one case worth shouting about.
		if data and data.starId and data.starId ~= liveStarId then
			warn(`[starworld] {plr.Name} arrived for star '{data.starId}' but this server `
				.. `is '{tostring(liveStarId)}' — reserved-server routing did not hold`)
		end
		return
	end

	if data and data.starId then
		liveStarId = data.starId
		-- Keep this star's MemoryStore mapping alive while anyone is home. Without
		-- it a star busy for longer than the TTL loses its entry, and the next
		-- arrival opens a second copy of a world people are standing in.
		if data.starAccess then
			StarRouting.keepAlive(data.starId, data.starAccess)
		end
	end
	configure(data)
end

Players.PlayerAdded:Connect(onPlayer)
for _, plr in Players:GetPlayers() do
	task.spawn(onPlayer, plr) -- Studio: players may already be here
end

return {}
