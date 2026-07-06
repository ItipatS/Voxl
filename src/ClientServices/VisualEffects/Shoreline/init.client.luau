--==================================================================================--
--  Shoreline (client entry)  ·  StarterPlayerScripts.VisualEffect.Shoreline
--==================================================================================--
--  The SHORE foam is a flat EditableImage canvas (ShoreCanvas, tiled / culled / throttled); the
--  open OCEAN is 3D voxel parts (Pool builds them with a static colour gradient, OceanWaves moves
--  them with a spectral wave field, LOD-culled). Cosmetic, client-only, nothing replicates. The
--  weather brain drives the sea state (calm <-> storm).
--==================================================================================--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script:WaitForChild("Config"))
local Bake = require(script:WaitForChild("Bake"))
local ShoreCanvas = require(script:WaitForChild("ShoreCanvas"))
local Pool = require(script:WaitForChild("Pool"))
local OceanWaves = require(script:WaitForChild("OceanWaves"))
local ShoreSound = require(script:WaitForChild("ShoreSound"))

-- Shared weather brain (sibling VisualEffect.Weather): "storm" 0..1 keeps the ocean swell
-- + beach sound in sync with the environment. Optional — if absent, storm = 0 (calm).
local WeatherSignals
do
	local ok = pcall(function()
		local weather = script.Parent:WaitForChild("Weather", 10)
		WeatherSignals = weather and require(weather:WaitForChild("WeatherSignals", 10))
		if WeatherSignals then
			WeatherSignals.Start() -- idempotent
		end
	end)
	if not ok then
		WeatherSignals = nil
	end
end

local bake = Bake.build(Config)
if not bake then
	return
end

ShoreCanvas.init(Config, bake)
local oceanParts = Pool.createOcean(bake, Config)
OceanWaves.init(Config, bake, oceanParts, Pool.bulkMove)
ShoreSound.init(Config, bake)

local localPlayer = Players.LocalPlayer
local function playerRootPos(): Vector3?
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	return hrp and (hrp :: BasePart).Position or nil
end

local t = 0
RunService.Heartbeat:Connect(function(dt: number)
	t += dt
	local storm = WeatherSignals and math.clamp(WeatherSignals.rain, 0, 1) or 0
	local pos = playerRootPos()
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or pos

	-- ocean LOD follows the CAMERA (waves move only near what you're looking at)
	debug.profilebegin("Shoreline/Ocean")
	OceanWaves.step(t, storm, camPos)
	debug.profileend()

	debug.profilebegin("Shoreline/Shore")
	ShoreCanvas.step(t, pos)
	if pos and bake.depthAt(pos.X, pos.Z) < 0.55 then
		ShoreCanvas.tryPlayerRipple(pos.X, pos.Z, t)
	end
	debug.profileend()

	ShoreSound.update(camPos, storm)
end)
