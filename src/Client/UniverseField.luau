--!strict
-- Renders the procedural star FRONTIER (std/universe). For each slot near the player it
-- asks the generator whether a star exists this week and, if so, spawns the world as a big
-- glowing orb at its REAL position, tinted by tier (a soft difficulty hint — DESIGN). Each
-- star carries an APPROACH PREVIEW billboard (its procedural name + the 3 resource TYPES;
-- tier/node/quality stay hidden) that auto-shows only when you're near, via MaxDistance —
-- the "should I go?" hook. Cell load/unload around the player like DustField; stars are
-- STATIC (real world positions) so there's no per-frame movement. Claimed stars overlay later.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService")

local std = ReplicatedStorage:WaitForChild("std")
local universe = require(std:WaitForChild("universe"))
local blink = require(std:WaitForChild("ClientNet"))
local transition = require(std:WaitForChild("transition"))
local constellation = require(std:WaitForChild("constellation"))

local player = Players.LocalPlayer

-- One trip in flight at a time. On Enter we optimistically close the cartoon iris + queue the
-- teleport loading GUI; if the server denies (no star / too far / teleport failed — Studio can't
-- cross places) or nothing happens in time, we reverse the iris so the screen never stays black.
local traveling = false
local TRAVEL_TIMEOUT = 12 -- s backstop if no teleport and no explicit denial arrives

local function beginTravel(star: universe.Star)
	if traveling then
		return
	end
	traveling = true
	local info = {
		name = star.name,
		types = star.types,
		subtitle = "Traveling…",
		primary = star.types[1],
	}
	pcall(function()
		TeleportService:SetTeleportGui(transition.buildTeleportGui(info))
	end)
	transition.close(info)
	blink.EnterStar.Fire({ cx = star.slot[1], cy = star.slot[2], cz = star.slot[3] })
	task.delay(TRAVEL_TIMEOUT, function()
		if traveling then
			traveling = false
			transition.open()
		end
	end)
end

-- Same iris/loading flow as a frontier star, but keyed by hub index rather than slot.
local function beginHubTravel(hub: constellation.Hub)
	if traveling then
		return
	end
	traveling = true
	local types = {}
	for i, b in hub.biomes do
		types[i] = b.type
	end
	local info = { name = hub.name, types = types, subtitle = "Traveling…", primary = types[1] }
	pcall(function()
		TeleportService:SetTeleportGui(transition.buildTeleportGui(info))
	end)
	transition.close(info)
	blink.EnterHub.Fire(hub.index)
	task.delay(TRAVEL_TIMEOUT, function()
		if traveling then
			traveling = false
			transition.open()
		end
	end)
end

blink.EnterDenied.On(function()
	if not traveling then
		return
	end
	traveling = false
	transition.open()
end)

local RENDER_CELLS = 2 -- slots each way (±2 → 5³ = 125 slots, ~44 stars) [TUNE]
local STAR_SIZE = 2047 -- planet diameter = the max part size (a bounded world; interior TBD)
local APPROACH_RADIUS = 4000 -- show a star's name + resource types within this [TUNE]
local ENTER_RADIUS = 1500 -- fly this close → the "Enter" prompt appears (must be ≤ server ENTER_RADIUS) [TUNE]

-- A LANDMARK is meant to be found, so its label carries much further than an
-- ordinary star's — you should be able to see which way to fly from most of the
-- way across the constellation. [TUNE]
local LANDMARK_RADIUS = 90000
-- How often the distance readouts refresh. They're read while flying, so a few
-- times a second is plenty and costs nothing next to a per-frame loop.
local DISTANCE_INTERVAL = 0.2

local SILK = Font.new("rbxassetid://12187371840", Enum.FontWeight.Regular, Enum.FontStyle.Normal)

-- Tier → colour. Calm/cool at T1, hot/strange at T5 → "brighter/stranger = spicier"
-- (DESIGN: proxy glow as a soft, non-spoiling difficulty hint).
local TIER_COLOR = {
	Color3.fromRGB(150, 220, 255), -- T1 calm blue
	Color3.fromRGB(120, 255, 170), -- T2 green
	Color3.fromRGB(255, 225, 120), -- T3 gold
	Color3.fromRGB(255, 140, 90), -- T4 orange
	Color3.fromRGB(255, 90, 210), -- T5 magenta (rare/spicy)
}

-- Planet body template: a MeshPart with a SurfaceAppearance, authored in Studio. MOVE it
-- into ReplicatedStorage.Assets as "Planet" and we clone + tint it (else we fall back to a
-- Neon ball). We COLOUR by primary resource TYPE (biome variety from one mesh) and set GLOW
-- STRENGTH by TIER (the soft "brighter = spicier" difficulty hint) via SurfaceAppearance.
local planetTemplate = ReplicatedStorage:WaitForChild("Essential"):FindFirstChild("Planet")

