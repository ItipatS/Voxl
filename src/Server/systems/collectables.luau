-- ServerScriptService/systems/collectables.luau
-- Server-authoritative STREAMED collectable star field. The whole field lives
-- here as DATA (no Instances) — up to ~65535 stars scattered across the area.
-- Each tick we only SIMULATE stars near a player, and stream the new + moving
-- ones to each nearby player in Blink batches (StarStream), unloading ones that
-- fall out of range (StarUnload) — exactly like ChunkServer streams chunks. The
-- client (Client/StarRenderer) renders + interpolates them and requests catches
-- (StarCatch), which we validate against the real position before awarding.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local config = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

--=====================================================================
-- Visible-at-once ≈ STAR_COUNT * (STREAM_RADIUS / FIELD_RADIUS)^3. A 3D field is
-- sparse, so density needs a big count. FIELD_RADIUS must cover where players
-- actually fly (the whole constellation, incl. spawn + starter stars) or there's
-- empty space near spawn.
local STAR_COUNT     = 30000                    -- ≤ 65535 (u16 network id); buckets keep it cheap
local FIELD_RADIUS   = 22000                    -- covers most of the (bigger) constellation ring
local STREAM_RADIUS  = 1400                     -- stream + simulate stars within this of a player

local FLEE_RADIUS    = 55
local FLEE_FORCE     = 130
local WANDER_FORCE   = 14
local MAX_SPEED      = 60                       -- < player flight speed, so it's catchable
local DAMPING        = 1.6

local CATCH_RADIUS   = 16                       -- server-validated catch distance
local STREAM_BATCH   = 50                       -- StarState is 14 bytes → keep unreliable packets < ~900B
local SIM_HZ         = 20
--=====================================================================

local CENTER = config.CENTER
local rng = Random.new()

type Star = { home: Vector3, pos: Vector3, vel: Vector3, seed: number, moving: boolean }
local stars: { Star } = {} -- index = network id (1..STAR_COUNT)

local function randomHome(): Vector3
	local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
	if dir.Magnitude < 1e-3 then
		dir = Vector3.yAxis
	end
	return CENTER + dir.Unit * (FIELD_RADIUS * rng:NextNumber(0, 1) ^ (1 / 3))
end

for i = 1, STAR_COUNT do
	local h = randomHome()
	stars[i] = { home = h, pos = h, vel = Vector3.zero, seed = i * 37.13, moving = false }
end

-- ---- spatial buckets (by HOME cell) ----------------------------------------
-- Process only stars NEAR a player instead of scanning all STAR_COUNT every tick —
-- that O(stars·players) scan was the cold-start lag. A star's pos wanders only ~a
-- flee-radius from home, so bucketing by home cell + checking the 3×3×3 around a
-- player covers everything in stream range.
local CELL = STREAM_RADIUS
local buckets: { [string]: { number } } = {}
local function cellKey(pos: Vector3): string
	return `{math.floor(pos.X / CELL)},{math.floor(pos.Y / CELL)},{math.floor(pos.Z / CELL)}`
end
local function addToBucket(id: number, pos: Vector3)
	local k = cellKey(pos)
	local b = buckets[k]
	if not b then
		b = {}
		buckets[k] = b
	end
	table.insert(b, id)
