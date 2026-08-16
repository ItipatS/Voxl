-- Compile-check Luau sources without Studio. Lune's luau.load runs the real
-- compiler, so this catches syntax and (via --!strict) parse-level mistakes in
-- files that can't be executed outside Roblox.
--   lune run tools/mcimport/syntax.luau <file> [file ...]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local bad = 0
for _, path in process.args do
	local ok, err = pcall(function()
		luau.load(fs.readFile(path), { debugName = path })
	end)
	if ok then
		print(`  ok   {path}`)
	else
		bad += 1
		print(`  FAIL {path}\n       {err}`)
	end
end
if bad > 0 then
	print(`{bad} file(s) failed to compile`)
	process.exit(1)
end
print("all files compile")
