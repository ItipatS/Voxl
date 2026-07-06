--!strict
-- Authoritative handler for planting a private star (Blink PlantStar → doc 18).
-- The client only PROPOSES a name + grid cell; everything is re-validated here:
--   1. player hasn't already planted (one star each)
--   2. player actually holds a Star Seed
--   3. name passes the same sanity rules as the client
--   4. the cell (rebuilt from indices, not a trusted position) is plantable
--   5. name + cell are globally unclaimed (PlanetRegistry, atomic)
-- Only then does it commit (plot + biome + name) and consume the seed, replying
-- PlantStarResult either way so the prompt's log can show the reason.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local planting = require(ReplicatedStorage.std.planting)
local constellation = require(ReplicatedStorage.std.constellation)
local PrivateStarStore = require(script.Parent.PrivateStarStore)
local PlayerStore = require(script.Parent.PlayerStore)
local PlanetRegistry = require(script.Parent.PlanetRegistry)

local SEED_KEY = "star_seed"

-- Server-side name sanity (mirrors CreatePlanetController.validate). Returns the
-- trimmed name or nil.
local function cleanName(raw: string): string?
	local name = (raw:gsub("^%s+", ""):gsub("%s+$", ""))
	if #name < 3 or #name > 18 then
		return nil
	end
	if not name:match("^[%w %-']+$") then
		return nil
	end
	return name
end

-- Nearest resource star's biome (LANDMARKS template minus "Star"): a planted star
-- inherits its neighbour's biome.
local function nearestBiome(pos: Vector3): string
	local best, bestD = "", math.huge
	for _, lm in constellation.LANDMARKS do
		if lm.template ~= "BlackHole" then
			local d = (pos - lm.pos).Magnitude
			if d < bestD then
				bestD = d
				best = (lm.template :: string):gsub("Star$", "")
			end
		end
	end
	return best
end

blink.PlantStar.On(function(player: Player, req: { name: string, cx: number, cz: number })
	local function reply(ok: boolean, reason: string?)
		blink.PlantStarResult.Fire(player, { ok = ok, reason = reason or "" })
	end

	if PrivateStarStore.isPlanted(player.UserId) then
		return reply(false, "You already have a star.")
	end
	if PlayerStore.itemCount(player, SEED_KEY) < 1 then
		return reply(false, "You have no Star Seed.")
	end

	local name = cleanName(req.name)
	if not name then
		return reply(false, "Invalid name.")
	end

	local center = planting.centerFromIndex(req.cx, req.cz)
	center = Vector3.new(center.X, constellation.CENTER.Y, center.Z)
	if not planting.isPlantable(center) then
		return reply(false, "You can't plant there.")
	end
	local cellKey = planting.cellKey(center)

	-- Reserve name first, then cell; roll the name back if the cell is taken.
	if not PlanetRegistry.reserveName(name, player.UserId) then
		return reply(false, `"{name}" is already taken.`)
	end
	if not PlanetRegistry.reserveCell(cellKey, player.UserId) then
		PlanetRegistry.releaseName(name, player.UserId)
		return reply(false, "That spot is already taken.")
	end

	local biome = nearestBiome(center)
	if not PrivateStarStore.plant(player.UserId, center.X, center.Y, center.Z, biome, name) then
		PlanetRegistry.releaseName(name, player.UserId)
		PlanetRegistry.releaseCell(cellKey, player.UserId)
		return reply(false, "Couldn't plant right now.")
	end

	PlayerStore.consumeItem(player, SEED_KEY, 1)
	reply(true, name)
end)

return {}
