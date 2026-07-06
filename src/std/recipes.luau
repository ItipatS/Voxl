--!strict
-- The RECIPE registry — SHARED (server validates crafts, client shows the tree + UIs). Two
-- recipe kinds (doc 22): TABLE recipes (3×3 pattern, instant) and STATION recipes (time-based:
-- furnace/sawmill/crusher/loom). References material keys (std/materials) + product keys (tools/
-- blocks — registered in itemdb/Blocks later). The refining chains are GENERATED per tier; the
-- table core is authored + a tier-upgrade RULE (doc 11: tier-N tool = tier-(N-1) tool + tier-N
-- metal) generates the rest. All values [TUNE]. Recipes unlock on obtaining their inputs.

local materials = require(game:GetService("ReplicatedStorage"):WaitForChild("std"):WaitForChild("materials"))
local mk = materials.matKey

local M = {}

export type Ingredient = { key: string, count: number }
export type Recipe = {
	id: string,
	out: Ingredient,
	surface: string, -- "table" | "furnace" | "sawmill" | "crusher" | "loom"
	time: number?, -- station only (seconds)
	fuel: number?, -- furnace only (fuel units)
	shape: { string }?, -- table SHAPED: rows of symbols (≤3×3), space = empty
	keys: { [string]: string }?, -- table shaped: symbol → material/product key
	inputs: { Ingredient }?, -- table SHAPELESS or STATION inputs
}

