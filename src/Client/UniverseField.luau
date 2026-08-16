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

	-- Approach preview: auto-hidden past APPROACH_RADIUS via MaxDistance (no per-frame loop).
	local bb = Instance.new("BillboardGui")
	bb.Name = "Approach"
	bb.Adornee = part
	bb.Size = UDim2.fromOffset(300, 90)
	bb.StudsOffsetWorldSpace = Vector3.new(0, STAR_SIZE * 0.65, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = APPROACH_RADIUS
	bb.Parent = part

	local nameLbl = label(bb, 0, 0.6, typeColor)
	nameLbl.Text = star.name
	local typesLbl = label(bb, 0.62, 0.38, Color3.fromRGB(210, 220, 235))
	typesLbl.Text = table.concat(star.types, "  ·  ")

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
	for key in cells do
		if not want[key] then
			unloadCell(key)
		end
	end
end

local lastCenter: string? = nil
RunService.Heartbeat:Connect(function()
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
end)

return {}
