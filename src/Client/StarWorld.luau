--!strict
-- Star place (client): configure WorldGen for this star's bounded world BEFORE ChunkClient
-- generates any terrain, using the server-published config so the client's terrain matches
-- the server's spawn/collision view. Required first in the ResourceStar branch of main.client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local starconfig = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("starconfig"))

-- Wait briefly for the server to publish the star config (else fall back to the TEST star).
local t0 = os.clock()
while ReplicatedStorage:GetAttribute("StarSeed") == nil and os.clock() - t0 < 3 do
	task.wait(0.05)
end

local cfg = starconfig.get()
WorldGen.applyStarByTypes(cfg.seed, cfg.radius, cfg.types)

return {}
