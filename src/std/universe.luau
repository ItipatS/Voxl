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

-- Per-BIOME tier roll. A star's featured resource types are each a biome with its OWN tier —
-- mostly T1, rarer higher, and AT MOST one T5 per star (DESIGN: "mostly T1 … exactly one T5
-- biome on stars that roll it"). So a star isn't "a Tn star"; it's a mix, and its headline
-- `tier` is just its best biome. Weights sum to 100. [TUNE]
M.BIOME_TIER_WEIGHTS = { 80, 14, 4.5, 1.3, 0.2 } -- T1 .. T5  (P(all-3-T1) ≈ 51% of stars)

-- Approach-preview resource TYPES: a star shows 3 of these on approach; tier/node stay
-- hidden (DESIGN star-approach UX). Placeholder taxonomy [TUNE] — refine with the resource
-- design (there are 5 types × 5 biomes in DESIGN).
M.RESOURCE_TYPES = { "Flora", "Stone", "Sand", "Frost", "Bog" } -- the 5 gather families (doc 21)

local CENTER = constellation.CENTER
local VOID = constellation.VOID_RADIUS -- no procedural stars inside the maw's void zone

export type Star = {
	slot: { number }, -- {cx,cy,cz} — this IS the starId
	pos: Vector3,
	seed: number, -- rolls the star's identity; frozen as originSeed on claim
	tier: number, -- 1..5 — the star's BEST biome tier (headline / payoff hint; most stars are T1)
	types: { string }, -- 3 featured resource types (shown on approach)
	biomes: { { type: string, tier: number } }, -- per-type biome tiers (mostly T1, ≤1 T5)
	name: string, -- procedural Latin/scientific default name (overridden on claim)
	map: string?, -- LANDMARK only: a baked world under Misc.MapData (doc 23)
	radius: number?, -- LANDMARK only: that world's own footprint, in blocks
}

-- ===== LANDMARK stars (doc 23) =====
-- Hand-authored fixtures in a procedural frontier. A landmark ALWAYS occupies its slot
-- — it ignores the density roll and the weekly reshuffle — and its world is a BAKED map
-- instead of a rolled island. Permanent, findable, identical for everyone: the frontier
-- needs a few places that are somewhere rather than anywhere.
export type Landmark = {
	slot: { number },
	map: string,
	name: string,
	radius: number,
	tier: number,
	types: { string },
	biomes: { { type: string, tier: number } },
}

local LANDMARKS: { Landmark } = {
	{
		slot = { 3, 0, 0 }, -- ~28k studs out: outside the maw void, near the starter ring
		map = "FantasyMedieval",
		name = "Aldermoor",
		radius = 448,
		tier = 3,
		types = { "Flora", "Stone", "Bog" },
		biomes = { { type = "Flora", tier = 3 }, { type = "Stone", tier = 2 }, { type = "Bog", tier = 2 } },
	},
}
M.LANDMARKS = LANDMARKS

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
local function biomeTier(r: Random): number
	local roll = r:NextNumber(0, 100)
	local acc = 0
	for tier, w in M.BIOME_TIER_WEIGHTS do
		acc += w
		if roll < acc then
			return tier
		end
	end
	return #M.BIOME_TIER_WEIGHTS
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
	Flora = { "Verdantia", "Silvana", "Viridis", "Frondia" },
	Stone = { "Petraia", "Saxena", "Montara", "Cragos" },
	Sand = { "Aridia", "Siccara", "Dunara", "Ustia" },
	Frost = { "Glacia", "Gelida", "Nivara", "Brumis" },
	Bog = { "Palusia", "Limara", "Uligo", "Fennis" },
}
local SPECIES = {
	"borealis", "australis", "magna", "minor", "prima", "nova", "antiqua", "profunda",
	"serena", "aspera", "lucida", "umbra", "ferox", "placida", "errans", "obscura",
}
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }

local function nameFor(r: Random, types: { string }): string
	local g = GENUS[types[1]] or GENUS.Flora
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
	local types = pick3(r, M.RESOURCE_TYPES)
	-- Each featured type is a biome with its own tier — mostly T1, and AT MOST one T5 per star.
	-- The headline `tier` is the best biome (the payoff hint the glow can key off).
	local biomes: { { type: string, tier: number } } = {}
	local maxTier, hasT5 = 1, false
	for _, ty in types do
		local t = biomeTier(r)
		if t == 5 then
			if hasT5 then
				t = 4 -- only one T5 biome per star
			else
				hasT5 = true
			end
		end
		biomes[#biomes + 1] = { type = ty, tier = t }
		if t > maxTier then
			maxTier = t
		end
	end
	local name = nameFor(r, types)
	return { slot = { cx, cy, cz }, pos = pos, seed = seed, tier = maxTier, types = types, biomes = biomes, name = name }
end

-- The landmark occupying a slot, as a full Star (nil if the slot holds none). Its position
-- is still slot-derived, so it sits in the field exactly like any other star — it just never
-- moves, never disappears, and carries a baked world.
function M.landmarkAt(cx: number, cy: number, cz: number): Star?
	for _, L in LANDMARKS do
		if L.slot[1] == cx and L.slot[2] == cy and L.slot[3] == cz then
			local s = M.SLOT_SIZE
			return {
				slot = { cx, cy, cz },
				pos = Vector3.new((cx + 0.5) * s, (cy + 0.5) * s, (cz + 0.5) * s),
				seed = 0, -- unused: a baked world isn't rolled from a seed
				tier = L.tier,
				types = L.types,
				biomes = L.biomes,
				name = L.name,
				map = L.map,
				radius = L.radius,
			}
		end
	end
	return nil
end

-- The UNCLAIMED star in a slot this week (nil if the slot is empty this week or falls in the
-- maw void). Callers overlay claimed stars + skip claimed slots themselves (ClaimedCoords).
function M.starAt(cx: number, cy: number, cz: number, week: number): Star?
	local landmark = M.landmarkAt(cx, cy, cz)
	if landmark then
		return landmark -- fixed: no density roll, no weekly reshuffle
	end
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
