-- Client bootstrap. WaitForChild dependencies explicitly (Rojo live-sync can run
-- this before the tree is replicated). One codebase, two places: load the modules
-- for whichever place this is (std.placemode).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Packages")
ReplicatedStorage:WaitForChild("std")
ReplicatedStorage:WaitForChild("Misc")

local placemode = require(ReplicatedStorage.std:WaitForChild("placemode"))
local here = script.Parent

-- We drive our own hotbar/inventory + attach held Tools to the character (not the
-- Backpack), so hide Roblox's built-in backpack/inventory GUI entirely.
local StarterGui = game:GetService("StarterGui")
task.spawn(function()
	for _ = 1, 10 do
		local ok = pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false)
		if ok then
			break
		end
		task.wait(0.5)
	end
end)

local function req(name: string)
	require(here:WaitForChild(name))
end

if placemode.Mode == "ResourceStar" then
	-- RESOURCE STAR — the voxel gathering "wild" (Forest first): terrain streaming
	-- + build/gather. (Biome-locking + regional seed come next.)
	req("StarWorld") -- configure WorldGen for this star's bounded world BEFORE terrain generates
	req("ChunkClient")
	req("StarFly") -- F to fly: the only practical way to survey an 896-block map
	req("Prompts") -- styled ProximityPrompt UI (expressive-prompts) for world interactions
	req("UI") -- the UI framework (Controller/Sound/Tween/Notifier + registry bootstrap) — doc 19
	-- ONE inventory, the same one the lobby uses. The star place used to run its own
	-- (BlockInventory/Hotbar/InventoryRender over a hardcoded 7-block palette), which
	-- is why your inventory looked different depending on which place you were in.
	-- Blocks are items now (itemdb `block_<id>`), so these modules cover them too.
	req("ItemMirror") -- item inventory + weight mirror (doc 17)
	req("ItemInventory") -- the 45-slot grid + weight bar
	req("ItemHotbar") -- slots 1-9; also selects the block BlockEdit places
	req("HeldTools") -- held-tool activation → behavior + particle distance-LOD (doc 20)
	req("BlockEdit")
	req("LockController")
	req("StarExit") -- QuickMenu > Back > confirm > back to the Cluster
	-- The LOBBY's camera, on the ground. Not a nicety: Roblox's default camera
	-- claims the scroll wheel for zoom, so the hotbar never sees it and 1-9 becomes
	-- the only way to change slots. T toggles first person; Alt+scroll zooms.
	req("CameraController")
	req("Music") -- same shuffle playlist as the lobby (SoundService.Musics)
	req("DayNight") -- server clock -> Lighting.ClockTime (the lobby is permanent night)
else
	-- LOBBY (The Cluster) — zero-g jet flight, stars, black hole, collectables.
	req("FlightController")
	req("FlightStun") -- asteroid-hit response (stun/knockback/flash); FlightController consults it
	req("CameraController") -- custom shiftlock camera (scroll→hotbar, alt+scroll→zoom)
	req("DustField") -- seed-derived collectable star dust (auto-collect → star fuel); replaces StarField
	req("StarRenderer")
	req("AsteroidRenderer") -- streamed moving asteroid hazards (server-authoritative)
	req("SpaceProxies")
	req("MawWarning") -- ominous void-zone sphere at the maw (dust/stars stop generating inside it)
	req("UniverseField") -- procedural star frontier (std/universe): tier-coloured orbs, cell load/unload
	req("Prompts") -- styled ProximityPrompt UI (expressive-prompts) — Init before prompts exist
	req("UI") -- the UI framework (Controller/Sound/Tween/Notifier + registry bootstrap) — doc 19
	req("ZoneWatcher") -- announces biome/zone changes as you fly
	req("ItemMirror") -- item inventory + weight mirror; Star Seed planting lives here (doc 17)
	req("ItemInventory") -- item slots + weight bar (Star Seed lives here)
	req("ItemHotbar") -- Tool items in the hotbar; 1-9/click select → equip (doc 20)
	req("HeldTools") -- held-tool activation → behavior + particle distance-LOD (doc 20)
	req("CreatePlanetController") -- the "name your star" prompt (input↔confirm states)
	req("PlantingController") -- Star Seed → planet overlay on the grid → plant (doc 18)
	req("Music")
end
