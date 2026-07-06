--!nonstrict
--==================================================================================--
--  CloudSystem  ·  multi-layer PARALLAX clouds + one projected ground shadow
--==================================================================================--
--  Several independent cloud layers at different heights and speeds (HIGH = slow + faint +
--  big lumps, LOW = fast + dense). The different scroll speeds are what make the sky read as
--  *flowing* depth instead of one flat sheet sliding by. Each layer is greedy-meshed parts,
--  built once and revealed by `cover`.
--
--  Reads the shared WeatherSignals brain: `cover` reveals clouds, `rain` tints them storm-grey,
--  `sunDir` projects the shadow. Drift DIRECTION is CONFIG.direction (independent + tunable).
--
--  TUNABLES you'll actually touch:
--    • CONFIG.direction            — which way the whole sky drifts (XZ)
--    • CONFIG.layers[i].altitude   — height of each layer
--    • CONFIG.layers[i].speed      — drift speed (make them DIFFERENT for parallax)
--    • CONFIG.shadow.intensity     — how dark the ground shadow gets (0..1)
--==================================================================================--

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local AssetService = game:GetService("AssetService")

local WeatherSignals = require(script.Parent:WaitForChild("WeatherSignals"))

local CloudSystem = {}

--==================================================================================--
--  CONFIG
--==================================================================================--
local CONFIG = {
	direction = Vector2.new(1, 0.25), -- drift direction in XZ (normalized at runtime)
	follow = true, -- keep layers centred over the camera so the sky is always covered

	noiseScale = 2.4, -- cylinder radius → how many lumps wrap the seamless drift axis
	noiseScaleZ = 0.12, -- lump size across the free axis
	fadeBand = 0.12, -- softness of the cover fade-in
	edgeFade = 0.22, -- outer fraction of each slab that fades to nothing (hides the "box" edge)

	colorClear = Color3.fromRGB(245, 248, 255),
	colorStorm = Color3.fromRGB(120, 128, 140),

	-- HIGH = slow + faint + big lumps · LOW = fast + dense. DIFFERENT speeds == parallax.
	layers = {
		{ altitude = 1500, speed = 6, grid = 52, cell = 46, thickness = 70, minDensity = 0.56, opacity = 0.55, seed = 11 },
		{ altitude = 1080, speed = 14, grid = 64, cell = 32, thickness = 55, minDensity = 0.50, opacity = 0.85, seed = 99 },
		{ altitude = 760, speed = 26, grid = 72, cell = 24, thickness = 46, minDensity = 0.46, opacity = 1.00, seed = 47 },
	},

	shadow = {
		enabled = true,
		sourceLayer = 3, -- which layer casts the ground shadow (the low, dense one)
		intensity = 0.55, -- 0..1 overall darkness of the cast shadow
		lift = 2, -- studs above the local ground
		maxAlpha = 150, -- baked darkness at the densest cells (0..255)
		color = Color3.fromRGB(18, 22, 30),
		groundRayHeight = 1500, -- down-ray to find ground height under the camera
		maxTilt = 3.0, -- clamp the sun projection to maxTilt × height (low-sun blow-up guard)
	},
}
CloudSystem.Config = CONFIG

--==================================================================================--
--  FIELD  ·  one noise function, parameterised per layer (seed) so layers differ
--==================================================================================--
-- Tiles seamlessly along ix (cylinder mapping) so the drift wraps without a seam; free along
-- iz. The cylinder RADIUS (noiseScale) gives real variation around the loop (too small → the
-- clouds collapse into full-width strips). One extra octave puffs the edges.
local function density(ix: number, iz: number, grid: number, seed: number): number
	local a = (ix / grid) * 2 * math.pi
	local R = CONFIG.noiseScale
	local nx, nz = math.cos(a) * R + seed, math.sin(a) * R
	local zc = iz * CONFIG.noiseScaleZ
	local n = math.noise(nx, nz, zc)
	n += 0.5 * math.noise(nx * 2.1, nz * 2.1, zc * 2.1 + 4.7)
	return n / 1.5 + 0.5 -- ~0..1, centred ~0.5
end

local function headingAngle(): number
	local dir = CONFIG.direction.Unit
	return math.atan2(-dir.Y, dir.X)
end

