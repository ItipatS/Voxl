--!strict
-- Private-star size progression: expandTier (0..MAX_TIER) → {footprint, height} in
-- BLOCKS. Small footprint (cozy, distinct islands) + tall height (the private
-- star's verticality signature — up to 4x the wild's 256). Reserve the MAX
-- footprint at plant time (doc 13) so expansion room is always guaranteed. [TUNE]

local TIERS = {
	{ footprint = 48, height = 256 },
	{ footprint = 64, height = 320 },
	{ footprint = 96, height = 448 },
	{ footprint = 128, height = 576 },
	{ footprint = 192, height = 768 },
	{ footprint = 256, height = 1024 },
}

local M = {}

M.MAX_TIER = #TIERS - 1 -- tiers are 0-indexed (0..5)

-- Footprint (x/z) and height for a given expand tier.
function M.dims(expandTier: number): (number, number)
	local t = TIERS[math.clamp(expandTier, 0, M.MAX_TIER) + 1]
	return t.footprint, t.height
end

-- Max footprint (reserved at plant so neighbours can't block future expansion).
function M.maxFootprint(): number
	return TIERS[#TIERS].footprint
end

return M
