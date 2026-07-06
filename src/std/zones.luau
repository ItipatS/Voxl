--!strict
-- Zone framework (SHARED). Declare a named region ONCE here and it's usable everywhere:
-- the client announces it (Client/ZoneWatcher) and the server can read it for effects
-- later (zones.at(pos)). Priority = LIST order (first match wins). Adding a special zone =
-- ONE entry in LIST. `contains` is any predicate; the sphere/shell helpers cover the common
-- cases, drop in a custom function for anything fancy (region boxes, biome fields, …).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

local M = {}

export type Zone = { id: string, title: string, subtitle: string?, contains: (Vector3) -> boolean }

local BH = constellation.BLACKHOLE
local STAR_ZONE_R = 1600 -- how close to a starter star counts as "in its airspace"

-- ---- shape helpers (build a `contains` predicate) ---------------------------
function M.sphere(center: Vector3, radius: number): (Vector3) -> boolean
	local r2 = radius * radius
	return function(p: Vector3): boolean
		local d = p - center
		return d:Dot(d) < r2
	end
end

function M.shell(center: Vector3, rMin: number, rMax: number): (Vector3) -> boolean
	return function(p: Vector3): boolean
		local d = (p - center).Magnitude
		return d >= rMin and d < rMax
	end
end

-- ---- the zones (priority order: first match wins) ---------------------------
M.LIST = {
	-- inside the event horizon — the point of no return
	{ id = "maw", title = "The Maw", subtitle = "Nothing escapes", contains = M.sphere(BH.pos, BH.radius) },
	-- the dead shell between the cluster and the maw (dust + stars are gone here) — a WARNING
	{
		id = "brink",
		title = "The Brink",
		subtitle = "Turn back — the maw pulls",
		contains = M.shell(BH.pos, BH.radius, constellation.VOID_RADIUS),
	},
} :: { Zone }

-- starter-star airspaces (generated from the landmarks)
for _, lm in constellation.LANDMARKS do
	if lm.template ~= "BlackHole" then
		local biome = (lm.template :: string):gsub("Star$", "")
		M.LIST[#M.LIST + 1] = { id = lm.template, title = biome, subtitle = "Starter Star", contains = M.sphere(lm.pos, STAR_ZONE_R) }
	end
end

-- default: the open cluster (always matches → keep it LAST)
M.LIST[#M.LIST + 1] = { id = "cluster", title = "The Cluster", subtitle = "Open frontier", contains = function()
	return true
end }

-- The zone `pos` is in (first match wins; the cluster catches everything else).
function M.at(pos: Vector3): Zone
	for _, z in M.LIST do
		if z.contains(pos) then
			return z
		end
	end
	return M.LIST[#M.LIST] -- unreachable (cluster always matches), but keeps the type honest
end

return M