--==================================================================================--
--  LAYER BUILD  ·  greedy-meshed parts for one altitude
--==================================================================================--
local function buildLayer(cfg, parent: Instance)
	local G = cfg.grid
	local span = G * cfg.cell
	local half = span / 2

	local model = Instance.new("Model")
	model.Name = "CloudLayer_" .. tostring(math.floor(cfg.altitude))

	-- precompute the density field for cheap greedy scanning
	local dens = table.create(G)
	for iz = 1, G do
		local row = table.create(G)
		for ix = 1, G do
			row[ix] = density(ix, iz, G, cfg.seed)
		end
		dens[iz] = row
	end

	local used = {}
	local function solid(ix, iz)
		return dens[iz][ix] > cfg.minDensity
	end
	local function taken(ix, iz)
		return used[(iz - 1) * G + ix] == true
	end

	local parts = {}
	for iz = 1, G do
		for ix = 1, G do
			if solid(ix, iz) and not taken(ix, iz) then
				-- REAL 2D greedy meshing: widest run along ix, then grow down iz while full
				local w = 1
				while ix + w <= G and solid(ix + w, iz) and not taken(ix + w, iz) do
					w += 1
				end
				local h = 1
				while iz + h <= G do
					local ok = true
					for k = 0, w - 1 do
						if not solid(ix + k, iz + h) or taken(ix + k, iz + h) then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					h += 1
				end

				local dmax = 0
				for zz = iz, iz + h - 1 do
					for xx = ix, ix + w - 1 do
						used[(zz - 1) * G + xx] = true
						dmax = math.max(dmax, dens[zz][xx])
					end
				end

				local lx = (ix - 1 + w / 2) * cfg.cell - half
				local lz = (iz - 1 + h / 2) * cfg.cell - half
				-- radial edge fade (1 in the middle → 0 at the slab rim) hides the hard box edge
				local edge = math.max(math.abs(lx), math.abs(lz)) / half
				local edgeFactor = math.clamp((1 - edge) / CONFIG.edgeFade, 0, 1)

				local p = Instance.new("Part")
				p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
				p.CastShadow = false
				p.Material = Enum.Material.SmoothPlastic
				p.Transparency = 1
				p.Size = Vector3.new(w * cfg.cell, cfg.thickness, h * cfg.cell)
				p.Position = Vector3.new(lx, cfg.altitude, lz)
				p.Parent = model
				table.insert(parts, { p = p, d = dmax, edge = edgeFactor })
			end
		end
	end

	model.Parent = parent
	return { model = model, parts = parts, span = span, cfg = cfg }
end

local function moveLayer(layer, cx: number, cz: number, heading: number, t: number)
	-- drift along local +X, wrap by this layer's span (seamless: the field tiles in X). Per-layer
	-- `speed` makes each layer slide at its own pace → parallax. CONSTANT rate × server time so
	-- it's identical on every client and never jitters. (FTC-209)
	local scroll = (layer.cfg.speed * t) % layer.span
	local pivot = CFrame.new(cx, layer.cfg.altitude, cz) * CFrame.Angles(0, heading, 0)
	layer.model:PivotTo(pivot * CFrame.new(scroll, 0, 0))
end

local function revealLayer(layer, cover: number, tint: Color3)
	local threshold = 1 - cover
	for _, e in layer.parts do
		local a = math.clamp((e.d - threshold) / CONFIG.fadeBand, 0, 1) * e.edge * layer.cfg.opacity
		e.p.Transparency = 1 - a
		e.p.Color = tint
	end
end

--==================================================================================--
--  SHADOW  ·  one ground plane, the source layer's field baked in, projected by the sun
--==================================================================================--
local Shadow = { plane = nil, tex = nil, span = 0, altitude = 0, speed = 0, headDir = Vector2.new(1, 0) }

local function bakeShadowImage(cfg)
	local ok, img = pcall(function()
		local G = cfg.grid
		local e = AssetService:CreateEditableImage({ Size = Vector2.new(G, G) })
		local buf = buffer.create(G * G * 4)
		local c = CONFIG.shadow.color
		local r8, g8, b8 = math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255)
		for iz = 1, G do
			for ix = 1, G do
				local i = ((iz - 1) * G + (ix - 1)) * 4
				local d = density(ix, iz, G, cfg.seed)
				local k = math.clamp((d - cfg.minDensity) / (1 - cfg.minDensity), 0, 1)
				buffer.writeu8(buf, i + 0, r8)
				buffer.writeu8(buf, i + 1, g8)
				buffer.writeu8(buf, i + 2, b8)
				buffer.writeu8(buf, i + 3, math.floor(k * CONFIG.shadow.maxAlpha))
			end
		end
		e:WritePixelsBuffer(Vector2.zero, Vector2.new(G, G), buf)
		return e
	end)
	return ok and img or nil
end

function Shadow.build(parent: Instance)
	local cfg = CONFIG.layers[CONFIG.shadow.sourceLayer]
	Shadow.span = cfg.grid * cfg.cell
	Shadow.altitude = cfg.altitude
	Shadow.speed = cfg.speed
	local dir = CONFIG.direction.Unit
	Shadow.headDir = dir

	local plane = Instance.new("Part")
	plane.Anchored, plane.CanCollide, plane.CanQuery, plane.CanTouch = true, false, false, false
	plane.Transparency = 1
	plane.Size = Vector3.new(Shadow.span, 0.05, Shadow.span)
	plane.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.atan2(-dir.Y, dir.X), 0)

	local tex = Instance.new("Texture")
	tex.Face = Enum.NormalId.Top
	tex.StudsPerTileU = Shadow.span -- 1 texture tile == 1 cloud slab → 1:1 alignment
	tex.StudsPerTileV = Shadow.span
	local img = bakeShadowImage(cfg)
	if img then
		local ok, err = pcall(function()
			tex.TextureContent = (Content :: any).fromObject(img)
		end)
		if not ok then
			warn("[CloudSystem] shadow EditableImage→Texture bind failed: " .. tostring(err))
		end
	end
	tex.Parent = plane

	plane.Parent = parent
	Shadow.plane, Shadow.tex = plane, tex
