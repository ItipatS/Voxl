-- Exercise the REAL WorldGen outside Roblox: is it still deterministic (server and
-- client both derive terrain from it, so a mismatch is a desync), do ore veins
-- appear at a sane rate, and does each biome grow the species we assigned it?
--   lune run tools/mcimport/test_worldgen.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

-- Read every source up front: Lune's fs is async, and reading inside a gsub
-- callback yields across a C-call boundary.
local blocksSrc = fs.readFile("src/Misc/Blocks.luau")
local worldGenSrc = fs.readFile("src/Misc/WorldGen.luau")

local env = [[
local Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end }
local Enum = setmetatable({}, { __index = function(_, k)
    return setmetatable({}, { __index = function(_, n) return { EnumItem = k .. "." .. n } end })
end })
]]

-- Swap the two Roblox requires for inline stubs, with plain string surgery.
local function replaceOnce(haystack: string, needle: string, sub: string): string
	local at = string.find(haystack, needle, 1, true)
	assert(at, `could not find "{needle}" in WorldGen.luau`)
	return string.sub(haystack, 1, at - 1) .. sub .. string.sub(haystack, at + #needle)
end

local src = replaceOnce(worldGenSrc, 'local ReplicatedStorage = game:GetService("ReplicatedStorage")', "")
src = replaceOnce(src, "local Blocks = require(ReplicatedStorage.Misc.Blocks)",
	"local Blocks = (function()\n" .. blocksSrc .. "\nend)()")
src = replaceOnce(src, "local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)",
	"local PrebakedMap = { load = function() end, open = function() end }")

local WorldGen = luau.load(env .. src, { debugName = "WorldGen" })()

-- the TEST star from std/starconfig
WorldGen.applyStarByBiomes(424242, 96, {
	{ type = "Flora", tier = 2 }, { type = "Stone", tier = 1 }, { type = "Bog", tier = 3 },
})

local failures = 0
local function check(ok: boolean, what: string)
	if not ok then
		failures += 1
		print(`  FAIL {what}`)
	end
end

-- ---- determinism: the whole client/server contract rests on this ----
for _, p in { { 37, -12 }, { -200, 88 }, { 0, 0 }, { 61, 61 } } do
	local h1, b1 = WorldGen.getColumn(p[1], p[2])
	local h2, b2 = WorldGen.getColumn(p[1], p[2])
	check(h1 == h2 and b1 == b2, `getColumn({p[1]},{p[2]}) is not stable`)
	if h1 >= 20 then
		check(
			WorldGen.blockAt(p[1], h1 - 3, p[2], h1, b1) == WorldGen.blockAt(p[1], h1 - 3, p[2], h1, b1),
			`blockAt({p[1]},{h1 - 3},{p[2]}) is not stable`
		)
	end
end

local names = {}
for n, id in WorldGen.BLOCK do
	names[id] = n
end

-- ---- sample the star ----
local counts, solid = {}, 0
for wz = -90, 90, 2 do
	for wx = -90, 90, 2 do
		local surf, biome = WorldGen.getColumn(wx, wz)
		if surf >= 0 then
			for y = 20, surf + WorldGen.TREE_MAX_H do
				local blk = WorldGen.blockAt(wx, y, wz, surf, biome)
				if blk ~= 0 then
					solid += 1
					counts[blk] = (counts[blk] or 0) + 1
				end
			end
		end
	end
end

local rows = {}
for id, n in counts do
	table.insert(rows, { id = id, n = n })
end
table.sort(rows, function(a, b)
	return a.n > b.n
end)

print(`sampled {solid} solid cells across the TEST star`)
for i = 1, math.min(#rows, 12) do
	local r = rows[i]
	print(string.format("  %8d  %6.2f%%  %s", r.n, r.n / solid * 100, names[r.id] or `?{r.id}`))
end

local ORES = { "CoalOre", "IronOre", "CopperOre", "GoldOre", "DiamondOre", "EmeraldOre", "LapisOre", "RedstoneOre" }
local oreTotal = 0
print("\nores:")
for _, o in ORES do
	local c = counts[WorldGen.BLOCK[o]] or 0
	oreTotal += c
	print(string.format("  %-12s %6d  %5.3f%%", o, c, c / solid * 100))
end
local orePct = oreTotal / solid * 100
print(string.format("  %-12s %6d  %5.2f%%", "TOTAL", oreTotal, orePct))
check(orePct > 0.3 and orePct < 12, `ore share {string.format("%.2f", orePct)}% is outside a sane 0.3-12%`)

local deep = (counts[WorldGen.BLOCK.Deepslate] or 0) / solid * 100
print(string.format("\ndeepslate: %.1f%% of solid cells", deep))
check(deep > 0, "no deepslate anywhere — the strata pass did nothing")

print("\ntree species present:")
local wood = 0
for _, w in { "OakLog", "BirchLog", "SpruceLog", "JungleLog", "AcaciaLog", "DarkOakLog" } do
	local c = counts[WorldGen.BLOCK[w]] or 0
	wood += c
	if c > 0 then
		print(`  {w}: {c}`)
	end
end
check(wood > 0, "no tree trunks generated at all")

-- ---- does the species actually follow the biome? ----
-- One star per family, so the tree table is exercised rather than assumed.
print("\nspecies by star:")
local LOGS = { "OakLog", "BirchLog", "SpruceLog", "JungleLog", "AcaciaLog", "DarkOakLog" }
for _, case in
	{
		{ label = "Frost T2 (Taiga)", biomes = { { type = "Frost", tier = 2 } }, want = "SpruceLog" },
		{ label = "Flora T3 (Jungle)", biomes = { { type = "Flora", tier = 3 } }, want = "JungleLog" },
		{ label = "Bog T4 (Mire)", biomes = { { type = "Bog", tier = 4 } }, want = "DarkOakLog" },
	}
do
	WorldGen.applyStarByBiomes(90210, 96, case.biomes)
	local seen = {}
	for wz = -70, 70, 3 do
		for wx = -70, 70, 3 do
			local surf, biome = WorldGen.getColumn(wx, wz)
			if surf >= 0 then
				for y = surf, surf + WorldGen.TREE_MAX_H do
					local blk = WorldGen.blockAt(wx, y, wz, surf, biome)
					if blk ~= 0 then
						seen[blk] = (seen[blk] or 0) + 1
					end
				end
			end
		end
	end
	local found = {}
	for _, w in LOGS do
		if (seen[WorldGen.BLOCK[w]] or 0) > 0 then
			table.insert(found, w)
		end
	end
	print(`  {case.label}: {#found > 0 and table.concat(found, ", ") or "(no trees)"}`)
	check(table.find(found, case.want) ~= nil, `{case.label} should grow {case.want}`)
end

if failures > 0 then
	print(`\n{failures} check(s) FAILED`)
	process.exit(1)
end
print("\nPASS")
