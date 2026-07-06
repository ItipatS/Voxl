--!strict
-- Planting grid. The resident zone (the constellation, minus each starter star's
-- no-plant commons and the black-hole hazard) is a lattice of cells; each cell
-- holds at most one planet. A cell is sized to the BIGGEST planet (max expandTier
-- footprint) + a buffer, so planets never overlap even fully grown (level 5 grows
-- them inside AND out) and the spacing keeps the field sparse. Occupancy is just
-- "is this cell key taken" — no geometry checks.
--
-- Planar for now (one layer at CENTER.y — reads as a galaxy disk); can become a
-- thin slab / full 3D by giving cellCenter a Y index.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))
local starsize = require(ReplicatedStorage.std:WaitForChild("starsize"))
local WorldGen = require(ReplicatedStorage:WaitForChild("Misc"):WaitForChild("WorldGen"))

local M = {}

local BUFFER = 500 -- studs of empty space between max-size planets (density knob)
local ZONE_RADIUS = 24000 -- resident zone outer radius (planets live in the annulus; ~ring radius)

local CENTER = constellation.CENTER
-- Cell = biggest planet's footprint (blocks → studs) + buffer.
M.CELL = starsize.maxFootprint() * WorldGen.BLOCK_SIZE + BUFFER

-- Snap a world position to its grid-cell centre (planar: Y locked to CENTER.y).
function M.cellCenter(pos: Vector3): Vector3
	local rel = pos - CENTER
	local cx = math.round(rel.X / M.CELL)
	local cz = math.round(rel.Z / M.CELL)
	return CENTER + Vector3.new(cx * M.CELL, 0, cz * M.CELL)
end

-- Stable key for a cell centre (for occupancy lookups + the manifest).
function M.cellKey(center: Vector3): string
	local rel = center - CENTER
	return `{math.round(rel.X / M.CELL)},{math.round(rel.Z / M.CELL)}`
end

-- Integer grid indices for a world position (what the client sends the server to
-- name a cell without trusting a float position).
function M.cellIndex(pos: Vector3): (number, number)
	local rel = pos - CENTER
	return math.round(rel.X / M.CELL), math.round(rel.Z / M.CELL)
end

-- Rebuild a cell centre from indices (server reconstructs + re-validates the spot
-- the client picked; never trust a client-sent position).
function M.centerFromIndex(cx: number, cz: number): Vector3
	return CENTER + Vector3.new(cx * M.CELL, 0, cz * M.CELL)
end

-- Is this cell centre a legal plant spot? Inside the zone, and clear (by half a
-- cell so the planet never pokes in) of the black hole + every starter star.
function M.isPlantable(center: Vector3): boolean
	local margin = M.CELL * 0.5
	if (center - CENTER).Magnitude > ZONE_RADIUS then
		return false
	end
	local bh = constellation.BLACKHOLE
	if (center - bh.pos).Magnitude < bh.radius + margin then
		return false
	end
	for _, sp in constellation.STARTER_STARS do
		if (center - sp).Magnitude < constellation.NO_PLANT_RADIUS + margin then
			return false
		end
	end
	return true
end

return M
