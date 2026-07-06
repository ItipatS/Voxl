--!strict
--==================================================================================--
--  RainSystem  ·  client-side, server-time-synced weather stack
--==================================================================================--
--  THREE LAYERS (see the design convo):
--    • SHELL   – camera-following rain streaks (the "immersive" everywhere-around-you bit)
--    • WORLD   – puddles + ground impacts (have a real address, terrain occludes them)
--    • LENS    – the lighting / atmosphere grade drawn over the whole scene
--
--  SIGNALS LIVE IN WeatherSignals NOW. This module no longer owns the weather model —
--  it READS the shared brain (rain / effRain / wetness / windSpeed / rayParams) that
--  WeatherSignals computes once per frame. CloudSystem + StarDome read the same brain,
--  so rain, clouds and sky all couple to one wind / one cover / one wetness. (FTC-209)
--
--  WHY IT NEEDS NO REPLICATION: every value is a pure function of the synced server
--  clock + a fixed SEED, so all clients compute identical weather locally. The server
--  only ever sets one optional attribute (WeatherSignals.Config.overrideAttr) to FORCE
--  weather for an event; continuous weather is never sent over the wire.
--==================================================================================--

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local WeatherSignals = require(script.Parent:WaitForChild("WeatherSignals"))

local RainSystem = {}

--==================================================================================--
--  CONFIG  ·  RENDER tunables only. The weather MODEL (clock/noise/wind/wetness) moved
--  to WeatherSignals.Config — edit it there.
--==================================================================================--
local CONFIG = {
	shell = {  -- the rain you stand inside
		enabled = true,
		radii = { 42, 84 },     -- inner + outer ring → parallax. add more for depth.
		height = 220,
		fallSpeed = 55,             -- base UV fall speed
		fallRainBoost = 45,          -- extra fall speed at full rain
		windFactor = 0.05,           -- how much wind shears the streaks sideways
		color = Color3.fromRGB(210, 222, 235),
		streakAssetId = "rbxassetid://202975950",          -- optional rbxassetid://... (must be an IMAGE asset, not a Decal);
		                             -- empty = generate procedurally via EditableImage (verified working)
	},

	puddles = {  -- the wet ground, driven by `wetness` not `rain`
		enabled = true,
		count = 40,             -- pool size (bounded cost no matter how big the map is)
		scanRadius = 70,             -- how far around the camera puddles may spawn
		recycleRadius = 95,          -- past this from camera, a puddle is recycled forward
		raycastHeight = 60,          -- down-ray start height when probing for flat ground
		flatNormalY = 0.96,          -- only land puddles on near-flat surfaces
		thickness = 0.08,
		minSize = 3,
		maxSize = 9,
		reflectance = 0.55,          -- fakes wetness by mirroring the sky (Roblox has no cheap real reflection)
		color = Color3.fromRGB(40, 48, 60),
		minTransparency = 0.25,      -- most-opaque a puddle gets (at full wetness)
		fade = 4,              -- fade-in/out speed
		recyclesPerFrame = 3,        -- throttle: how many puddles may be re-placed per frame
	},

	impacts = {  -- brief splash rings where drops hit (particles earn their place here)
		enabled = true,
		pool = 16,
		perSecond = 14,              -- at full rain; scales down with rain
		life = 0.35,
		startSize = 0.6,
		endSize = 3.2,
		color = Color3.fromRGB(200, 215, 230),
		waterColor = Color3.fromRGB(150, 195, 220),
	},

	lighting = {  -- the LENS grade: lerp between two presets by `rain`
		-- DISABLED: this layer creates/drives an Atmosphere + ColorCorrection, which blooms
		-- the sun into a glowing blob and fights the game's own sky + LenFlare (src/LenFlare).
		-- Sky / sun / flare are owned elsewhere; leave them alone. Re-enable only with a
		-- gentler, Atmosphere-free grade if storm darkening is wanted later. (FTC-209)
		enabled = false,
		clear = {
			Brightness = 2.5, Exposure = 0.0,
			OutdoorAmbient = Color3.fromRGB(150, 150, 160),
			AtmoDensity = 0.30, AtmoHaze = 0.0, AtmoColor = Color3.fromRGB(199, 199, 199),
			CCSaturation = 0.0, CCTint = Color3.fromRGB(255, 255, 255), CCBrightness = 0.0,
		},
		storm = {
			Brightness = 0.85, Exposure = -0.40,
			OutdoorAmbient = Color3.fromRGB(70, 76, 90),
			AtmoDensity = 0.45, AtmoHaze = 2.2, AtmoColor = Color3.fromRGB(150, 160, 175),
			CCSaturation = -0.25, CCTint = Color3.fromRGB(192, 202, 216), CCBrightness = -0.05,
		},
	},
}
RainSystem.Config = CONFIG  -- exposed so you can tweak live