local list: { Recipe } = {}
local function add(r: Recipe)
	list[#list + 1] = r
end
local function I(key: string, count: number?): Ingredient
	return { key = key, count = count or 1 }
end

-- ===================== STATION recipes (time-based, per tier) =====================
for t = 1, 5 do
	local time = 3 + t -- higher tiers take longer [TUNE]
	-- Furnace
	add({ id = `smelt_ore_{t}`, out = I(mk("ingot", t)), surface = "furnace", time = 4 + t, fuel = 1, inputs = { I(mk("ore", t)) } })
	add({ id = `smelt_dust_{t}`, out = I(mk("ingot", t), 2), surface = "furnace", time = 4 + t, fuel = 1, inputs = { I(mk("oredust", t)) } }) -- crush→smelt = 2× ingots
	add({ id = `smelt_glass_{t}`, out = I(mk("glass", t)), surface = "furnace", time = 3 + t, fuel = 1, inputs = { I(mk("silica", t)) } })
	-- Sawmill
	add({ id = `saw_plank_{t}`, out = I(mk("plank", t), 4), surface = "sawmill", time = time, inputs = { I(mk("wood", t)) } })
	-- Crusher
	add({ id = `crush_rock_{t}`, out = I(mk("gravel", t)), surface = "crusher", time = time, inputs = { I(mk("rock", t)) } })
	add({ id = `crush_ore_{t}`, out = I(mk("oredust", t)), surface = "crusher", time = time, inputs = { I(mk("ore", t)) } })
	add({ id = `crush_gem_{t}`, out = I(mk("cutgem", t)), surface = "crusher", time = time + 2, inputs = { I(mk("gem", t)) } })
	-- Loom
	add({ id = `loom_thread_{t}`, out = I(mk("thread", t)), surface = "loom", time = time, inputs = { I(mk("fiber", t)) } })
	add({ id = `loom_cloth_{t}`, out = I(mk("cloth", t)), surface = "loom", time = time, inputs = { I(mk("thread", t), 2) } })
end
-- Charcoal (any wood → fuel), the early fuel.
add({ id = "smelt_charcoal", out = I("charcoal"), surface = "furnace", time = 4, fuel = 1, inputs = { I(mk("wood", 1)) } })

-- ===================== TABLE recipes (3×3 pattern, instant) =====================
-- Shapeless intermediates.
add({ id = "stick", out = I("stick", 4), surface = "table", inputs = { I(mk("plank", 1), 2) } })
add({ id = "rope", out = I("rope"), surface = "table", inputs = { I(mk("cloth", 1)) } })

-- T1 tools = SHAPED from planks + sticks (wooden). Product keys "<tool>_1".
local TOOLS = {
	{ tool = "pickaxe", shape = { "PPP", " S ", " S " } },
	{ tool = "axe", shape = { "PP ", "PS ", " S " } },
	{ tool = "shovel", shape = { " P ", " S ", " S " } },
	{ tool = "hoe", shape = { "PP ", " S ", " S " } },
}
for _, td in TOOLS do
	add({
		id = `{td.tool}_1`,
		out = I(`{td.tool}_1`),
		surface = "table",
		shape = td.shape,
		keys = { P = mk("plank", 1), S = "stick" },
	})
	-- Tier ascension (doc 11): tier-t tool = tier-(t-1) tool + 2× tier-t ingot. No skipping.
	for t = 2, 5 do
		add({
			id = `{td.tool}_{t}`,
			out = I(`{td.tool}_{t}`),
			surface = "table",
			inputs = { I(`{td.tool}_{t - 1}`), I(mk("ingot", t), 2) },
		})
	end
end

-- Building blocks (crafted — the placeable palette; terrain never drops). Keys → Blocks.luau.
add({ id = "block_planks", out = I("block_planks", 4), surface = "table", inputs = { I(mk("plank", 1), 1) } })
add({ id = "block_cobblestone", out = I("block_cobblestone"), surface = "table", inputs = { I(mk("gravel", 1), 2) } })
add({ id = "block_glass", out = I("block_glass"), surface = "table", inputs = { I(mk("glass", 1)) } })
add({ id = "torch", out = I("torch", 4), surface = "table", shape = { "C", "S" }, keys = { C = "charcoal", S = "stick" } })

-- ---- Aesthetic STYLING (doc 22): cosmetic, off the tier tree ----------------
-- Stains from the Alchemy Vat (natural sources → dye).
add({ id = "vat_stain_dark", out = I("stain_dark", 2), surface = "vat", time = 4, inputs = { I("charcoal") } })
add({ id = "vat_stain_pale", out = I("stain_pale", 2), surface = "vat", time = 4, inputs = { I(mk("salt", 1)) } })
add({ id = "vat_stain_amber", out = I("stain_amber", 2), surface = "vat", time = 4, inputs = { I(mk("sap", 1)) } })
add({ id = "vat_stain_russet", out = I("stain_russet", 2), surface = "vat", time = 4, inputs = { I(mk("fungus", 1)) } })
-- plank + stain → styled plank block (same tier; keys → Blocks.luau). Plain plank = oak default.
local WOOD_STYLES = {
	{ style = "birch", stain = "stain_pale" },
	{ style = "spruce", stain = "stain_dark" },
	{ style = "jungle", stain = "stain_russet" },
	{ style = "acacia", stain = "stain_amber" },
}
for _, w in WOOD_STYLES do
	add({ id = `style_{w.style}_plank`, out = I(`block_{w.style}_plank`, 4), surface = "table", inputs = { I(mk("plank", 1), 4), I(w.stain) } })
end

-- Stations + storage (man-made → they DROP, so you can retrieve them).
add({ id = "station_table", out = I("station_table"), surface = "table", inputs = { I(mk("plank", 1), 4) } })
add({ id = "station_furnace", out = I("station_furnace"), surface = "table", inputs = { I(mk("rock", 1), 8) } })
add({ id = "station_sawmill", out = I("station_sawmill"), surface = "table", inputs = { I(mk("plank", 1), 4), I(mk("ingot", 2), 2) } })
add({ id = "station_crusher", out = I("station_crusher"), surface = "table", inputs = { I(mk("rock", 1), 4), I(mk("ingot", 2), 2) } })
add({ id = "chest", out = I("chest"), surface = "table", inputs = { I(mk("plank", 1), 6) } })

M.LIST = list

-- Index: product key → the recipes that make it (for the crafting-tree browser, doc 11).
local byOut: { [string]: { Recipe } } = {}
for _, r in list do
	local o = byOut[r.out.key]
	if not o then
		o = {}
		byOut[r.out.key] = o
	end
	o[#o + 1] = r
end
M.byOut = byOut

function M.recipesFor(outKey: string): { Recipe }
	return byOut[outKey] or {}
end

return M
