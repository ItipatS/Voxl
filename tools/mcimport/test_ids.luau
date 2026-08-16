-- Blocks.luau and tools/mcimport/voxlids.js must produce byte-identical block ids.
-- Baked maps store RAW ids, so any drift between the two silently turns a map's
-- roofs into wool or its water into stone. This runs the REAL Blocks.luau (with
-- Roblox globals stubbed) and diffs its ID table against the JS one.
--   lune run tools/mcimport/test_ids.luau <ids.json>

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local expectedFile = process.args[1]
assert(expectedFile, "usage: lune run test_ids.luau <ids.json>")

-- Roblox globals Blocks.luau touches: Color3.fromRGB and Enum.Material.*
local env = [[
local Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end,
                 new = function(r, g, b) return { r = r, g = g, b = b } end }
local Enum = setmetatable({}, { __index = function(_, k)
    return setmetatable({}, { __index = function(_, n) return { EnumItem = k .. "." .. n } end })
end })
]]
local src = fs.readFile("src/Misc/Blocks.luau")
local Blocks = luau.load(env .. src, { debugName = "Blocks" })()

local expected = serde.decode("json", fs.readFile(expectedFile))

local bad, n = 0, 0
for name, id in expected do
	n += 1
	if Blocks.ID[name] ~= id then
		bad += 1
		print(`  MISMATCH {name}: Blocks.luau has {tostring(Blocks.ID[name])}, voxlids.js has {id}`)
	end
end
for name, id in Blocks.ID do
	if expected[name] == nil then
		bad += 1
		print(`  EXTRA in Blocks.luau: {name} = {id}`)
	end
end

-- every id must also have a def, or the mesher paints it magenta
local missingDefs = {}
for name, id in Blocks.ID do
	if id ~= 0 and Blocks.defs[id] == nil then
		table.insert(missingDefs, name)
	end
end
if #missingDefs > 0 then
	bad += #missingDefs
	print(`  ids with no block def: {table.concat(missingDefs, ", ")}`)
end

if bad == 0 then
	print(`PASS — {n} block ids agree, all have defs`)
else
	print(`FAIL — {bad} problem(s)`)
	process.exit(1)
end