--==================================================================================--
--  helpers
--==================================================================================--
local function lerp(a: number, b: number, k: number): number
	return a + (b - a) * k
end

local function approach(cur: number, target: number, rate: number, dt: number): number
	return cur + (target - cur) * math.min(dt * rate, 1)
end

--==================================================================================--
--  SHELL  ·  camera-locked rain streaks (immersive layer)
--==================================================================================--
local Shell = { rig = nil :: Model?, textures = {}, editable = nil :: any }

local function makeStreakImage(): (EditableImage?, string?)
	-- procedural vertical streaks via EditableImage → no asset upload needed to test.
	-- CreateEditableImage can THROW (perms / memory budget) or the binding API can shift
	-- between Roblox versions — both used to fail silently here, which is exactly why the
	-- rain shell showed nothing and printed nothing. Return the error so the caller logs it.
	local ok, imgOrErr = pcall(function()
		local AssetService = game:GetService("AssetService")
		local W, H = 64, 128
		local e = AssetService:CreateEditableImage({ Size = Vector2.new(W, H) })
		if not e then
			error("AssetService:CreateEditableImage returned nil")
		end
		local buf = buffer.create(W * H * 4)
		-- Several streaks per tile at varied intensity. The old image lit only ~2 of 64
		-- columns, so even when rendered the streaks were nearly impossible to spot. Make
		-- roughly every 4th-6th column a streak, each a soft head→tail vertical gradient.
		for x = 0, W - 1 do
			local on = (x % 5 == 0) or (x % 7 == 2) or (x % 11 == 4)
			local peak = (x % 7 == 2) and 235 or 170   -- a few brighter streaks for depth
			for y = 0, H - 1 do
				local i = (y * W + x) * 4
				local a = 0
				if on then
					local head = (y / H) ^ 0.7        -- soft vertical gradient, brighter toward the head
					a = math.floor(peak * head)
				end
				buffer.writeu8(buf, i + 0, 235)
				buffer.writeu8(buf, i + 1, 244)
				buffer.writeu8(buf, i + 2, 255)
				buffer.writeu8(buf, i + 3, a)
			end
		end
		e:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), buf)
		return e
	end)
	if ok then
		return imgOrErr :: EditableImage, nil
	end
	return nil, tostring(imgOrErr)
end

