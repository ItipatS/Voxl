--!strict
-- One codebase, two published places (doc 13). `game.PlaceId` picks the mode; a
-- Studio override lets us test either mode without publishing. Both client and
-- server require this (it's shared std) so they always agree on the mode.
--
-- Setup: paste the two PlaceIds below (Creator Hub → place → ⋯ → Copy ID). While
-- an id is 0 it's ignored, so we fall back to the Studio override / Lobby default.

local RunService = game:GetService("RunService")

export type Mode = "Lobby" | "ResourceStar"

local LOBBY_PLACE_ID: number = 126553668196124
local RESOURCE_PLACE_ID: number = 135120092161486

-- In Studio, force a mode for testing (nil = use PlaceId). Flip to "ResourceStar"
-- to boot the Forest gathering world without publishing.
local STUDIO_OVERRIDE: Mode? = "Lobby"

local function resolve(): Mode
	if RunService:IsStudio() and STUDIO_OVERRIDE ~= nil then
		return STUDIO_OVERRIDE
	end
	if RESOURCE_PLACE_ID ~= 0 and game.PlaceId == RESOURCE_PLACE_ID then
		return "ResourceStar"
	end
	return "Lobby" -- the lobby place, or any unset id during setup
end

return {
	Mode = resolve() :: Mode,
	LOBBY_PLACE_ID = LOBBY_PLACE_ID,
	RESOURCE_PLACE_ID = RESOURCE_PLACE_ID,
}
