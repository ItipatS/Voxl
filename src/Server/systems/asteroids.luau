-- ServerScriptService/systems/asteroids.luau
-- Server-authoritative MOVING hazard field (like collectables/stars, but each rock
-- drifts at a constant velocity). Asteroids live here as DATA (no server Instances);
-- each tick we advance them, stream the ones near each player (pos + vel, once, so
-- the client dead-reckons), and detect player collisions. On a hit the SERVER applies
-- the damage and owns the i-frame window, then fires AsteroidHit to the client for the
-- feel (stun / knockback / flash). Speeds sit BELOW cruise (160) so a careful flier can
-- dodge, but a booster (×2.4 ≈ 384) outruns their own reaction time and rams them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local config = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

--=====================================================================
local COUNT         = 1600                     -- rocks across the whole field
local FIELD_RADIUS  = 22000                    -- roam volume (matches the star field)
local STREAM_RADIUS = 3500                     -- stream + collide within this of a player
local SIZE_MIN, SIZE_MAX   = 18, 85            -- world radius (big rocks, readable from afar)
local SPEED_MIN, SPEED_MAX = 45, 130           -- studs/s (< cruise 160 → dodgeable un-boosted)

local DAMAGE        = 22                        -- per hit (humanoid:TakeDamage; ForceField immune)
local STUN          = 1.1                       -- seconds the client freezes + gets shoved
local IFRAME        = STUN + 0.5                -- invincible until the stun's well past
local PLAYER_RADIUS = 4                         -- HRP fudge added to the rock radius

local SIM_HZ        = 20
local STREAM_BATCH  = 24                        -- AsteroidState ≈ 31 bytes → keep unreliable < ~900B
--=====================================================================

local CENTER = config.CENTER
local BH = config.BLACKHOLE
local MIN_SPAWN_R = BH.radius + 800             -- don't spawn inside the central hazard
local rng = Random.new()

-- How many mesh shapes the client can render (ReplicatedStorage.Assets.Astroids).
local shapeCount = 1
do
	local astro = ReplicatedStorage:WaitForChild("Assets"):FindFirstChild("Astroids")
	if astro then
		local n = 0
		for _, d in astro:GetChildren() do
			if d:IsA("BasePart") then
				n += 1
			end
		end
		shapeCount = math.max(1, n)
	end
end

type Asteroid = { pos: Vector3, vel: Vector3, size: number, shape: number }
local rocks: { Asteroid } = {} -- index = network id (1..COUNT)

local function randomDir(): Vector3
	local d = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
	if d.Magnitude < 1e-3 then
		d = Vector3.yAxis
	end
	return d.Unit
end

local function randomFieldPos(): Vector3
	-- Uniform in the shell [MIN_SPAWN_R, FIELD_RADIUS] (cube-root keeps it volume-uniform).
	local t = rng:NextNumber(0, 1) ^ (1 / 3)
	local r = MIN_SPAWN_R + t * (FIELD_RADIUS - MIN_SPAWN_R)
	return CENTER + randomDir() * r
end

local function roll(a: Asteroid)
	a.pos = randomFieldPos()
	a.vel = randomDir() * rng:NextNumber(SPEED_MIN, SPEED_MAX)
	a.size = rng:NextNumber(SIZE_MIN, SIZE_MAX)
	a.shape = rng:NextInteger(1, shapeCount)
end

for i = 1, COUNT do
	local a = { pos = Vector3.zero, vel = Vector3.zero, size = 0, shape = 1 }
	roll(a)
	rocks[i] = a
end

-- ---- per-player streamed set + i-frame window -------------------------------
local sentBy: { [Player]: { [number]: boolean } } = {}
local iframeUntil: { [Player]: number } = {}
Players.PlayerRemoving:Connect(function(plr)
	sentBy[plr] = nil
	iframeUntil[plr] = nil
end)

local function rootAndHum(plr: Player): (Vector3?, Humanoid?)
	local char = plr.Character
	if not char then
		return nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") then
		return root.Position, hum
	end
	return nil, hum
end

-- On respawn (drifted out of the field), the rock jumps to a new pos/vel — so we must
-- UNLOAD it from anyone rendering the old trajectory (they dead-reckon; they'd never
-- self-correct). It re-streams fresh when it next enters range.
local function respawn(id: number, a: Asteroid)
	roll(a)
	for plr, sent in sentBy do
		if sent[id] then
			sent[id] = nil
			blink.AsteroidUnload.Fire(plr, { id })
		end
	end
end

-- ---- simulate + stream + collide -------------------------------------------
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

	-- Advance every rock; respawn the ones that drifted past the field edge.
	for id, a in rocks do
		a.pos += a.vel * step
		if (a.pos - CENTER).Magnitude > FIELD_RADIUS then
			respawn(id, a)
		end
	end

	-- Per player: stream near rocks (once, pos+vel) + collide.
	for _, plr in Players:GetPlayers() do
		local pp, hum = rootAndHum(plr)
		if not pp then
			continue
		end
		local sent = sentBy[plr]
		if not sent then
			sent = {}
			sentBy[plr] = sent
		end
		local canHit = hum ~= nil and hum.Health > 0 and clock >= (iframeUntil[plr] or 0)

		local stream: { { id: number, dp: Vector3, vel: Vector3, size: number, shape: number } } = {}
		local inRange: { [number]: boolean } = {}
		for id, a in rocks do
			local d = (a.pos - pp).Magnitude
			if d < STREAM_RADIUS then
				inRange[id] = true
				if not sent[id] then
					sent[id] = true
					stream[#stream + 1] = { id = id, dp = a.pos, vel = a.vel, size = a.size, shape = a.shape }
				end
				if canHit and d < a.size + PLAYER_RADIUS then
					canHit = false -- one hit per tick
					iframeUntil[plr] = clock + IFRAME
					local h = hum :: Humanoid
					h:TakeDamage(DAMAGE)
					local away = pp - a.pos
					local dir = if away.Magnitude > 1e-3 then away.Unit else Vector3.yAxis
					blink.AsteroidHit.Fire(plr, { dir = dir, stun = STUN })
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

		local i = 1
		while i <= #stream do
			local batch = {}
			while #batch < STREAM_BATCH and stream[i] do
				batch[#batch + 1] = stream[i]
				i += 1
			end
			blink.AsteroidStream.Fire(plr, batch)
		end
		if #unload > 0 then
			blink.AsteroidUnload.Fire(plr, unload)
		end
	end
end)

return {}
