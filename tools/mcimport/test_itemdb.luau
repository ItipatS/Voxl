-- Blocks are now items (itemdb `block_<id>`), and item KEYS are written into player
-- profiles. A duplicate id, a collision with the crafting ranges, or a block that
-- silently has no item would each be permanent damage to real save data — so check
-- the whole registry rather than trusting the id arithmetic.
--
--   lune run tools/mcimport/test_itemdb.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

-- ---- Roblox stubs, enough to load Blocks + itemdb ----
local env = [[
local Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end,
                 new = function(r, g, b) return { r = r, g = g, b = b } end }
local Enum = setmetatable({}, { __index = function(_, k)
    return setmetatable({}, { __index = function(_, n) return { EnumItem = k .. "." .. n } end })
end })
local Instance = { new = function() return { Parent = nil } end }
]]

local function replaceOnce(hay: string, needle: string, sub: string): string
	local at = string.find(hay, needle, 1, true)
	assert(at, `could not find "{needle}"`)
	return string.sub(hay, 1, at - 1) .. sub .. string.sub(hay, at + #needle)
end

local blocksSrc = fs.readFile("src/Misc/Blocks.luau")
local itemdbSrc = fs.readFile("src/std/itemdb.luau")
local materialsSrc = fs.readFile("src/std/materials.luau")
local recipesSrc = fs.readFile("src/std/recipes.luau")

-- itemdb pulls materials/recipes off script.Parent and Blocks off ReplicatedStorage;
-- inline all three so the real file runs unmodified apart from its lookups.
local src = itemdbSrc
src = replaceOnce(src, "local materials = require(script.Parent.materials)",
	"local materials = (function()\n" .. materialsSrc .. "\nend)()")
-- recipes reaches for materials through the DataModel; hand it the module directly.
local recipesInline = replaceOnce(recipesSrc,
	'local materials = require(game:GetService("ReplicatedStorage"):WaitForChild("std"):WaitForChild("materials"))',
	"local materials = (function()\n" .. materialsSrc .. "\nend)()")
src = replaceOnce(src, "local recipes = require(script.Parent.recipes)",
	"local recipes = (function()\n" .. recipesInline .. "\nend)()")
src = replaceOnce(src, 'local ReplicatedStorage = game:GetService("ReplicatedStorage")', "")
src = replaceOnce(src, "local Blocks = require(ReplicatedStorage.Misc.Blocks)",
	"local Blocks = BLOCKS_IN")

local prelude = env .. "local BLOCKS_IN = (function()\n" .. blocksSrc .. "\nend)()\n"
local itemdb = luau.load(prelude .. src, { debugName = "itemdb" })()
local Blocks = luau.load(env .. blocksSrc, { debugName = "Blocks" })()

local failures = 0
local function check(ok: boolean, msg: string)
	if not ok then
		failures += 1
		print("FAIL: " .. msg)
	end
end

-- 1. Every block above Air has an item, and it round-trips both ways.
local blockCount = 0
for blockId, d in Blocks.defs do
	if blockId > 0 then
		blockCount += 1
		local def = itemdb.forBlock(blockId)
		if not def then
			check(false, `block {blockId} ({d.name}) has no item`)
		else
			check(def.placesBlock == blockId,
				`item {def.key} places block {tostring(def.placesBlock)}, expected {blockId}`)
			check(itemdb.blockOf(def.key) == blockId,
				`blockOf({def.key}) did not return {blockId}`)
			check(def.kind == "Block", `item {def.key} has kind {def.kind}, expected Block`)
			check(itemdb.byKey(def.key) == def, `byKey({def.key}) is not the same def`)
			check(itemdb.byId(def.id) == def, `byId({def.id}) is not the same def`)
		end
	end
end

-- 2. No id or key collisions ANYWHERE in the registry. itemdb asserts on duplicates
-- at load, so reaching here already proves a lot — but the block range must also not
-- have quietly swallowed the crafting ranges, which assert would not catch (they
-- would just be different items with legal ids).
local ids: { [number]: string } = {}
local keys: { [string]: boolean } = {}
local kinds: { [string]: number } = {}
for _, d in itemdb.DEFS do
	check(ids[d.id] == nil, `id {d.id} used by both {tostring(ids[d.id])} and {d.key}`)
	check(not keys[d.key], `key {d.key} defined twice`)
	ids[d.id] = d.key
	keys[d.key] = true
	kinds[d.kind] = (kinds[d.kind] or 0) + 1
end

-- 3. Block ids live above every other range, so future crafting items can never
-- grow into them.
local maxNonBlock, minBlock = 0, math.huge
for _, d in itemdb.DEFS do
	if d.kind == "Block" then
		minBlock = math.min(minBlock, d.id)
	else
		maxNonBlock = math.max(maxNonBlock, d.id)
	end
end
check(minBlock > maxNonBlock,
	`block ids start at {minBlock} but a non-block item reaches {maxNonBlock}`)

-- 4. A block item must never be holdable — EquipService would try to build a Tool.
for _, d in itemdb.DEFS do
	if d.placesBlock then
		check(d.kind == "Block", `{d.key} places a block but is kind {d.kind}`)
		check(d.behavior == nil, `{d.key} is a block with a behavior ({tostring(d.behavior)})`)
	end
end

print(`{blockCount} blocks -> items; {#itemdb.DEFS} defs total`)
local order = { "Block", "Material", "Tool", "Consumable" }
for _, k in order do
	if kinds[k] then
		print(`  {kinds[k]}  {k}`)
	end
end
print(`  block ids {minBlock}..{minBlock + blockCount - 1}, everything else <= {maxNonBlock}`)

if failures > 0 then
	print(`\nFAILED — {failures} problem(s)`)
	process.exit(1)
end
print("\nPASS — every block has exactly one item, ids and keys are unique")
