--!strict
-- Universe star field — the SHARED, seed-derived generator for the explore-and-claim
-- universe (the STAR analogue of std/dust). Per doc 15: the universe is a discrete grid of
-- star SLOTS; which slots hold an unclaimed star THIS WEEK, and each star's identity
-- (position within its slot, tier, approach resource types), are a pure function of a weekly
-- universe seed + the slot coordinate. Both server and client call this to agree on the
-- frontier with ZERO streamed positions.
--
-- Key rules (doc 15 / DESIGN):
--   * starId == the slot coordinate {cx,cy,cz} — permanent, transfer-safe, the plot.
--   * A star's PERMANENT properties derive from its `seed` (via buildStar), NOT from the
--     week — so a CLAIMED star freezes its `seed` as `originSeed` and reproduces identically
--     forever (buildStar(slot, originSeed)), immune to the weekly reshuffle.
--   * An UNCLAIMED star's existence + `seed` come from the week rng (starAt) → it rerolls
--     fresh every week. Rotating the week seed = the weekly frontier refresh.
--   * Claimed slots are the caller's concern (the ClaimedCoords skip-set, server-only) — the
--     generator produces the raw unclaimed field; the claimed overlay/skip layers on top,
--     exactly like std/dust's generator vs its cooldown ledger.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

local M = {}

M.UNIVERSE_SEED = 770077 -- global; the weekly seed derives from this + the week number
M.SLOT_SIZE = 8000 -- stud grid spacing between slots (>> planet size so big worlds don't touch) [TUNE]
M.DENSITY = 0.35 -- fraction of slots that hold an unclaimed star this week [TUNE]
M.WEEK_SECONDS = 7 * 24 * 3600

-- Tier roll: mostly T1, scarce T5 (DESIGN "check your seed"). Weights sum to 100. [TUNE]
M.TIER_WEIGHTS = { 60, 22, 11, 5, 2 } -- T1 .. T5

-- Approach-preview resource TYPES: a star shows 3 of these on approach; tier/node stay
-- hidden (DESIGN star-approach UX). Placeholder taxonomy [TUNE] — refine with the resource
-- design (there are 5 types × 5 biomes in DESIGN).
M.RESOURCE_TYPES = { "Verdant", "Arid", "Rocky", "Frost", "Mire" }

local CENTER = constellation.CENTER
local VOID = constellation.VOID_RADIUS -- no procedural stars inside the maw's void zone

export type Star = {
	slot: { number }, -- {cx,cy,cz} — this IS the starId
	pos: Vector3,
	seed: number, -- rolls the star's identity; frozen as originSeed on claim
	tier: number, -- 1..5
	types: { string }, -- 3 approach-preview resource types
	name: string, -- procedural Latin/scientific default name (overridden on claim)
}

-- ---- deterministic hashing (exact in f64; stable across server + client) -----
local P = 2147483647 -- 2^31-1 (prime)
local function h32(h: number, v: number): number
	-- h < P, so h*8191 < 2^44 (well under 2^53) → exact. v normalised into [0,P).
	return (h * 8191 + (v % P + P) % P) % P
end
local function slotSeed(cx: number, cy: number, cz: number, week: number): number
	local h = 2166136261 % P
	h = h32(h, week)
	h = h32(h, cx)
	h = h32(h, cy)
	h = h32(h, cz)
	return h
end

-- ---- rolls -------------------------------------------------------------------
local function weightedTier(r: Random): number
	local roll = r:NextNumber(0, 100)
	local acc = 0
	for tier, w in M.TIER_WEIGHTS do
		acc += w
		if roll < acc then
			return tier
		end
	end
	return #M.TIER_WEIGHTS
end

local function pick3(r: Random, list: { string }): { string }
	local pool = table.clone(list)
	local out: { string } = {}
	for _ = 1, math.min(3, #pool) do
		local j = r:NextInteger(1, #pool)
		out[#out + 1] = pool[j]
		pool[j] = pool[#pool]
		pool[#pool] = nil
	end
	return out
end

-- Procedural star name: a Latin-ish scientific binomial "Genus species", seeded from the
-- star so it's stable + shared. Genus is drawn from the PRIMARY resource type; species is a
-- generic Latin descriptor; ~30% get a roman-numeral designation. (Overridden when claimed.)
local GENUS: { [string]: { string } } = {
	Verdant = { "Verdantia", "Silvana", "Viridis", "Frondia" },
	Arid = { "Aridia", "Siccara", "Dunara", "Ustia" },
	Rocky = { "Petraia", "Saxena", "Montara", "Cragos" },
	Frost = { "Glacia", "Gelida", "Nivara", "Brumis" },
	Mire = { "Palusia", "Limara", "Uligo", "Fennis" },
}
local SPECIES = {
	"borealis", "australis", "magna", "minor", "prima", "nova", "antiqua", "profunda",
	"serena", "aspera", "lucida", "umbra", "ferox", "placida", "errans", "obscura",
}
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }

local function nameFor(r: Random, types: { string }): string
	local g = GENUS[types[1]] or GENUS.Verdant
	local name = g[r:NextInteger(1, #g)] .. " " .. SPECIES[r:NextInteger(1, #SPECIES)]
	if r:NextNumber() < 0.3 then
		name ..= " " .. ROMAN[r:NextInteger(1, #ROMAN)]
	end
	return name
end

function M.cellOf(pos: Vector3): (number, number, number)
	local s = M.SLOT_SIZE
	return math.floor(pos.X / s), math.floor(pos.Y / s), math.floor(pos.Z / s)
end

function M.currentWeek(now: number): number
	return math.floor(now / M.WEEK_SECONDS)
end

-- Reproduce a star's full identity from its slot + seed. Used for BOTH the unclaimed field
-- (seed from the week rng) and CLAIMED stars (seed = the frozen originSeed) — same input,
-- same star, forever.
function M.buildStar(cx: number, cy: number, cz: number, seed: number): Star
	local r = Random.new(seed)
	local s = M.SLOT_SIZE
	-- keep the star in the CENTRAL half of its slot so big worlds never overlap neighbours
	-- (and cellOf(pos) still maps back to this slot).
	local j = s * 0.25
	local pos = Vector3.new(
		(cx + 0.5) * s + r:NextNumber(-j, j),
		(cy + 0.5) * s + r:NextNumber(-j, j),
		(cz + 0.5) * s + r:NextNumber(-j, j)
	)
	local tier = weightedTier(r)
	local types = pick3(r, M.RESOURCE_TYPES)
	local name = nameFor(r, types)
	return { slot = { cx, cy, cz }, pos = pos, seed = seed, tier = tier, types = types, name = name }
end

-- The UNCLAIMED star in a slot this week (nil if the slot is empty this week or falls in the
-- maw void). Callers overlay claimed stars + skip claimed slots themselves (ClaimedCoords).
function M.starAt(cx: number, cy: number, cz: number, week: number): Star?
	local rng = Random.new(slotSeed(cx, cy, cz, week))
	if rng:NextNumber() >= M.DENSITY then
		return nil -- no star in this slot this week
	end
	local seed = rng:NextInteger(1, 2 ^ 31 - 1)
	local star = M.buildStar(cx, cy, cz, seed)
	if (star.pos - CENTER).Magnitude < VOID then
		return nil -- inside the maw void — no frontier here
	end
	return star
end

return M
