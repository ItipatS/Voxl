--!strict
-- The MATERIAL taxonomy — every raw + refined crafting material, SHARED (server authority +
-- client UI read the same keys). The answer to "what materials exist": 5 biome families × 3
-- node-roles × 5 tiers = 75 RAWS (all T1 wood variants drop the same `wood_1`, etc. — the mesh
-- variety at T1 is cosmetic, the material is unified per kind+tier), plus the REFINED goods the
-- stations produce. Keys are `<kind>_<tier>`; ids/inventory integration (itemdb) layer on later.
-- See doc 21 (nodes) + doc 22 (crafting). All names/values [TUNE].

local M = {}

export type MatKind = "raw" | "refined" | "fuel" | "stain"
export type MatDef = {
	key: string, -- stable code handle
	name: string, -- display
	kind: MatKind,
	family: string?, -- Flora/Stone/Sand/Frost/Bog (raws)
	role: string?, -- the node-role that drops it (raws)
	tier: number, -- 1..5
}

-- ---- RAWS: 15 kinds (family × role), each with 5 tier names -------------------
-- `primary` marks the family's headline resource (doc 21). Tier names are flavour; the DROP
-- for every T-n node of that kind is the same key regardless of biome mesh.
type Kind = { key: string, family: string, role: string, primary: boolean, tiers: { string } }
local KINDS: { Kind } = {
	-- Flora
	{ key = "wood", family = "Flora", role = "Tree", primary = true, tiers = { "Softwood", "Hardwood", "Ironwood", "Heartwood", "Luminwood" } },
	{ key = "fiber", family = "Flora", role = "Shrub", primary = false, tiers = { "Fiber", "Flax", "Silkvine", "Rootweave", "Spectrafiber" } },
	{ key = "sap", family = "Flora", role = "Bloom", primary = false, tiers = { "Sap", "Resin", "Amber", "Nectar", "Lumen-Sap" } },
	-- Stone
	{ key = "ore", family = "Stone", role = "Ore Vein", primary = true, tiers = { "Copper Ore", "Iron Ore", "Gold Ore", "Titanite Ore", "Void Ore" } },
	{ key = "gem", family = "Stone", role = "Crystal", primary = false, tiers = { "Quartz", "Amethyst", "Ruby", "Diamond", "Prime-Gem" } },
	{ key = "rock", family = "Stone", role = "Loose Rock", primary = false, tiers = { "Stone", "Granite", "Basalt", "Obsidian", "Monolith Stone" } },
	-- Sand
	{ key = "silica", family = "Sand", role = "Silica Spire", primary = true, tiers = { "Silica", "Quartz-Sand", "Fine Silica", "Crystal Silica", "Prime Silica" } },
	{ key = "glassshard", family = "Sand", role = "Glass Shard", primary = false, tiers = { "Glass Shard", "Clear Shard", "Tinted Shard", "Crystal Shard", "Prime Shard" } },
	{ key = "salt", family = "Sand", role = "Salt Crust", primary = false, tiers = { "Salt", "Rock Salt", "Mineral Salt", "Bitter Salt", "Prime Salt" } },
	-- Frost
	{ key = "ice", family = "Frost", role = "Ice Core", primary = true, tiers = { "Ice", "Packed Ice", "Blue Ice", "Deep Ice", "Aurora Ice" } },
	{ key = "cryocrystal", family = "Frost", role = "Cryo Crystal", primary = false, tiers = { "Frost Shard", "Cryo-Crystal", "Rime Crystal", "Glacial Crystal", "Aurora-Crystal" } },
	{ key = "rime", family = "Frost", role = "Rime", primary = false, tiers = { "Rime", "Hoarfrost", "Frost-Salt", "Cryo-Salt", "Prime-Rime" } },
	-- Bog
	{ key = "spore", family = "Bog", role = "Spore Pod", primary = true, tiers = { "Spore", "Mycelium", "Bloomspore", "Giant Spore", "Prime-Spore" } },
	{ key = "tar", family = "Bog", role = "Tar Seep", primary = false, tiers = { "Tar", "Pitch", "Bitumen", "Black Tar", "Void-Tar" } },
	{ key = "fungus", family = "Bog", role = "Fungal Cap", primary = false, tiers = { "Fungus", "Toadstool", "Glowcap", "Titancap", "Lumen-Cap" } },
}
M.KINDS = KINDS

