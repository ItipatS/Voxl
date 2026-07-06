--!strict
-- Constellation spatial layout — shared by server + client so both agree on hub
-- positions, no-plant/warp radii, and the centre black hole. All [TUNE]: anchored
-- to flight speed ~160 studs/s (FlightController.SPEED) — the *ratios* (hop-time
-- >> commons >> warp) matter more than the exact studs. See docs/13.
--
-- STARTER STARS = the 5 pentagram points, now communal starter hub-towns (the
-- explore-and-claim pivot, DESIGN.md): mostly-T1 trailheads with named markets, not
-- biome-region "resource stars". (Enterable stars out in the field are procedural;
-- that's the deeper rework — these 5 are just the fixed on-ramp geography.)

local CENTER = Vector3.new(0, 500, 0)

-- The whole universe scales off ONE number now that landmarks are parallax proxies
-- (SpaceProxies) — no real geometry at these distances, so we can go huge. Bump
-- RING_RADIUS to expand; everything below (radii, star field, planting) is relative.
local RING_RADIUS = 30000 -- was ~5000; the starter stars sit on this pentagon ring

-- 5 starter stars on a pentagon ring around CENTER, Y-jittered for 3D depth.
local Y_JITTER = { 0, 2400, -1200, 1800, -1800 }
local STARTER_STARS = {}
for i = 0, 4 do
	local a = math.rad(i * 72)
	STARTER_STARS[i + 1] = CENTER + Vector3.new(math.cos(a) * RING_RADIUS, Y_JITTER[i + 1], math.sin(a) * RING_RADIUS)
end

local M = {
	CENTER = CENTER,
	STARTER_STARS = STARTER_STARS,
	RING_RADIUS = RING_RADIUS,

	NO_PLANT_RADIUS = 6000, -- can't plant an island within this of a starter star (the commons)
	WARP_RADIUS = 2200, -- fly within this of a starter star core → the entry countdown
	ISLAND_SPACING = 1200, -- min gap between planted islands (max footprint + buffer)

	-- Centre black hole: a SOFT drag so cutting straight across the middle is a bit
	-- slower + tugged, making star-to-star hops beat skipping through. Never a wall.
	BLACKHOLE = {
		pos = CENTER,
		radius = 12000, -- event horizon: once inside you can't escape
		pull = 600, -- inward acceleration (studs/s^2), grows toward the core
		coreRadius = 700, -- consumed here → respawn
	},
}

-- Void danger zone: dust + collectable stars stop generating within this of CENTER, and
-- a warning sphere (Client/MawWarning) marks it — so the field thinning + the ominous shell
-- warn you BEFORE the event horizon at BLACKHOLE.radius. [TUNE] the margin.
M.VOID_RADIUS = M.BLACKHOLE.radius + 2000 -- 14000

-- Landmark parallax proxies (black hole + starter stars). The CLIENT renders each
-- as a proxy cloned from ReplicatedStorage.Assets[template] kept close to the camera;
-- `pos` is the REAL world position (server gameplay uses it too). apparent size ∝
-- baseScale / distance, so distant stars read smaller — bump baseScale if too small.
-- (Template names below are legacy biome-flavoured art; starter stars get proper
-- fancy hub-town names + visuals in the naming pass — see DESIGN.md.)
M.LANDMARKS = {
	{ template = "BlackHole", pos = CENTER, baseScale = 20, proxyDist = 100 },
	{ template = "ForestStar", pos = STARTER_STARS[1], baseScale = 6, proxyDist = 500 },
	{ template = "DesertStar", pos = STARTER_STARS[2], baseScale = 6, proxyDist = 500 },
	{ template = "MountainStar", pos = STARTER_STARS[3], baseScale = 6, proxyDist = 500 },
	{ template = "HillStar", pos = STARTER_STARS[4], baseScale = 6, proxyDist = 500 },
	{ template = "SwampStar", pos = STARTER_STARS[5], baseScale = 6, proxyDist = 500 },
}

-- True if `pos` is far enough from every starter star to plant an island.
-- (Island-vs-island spacing is checked by the planting system against the manifest.)
function M.canPlantAt(pos: Vector3): boolean
	for _, sp in M.STARTER_STARS do
		if (pos - sp).Magnitude < M.NO_PLANT_RADIUS then
			return false
		end
	end
	return true
end

return M
