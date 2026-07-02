--!strict
-- Server bootstrap. Deliberately race-proof: under Rojo live-sync (and sometimes
-- normal replication) this script can run before the tree is fully populated, so
-- we WaitForChild every dependency explicitly instead of grabbing whatever happens
-- to exist at this instant. In particular, `systems:GetChildren()` at boot can be
-- empty/partial — which silently wires 0 systems — so we wait for each system by
-- name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Cross-tree dependencies used by std / systems.
ReplicatedStorage:WaitForChild("Packages")
ReplicatedStorage:WaitForChild("std")
ReplicatedStorage:WaitForChild("Misc")

local start = require(ReplicatedStorage.std.start)

-- Every server system, waited for by name so a partially-synced `systems` folder
-- can never wire an incomplete set. Add new systems here.
-- WorldStore is a service required directly by BlockEditServer (not a scheduler
-- system), so it's not listed here.
local SYSTEMS = { "ChunkServer", "players", "spawn", "BlockEditServer" }

local systemsFolder = script.Parent:WaitForChild("systems")
local modules: { ModuleScript } = {}
for _, name in SYSTEMS do
	local module = systemsFolder:WaitForChild(name, 30) :: ModuleScript?
	if module then
		modules[#modules + 1] = module
	else
		warn(`[main] system '{name}' never appeared (WaitForChild timed out)`)
	end
end

local ok, err = pcall(start, modules)
if not ok then
	warn("[main] start() failed:", err)
end
