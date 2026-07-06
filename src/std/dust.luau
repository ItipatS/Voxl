--!strict
-- Star-dust field — the SHARED definition of where every dust mote is. Positions are
-- a pure function of a global seed (like terrain from a chunk seed), so server + client
-- generate the identical field with ZERO position bytes on the wire. The server stores
-- only a cooldown ledger of collected motes (see systems/dustfield); it recomputes any
-- single mote's position on demand to validate a collect. A mote is addressed by its
-- CELL (cx,cy,cz) + local INDEX. Determinism relies on Random.new(seed) being stable.

local M = {}

local constellation =
	require(game:GetService("ReplicatedStorage"):WaitForChild("std"):WaitForChild("constellation")) -- maw VOID_RADIUS (shared)

M.DUST_SEED = 20260706 -- global; everyone generates the same field. (bump = reshuffle)
M.CELL_SIZE = 400 -- stud cube per cell
M.MOTES_PER_CELL = 5
M.FIELD_RADIUS = 22000 -- dust exists within this of CENTER (matches the star/asteroid field)
M.COLLECT_RADIUS = 22 -- auto-collect when a flier is within this of a mote's base position
M.COOLDOWN = 25 -- seconds a collected mote stays dim before it refills
M.FUEL_PER_MOTE = 14 -- star fuel (boost stamina, max 100) granted per mote [TUNE]

M.SIZE_MIN, M.SIZE_MAX = 4, 14

local CENTER = Vector3.new(0, 500, 0)
M.CENTER = CENTER

-- Firefly palette (same vibe as the old decorative StarField).
local PALETTE = {
	Color3.fromRGB(43, 253, 88), Color3.fromRGB(182, 252, 77), Color3.fromRGB(38, 255, 164),
	Color3.fromRGB(253, 102, 43), Color3.fromRGB(252, 220, 77), Color3.fromRGB(255, 152, 84),
	Color3.fromRGB(255, 90, 99), Color3.fromRGB(160, 200, 255), Color3.fromRGB(120, 180, 255),
	Color3.fromRGB(217, 64, 255), Color3.fromRGB(255, 31, 199), Color3.fromRGB(255, 255, 255),
}
M.PALETTE = PALETTE

export type Mote = { idx: number, pos: Vector3, color: Color3, size: number, shape: number }

function M.cellOf(pos: Vector3): (number, number, number)
	local s = M.CELL_SIZE
	return math.floor(pos.X / s), math.floor(pos.Y / s), math.floor(pos.Z / s)
end

-- Distinct, collision-free integer seed per cell (cells are well within ±2048, so this
-- stays exact in f64). DUST_SEED just offsets the whole field.
local function cellSeed(cx: number, cy: number, cz: number): number
	return M.DUST_SEED + (cx + 2048) + (cy + 2048) * 4096 + (cz + 2048) * 16777216
end

-- All motes in a cell (deterministic). Motes outside the field sphere are dropped, but
-- the RNG is still advanced for them so every mote's `idx` maps to the same draws on
-- both server + client (index alignment is what makes MoteRef work).
function M.motesInCell(cx: number, cy: number, cz: number): { Mote }
	local rng = Random.new(cellSeed(cx, cy, cz))
	local s = M.CELL_SIZE
	local ox, oy, oz = cx * s, cy * s, cz * s
	local out: { Mote } = {}
	for i = 1, M.MOTES_PER_CELL do
		local pos = Vector3.new(ox + rng:NextNumber(0, s), oy + rng:NextNumber(0, s), oz + rng:NextNumber(0, s))
		local color = PALETTE[rng:NextInteger(1, #PALETTE)]
		local size = rng:NextNumber(M.SIZE_MIN, M.SIZE_MAX)
		local shape = rng:NextInteger(1, 64) -- client maps into its own shape-template count
		-- keep motes inside the field but OUT of the maw void zone (dust vanishes near the
		-- black hole as a danger cue). RNG was already advanced above, so idx stays aligned.
		local d = (pos - CENTER).Magnitude
		if d <= M.FIELD_RADIUS and d >= constellation.VOID_RADIUS then
			out[#out + 1] = { idx = i, pos = pos, color = color, size = size, shape = shape }
		end
	end
	return out
end

-- One mote by ref (server uses this to validate a collect). Regenerates the cell — cheap
-- (MOTES_PER_CELL is tiny). Returns nil if that index was culled / doesn't exist.
function M.moteAt(cx: number, cy: number, cz: number, idx: number): Mote?
	for _, m in M.motesInCell(cx, cy, cz) do
		if m.idx == idx then
			return m
		end
	end
	return nil
end

return M