local TYPE_COLOR: { [string]: Color3 } = {
	Flora = Color3.fromRGB(120, 200, 90), -- green
	Stone = Color3.fromRGB(160, 160, 170), -- grey
	Sand = Color3.fromRGB(220, 190, 120), -- tan
	Frost = Color3.fromRGB(170, 220, 255), -- pale blue
	Bog = Color3.fromRGB(120, 140, 90), -- murky
}

-- Fixed for this session; a week rollover mid-session won't reshuffle live yet.
local WEEK = universe.currentWeek(os.time())

local folder = Instance.new("Folder")
folder.Name = "UniverseField"
folder.Parent = Workspace

local cells: { [string]: { Instance } } = {} -- cellKey -> instances (0 or 1 star per slot)

-- Distance readouts for the stars currently rendered. Entries whose label has been
-- destroyed (its cell unloaded) are dropped on the next pass, so this never needs
-- unhooking from unloadCell.
-- `radius` is subtracted from the reported distance, so the number is range to the
-- thing's SURFACE. A hub proxy has no real surface, so it uses 0 and reports range
-- to the point.
type Tracked = { label: TextLabel, pos: Vector3, radius: number }
local tracked: { Tracked } = {}

local function cellKey(cx: number, cy: number, cz: number): string
	return `{cx},{cy},{cz}`
end

