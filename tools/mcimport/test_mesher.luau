-- Run the REAL greedy mesher against a synthetic voxel field and check its output.
--
-- Doubled parts are close to invisible in game — the world looks right and the
-- frame rate quietly dies — so the only way to know is to collect every box it
-- emits and test them against each other. Two boxes that share any volume is a bug
-- by definition: every cell must be covered at most once.
--
--   lune run tools/mcimport/test_mesher.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

-- ---- Roblox stubs, enough to load Mesher ----
local env = [[
local Vector3 = { new = function(x, y, z) return { X = x or 0, Y = y or 0, Z = z or 0 } end }
Vector3.one = Vector3.new(1, 1, 1)
local Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end,
                 new = function(r, g, b) return { r = r, g = g, b = b } end }
local CFrame = { new = function(...) return { ... } end, lookAt = function(...) return { ... } end }
local Enum = setmetatable({}, { __index = function(_, k)
    return setmetatable({}, { __index = function(_, n) return { EnumItem = k .. "." .. n } end })
end })
local Instance = { new = function() return { Parent = nil, Destroy = function() end,
    GetChildren = function() return {} end, IsA = function() return false end } end }
]]

local blocksSrc = fs.readFile("src/Misc/Blocks.luau")
local mesherSrc = fs.readFile("src/Misc/Mesher.luau")

-- ---- a synthetic world, so the terrain under test is known exactly ----
-- Flat ground with a hill, a floating slab, and a cave: enough shapes that a merge
-- bug in any axis has somewhere to show up.
local FAKE_WORLDGEN = [[
local WorldGen = {}
WorldGen.CHUNK_SIZE = 16
WorldGen.WORLD_HEIGHT = 256
WorldGen.BLOCK_SIZE = 3.5
WorldGen.CAVE_START_Y = 20
WorldGen.TREE_MAX_H = 0
WorldGen.TREE_BIOMES = {}
WorldGen.BLOCK = Blocks.ID
local GRASS, DIRT, STONE, AIR = Blocks.ID.Grass, Blocks.ID.Dirt, Blocks.ID.Stone, 0

local function surfaceOf(wx, wz)
    local h = 40
    -- a hill, so columns differ in height (tests vertical merging)
    local dx, dz = wx - 8, wz - 8
    local d2 = dx * dx + dz * dz
    if d2 < 49 then h = 46 end
    return h
end

function WorldGen.getColumn(wx, wz)
    return surfaceOf(wx, wz), 1
end
function WorldGen.getSurfaceHeight(wx, wz)
    return (surfaceOf(wx, wz))
end
function WorldGen.biomeGrassColor()
    return nil
end
function WorldGen.meshFloor()
    return 28
end
function WorldGen.blockAt(wx, y, wz, surfaceY, biomeId)
    if y > surfaceY then
        -- a floating slab above the ground: an island with air under it
        if y >= 60 and y <= 61 and wx >= 2 and wx <= 12 and wz >= 2 and wz <= 12 then
            return STONE
        end
        return AIR
    end
    -- a cave carved through the middle
    if y >= 33 and y <= 35 and wz >= 4 and wz <= 11 then
        return AIR
    end
    if y == surfaceY then return GRASS end
    if surfaceY - y <= 3 then return DIRT end
    return STONE
end
return WorldGen
]]

local FAKE_WORLDDIFF = [[
local WorldDiff = {}
function WorldDiff.blockAt(wx, y, wz, s, b) return WorldGen.blockAt(wx, y, wz, s, b) end
function WorldDiff.chunkHasEdits() return false end
function WorldDiff.chunkYBounds() return nil, nil end
return WorldDiff
]]

