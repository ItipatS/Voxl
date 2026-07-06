-- ServerScriptService/systems/starworld.luau  (Star / ResourceStar place)
-- Configure WorldGen for THIS star's bounded world, and PUBLISH the config so every client
-- generates the identical terrain. Must run BEFORE `spawn` (which reads the surface height)
-- and before chunk streaming. For now it uses the TEST star (std/starconfig); the real flow
-- will read TeleportData (starId + originSeed + rolled types) here instead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local starconfig = require(ReplicatedStorage.std.starconfig)

local cfg = starconfig.get()
WorldGen.applyStarByTypes(cfg.seed, cfg.radius, cfg.types)
starconfig.set(cfg.seed, cfg.radius, cfg.types) -- replicate so clients match

return {}
