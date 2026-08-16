-- Runs the REAL src/Misc/PrebakedMap.luau (via Lune) against the REAL baked data
-- and checks every sampled column against what Minecraft actually had there.
-- This is the only test that exercises the whole pipe end to end outside Studio:
--   .mca → bake.js → base64 modules → PrebakedMap → columnTop/blockAt
--
--   lune run tools/mcimport/test_reader.luau <mapDir> <samples.json>

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local mapDir = process.args[1]
local samplesFile = process.args[2]
assert(mapDir and samplesFile, "usage: lune run test_reader.luau <mapDir> <samples.json>")

-- ---- load PrebakedMap with its Roblox requires stubbed (inflate is inlined) ----
local inflateSrc = fs.readFile("src/Misc/inflate.luau")
local src = fs.readFile("src/Misc/PrebakedMap.luau")
src = src:gsub('local ReplicatedStorage = game:GetService%("ReplicatedStorage"%)\n', "")
src = src:gsub(
	"local Blocks = require%(ReplicatedStorage%.Misc%.Blocks%)",
	function()
		return "local Blocks = { ID = { Stone = 4 } }"
	end
)
src = src:gsub("local Inflate = require%(ReplicatedStorage%.Misc%.inflate%)", function()
	return "local Inflate = (function()\n" .. inflateSrc .. "\nend)()"
end)
local PrebakedMap = luau.load(src, { debugName = "PrebakedMap" })()

-- ---- rebuild the Source table from the generated modules ----
local init = fs.readFile(mapDir .. "/init.luau")
local radius = tonumber(init:match("radius = (%d+)")) :: number
local partLen = tonumber(init:match("partLen = (%d+)")) :: number
local spawnX = tonumber(init:match("spawn = { x = (-?%d+)"))
local nParts = 0
for _ in init:gmatch("require%(script%.p%d+%)") do
	nParts += 1
end

local parts = {}
for i = 1, nParts do
	local text = fs.readFile(`{mapDir}/p{i}.luau`)
	parts[i] = text:match("%[==%[(.-)%]==%]") :: string
	assert(parts[i], `p{i}.luau: no base64 payload`)