local defs: { MatDef } = {}
local byKey: { [string]: MatDef } = {}

local function add(d: MatDef)
	assert(not byKey[d.key], `materials: duplicate key '{d.key}'`)
	defs[#defs + 1] = d
	byKey[d.key] = d
end

for _, k in KINDS do
	for tier = 1, 5 do
		add({ key = `{k.key}_{tier}`, name = k.tiers[tier], kind = "raw", family = k.family, role = k.role, tier = tier })
	end
end

-- ---- REFINED: what the stations produce (doc 22) ----------------------------
-- Tiered refined goods follow their raw's tier. Ingot names track the ore metal.
local INGOT = { "Copper", "Iron", "Gold", "Titanite", "Voidsteel" }
for tier = 1, 5 do
	add({ key = `plank_{tier}`, name = "Planks", kind = "refined", family = "Flora", tier = tier }) -- Sawmill: wood → planks
	add({ key = `ingot_{tier}`, name = INGOT[tier], kind = "refined", family = "Stone", tier = tier }) -- Furnace: ore(+crush) → ingot
	add({ key = `glass_{tier}`, name = "Glass", kind = "refined", family = "Sand", tier = tier }) -- Furnace: silica → glass
	add({ key = `thread_{tier}`, name = "Thread", kind = "refined", family = "Flora", tier = tier }) -- Loom: fiber → thread
	add({ key = `cloth_{tier}`, name = "Cloth", kind = "refined", family = "Flora", tier = tier }) -- Loom: thread → cloth
	add({ key = `gravel_{tier}`, name = "Gravel", kind = "refined", family = "Stone", tier = tier }) -- Crusher: rock → gravel
	add({ key = `oredust_{tier}`, name = "Ore Dust", kind = "refined", family = "Stone", tier = tier }) -- Crusher: ore → dust (2× smelt)
	add({ key = `cutgem_{tier}`, name = "Cut Gem", kind = "refined", family = "Stone", tier = tier }) -- Press/Crusher: gem → cut gem
end

-- Fuels + universal intermediates (not per-tier).
add({ key = "charcoal", name = "Charcoal", kind = "fuel", tier = 1 }) -- Furnace: wood → charcoal
add({ key = "coal", name = "Coal", kind = "fuel", tier = 1 })
add({ key = "stick", name = "Stick", kind = "refined", tier = 1 }) -- table: planks → sticks
add({ key = "rope", name = "Rope", kind = "refined", tier = 1 }) -- table/loom: cloth → rope

-- Stains (dyes) — the AESTHETIC axis (doc 22). From the Alchemy Vat (natural sources); re-skin
-- planks/stone/glass/cloth cosmetically, OFF the tier tree.
local STAINS = {
	{ key = "stain_pale", name = "Pale Stain" }, -- birch
	{ key = "stain_dark", name = "Dark Stain" }, -- spruce
	{ key = "stain_russet", name = "Russet Stain" }, -- jungle
	{ key = "stain_amber", name = "Amber Stain" }, -- acacia
	{ key = "stain_crimson", name = "Crimson Stain" },
	{ key = "stain_verdant", name = "Verdant Stain" },
	{ key = "stain_azure", name = "Azure Stain" },
}
for _, s in STAINS do
	add({ key = s.key, name = s.name, kind = "stain", tier = 1 })
end

M.DEFS = defs

function M.byKey(key: string): MatDef?
	return byKey[key]
end

function M.name(key: string): string
	local d = byKey[key]
	return if d then d.name else key
end

-- Raw material key for a (kind, tier), e.g. matKey("wood", 3) == "wood_3".
function M.matKey(kind: string, tier: number): string
	return `{kind}_{tier}`
end

return M