function Shell.build(parent: Instance)
	local rig = Instance.new("Model")
	rig.Name = "RainShell"

	local editable, imgErr = nil, nil
	if CONFIG.shell.streakAssetId == "" then
		editable, imgErr = makeStreakImage()
		if not editable then
			warn("[RainSystem] rain-shell streak image could NOT be created — the camera rain "
				.. "will be invisible (puddles/impacts/screen-rain don't use a texture, which is why "
				.. "they still work). Fix: set CONFIG.shell.streakAssetId to a rain-streak rbxassetid. "
				.. "EditableImage error: " .. tostring(imgErr))
		end
	end

	-- Bind the procedural streak image ONCE and reuse it. This is the API that moves around
	-- between Roblox versions (EditableImage → Texture). If it fails the streaks are simply
	-- invisible — so surface the error instead of swallowing it, and fall back to a plain
	-- asset id if CONFIG.shell.streakAssetId is set. (FTC-209)
	local streakContent: any = nil
	if editable then
		local ok, res = pcall(function()
			return (Content :: any).fromObject(editable)
		end)
		if ok then
			streakContent = res
			Shell.editable = editable -- retain a strong ref so the image isn't GC'd → blank texture
			print("[RainSystem] rain shell built — streak texture bound OK.")
		else
			warn("[RainSystem] EditableImage→Texture bind failed — rain streaks will be invisible. "
				.. "Set CONFIG.shell.streakAssetId to a fallback rbxassetid. Error: " .. tostring(res))
		end
	end

	for _, radius in CONFIG.shell.radii do
		for i = 0, 3 do
			local yaw = math.rad(i * 90)
			local dir = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
			local wall = Instance.new("Part")
			wall.Anchored, wall.CanCollide, wall.CanQuery, wall.CanTouch = true, false, false, false
			wall.Massless = true
			wall.Transparency = 1   -- the part itself is invisible; only the Texture shows
			wall.Size = Vector3.new(radius * 2, CONFIG.shell.height, 0.1)
			wall.CFrame = CFrame.lookAt(dir * radius, Vector3.zero)

			-- texture BOTH big faces so we never have to reason about which one points inward
			for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
				local tex = Instance.new("Texture")
				tex.Face = face
				tex.StudsPerTileU = radius
				tex.StudsPerTileV = CONFIG.shell.height
				tex.Color3 = CONFIG.shell.color
				if streakContent then
					tex.TextureContent = streakContent
				elseif CONFIG.shell.streakAssetId ~= "" then
					tex.Texture = CONFIG.shell.streakAssetId
				end
				tex.Parent = wall
				table.insert(Shell.textures, { tex = tex, radius = radius })
			end
			wall.Parent = rig
		end
	end
	rig.Parent = parent
	Shell.rig = rig
end

function Shell.update(cam: Camera)
	if not Shell.rig then return end
	Shell.rig:PivotTo(CFrame.new(cam.CFrame.Position))  -- follow position only; streaks stay world-vertical
	-- WeatherSignals.time is the ABSOLUTE server clock (~1.75e9). The old code set
	-- OffsetStudsV = -t * fall directly, producing ~1e11 — far past float32 precision, so the
	-- UV snapped to garbage and the texture drew NOTHING (this is the real reason the shell was
	-- blank, regardless of which texture was on it). The image tiles seamlessly, so wrapping the
	-- offset into one tile (% StudsPerTile) is visually identical but stays small + precise, and
	-- it still animates because t advances every frame. (FTC-209)
	local t, inner = WeatherSignals.time, CONFIG.shell.radii[1]
	local windScroll = WeatherSignals.Config.windBaseSpeed * CONFIG.shell.windFactor
	for _, e in Shell.textures do
		local rScale = inner / e.radius                  -- outer ring: fainter + parallax
		local fall = CONFIG.shell.fallSpeed * (e.radius / inner)
		e.tex.OffsetStudsV = -(t * fall) % CONFIG.shell.height -- wrap into [0, tileV)
		e.tex.OffsetStudsU = -(t * windScroll) % e.radius      -- wrap into [0, tileU)
		e.tex.Transparency = 1 - WeatherSignals.effRain * rScale
	end
end

--==================================================================================--
--  PUDDLES  ·  pooled wet patches around the camera (world layer, driven by wetness)
--==================================================================================--
local Puddles = { pool = {} }

function Puddles.build(parent: Instance)
	for i = 1, CONFIG.puddles.count do
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.Material = Enum.Material.Glass
		p.Reflectance = CONFIG.puddles.reflectance
		p.Color = CONFIG.puddles.color
		p.Transparency = 1
		p.Size = Vector3.new(CONFIG.puddles.thickness, CONFIG.puddles.minSize, CONFIG.puddles.minSize)
		p.Parent = parent
		Puddles.pool[i] = { part = p, active = false, alpha = 1 }
	end
end