local function label(parent: Instance, yScale: number, height: number, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromScale(0, yScale)
	t.Size = UDim2.new(1, 0, height, 0)
	t.FontFace = SILK
	t.TextScaled = true
	t.TextColor3 = color
	t.TextStrokeTransparency = 0.4
	t.Parent = parent
	return t
end

local function configurePart(part: BasePart)
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Size = Vector3.one * STAR_SIZE
end

-- Build the planet body: the authored mesh (tinted via SurfaceAppearance) if present, else a
-- Neon ball. Returns (root to parent, visible part to position + adorn the billboard to).
local function buildBody(star: universe.Star): (Instance, BasePart)
	local typeColor = TYPE_COLOR[star.types[1]] or Color3.new(1, 1, 1)
	if planetTemplate then
		local model = planetTemplate:Clone()
		local mesh: BasePart? = nil
		if model:IsA("BasePart") then
			mesh = model
		else
			local m = model:FindFirstChildWhichIsA("MeshPart")
			if m and m:IsA("BasePart") then
				mesh = m
			end
		end
		if mesh then
			configurePart(mesh)
			mesh.CFrame = CFrame.new(star.pos)
			local sa = mesh:FindFirstChildWhichIsA("SurfaceAppearance")
			if sa then
				sa.Color = typeColor -- tint the ColorMap → biome variety
				sa.EmissiveTint = typeColor
			end
			return model, mesh
		end
		model:Destroy() -- template has no MeshPart → fall back
	end
	-- fallback: Neon ball tinted by tier
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = TIER_COLOR[star.tier] or TIER_COLOR[1]
	configurePart(p)
	p.Position = star.pos
	return p, p
end

local function makeStar(star: universe.Star): Instance
	local typeColor = TYPE_COLOR[star.types[1]] or Color3.new(1, 1, 1)
	local root, part = buildBody(star)
	root.Name = `Star_{star.slot[1]}_{star.slot[2]}_{star.slot[3]}`

	-- Approach preview: auto-hidden past MaxDistance (no per-frame visibility check).
	local bb = Instance.new("BillboardGui")
	bb.Name = "Approach"
	bb.Adornee = part
	bb.Size = UDim2.fromOffset(300, 120)
	bb.StudsOffsetWorldSpace = Vector3.new(0, STAR_SIZE * 0.65, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = APPROACH_RADIUS
	bb.Parent = part

	local nameLbl = label(bb, 0, 0.45, typeColor)
	nameLbl.Text = star.name
	local typesLbl = label(bb, 0.47, 0.28, Color3.fromRGB(210, 220, 235))
	typesLbl.Text = table.concat(star.types, "  ·  ")

	-- Distance readout. Space has no landmarks to judge range against, so without a
	-- number you cannot tell a star 2,000 studs away from one 40,000 away — they're
	-- the same dot. Updated on an interval below.
	local distLbl = label(bb, 0.74, 0.26, Color3.fromRGB(160, 175, 195))
	distLbl.Text = ""
	tracked[#tracked + 1] = { label = distLbl, pos = star.pos, radius = STAR_SIZE * 0.5 }

	-- Enter prompt (expressive-prompts renders Style=Custom, via Prompts.luau). Appears when
	-- you fly up to the planet; the server (starentry) validates + teleports into this star.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Enter"
	prompt.ObjectText = star.name
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = ENTER_RADIUS
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function()
		beginTravel(star)
	end)

	root.Parent = folder
	return root
end

local function loadCell(cx: number, cy: number, cz: number)
	local key = cellKey(cx, cy, cz)
	if cells[key] then
		return
	end
	local list: { Instance } = {}
	local star = universe.starAt(cx, cy, cz, WEEK)
	if star then
		list[1] = makeStar(star)
	end
	cells[key] = list -- store even when empty, so we don't re-generate the slot every cross
end

local function unloadCell(key: string)
	local list = cells[key]
	if not list then
		return
	end
	for _, inst in list do
		inst:Destroy()
	end
	cells[key] = nil
end

-- Load the ring of slots around the player's slot, unload the rest. Only on cell cross.
local function refreshCells(cx: number, cy: number, cz: number)
	local want: { [string]: boolean } = {}
	for dx = -RENDER_CELLS, RENDER_CELLS do
		for dy = -RENDER_CELLS, RENDER_CELLS do
			for dz = -RENDER_CELLS, RENDER_CELLS do
				local kx, ky, kz = cx + dx, cy + dy, cz + dz
				want[cellKey(kx, ky, kz)] = true
				loadCell(kx, ky, kz)
			end
		end
	end
	-- The hubs need no special case here: they aren't universe slots at all, so
	-- they're built once as signs and never stream in or out.
	for key in cells do
		if not want[key] then
			unloadCell(key)
		end
	end
end

-- ===== hub-town signs =====
-- The 5 starter stars are drawn by SpaceProxies as camera-locked PROXIES: fake
-- objects held a fixed distance in front of you and scaled to fake depth. A label
-- adorned to one would inherit that lie and report a few hundred studs no matter
-- where you were. So these are separate, real markers at the stars' TRUE positions
-- — an invisible anchor each, carrying the same billboard the frontier stars use.

local function makeSigns()
	local signs = Instance.new("Folder")
	signs.Name = "Signs"
	signs.Parent = folder

	-- The maw first, then a sign per hub. Hub signs also carry the Enter prompt: the
	-- proxy the hub is DRAWN as is camera-locked, so a prompt on it would trigger from
	-- anywhere — the real anchor is the only honest place to put it.
	local marks: { { pos: Vector3, name: string, maw: boolean, hub: constellation.Hub? } } = {
		{ pos = constellation.CENTER, name = "THE MAW", maw = true, hub = nil },
	}
	for _, h in constellation.HUBS do
		table.insert(marks, { pos = h.pos, name = h.name, maw = false, hub = h })
	end

	for _, L in marks do
		local isMaw = L.maw
		local anchor = Instance.new("Part")
		anchor.Name = `Sign_{L.name}`
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CastShadow = false
		anchor.Locked = true
		anchor.Transparency = 1
		anchor.Size = Vector3.one
		anchor.Position = L.pos
		anchor.Parent = signs

		local bb = Instance.new("BillboardGui")
		bb.Name = "Sign"
		bb.Adornee = anchor
		bb.Size = UDim2.fromOffset(300, 84)
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = LANDMARK_RADIUS -- these are the things you navigate BY
		bb.Parent = anchor

		local tint = if isMaw then Color3.fromRGB(255, 120, 90) else Color3.fromRGB(255, 225, 150)
		local nameLbl = label(bb, 0, 0.6, tint)
		nameLbl.Text = if isMaw then "☀ THE MAW" else `★ {L.name}`
		local distLbl = label(bb, 0.62, 0.38, Color3.fromRGB(160, 175, 195))
		distLbl.Text = ""
		-- radius 0: for a hub or the maw the useful number is range to the point,
		-- not to a surface (the proxy has no real one)
		tracked[#tracked + 1] = { label = distLbl, pos = L.pos, radius = 0 }

		local hub = L.hub
		if hub then
			local prompt = Instance.new("ProximityPrompt")
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.ActionText = "Enter"
			prompt.ObjectText = hub.name
			prompt.HoldDuration = 0.4
			prompt.MaxActivationDistance = ENTER_RADIUS
			prompt.RequiresLineOfSight = false
			prompt.Parent = anchor
			prompt.Triggered:Connect(function()
				beginHubTravel(hub)
			end)
		end
	end
end

-- "12,480 studs" reads worse than "12.5k" at a glance while flying.
local function studs(d: number): string
	if d >= 10000 then
		return `{string.format("%.1f", d / 1000)}k studs`
	end
	return `{string.format("%d", d)} studs`
end

local function updateDistances(from: Vector3)
	local write = 1
	for i = 1, #tracked do
		local t = tracked[i]
		if t.label.Parent then
			local d = (t.pos - from).Magnitude
			-- Subtract the orb's radius so the number is distance to the SURFACE —
			-- "0" should mean you've arrived, not that you're inside the planet.
			local surface = math.max(0, d - t.radius)
			t.label.Text = if surface < 1 then "arrived" else studs(surface)
			tracked[write] = t
			write += 1
		end
	end
	for i = #tracked, write, -1 do
		tracked[i] = nil -- its cell unloaded
	end
end

makeSigns() -- the hubs and the maw are fixed, so they're built once and never unloaded

local lastCenter: string? = nil
local sinceDistance = 0
RunService.Heartbeat:Connect(function(dt: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local cx, cy, cz = universe.cellOf(root.Position)
	local here = cellKey(cx, cy, cz)
	if here ~= lastCenter then
		lastCenter = here
		refreshCells(cx, cy, cz)
	end

	sinceDistance += dt
	if sinceDistance >= DISTANCE_INTERVAL then
		sinceDistance = 0
		updateDistances(root.Position)
	end
end)

return {}
