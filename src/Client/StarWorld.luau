--!strict
-- Star place (client): configure WorldGen for this star's bounded world BEFORE ChunkClient
-- generates any terrain, using the server-published config so the client's terrain matches
-- the server's spawn/collision view. Required first in the ResourceStar branch of main.client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local starconfig = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("starconfig"))

-- Wait briefly for the server to publish the star config (else fall back to the TEST star).
local t0 = os.clock()
while ReplicatedStorage:GetAttribute("StarSeed") == nil and os.clock() - t0 < 3 do
	task.wait(0.05)
end

-- One call covers both worlds a star can be: a rolled procedural island (derived
-- locally from the seed, nothing on the wire), or a BAKED one imported from a real
-- map (doc 23), which starts empty here and fills in as ChunkClient receives the
-- chunks the player actually walks into.
local cfg = starconfig.get()
local map = starconfig.applyClient(cfg)

if cfg.map and not map then
	warn(
		`[StarWorld] star claims baked map "{cfg.map}" but the client could not build a `
			.. `receiver — StarMapMeta was "{tostring(ReplicatedStorage:GetAttribute("StarMapMeta"))}". `
			.. "Falling back to procedural, which will NOT match the server."
	)
elseif map then
	print(`[StarWorld] baked "{map.name}", radius {map.radius}, yFloor {map.yFloor}`)
else
	print(`[StarWorld] procedural seed {cfg.seed}, radius {cfg.radius}`)
end

return {}