end

function Shadow.update(S)
	if not Shadow.plane or not Shadow.tex then
		return
	end
	local sun = S.sunDir

	-- fade out smoothly as the sun nears the horizon (no harsh on/off)
	local sunFade = math.clamp((sun.Y - 0.05) / 0.25, 0, 1)
	if sunFade <= 0 then
		Shadow.tex.Transparency = 1
		return
	end

	local cam = Workspace.CurrentCamera
	local groundY, px, pz = 0, 0, 0
	if cam then
		local camPos = cam.CFrame.Position
		px, pz = camPos.X, camPos.Z
		local hit = Workspace:Raycast(
			camPos + Vector3.new(0, CONFIG.shadow.groundRayHeight, 0),
			Vector3.new(0, -CONFIG.shadow.groundRayHeight * 2, 0),
			S.rayParams
		)
		if hit then
			groundY = hit.Position.Y
		end
	end
	Shadow.plane.Position = Vector3.new(px, groundY + CONFIG.shadow.lift, pz)

	-- sun projection of the cloud layer onto the ground. CLAMP it: H * (sun.X / sun.Y) blows up
	-- toward 100000+ studs as the sun nears the horizon (sun.Y → 0), which is what threw the
	-- shadow miles away. Cap the tilt to maxTilt × height; the offset is also wrapped per tile.
	local H = Shadow.altitude - groundY
	local maxOff = H * CONFIG.shadow.maxTilt
	local tx = math.clamp(-H * (sun.X / sun.Y), -maxOff, maxOff)
	local tz = math.clamp(-H * (sun.Z / sun.Y), -maxOff, maxOff)

	local dx, dz = Shadow.headDir.X, Shadow.headDir.Y
	local scroll = (Shadow.speed * S.time) % Shadow.span
	local projU = tx * dx + tz * dz
	local projV = -tx * dz + tz * dx
	Shadow.tex.OffsetStudsU = -(scroll + projU) % Shadow.span
	Shadow.tex.OffsetStudsV = -(projV) % Shadow.span
	Shadow.tex.Transparency = 1 - (S.cover * CONFIG.shadow.intensity * sunFade)
end

--==================================================================================--
--  ORCHESTRATION
--==================================================================================--
function CloudSystem.Start()
	if CloudSystem._running then
		return
	end
	CloudSystem._running = true

	WeatherSignals.Start()

	local root = Instance.new("Folder")
	root.Name = "CloudFX"
	root.Parent = Workspace
	CloudSystem._root = root
	WeatherSignals.registerIgnore(root)

	CloudSystem._layers = {}
	for _, lcfg in CONFIG.layers do
		table.insert(CloudSystem._layers, buildLayer(lcfg, root))
	end
	if CONFIG.shadow.enabled then
		Shadow.build(root)
	end

	local lastCover, lastRain = -1, -1
	CloudSystem._conn = RunService.RenderStepped:Connect(function()
		local S = WeatherSignals
		local heading = headingAngle()

		local cx, cz = 0, 0
		local cam = Workspace.CurrentCamera
		if CONFIG.follow and cam then
			cx, cz = cam.CFrame.Position.X, cam.CFrame.Position.Z
		end

		-- MOVE every frame (cheap: one PivotTo per layer)
		for _, layer in CloudSystem._layers do
			moveLayer(layer, cx, cz, heading, S.time)
		end

		-- REVEAL only when cover/rain actually moved (transparency over hundreds of parts)
		if math.abs(S.cover - lastCover) > 0.004 or math.abs(S.rain - lastRain) > 0.004 then
			lastCover, lastRain = S.cover, S.rain
			local tint = CONFIG.colorClear:Lerp(CONFIG.colorStorm, S.rain)
			for _, layer in CloudSystem._layers do
				revealLayer(layer, S.cover, tint)
			end
		end

		if CONFIG.shadow.enabled then
			Shadow.update(S)
		end
	end)
end

function CloudSystem.Stop()
	if not CloudSystem._running then
		return
	end
	CloudSystem._running = false
	if CloudSystem._conn then
		CloudSystem._conn:Disconnect()
	end
	if CloudSystem._root then
		CloudSystem._root:Destroy()
	end
	CloudSystem._layers = {}
	Shadow.plane, Shadow.tex = nil, nil
end

return CloudSystem