function Puddles.update(dt: number, cam: Camera, rp: RaycastParams)
	local origin = cam.CFrame.Position
	local wet = WeatherSignals.wetness
	local cfg = CONFIG.puddles

	-- (re)place a throttled number of puddles onto flat ground near the camera
	local budget = cfg.recyclesPerFrame
	for _, e in Puddles.pool do
		if budget <= 0 then break end
		local stale = (not e.active) or ((e.part.Position - origin).Magnitude > cfg.recycleRadius)
		if stale and wet > 0.02 then
			budget -= 1
			local a = math.random() * 2 * math.pi
			local d = math.sqrt(math.random()) * cfg.scanRadius   -- sqrt → even area distribution
			local probe = origin + Vector3.new(math.cos(a) * d, cfg.raycastHeight, math.sin(a) * d)
			local hit = Workspace:Raycast(probe, Vector3.new(0, -cfg.raycastHeight * 2, 0), rp)
			if hit and hit.Normal.Y > cfg.flatNormalY and hit.Material ~= Enum.Material.Water then
				local size = cfg.minSize + math.random() * (cfg.maxSize - cfg.minSize)
				e.part.Size = Vector3.new(cfg.thickness, size, size)
				e.part.CFrame = CFrame.new(hit.Position + Vector3.new(0, cfg.thickness * 0.5, 0))
					* CFrame.Angles(0, 0, math.rad(90))   -- lay the cylinder flat, disc facing up
				e.active = true
			end
		end
	end

	-- fade every puddle toward its target opacity (driven by wetness)
	for _, e in Puddles.pool do
		local visible = e.active and wet > 0.02
		local target = visible and (1 - wet * (1 - cfg.minTransparency)) or 1
		e.alpha = approach(e.alpha, target, cfg.fade, dt)
		e.part.Transparency = e.alpha
		if e.alpha > 0.98 and not visible then e.active = false end
	end
end

--==================================================================================--
--  IMPACTS  ·  brief splash rings where drops land (pooled, near camera)
--==================================================================================--
local Impacts = { pool = {}, accum = 0 }

function Impacts.build(parent: Instance)
	for i = 1, CONFIG.impacts.pool do
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.Material = Enum.Material.Neon
		p.Color = CONFIG.impacts.color
		p.Transparency = 1
		p.Size = Vector3.new(0.05, CONFIG.impacts.startSize, CONFIG.impacts.startSize)
		p.Parent = parent
		Impacts.pool[i] = { part = p, t = math.huge }
	end
end

