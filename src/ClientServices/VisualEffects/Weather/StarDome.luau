--!strict
--==================================================================================--
--  StarDome  ·  immersive night sky (SHELL layer · client · free)
--==================================================================================--
--  A camera-locked star field + deterministic ambient shooting stars. These are
--  COSMETIC — every value derives from the shared clock, so all clients see the same
--  sky with zero replication. (The REAL collectable meteorite is a separate, server-
--  authoritative world object — see MeteorService.)
--
--  COUPLING (reads WeatherSignals):
--    • sunDir.Y  → stars fade IN as the sun drops below the horizon
--    • cover     → clouds HIDE the stars (overcast night = dim sky)
--    • time      → twinkle + the deterministic shooting-star slot schedule
--==================================================================================--

local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local WeatherSignals = require(script.Parent:WaitForChild("WeatherSignals"))

local StarDome = {}

--==================================================================================--
--  CONFIG
--==================================================================================--
local CONFIG = {
	seed      = 7,
	radius    = 1500,          -- dome radius (camera-locked; stars feel infinitely far)
	starCount = 420,
	sizeMin   = 0.6,
	sizeMax   = 1.8,
	palette   = {
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(200, 214, 255),
		Color3.fromRGB(255, 232, 205),
	},

	twinkleSpeed = 2.2,
	twinkleDepth = 0.45,       -- 0..1 how much brightness oscillates

	nightStart = 0.08,         -- sun.Y where stars BEGIN to appear
	nightBand  = 0.18,         -- sun.Y span over which they fully fade in
	coverHide  = 0.85,         -- how strongly clouds dim the stars

	shoot = {
		streams   = 3,         -- parallel shooting-star "lanes"
		period    = 14,        -- seconds per slot, per stream
		threshold = 0.18,      -- noise must exceed this for a slot to fire (rarity)
		durFrac   = 0.10,      -- fraction of the slot the streak is visible
		length    = 70,
		color     = Color3.fromRGB(220, 235, 255),
	},
}
StarDome.Config = CONFIG

--==================================================================================--
--  helpers
--==================================================================================--
local function dirFromSeed(s: number): Vector3
	-- pseudo-random unit direction biased to the upper hemisphere
	local theta = (math.noise(s, 0.1) * 0.5 + 0.5) * 2 * math.pi
	local y = 0.10 + (math.noise(0.1, s) * 0.5 + 0.5) * 0.9
	local r = math.sqrt(math.max(0, 1 - y * y))
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

--==================================================================================--
--  STARS  ·  welded to one anchor so the whole field moves with a single CFrame write
--==================================================================================--
local Stars = { anchor = nil :: Part?, list = {} }

function Stars.build(parent: Instance)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = true, false, false, false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Parent = parent
	Stars.anchor = anchor

	local rng = Random.new(CONFIG.seed)
	for _ = 1, CONFIG.starCount do
		local dir = dirFromSeed(rng:NextNumber(0, 1000))
		local s = Instance.new("Part")
		s.Anchored, s.CanCollide, s.CanQuery, s.CanTouch = false, false, false, false
		s.Massless = true
		s.Material = Enum.Material.Neon
		s.Color = CONFIG.palette[rng:NextInteger(1, #CONFIG.palette)]
		s.Transparency = 1
		local sz = rng:NextNumber(CONFIG.sizeMin, CONFIG.sizeMax)
		s.Size = Vector3.new(sz, sz, sz)
		s.CFrame = CFrame.new(dir * CONFIG.radius)  -- relative to anchor at build time
		s.Parent = parent

		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1 = anchor, s
		w.Parent = s

		table.insert(Stars.list, {
			p = s,
			phase = rng:NextNumber(0, math.pi * 2),
			bright = rng:NextNumber(0.5, 1.0),
		})
	end
end

function Stars.update(camPos: Vector3, vis: number, t: number)
	if Stars.anchor then Stars.anchor.CFrame = CFrame.new(camPos) end
	local depth = CONFIG.twinkleDepth
	for _, st in Stars.list do
		local tw = (1 - depth) + depth * (0.5 + 0.5 * math.sin(t * CONFIG.twinkleSpeed + st.phase))
		st.p.Transparency = 1 - vis * tw * st.bright
	end
end

--==================================================================================--
--  SHOOTING STARS  ·  deterministic slot schedule (every client, same streak, same instant)
--==================================================================================--
local Shoot = { parts = {} }

function Shoot.build(parent: Instance)
	for _ = 1, CONFIG.shoot.streams do
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.Material = Enum.Material.Neon
		p.Color = CONFIG.shoot.color
		p.Transparency = 1
		p.Size = Vector3.new(1, 1, CONFIG.shoot.length)  -- extends along local -Z (lookAt axis)
		p.Parent = parent
		table.insert(Shoot.parts, p)
	end
end

function Shoot.update(camPos: Vector3, vis: number, t: number)
	local cfg = CONFIG.shoot
	for i, p in Shoot.parts do
		local off = (i - 1) * 0.37
		local phase = t / cfg.period + off
		local slot = math.floor(phase)
		local fire = math.noise(slot * 0.13 + CONFIG.seed + i, 5.5) > cfg.threshold
		local f = phase - slot                          -- 0..1 through the slot
		if fire and f < cfg.durFrac and vis > 0.2 then
			local pp = f / cfg.durFrac                  -- 0..1 across the streak's life
			local d0 = dirFromSeed(slot * 1.7 + i)
			local d1 = dirFromSeed(slot * 1.7 + i + 91)
			local dir = d0:Lerp(d1, pp)
			local pos = camPos + dir * (CONFIG.radius * 0.95)
			p.CFrame = CFrame.lookAt(pos, pos + (d1 - d0))
			local fade = math.clamp(math.min(pp / 0.15, (1 - pp) / 0.3), 0, 1)
			p.Transparency = 1 - fade * vis
		else
			p.Transparency = 1
		end
	end
end

--==================================================================================--
--  ORCHESTRATION
--==================================================================================--
function StarDome.Start()
	if StarDome._running then return end
	StarDome._running = true
	WeatherSignals.Start()

	local root = Instance.new("Folder")
	root.Name = "StarFX"
	root.Parent = Workspace
	StarDome._root = root
	WeatherSignals.registerIgnore(root)

	Stars.build(root)
	Shoot.build(root)

	StarDome._conn = RunService.RenderStepped:Connect(function()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local S = WeatherSignals
		local camPos = cam.CFrame.Position

		-- night factor + cloud occlusion → one shared visibility scalar
		local night = math.clamp((CONFIG.nightStart - S.sunDir.Y) / CONFIG.nightBand, 0, 1)
		local vis = night * (1 - S.cover * CONFIG.coverHide)

		Stars.update(camPos, vis, S.time)
		Shoot.update(camPos, vis, S.time)
	end)
end

function StarDome.Stop()
	if not StarDome._running then return end
	StarDome._running = false
	if StarDome._conn then StarDome._conn:Disconnect() end
	if StarDome._root then StarDome._root:Destroy() end
	Stars.list, Shoot.parts = {}, {}
	Stars.anchor = nil
end

return StarDome
