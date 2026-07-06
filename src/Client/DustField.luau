--!strict
-- Star dust — a SEED-DERIVED collectable field (replaces the old decorative StarField).
-- Positions come from std/dust (a pure function of a global seed), so we generate the
-- motes around the player locally by CELL — no positions are streamed, only the sparse
-- "cooling" deltas (server owns those; see systems/dustfield). Fly through a mote and we
-- auto-collect it: ask the server, and on confirmation grant STAR FUEL (FlightBoost
-- stamina), play the DustCollect burst in the mote's colour, and dim it until its
-- cooldown expires. Everyone sees the same field + the same dimming.
--
-- Movement is ONE Workspace:BulkMoveTo per frame (never per-part) — see the bulk-move
-- convention in CLAUDE.md.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local blink = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("ClientNet"))
local dust = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("dust"))
local FlightBoost = require(script.Parent:WaitForChild("FlightBoost"))

local player = Players.LocalPlayer
local rng = Random.new()

local RENDER_CELLS = 3 -- cells each way around the player (±3 → 7³ = 343 cells)
local WOBBLE = 1.5 -- studs of cosmetic client-side drift
local BASE_TRANSP = 0.1
local DIM_TRANSP = 0.92
local COLLECT_THROTTLE = 0.1 -- seconds between auto-collect sweeps
local PENDING_TIME = 0.6 -- don't re-ask for the same mote until the server has replied

