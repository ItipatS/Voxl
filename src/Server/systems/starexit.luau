-- ServerScriptService/systems/starexit.luau  (Star place)
--!strict

-- The way home. Until this existed, a player who entered a star was stuck there:
-- every teleport in the codebase pointed at the star place, `LOBBY_PLACE_ID` was
-- declared and never read once, and the only exit was closing the game.
--
-- The client asks (QuickMenu → Back → confirm prompt) and the SERVER teleports.
-- That split is not ceremony: a client that names its own teleport destination is
-- a client that can teleport anywhere, and the last client-side teleport in this
-- codebase silently dropped every hub arrival into the test star for weeks
-- (see the shape check in starworld.configure).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")

local blink = require(ServerScriptService.ServerNet)
local placemode = require(ReplicatedStorage.std.placemode)

-- One trip at a time. TeleportAsync is not instant, and a player mashing the
-- confirm button would otherwise queue several — Roblox rate-limits that, and the
-- failure lands on the player as a teleport that simply never happens.
local leaving: { [Player]: boolean } = {}

Players.PlayerRemoving:Connect(function(plr)
	leaving[plr] = nil
end)

blink.LeaveStar.On(function(plr: Player)
	if leaving[plr] then
		return
	end
	if placemode.LOBBY_PLACE_ID == 0 then
		-- An unset place id would teleport into the void of a nonexistent place.
		warn("[starexit] LOBBY_PLACE_ID is 0 — set it in std/placemode before shipping")
		blink.LeaveDenied.Fire(plr, "The Cluster is unreachable from here.")
		return
	end

	leaving[plr] = true
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placemode.LOBBY_PLACE_ID, { plr })
	end)
	if not ok then
		leaving[plr] = nil
		warn(`[starexit] could not send {plr.Name} to the lobby: {err}`)
		-- Studio is the common case here (TeleportAsync does not work in Studio),
		-- and saying so beats a button that looks broken.
		blink.LeaveDenied.Fire(plr, "Could not return to the Cluster right now.")
	end
end)

return {}
