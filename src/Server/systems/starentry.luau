-- ServerScriptService/systems/starentry.luau  (Lobby)
-- Server-authoritative entry to a procedural star. The client (UniverseField prompt) fires
-- EnterStar with the star's universe SLOT; we recompute the star from the seed (anti-cheat:
-- it must actually exist there this week) and check the player is near it, then teleport
-- them to the Star place with that star's world config in TeleportData. (MemoryStore
-- single-live routing — all visitors of one starId to one server — layers on here later.)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")

local blink = require(ServerScriptService.ServerNet)
local universe = require(ReplicatedStorage.std.universe)
local placemode = require(ReplicatedStorage.std.placemode)

local STAR_WORLD_RADIUS = 96 -- bounded-world island radius in blocks [TUNE]
local ENTER_RADIUS = 1600 -- must be within this of the star to enter (matches the prompt)

local function rootPos(plr: Player): Vector3?
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- EnterDenied reason codes (must match the client's iris re-open; the code is informational).
local DENY_NO_STAR = 0
local DENY_TOO_FAR = 1
local DENY_TELEPORT = 2

blink.EnterStar.On(function(plr: Player, slot)
	local star = universe.starAt(slot.cx, slot.cy, slot.cz, universe.currentWeek(os.time()))
	if not star then
		blink.EnterDenied.Fire(plr, DENY_NO_STAR) -- no star in that slot this week (anti-cheat)
		return
	end
	local pp = rootPos(plr)
	if not pp or (star.pos - pp).Magnitude > ENTER_RADIUS then
		blink.EnterDenied.Fire(plr, DENY_TOO_FAR) -- not actually near it
		return
	end

	local opts = Instance.new("TeleportOptions")
	-- Carry the full biome MIX (per-type tier) so the star world generates the exact rolled
	-- ladder rungs, not a tier-less approximation. starName drives the loading card; starTypes
	-- kept for older-client tolerance.
	-- A LANDMARK star (doc 23) carries a baked world: `starMap` names it and the star's
	-- own radius wins, since an imported map's footprint isn't ours to choose.
	opts:SetTeleportData({
		starSeed = star.seed,
		starRadius = star.radius or STAR_WORLD_RADIUS,
		starName = star.name,
		starTypes = star.types,
		starBiomes = star.biomes,
		starMap = star.map,
	})
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placemode.RESOURCE_PLACE_ID, { plr }, opts)
	end)
	if not ok then
		-- Cross-place teleport can't complete in Studio / an unpublished place — tell the client
		-- so it reverses the iris instead of sitting on a black screen.
		warn(`[starentry] teleport for {plr.Name} failed (Studio/unpublished?): {err}`)
		blink.EnterDenied.Fire(plr, DENY_TELEPORT)
	end
end)

return {}