end
print(`loaded {nParts} parts, partLen {partLen}, radius {radius}, spawn.x {spawnX}`)
for i = 1, nParts - 1 do
	assert(#parts[i] == partLen, `part {i} is {#parts[i]} chars, expected {partLen}`)
end
assert(partLen % 4 == 0, "partLen must be a multiple of 4 or a base64 group straddles two parts")

local t0 = os.clock()
local map = PrebakedMap.open({ name = "test", radius = radius, partLen = partLen, parts = parts })
print(`header + index decoded in {string.format("%.1f", (os.clock() - t0) * 1000)} ms`)
print(
	`meta: grid {map.meta.nx}×{map.meta.nz} from ({map.meta.cx0},{map.meta.cz0}), `
		.. `radius {map.meta.radius}, yFloor {map.meta.yFloor}`
)
assert(PrebakedMap.decodeMeta(PrebakedMap.encodeMeta(map.meta)).nx == map.meta.nx, "meta round-trip broke")

-- ---- compare against the Minecraft source ----
local samples = serde.decode("json", fs.readFile(samplesFile))
local checked, colMismatch, blockMismatch, voidCols, clippedCols = 0, 0, 0, 0, 0
local firstFail: string? = nil

t0 = os.clock()
for _, s in samples do
	local top = map.columnTop(s.x, s.z)
	if top < 0 then
		voidCols += 1
		continue
	end
	checked += 1

	-- Read the baked column back as top-down runs, stopping at the world floor.
	local got: { { number } } = {}
	local y = top
	while y >= map.yFloor do
		local id = map.blockAt(s.x, y, s.z)
		local last = got[#got]
		if last and last[1] == id then
			last[2] += 1
		else
			got[#got + 1] = { id, 1 }
		end
		y -= 1
	end
	-- Below the island's keel is open air, so the walk down to the world floor picks
	-- up a trailing air run that is not part of the column at all. Drop it, or every
	-- column looks like it has one run too many.
	while #got > 0 and got[#got][1] == 0 do
		got[#got] = nil
	end

	local clippedHere = (top - map.yFloor + 1) < 0

	-- Compare run for run. SOLID runs must match exactly — same block, same
	-- thickness, same order. AIR runs may be shorter than the source's, because
	-- compaction squashes globally-empty bands; they may never be longer.
	local i = 1
	for _, want in s.runs do
		local have = got[i]
		if have == nil then
			clippedHere = true -- ran past the floor; the rest is island interior
			break
		end
		if want[1] ~= have[1] then
			blockMismatch += 1
			if not firstFail then
				firstFail = `({s.x}, {s.z}) run {i}: expected id {want[1]}×{want[2]}, got id {have[1]}×{have[2]}`
			end
			break
		end
		local exact = if want[1] == 0 then have[2] <= want[2] else have[2] == want[2]
		-- the deepest run we could read may be cut short by the world floor
		if not exact and i < #got then
			blockMismatch += 1
			if not firstFail then
				firstFail = `({s.x}, {s.z}) run {i} (id {want[1]}): expected {want[2]} thick, got {have[2]}`
			end
			break
		end
		i += 1
	end

	-- ...and nothing floats above the reported top.
	if map.blockAt(s.x, top + 1, s.z) ~= 0 then
		colMismatch += 1
		if not firstFail then
			firstFail = `({s.x}, {top + 1}, {s.z}): block above the column top is not air`
		end
	end
	if clippedHere then
		clippedCols += 1
	end
end
local ms = (os.clock() - t0) * 1000
print(`checked {checked} columns in {string.format("%.0f", ms)} ms ({voidCols} void, outside the disc or clipped)`)
print(`  column-top errors: {colMismatch}`)
print(`  block mismatches:  {blockMismatch}`)
print(`  clipped at floor:  {clippedCols} ({string.format("%.1f", clippedCols / math.max(1, checked) * 100)}% — shell tail below y {map.yFloor} became island interior)`)
if firstFail then
	print(`  first failure: {firstFail}`)
end
-- ---- the STREAMING path: server hands out records, a fresh client rebuilds ----
-- This is what actually runs in game. The server never decompresses to forward, and
-- the client starts with nothing, so if the wire format were wrong the receiver
-- would disagree with the server here.
do
	local rx = PrebakedMap.receiver(map.meta)
	local fed, bytes = 0, 0
	local touched: { { number } } = {}
	for _, s in samples do
		local cx, cz = s.x // 16, s.z // 16
		local seen = false
		for _, t in touched do
			if t[1] == cx and t[2] == cz then
				seen = true
				break
			end
		end
		if seen then
			continue
		end
		touched[#touched + 1] = { cx, cz }
		local data, raw = map.record(cx, cz)
		if data then
			rx.feed(cx, cz, data, raw)
			fed += 1
			bytes += buffer.len(data)
		end
	end

	local diff = 0
	for _, s in samples do
		if map.columnTop(s.x, s.z) ~= rx.columnTop(s.x, s.z) then
			diff += 1
			continue
		end
		local top = rx.columnTop(s.x, s.z)
		for y = math.max(rx.yFloor, top - 40), top do
			if map.blockAt(s.x, y, s.z) ~= rx.blockAt(s.x, y, s.z) then
				diff += 1
				break
			end
		end
	end
	print(
		`streaming: fed {fed} chunks ({math.round(bytes / fed)} B avg compressed), `
			.. `{diff} disagreement(s) with the server's own view`
	)
	if diff > 0 then
		colMismatch += diff
		firstFail = firstFail or "receiver disagreed with the server after feeding records"
	end

	-- a dropped chunk must actually go away (the client frees terrain it can't see)
	local c0 = touched[1]
	rx.drop(c0[1], c0[2])
	local stillThere = false
	for lz = 0, 15 do
		for lx = 0, 15 do
			if rx.columnTop(c0[1] * 16 + lx, c0[2] * 16 + lz) >= 0 then
				stillThere = true
			end
		end
	end
	if stillThere then
		colMismatch += 1
		firstFail = firstFail or "drop() left the chunk behind"
	end
end

-- ---- what the mesher will actually have to chew through ----
-- The mesher builds a grid of 18×18×span per chunk, so span is its cost. Compare
-- the naive floor (the world floor) with the per-chunk floor the baked index gives.
local n, naive, smart, worst = 0, 0, 0, 0
t0 = os.clock()
for cz = -radius // 16, radius // 16, 3 do
	for cx = -radius // 16, radius // 16, 3 do
		local top = -1
		for lz = 0, 15, 3 do
			for lx = 0, 15, 3 do
				local t = map.columnTop(cx * 16 + lx, cz * 16 + lz)
				if t > top then
					top = t
				end
			end
		end
		if top < 0 then
			continue
		end
		n += 1
		naive += top - map.yFloor + 1
		local span = top - map.chunkFloor(cx, cz) + 1
		smart += span
		if span > worst then
			worst = span
		end
	end
end
if n > 0 then
	print(
		`mesh span over {n} chunks: {math.round(naive / n)} levels from the world floor `
			.. `→ {math.round(smart / n)} from the per-chunk floor (worst {worst}), `
			.. `{string.format("%.0f", (os.clock() - t0) * 1000)} ms to walk them`
	)
end

if colMismatch == 0 and blockMismatch == 0 and checked > 0 then
	print("PASS — the baked world matches the Minecraft source")
else
	print("FAIL")
	process.exit(1)
end
