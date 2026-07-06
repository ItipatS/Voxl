--!strict
-- Static registry of every carriable thing (items now; blocks carry weight via a
-- bridge). SHARED — the server authority (PlayerStore, ItemBehaviors) and the
-- client view (ItemMirror, item UI) require the SAME ids/shapes, so nothing can
-- disagree about what an id means. Immutable. See .claude/17-items-and-inventory.
--
-- Weight is the keystone constraint (design: hauling friction makes geography
-- matter). Every def has a `weight`; blocks have `blockWeight`. All numbers [TUNE].

local M = {}

-- Placeholder texture for any block/item with no defined icon or model — makes a
-- missing visual obvious instead of blank. Shared so block UI can use it too.
M.DEBUG_ICON = "rbxassetid://78128038044643"

export type Mode = "Lobby" | "ResourceStar"

-- Slot visual is HYBRID (pick one; neither = name-only fallback):
--   * icon  — a flat 2D sprite (rbxassetid://…). The default for most items; cheap,
--             and there are thousands of royalty-free icon packs to draw from.
--   * model — name of a `ReplicatedStorage.Models` child, rendered in the slot's
--             ViewportFrame. For voxel-style items that read better in 3D (a tree,
--             a tool). Auto-framed — no per-item camera config needed.
export type Kind = "Tool" | "Consumable" | "Material"

-- Rarity ladder (extensible). Drives UI colour/effect/border via UIData.Grade — this is
-- SEPARATE from `tier` (numeric item level / progression). e.g. a tier-2 mythical item.
export type Grade = "common" | "uncommon" | "rare" | "epic" | "legendary" | "mythical"

export type ItemDef = {
	id: number, -- stable u16 network id (item-only space; separate Blink channel from block u8s)
	key: string, -- code/profile handle
	name: string, -- display
	kind: Kind, -- Tool = hotbar/held, Consumable = inventory-click use, Material = inert (doc 20)
	tier: number, -- item LEVEL through progression (1..N) — a stat, NOT the rarity
	grade: Grade, -- RARITY → drives UI colour/effect/border (UIData.Grade)
	weight: number, -- weight budget per unit
	stack: number, -- max per stack (1 = unstackable)
	icon: string?, -- 2D slot sprite (rbxassetid://…) — hybrid default
	model: string?, -- ReplicatedStorage.Models child name → 3D viewport icon (voxel items)
	usableIn: { [string]: boolean }?, -- placemodes the behavior may run in (nil = not directly usable)
	behavior: string?, -- key into the server ItemBehaviors registry (nil = inert material)
	desc: { string }, -- tooltip lines
}

-- Ids are permanent once shipped. Add new items with new ids; never renumber.
local DEFS: { ItemDef } = {
	{
		id = 1,
		key = "star_seed",
		name = "Star Seed",
		kind = "Tool", -- held in-hand from the hotbar; activate to plant (doc 20)
		tier = 1, -- item level (progression)
		grade = "mythical", -- rarity → cosmic-starlight effect
		weight = 5,
		stack = 1,
		model = "StarSeed", -- ReplicatedStorage.Assets.Items.StarSeed (3D held model)
		usableIn = { Lobby = true },
		behavior = "plant_star",
		desc = {
			"A dormant world folded into a seed.",
			"Use it in the Cluster zone to plant your planet.",
		},
	},
}

local byKey: { [string]: ItemDef } = {}
local byId: { [number]: ItemDef } = {}
local function register(d: ItemDef)
	assert(not byKey[d.key], `itemdb: duplicate key '{d.key}'`)
	assert(not byId[d.id], `itemdb: duplicate id {d.id}`)
	byKey[d.key] = d
	byId[d.id] = d
end
for _, d in DEFS do
	register(d)
end

-- ---- GENERATED crafting items (materials + tools + product placeholders) -----
-- Placeholder icons for now: the resource/node art comes later and must NOT block crafting
-- development. Ids are allocated in fixed ranges from a deterministic source order.
local materials = require(script.Parent.materials)
local recipes = require(script.Parent.recipes)
local GRADE: { Grade } = { "common", "uncommon", "rare", "epic", "legendary" }
local function gradeFor(t: number): Grade
	return GRADE[math.clamp(t, 1, 5)]
end
local function addGen(d: ItemDef)
	DEFS[#DEFS + 1] = d
	register(d)
end

-- raws / refined / fuel / stains → Material items (id 1000+)
for i, m in materials.DEFS do
	addGen({
		id = 1000 + i,
		key = m.key,
		name = m.name,
		kind = "Material",
		tier = m.tier,
		grade = gradeFor(m.tier),
		weight = 1,
		stack = 99,
		icon = M.DEBUG_ICON,
		desc = { m.name },
	})
end

-- tools (pickaxe/axe/shovel/hoe × 5 tiers) → Tool items (id 2000+)
local TOOLS = { { "pickaxe", "Pickaxe" }, { "axe", "Axe" }, { "shovel", "Shovel" }, { "hoe", "Hoe" } }
local ti = 0
for _, tk in TOOLS do
	for tier = 1, 5 do
		ti += 1
		addGen({
			id = 2000 + ti,
			key = `{tk[1]}_{tier}`,
			name = `{tk[2]} T{tier}`,
			kind = "Tool",
			tier = tier,
			grade = gradeFor(tier),
			weight = 3,
			stack = 1,
			icon = M.DEBUG_ICON,
			usableIn = { ResourceStar = true },
			desc = { `Tier {tier} {tk[2]}` },
		})
	end
end

-- every OTHER key referenced by a recipe (blocks/stations/utility) → placeholder Material
-- (id 3000+), so all recipes resolve. Sorted for stable ids.
local pkeys: { string } = {}
local seen: { [string]: boolean } = {}
for _, r in recipes.LIST do
	local keys = { r.out.key }
	for _, ing in recipes.inputsOf(r) do
		keys[#keys + 1] = ing.key
	end
	for _, k in keys do
		if not byKey[k] and not seen[k] then
			seen[k] = true
			pkeys[#pkeys + 1] = k
		end
	end
end
table.sort(pkeys)
for i, k in pkeys do
	addGen({ id = 3000 + i, key = k, name = k, kind = "Material", tier = 1, grade = "common", weight = 1, stack = 99, icon = M.DEBUG_ICON, desc = { k } })
end

M.DEFS = DEFS

function M.byKey(key: string): ItemDef?
	return byKey[key]
end

function M.byId(id: number): ItemDef?
	return byId[id]
end

-- ---- Weight -----------------------------------------------------------------
-- Blocks cost weight too. Flat default with per-block overrides (tune later).
local BLOCK_WEIGHT_DEFAULT = 1
local BLOCK_WEIGHT: { [number]: number } = {
	-- [WorldGen.BLOCK.Stone] = 2, [WorldGen.BLOCK.OakLeaves] = 0.5, ...
}

function M.blockWeight(block: number): number
	return BLOCK_WEIGHT[block] or BLOCK_WEIGHT_DEFAULT
end

function M.itemWeight(key: string): number
	local d = byKey[key]
	return if d then d.weight else 0
end

-- Total carried weight = Σ block·blockWeight + Σ item·itemWeight. Derived, never
-- stored (no writer → no race; doc 16 §1).
function M.totalWeight(blocks: { [number]: number }, items: { [string]: number }): number
	local w = 0
	for block, n in blocks do
		w += M.blockWeight(block) * n
	end
	for key, n in items do
		w += M.itemWeight(key) * n
	end
	return w
end

-- Carry capacity. Constant for now; progression scales it later (change here only).
local BASE_CAPACITY = 500
function M.capacity(_profileData: any?): number
	return BASE_CAPACITY
end

return M
