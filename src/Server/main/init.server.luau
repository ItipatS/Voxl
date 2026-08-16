--!strict
-- Server bootstrap. Deliberately race-proof: under Rojo live-sync (and sometimes
-- normal replication) this script can run before the tree is fully populated, so
-- we WaitForChild every dependency explicitly instead of grabbing whatever happens
-- to exist at this instant.
--
-- One codebase, two places (std.placemode): each place wires only its own systems.
-- WorldStore is required directly by BlockEditServer (not a scheduler system), so
-- it's not listed here. PlayerStore (the player-profile authority: blocks + items +
-- weight) IS listed in both — the inventory must run in the Lobby too (Star Seed is
-- planted there), so we load it explicitly instead of relying on a transitive require.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Cross-tree dependencies used by std / systems.
ReplicatedStorage:WaitForChild("Packages")
ReplicatedStorage:WaitForChild("std")
ReplicatedStorage:WaitForChild("Misc")

local start = require(ReplicatedStorage.std.start)
local placemode = require(ReplicatedStorage.std:WaitForChild("placemode"))

-- LOBBY (The Cluster): stars, black hole, collectables, hosting.
local LOBBY_SYSTEMS = { "lobby", "constellation", "collectables", "asteroids", "PlayerState", "dustfield", "starentry", "players", "PrivateStarStore", "PlayerStore", "crafting", "PlantService", "EquipService", "devspawn" }
-- STAR place (= ResourceStar PlaceId): the voxel gathering world for ONE star. `starworld`
-- configures the bounded world from TeleportData + positions spawn + loads characters (so it
-- replaces the old boot-time `spawn` system).
-- EquipService is here as well as in the Lobby now: the star place runs the same
-- item hotbar, so it fires EquipItem, and without this nothing would answer it.
local RESOURCE_SYSTEMS = { "starworld", "ChunkServer", "players", "BlockEditServer", "PlayerStore", "crafting", "EquipService", "daynight" }

local SYSTEMS = if placemode.Mode == "ResourceStar" then RESOURCE_SYSTEMS else LOBBY_SYSTEMS

local systemsFolder = script.Parent:WaitForChild("systems")
local modules: { ModuleScript } = {}
for _, name in SYSTEMS do
	local module: ModuleScript = systemsFolder:FindFirstChild(name)
	if module then
		modules[#modules + 1] = module
	else
		warn(`[main] system '{name}' never appeared`)
	end
end

local ok, err = pcall(start, modules)
if not ok then
	warn("[main] start() failed:", err)
end
