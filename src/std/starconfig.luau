--!strict
-- Which star the Star (ResourceStar) place should generate. The place hosts ONE star at a
-- time (single-live, keyed by starId — the server routing is MemoryStore, doc 06/15). The
-- server publishes the visited star's config via ReplicatedStorage attributes; both server
-- and client call `WorldGen.applyStarByTypes(get())` so the client-generated terrain matches.
--
-- For now `get()` falls back to a fixed TEST star so the place is playable without the full
-- teleport flow. Later: the server reads TeleportData (starId + originSeed + rolled types)
-- and calls set().

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

export type StarCfg = { seed: number, radius: number, types: { string } }

-- Fallback TEST star until a real one is set. radius in BLOCKS (footprint ≈ 2×). [TUNE]
M.TEST = { seed = 424242, radius = 96, types = { "Flora", "Stone", "Bog" } } :: StarCfg

-- Server: publish this star's config so every client generates the identical world.
function M.set(seed: number, radius: number, types: { string })
	ReplicatedStorage:SetAttribute("StarSeed", seed)
	ReplicatedStorage:SetAttribute("StarRadius", radius)
	ReplicatedStorage:SetAttribute("StarTypes", table.concat(types, ","))
end

-- Current config: the replicated attrs if published, else the TEST star.
function M.get(): StarCfg
	local seed = ReplicatedStorage:GetAttribute("StarSeed")
	if seed == nil then
		return M.TEST
	end
	local types: { string } = {}
	for t in string.gmatch(ReplicatedStorage:GetAttribute("StarTypes") or "", "[^,]+") do
		types[#types + 1] = t
	end
	return { seed = seed, radius = ReplicatedStorage:GetAttribute("StarRadius") or 96, types = types }
end

return M
