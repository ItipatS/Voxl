-- Hammer src/Misc/inflate.luau against streams deflated by Node's zlib.
-- Cases are chosen to hit every DEFLATE block type: incompressible random data
-- (stored blocks), tiny inputs (fixed Huffman), and real map records (dynamic
-- Huffman with long match runs).
--   lune run tools/mcimport/test_inflate.luau <cases.json>

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local casesFile = process.args[1]
assert(casesFile, "usage: lune run test_inflate.luau <cases.json>")

local src = fs.readFile("src/Misc/inflate.luau")
local Inflate = luau.load(src, { debugName = "inflate" })()

local function fromBase64(s: string): buffer
	-- Lune has serde.decode for json but not base64 → do it here; the cases file
	-- is base64 because JSON can't carry raw bytes.
	local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lut = {}
	for i = 1, 64 do
		lut[string.byte(ALPHA, i)] = i - 1
	end
	local clean = s:gsub("=", "")
	local n = #clean
	local out = buffer.create((n * 3) // 4)
	local at = 0
	local acc, accBits = 0, 0
	for i = 1, n do
		acc = acc * 64 + lut[string.byte(clean, i)]
		accBits += 6
		if accBits >= 8 then
			accBits -= 8
			local byte = acc // (2 ^ accBits)
			buffer.writeu8(out, at, byte % 256)
			at += 1
			acc = acc % (2 ^ accBits)
		end
	end
	return out
end

local cases = serde.decode("json", fs.readFile(casesFile))
local pass, fail = 0, 0
local totalIn, totalOut, t0 = 0, 0, os.clock()

for _, c in cases do
	local input = fromBase64(c.deflated)
	local expected = fromBase64(c.raw)
	local ok, got = pcall(Inflate.raw, input, c.size)
	if not ok then
		fail += 1
		print(`  FAIL {c.name}: {got}`)
		continue
	end
	if buffer.len(got) ~= c.size then
		fail += 1
		print(`  FAIL {c.name}: got {buffer.len(got)} bytes, expected {c.size}`)
		continue
	end
	local bad = -1
	for i = 0, c.size - 1 do
		if buffer.readu8(got, i) ~= buffer.readu8(expected, i) then
			bad = i
			break
		end
	end
	if bad >= 0 then
		fail += 1
		print(
			`  FAIL {c.name}: byte {bad} is {buffer.readu8(got, bad)}, expected {buffer.readu8(expected, bad)}`
		)
	else
		pass += 1
		totalIn += buffer.len(input)
		totalOut += c.size
	end
end

local ms = (os.clock() - t0) * 1000
print(`{pass} passed, {fail} failed`)
if pass > 0 then
	print(
		`inflated {totalOut} bytes from {totalIn} in {string.format("%.0f", ms)} ms `
			.. `({string.format("%.1f", totalOut / 1024 / (ms / 1000))} KB/s)`
	)
end
if fail > 0 then
	process.exit(1)
end
print("PASS")