local function replaceOnce(hay: string, needle: string, sub: string): string
	local at = string.find(hay, needle, 1, true)
	assert(at, `could not find "{needle}"`)
	return string.sub(hay, 1, at - 1) .. sub .. string.sub(hay, at + #needle)
end

local src = replaceOnce(mesherSrc, 'local ReplicatedStorage = game:GetService("ReplicatedStorage")', "")
src = replaceOnce(src, "local WorldGen = require(ReplicatedStorage.Misc.WorldGen)",
	"local Blocks = (function()\n" .. blocksSrc .. "\nend)()\n"
		.. "local WorldGen = (function()\n" .. FAKE_WORLDGEN .. "\nend)()")
src = replaceOnce(src, "local Blocks = require(ReplicatedStorage.Misc.Blocks)", "")
src = replaceOnce(src, "local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)",
	"local WorldDiff = (function()\n" .. FAKE_WORLDDIFF .. "\nend)()")

local Mesher = luau.load(env .. src, { debugName = "Mesher" })()
local BLOCK = 3.5

-- ---- collect the boxes for one chunk ----
type Box = { x0: number, x1: number, y0: number, y1: number, z0: number, z1: number, id: number }

local function boxesFor(cx: number, cz: number): { Box }
	local out: { Box } = {}
	Mesher._runGreedy3D({ cx = cx, cz = cz }, function(id, size, centre)
		-- back from studs to whole cells, so overlap maths is exact integers
		local hw, hh, hd = size.X / BLOCK / 2, size.Y / BLOCK / 2, size.Z / BLOCK / 2
		local x = centre.X / BLOCK
		local y = centre.Y / BLOCK
		local z = centre.Z / BLOCK
		out[#out + 1] = {
			x0 = math.round(x - hw), x1 = math.round(x + hw),
			y0 = math.round(y - hh), y1 = math.round(y + hh),
			z0 = math.round(z - hd), z1 = math.round(z + hd),
			id = id,
		}
	end)
	return out
end

local function overlaps(a: Box, b: Box): boolean
	return a.x0 < b.x1 and b.x0 < a.x1
		and a.y0 < b.y1 and b.y0 < a.y1
		and a.z0 < b.z1 and b.z0 < a.z1
end

-- ---- the same audit against the REAL imported map ----
-- The synthetic field proves the algorithm; this proves the data. A chunk of real
-- terrain is where an exploded part count actually shows up.
local function auditRealMap()
	local dir = "src/ServerStorage/MapData/FantasyMedieval"
	if not fs.isDir(dir) then
		return
	end
	local inflateSrc = fs.readFile("src/Misc/inflate.luau")
	local prebakedSrc = fs.readFile("src/Misc/PrebakedMap.luau")
	local worldGenSrc = fs.readFile("src/Misc/WorldGen.luau")
	local initSrc = fs.readFile(dir .. "/init.luau")
	local nParts = 0
	for _ in string.gmatch(initSrc, "require%(script%.p%d+%)") do
		nParts += 1
	end
	local partsLiteral = {}
	for i = 1, nParts do
		local text = fs.readFile(`{dir}/p{i}.luau`)
		partsLiteral[i] = "[==[" .. (string.match(text, "%[==%[(.-)%]==%]") :: string) .. "]==]"
	end

	local pre = replaceOnce(prebakedSrc, 'local ReplicatedStorage = game:GetService("ReplicatedStorage")', "")
	pre = replaceOnce(pre, "local Blocks = require(ReplicatedStorage.Misc.Blocks)", "local Blocks = BLOCKS_IN")
	pre = replaceOnce(pre, "local Inflate = require(ReplicatedStorage.Misc.inflate)",
		"local Inflate = (function()\n" .. inflateSrc .. "\nend)()")

	local wg = replaceOnce(worldGenSrc, 'local ReplicatedStorage = game:GetService("ReplicatedStorage")', "")
	wg = replaceOnce(wg, "local Blocks = require(ReplicatedStorage.Misc.Blocks)", "local Blocks = BLOCKS_IN")
	wg = replaceOnce(wg, "local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)",
		"local PrebakedMap = (function()\n" .. pre .. "\nend)()")

	-- PrebakedMap is built in the OUTER scope and handed to WorldGen, rather than
	-- reached into from inside its closure.
	wg = replaceOnce(wg, "local PrebakedMap = (function()\n" .. pre .. "\nend)()", "local PrebakedMap = PREBAKED_OUT")

	local realSrc = replaceOnce(mesherSrc, 'local ReplicatedStorage = game:GetService("ReplicatedStorage")', "")
	realSrc = replaceOnce(realSrc, "local WorldGen = require(ReplicatedStorage.Misc.WorldGen)",
		"local BLOCKS_IN = (function()\n" .. blocksSrc .. "\nend)()\n"
			.. "local Blocks = BLOCKS_IN\n"
			.. "local PREBAKED_OUT = (function()\n" .. pre .. "\nend)()\n"
			.. "local WorldGen = (function()\n" .. wg .. "\nend)()\n"
			.. "WorldGen.applyPrebaked(PREBAKED_OUT.open("
			.. "{ name = 'test', radius = 448, partLen = 200000, parts = PARTS }))")
	realSrc = replaceOnce(realSrc, "local Blocks = require(ReplicatedStorage.Misc.Blocks)", "")
	realSrc = replaceOnce(realSrc, "local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)",
		"local WorldDiff = (function()\n" .. FAKE_WORLDDIFF .. "\nend)()")

	local prelude = "local PARTS = {\n" .. table.concat(partsLiteral, ",\n") .. "\n}\n"

	local BLOCKS: any = nil
	local ok, RealMesher = pcall(function()
		local exposed = replaceOnce(realSrc, "return ChunkMesher", "ChunkMesher._blocks = BLOCKS_IN\nreturn ChunkMesher")
		return luau.load(env .. prelude .. exposed, { debugName = "MesherReal" })()
	end)
	if ok then
		BLOCKS = RealMesher._blocks
	end
	if not ok then
		print(`\n(real-map audit skipped: {RealMesher})`)
		return
	end

	local byId: { [number]: number } = {}
	local casters = 0
	local boxes, chunks, worst, worstKey = 0, 0, 0, ""
	for cz = -3, 3 do
		for cx = -3, 3 do
			local n = 0
			RealMesher._runGreedy3D({ cx = cx, cz = cz }, function(id, _size, _c, _px, _nx, ePY)
				n += 1
				byId[id] = (byId[id] or 0) + 1
				if ePY then casters += 1 end
			end)
			if n > 0 then
				chunks += 1
				boxes += n
				if n > worst then
					worst, worstKey = n, `{cx},{cz}`
				end
			end
		end
	end
	if chunks > 0 then
		print(`\nreal map: {chunks} chunks -> {boxes} boxes ({math.round(boxes / chunks)} avg, worst {worst} at {worstKey})`)
		-- Why terrain shadows are off entirely rather than filtered: this is the best
		-- the sky-facing rule can do, and it is not close to enough.
		print(`  sky-facing: {casters} of {boxes} ({math.round(casters / boxes * 100)}%) — the ceiling for TERRAIN_CASTS_SHADOW`)
		local names = {}
		for n, id in BLOCKS.ID do
			names[id] = n
		end
		local rows = {}
		for id, n in byId do
			table.insert(rows, { id = id, n = n })
		end
		table.sort(rows, function(a, b)
			return a.n > b.n
		end)
		print("  boxes by block:")
		for i = 1, math.min(#rows, 10) do
			local r = rows[i]
			print(string.format("    %6d  %5.1f%%  %s", r.n, r.n / boxes * 100, names[r.id] or `?{r.id}`))
		end
	end
end

local totalBoxes, totalOverlaps = 0, 0
local worstExample: string? = nil

for cz = 0, 1 do
	for cx = 0, 1 do
		local boxes = boxesFor(cx, cz)
		totalBoxes += #boxes
		for i = 1, #boxes do
			for j = i + 1, #boxes do
				if overlaps(boxes[i], boxes[j]) then
					totalOverlaps += 1
					if not worstExample then
						local a, b = boxes[i], boxes[j]
						worstExample = string.format(
							"chunk (%d,%d): [%d..%d, %d..%d, %d..%d] id=%d  overlaps  [%d..%d, %d..%d, %d..%d] id=%d",
							cx, cz, a.x0, a.x1, a.y0, a.y1, a.z0, a.z1, a.id,
							b.x0, b.x1, b.y0, b.y1, b.z0, b.z1, b.id
						)
					end
				end
			end
		end
	end
end

print(`4 chunks meshed -> {totalBoxes} boxes ({math.round(totalBoxes / 4)} per chunk)`)
print(`overlapping pairs: {totalOverlaps}`)
if worstExample then
	print(`  e.g. {worstExample}`)
end

auditRealMap()

if totalOverlaps > 0 then
	print("\nFAIL — the mesher emits boxes that share volume (doubled parts)")
	process.exit(1)
end
print("\nPASS — every cell is covered at most once")