end
local function removeFromBucket(id: number, pos: Vector3)
	local b = buckets[cellKey(pos)]
	if b then
		local i = table.find(b, id)
		if i then
			b[i] = b[#b]
			b[#b] = nil
		end
	end
end
for i, s in stars do
	addToBucket(i, s.home)
end
-- Mark ids whose home cell is within ±1 of `pos` into `out` (deduped).
local function gatherNear(pos: Vector3, out: { [number]: boolean })
	local cx, cy, cz = math.floor(pos.X / CELL), math.floor(pos.Y / CELL), math.floor(pos.Z / CELL)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local b = buckets[`{cx + dx},{cy + dy},{cz + dz}`]
				if b then
					for _, id in b do
						out[id] = true
					end
				end
			end
		end
	end
end

-- ---- leaderstats.Stars -----------------------------------------------------
local function ensureStats(plr: Player)
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = plr
	end
	if not ls:FindFirstChild("Stars") then
		local v = Instance.new("IntValue")
		v.Name = "Stars"
		v.Parent = ls
	end
end
Players.PlayerAdded:Connect(ensureStats)
for _, plr in Players:GetPlayers() do
	ensureStats(plr)
end
local function award(plr: Player)
	local ls = plr:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild("Stars")
	if v and v:IsA("IntValue") then
		v.Value += 1
	end
end

-- ---- per-player streamed set (which star ids that client currently has) -----
local sentBy: { [Player]: { [number]: boolean } } = {}
Players.PlayerRemoving:Connect(function(plr)
	sentBy[plr] = nil
end)

local function rootPos(plr: Player): Vector3?
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- ---- catch (client requests, server validates proximity) -------------------
blink.StarCatch.On(function(plr: Player, id: number)
	local s = stars[id]
	local pp = rootPos(plr)
	if not s or not pp or (s.pos - pp).Magnitude > CATCH_RADIUS then
		return -- unknown star or not actually close → ignore (anti-cheat)
	end
	award(plr)
	blink.StarCaught.Fire(plr, id)
	-- drop it from everyone who has it, then respawn it elsewhere in the field
	for p, sent in sentBy do
		if sent[id] then
			blink.StarUnload.Fire(p, { id })
			sent[id] = nil
		end
	end
	removeFromBucket(id, s.home)
	local h = randomHome()
	s.home, s.pos, s.vel, s.moving = h, h, Vector3.zero, false
	addToBucket(id, h)
end)

-- ---- simulate near stars + stream ------------------------------------------
local acc = 0
local dtStep = 1 / SIM_HZ
local clock = 0

RunService.Heartbeat:Connect(function(dt: number)
	acc += dt
	if acc < dtStep then
		return
	end
	local step = acc
	acc = 0
	clock += step

	local samples: { Vector3 } = {}
	local nearSet: { [number]: boolean } = {} -- union of stars near ANY player
	for _, plr in Players:GetPlayers() do
		local pp = rootPos(plr)
		if pp then
			samples[#samples + 1] = pp
			gatherNear(pp, nearSet)
		end
	end

	-- Simulate only the near stars (the rest sit still, free).
	for id in nearSet do
		local s = stars[id]
		local accel = Vector3.zero
		for _, pp in samples do
			local away = s.pos - pp
			local d = away.Magnitude
			if d < FLEE_RADIUS and d > 1e-3 then
				accel += away.Unit * (FLEE_FORCE * (1 - d / FLEE_RADIUS))
			end
		end
		local t = clock * 0.25
		accel += Vector3.new(math.noise(t, s.seed, 0.0), math.noise(t, s.seed, 5.2) * 0.5, math.noise(t, s.seed, 9.7))
			* WANDER_FORCE
		s.vel = s.vel * math.exp(-DAMPING * step) + accel * step
		if s.vel.Magnitude > MAX_SPEED then
			s.vel = s.vel.Unit * MAX_SPEED
		end
		s.pos += s.vel * step
		s.moving = s.vel.Magnitude > 0.5
	end

	-- Stream per player: new + moving in-range stars (from nearby buckets), unload
	-- ones that left range (iterate the small `sent` set, not all stars).
	for _, plr in Players:GetPlayers() do
		local pp = rootPos(plr)
		if not pp then
			continue
		end
		local sent = sentBy[plr]
		if not sent then
			sent = {}
			sentBy[plr] = sent
		end

		local near: { [number]: boolean } = {}
		gatherNear(pp, near)

		local stream: { { id: number, dp: Vector3 } } = {}
		local inRange: { [number]: boolean } = {}
		for id in near do
			local s = stars[id]
			if (s.pos - pp).Magnitude < STREAM_RADIUS then
				inRange[id] = true
				if not sent[id] then
					sent[id] = true
					stream[#stream + 1] = { id = id, dp = s.pos }
				elseif s.moving then
					stream[#stream + 1] = { id = id, dp = s.pos }
				end
			end
		end

		local unload: { number } = {}
		for id in sent do
			if not inRange[id] then
				sent[id] = nil
				unload[#unload + 1] = id
			end
		end

		-- StarStream in unreliable-safe chunks.
		local i = 1
		while i <= #stream do
			local batch = {}
			while #batch < STREAM_BATCH and stream[i] do
				batch[#batch + 1] = stream[i]
				i += 1
			end
			blink.StarStream.Fire(plr, batch)
		end
		if #unload > 0 then
			blink.StarUnload.Fire(plr, unload)
		end
	end
end)

return {}