local function spawnImpact(cam: Camera, rp: RaycastParams)
	local origin = cam.CFrame.Position
	local a, d = math.random() * 2 * math.pi, math.sqrt(math.random()) * CONFIG.puddles.scanRadius
	local probe = origin + Vector3.new(math.cos(a) * d, CONFIG.puddles.raycastHeight, math.sin(a) * d)
	local hit = Workspace:Raycast(probe, Vector3.new(0, -CONFIG.puddles.raycastHeight * 2, 0), rp)
	if not hit then return end
	for _, e in Impacts.pool do
		if e.t == math.huge then
			e.t = 0
			e.part.Color = (hit.Material == Enum.Material.Water) and CONFIG.impacts.waterColor or CONFIG.impacts.color
			e.part.CFrame = CFrame.new(hit.Position + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
			return
		end
	end
end

function Impacts.update(dt: number, cam: Camera, rp: RaycastParams)
	-- spawn rate scales with how hard it's actually raining where you stand
	if WeatherSignals.effRain > 0.05 then
		Impacts.accum += dt * CONFIG.impacts.perSecond * WeatherSignals.effRain
		while Impacts.accum >= 1 do
			Impacts.accum -= 1
			spawnImpact(cam, rp)
		end
	end
	-- animate live rings: expand + fade, then release
	for _, e in Impacts.pool do
		if e.t ~= math.huge then
			e.t += dt
			local k = e.t / CONFIG.impacts.life
			if k >= 1 then
				e.t = math.huge
				e.part.Transparency = 1
			else
				local s = lerp(CONFIG.impacts.startSize, CONFIG.impacts.endSize, k)
				e.part.Size = Vector3.new(0.05, s, s)
				e.part.Transparency = k
			end
		end
	end
end

--==================================================================================--
--  LENS  ·  lighting / atmosphere grade (captured at Start, restored at Stop)
--==================================================================================--
local Lens = { atmo = nil :: Atmosphere?, cc = nil :: ColorCorrectionEffect?, saved = {}, owned = {} }

local function ensure(class: string): Instance
	local inst = Lighting:FindFirstChildOfClass(class)
	if not inst then
		inst = Instance.new(class)
		inst.Parent = Lighting
		table.insert(Lens.owned, inst)  -- remember we created it so Stop can clean up
	end
	return inst
end

function Lens.capture()
	Lens.atmo = ensure("Atmosphere") :: Atmosphere
	Lens.cc = ensure("ColorCorrectionEffect") :: ColorCorrectionEffect
	Lens.saved = {
		Brightness = Lighting.Brightness,
		Exposure = Lighting.ExposureCompensation,
		OutdoorAmbient = Lighting.OutdoorAmbient,
	}
end

function Lens.apply()
	local k = WeatherSignals.rain
	local c, s = CONFIG.lighting.clear, CONFIG.lighting.storm
	Lighting.Brightness = lerp(c.Brightness, s.Brightness, k)
	Lighting.ExposureCompensation = lerp(c.Exposure, s.Exposure, k)
	Lighting.OutdoorAmbient = c.OutdoorAmbient:Lerp(s.OutdoorAmbient, k)
	if Lens.atmo then
		Lens.atmo.Density = lerp(c.AtmoDensity, s.AtmoDensity, k)
		Lens.atmo.Haze = lerp(c.AtmoHaze, s.AtmoHaze, k)
		Lens.atmo.Color = c.AtmoColor:Lerp(s.AtmoColor, k)
	end
	if Lens.cc then
		Lens.cc.Saturation = lerp(c.CCSaturation, s.CCSaturation, k)
		Lens.cc.TintColor = c.CCTint:Lerp(s.CCTint, k)
		Lens.cc.Brightness = lerp(c.CCBrightness, s.CCBrightness, k)
	end
end

function Lens.restore()
	if Lens.saved.Brightness then
		Lighting.Brightness = Lens.saved.Brightness
		Lighting.ExposureCompensation = Lens.saved.Exposure
		Lighting.OutdoorAmbient = Lens.saved.OutdoorAmbient
	end
	for _, inst in Lens.owned do inst:Destroy() end
	Lens.owned = {}
end

--==================================================================================--
--  ORCHESTRATION
--==================================================================================--
function RainSystem.Start()
	if RainSystem._running then return end
	RainSystem._running = true

	-- start the shared brain FIRST so its RenderStepped fires before our render loop
	-- (connection order = fire order) → signals are fresh when we read them this frame.
	WeatherSignals.Start()

	local root = Instance.new("Folder")
	root.Name = "WeatherFX"
	root.Parent = Workspace
	RainSystem._root = root

	if CONFIG.shell.enabled   then Shell.build(root) end
	if CONFIG.puddles.enabled then Puddles.build(root) end
	if CONFIG.impacts.enabled then Impacts.build(root) end
	if CONFIG.lighting.enabled then Lens.capture() end

	-- exclude our own FX from the SHARED world-ray filter so rays hit terrain, not rain walls
	WeatherSignals.registerIgnore(root)

	RainSystem._conn = RunService.RenderStepped:Connect(function(dt)
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local rp = WeatherSignals.rayParams
		if CONFIG.shell.enabled    then Shell.update(cam) end
		if CONFIG.puddles.enabled  then Puddles.update(dt, cam, rp) end
		if CONFIG.impacts.enabled  then Impacts.update(dt, cam, rp) end
		if CONFIG.lighting.enabled then Lens.apply() end
	end)
end

function RainSystem.Stop()
	if not RainSystem._running then return end
	RainSystem._running = false
	if RainSystem._conn then RainSystem._conn:Disconnect() end
	if RainSystem._root then RainSystem._root:Destroy() end
	Lens.restore()
	Shell.textures = {}
	Puddles.pool = {}
	Impacts.pool = {}
end

-- convenience for testing from the client (production: set this attribute on the SERVER).
-- delegates to the shared override channel that WeatherSignals reads.
function RainSystem.SetOverride(value: number?)
	Workspace:SetAttribute(WeatherSignals.Config.overrideAttr, value or -1)
end

return RainSystem