-- Shape templates (same little meshes the decorative dust used).
local shapes: { BasePart } = {}
do
	local src = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Stars")
	for _, d in src:GetChildren() do
		if d:IsA("BasePart") then
			shapes[#shapes + 1] = d
		end
	end
end
local burstTemplate = ReplicatedStorage.Assets:WaitForChild("Particles"):WaitForChild("DustCollect") :: ParticleEmitter
local BURST_COUNT = burstTemplate:GetAttribute("EmitCount") or 60

local folder = Instance.new("Folder")
folder.Name = "DustField"
folder.Parent = Workspace

type Mote = {
	ref: { cx: number, cy: number, cz: number, idx: number },
	part: BasePart,
	base: Vector3,
	rot: CFrame,
	color: Color3,
	offset: number,
	coolUntil: number, -- os.clock; > now = dimmed
	pending: number, -- os.clock; > now = awaiting server reply, don't re-ask
	dimmed: boolean,
}

local cells: { [string]: { Mote } } = {}
local moteByKey: { [string]: Mote } = {}
local coolByKey: { [string]: number } = {} -- cooldowns held even for not-yet-loaded motes

-- Rebuilt only on cell load/unload; the render loop reuses it + a cframes buffer.
local active: { Mote } = {}
local parts: { BasePart } = {}
local cframes: { CFrame } = {}
local dirty = false

local function cellKey(cx: number, cy: number, cz: number): string
	return `{cx},{cy},{cz}`
end
local function moteKey(cx: number, cy: number, cz: number, idx: number): string
	return `{cx},{cy},{cz},{idx}`
end

local function loadCell(cx: number, cy: number, cz: number)
	local key = cellKey(cx, cy, cz)
	if cells[key] then
		return
	end
	local list: { Mote } = {}
	if #shapes > 0 then
		local now = os.clock()
		for _, m in dust.motesInCell(cx, cy, cz) do
			local part = shapes[((m.shape - 1) % #shapes) + 1]:Clone() :: BasePart
			local mag = part.Size.Magnitude
			if mag > 1e-3 then
				part.Size *= (m.size) / mag
			end
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Locked = true
			part.Material = Enum.Material.Neon
			part.Color = m.color
			local mk = moteKey(cx, cy, cz, m.idx)
			local coolUntil = coolByKey[mk] or 0
			local dimmed = coolUntil > now
			part.Transparency = if dimmed then DIM_TRANSP else BASE_TRANSP
			local rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28))
			part.CFrame = CFrame.new(m.pos) * rot
			part.Parent = folder
			local mote: Mote = {
				ref = { cx = cx, cy = cy, cz = cz, idx = m.idx },
				part = part,
				base = m.pos,
				rot = rot,
				color = m.color,
				offset = rng:NextNumber(0, 100),
				coolUntil = coolUntil,
				pending = 0,
				dimmed = dimmed,
			}
			list[#list + 1] = mote
			moteByKey[mk] = mote
		end
	end
	cells[key] = list
	dirty = true
end

local function unloadCell(key: string)
	local list = cells[key]
	if not list then
		return
	end
	for _, m in list do
		m.part:Destroy()
		moteByKey[moteKey(m.ref.cx, m.ref.cy, m.ref.cz, m.ref.idx)] = nil
	end
	cells[key] = nil
	dirty = true
end

local function rebuild()
	table.clear(active)
	table.clear(parts)
	for _, list in cells do
		for _, m in list do
			active[#active + 1] = m
			parts[#parts + 1] = m.part
		end
	end
	dirty = false
end

-- Load the ring of cells around the player's cell, unload the rest. Only runs when the
-- player crosses into a new cell (cheap trigger).
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

-- ---- collect confirmations + cooldown broadcasts ----------------------------
local function burst(pos: Vector3, color: Color3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.new(pos)
	p.Parent = folder
	local pe = burstTemplate:Clone()
	pe.Color = ColorSequence.new(color)
	pe.Enabled = false
	pe.Parent = p
	pe:Emit(BURST_COUNT)
	Debris:AddItem(p, 2.5)
end

blink.DustCollected.On(function(ref)
	-- our own confirmed collect: fuel + burst + dim
	FlightBoost.addFuel(dust.FUEL_PER_MOTE)
	local mk = moteKey(ref.cx, ref.cy, ref.cz, ref.idx)
	coolByKey[mk] = os.clock() + dust.COOLDOWN
	local m = moteByKey[mk]
	if m then
		m.coolUntil = coolByKey[mk]
		burst(m.base, m.color)
	end
end)

blink.DustCooldown.On(function(list)
	local now = os.clock()
	for _, c in list do
		local r = c.ref
		local mk = moteKey(r.cx, r.cy, r.cz, r.idx)
		local until_ = now + c.remaining / 10
		coolByKey[mk] = until_
		local m = moteByKey[mk]
		if m then
			m.coolUntil = until_
		end
	end
end)

-- ---- per-frame: cells + auto-collect + bulk move + dim ----------------------
local collectAcc = 0
local lastCenter: string? = nil -- which cell we last loaded around

RunService.RenderStepped:Connect(function(dt: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local pp = root.Position

	-- (Re)load the cell ring only when we cross into a new cell.
	local cx, cy, cz = dust.cellOf(pp)
	local here = cellKey(cx, cy, cz)
	if here ~= lastCenter then
		lastCenter = here
		refreshCells(cx, cy, cz)
	end
	if dirty then
		rebuild()
	end

	local now = os.clock()

	-- Auto-collect: fly through an available mote → ask the server (throttled).
	collectAcc += dt
	local doCollect = collectAcc >= COLLECT_THROTTLE
	if doCollect then
		collectAcc = 0
	end
	local cr2 = dust.COLLECT_RADIUS * dust.COLLECT_RADIUS

	for i, m in active do
		-- bulk-move CFrame (cosmetic wobble around the static base position)
		local t = now + m.offset
		local wob = Vector3.new(math.sin(t * 1.5), math.cos(t * 2) * 0.5, math.sin(t * 1.2)) * WOBBLE
		cframes[i] = CFrame.new(m.base + wob) * m.rot

		-- dim state (only touch the property on a transition)
		local cooling = m.coolUntil > now
		if cooling ~= m.dimmed then
			m.dimmed = cooling
			m.part.Transparency = if cooling then DIM_TRANSP else BASE_TRANSP
		end

		-- auto-collect (squared distance — avoid the sqrt over ~1700 motes/frame)
		if doCollect and not cooling and m.pending <= now then
			local d = m.base - pp
			if d:Dot(d) <= cr2 then
				m.pending = now + PENDING_TIME
				blink.DustCollect.Fire(m.ref)
			end
		end
	end

	-- cframes must match parts length (parts is resized by rebuild(); trim any stale
	-- tail from a previously larger frame BEFORE the bulk move).
	for j = #cframes, #active + 1, -1 do
		cframes[j] = nil
	end
	if #active > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end)

-- prune stale cooldowns so the map doesn't grow across a long session
task.spawn(function()
	while true do
		task.wait(15)
		local now = os.clock()
		for k, until_ in coolByKey do
			if until_ <= now and not moteByKey[k] then
				coolByKey[k] = nil
			end
		end
	end
end)

return {}
