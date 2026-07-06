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

blink.EnterStar.On(function(plr: Player, slot)
	local star = universe.starAt(slot.cx, slot.cy, slot.cz, universe.currentWeek(os.time()))
	if not star then
		return -- no star in that slot this week → ignore (anti-cheat)
	end
	local pp = rootPos(plr)
	if not pp or (star.pos - pp).Magnitude > ENTER_RADIUS then
		return -- not actually near it
	end

	local opts = Instance.new("TeleportOptions")
	opts:SetTeleportData({ starSeed = star.seed, starRadius = STAR_WORLD_RADIUS, starTypes = star.types })
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placemode.RESOURCE_PLACE_ID, { plr }, opts)
	end)
	if not ok then
		warn(`[starentry] teleport for {plr.Name} failed (Studio/unpublished?): {err}`)
	end
end)

return {}
