--!strict
-- Renders the procedural star FRONTIER (std/universe). For each slot near the player it
-- asks the generator whether a star exists this week and, if so, shows it as a glowing orb
-- at its REAL position, tinted by tier (a soft difficulty hint — DESIGN star-approach UX).
-- Cell load/unload around the player like DustField, but the stars are STATIC (real world
-- positions), so there's no per-frame movement — we only rebuild when you cross into a new
-- cell. Claimed stars (star_<coord> records) will overlay this later; for now it's the raw
-- unclaimed field so you can fly out and actually SEE the universe.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local universe = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("universe"))

local player = Players.LocalPlayer

local RENDER_CELLS = 3 -- slots each way around the player (±3 → 7³ = 343 slots, ~120 stars). [TUNE]
local STAR_SIZE = 500 -- visual orb diameter (worlds are small; [TUNE])

-- Tier → colour + glow. Calm/cool at T1, hot/strange at T5 → "brighter/stranger = spicier"
-- (DESIGN: proxy glow as a soft, non-spoiling difficulty hint).
local TIER_COLOR = {
	Color3.fromRGB(150, 220, 255), -- T1 calm blue
	Color3.fromRGB(120, 255, 170), -- T2 green
	Color3.fromRGB(255, 225, 120), -- T3 gold
	Color3.fromRGB(255, 140, 90), -- T4 orange
	Color3.fromRGB(255, 90, 210), -- T5 magenta (rare/spicy)
}

-- The week is fixed for this session; a week rollover mid-session won't reshuffle live yet.
local WEEK = universe.currentWeek(os.time())

local folder = Instance.new("Folder")
folder.Name = "UniverseField"
folder.Parent = Workspace

local cells: { [string]: { Instance } } = {} -- cellKey -> instances (0 or 1 star per slot)

local function cellKey(cx: number, cy: number, cz: number): string
	return `{cx},{cy},{cz}`
end

local function makeStar(star: universe.Star): Instance
	local color = TIER_COLOR[star.tier] or TIER_COLOR[1]
	local p = Instance.new("Part")
	p.Name = `Star_{star.slot[1]}_{star.slot[2]}_{star.slot[3]}`
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.one * STAR_SIZE
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Position = star.pos
	-- Neon self-emits (no PointLight — 100+ lights would blow the light budget + lag).
	-- Tier reads from the colour; higher tiers get a touch bigger for a stronger glow.
	p.Size = Vector3.one * (STAR_SIZE * (1 + (star.tier - 1) * 0.12))

	p.Parent = folder
	return p
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
