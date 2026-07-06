--!strict
--==================================================================================--
--  Weather (client entry)  ·  StarterPlayerScripts.VisualEffect.Weather
--==================================================================================--
--  Boots the deterministic, server-time-synced weather stack. Everything renders
--  client-side off the shared WeatherSignals brain; the server only forces weather by
--  setting workspace attributes (see WeatherSignals.Config.overrideAttr). (FTC-209)
--
--  Phase A: brain + rain.  Phase B: clouds + sky.  Phase C: screen-space FX + sun flare.
--
--  NOTE: LenFlare + ScreenRain used to live at src/ root, which is mounted NOWHERE in
--  the Rojo tree — so they never synced and never ran (no sun flare, no rain distortion).
--  They now sit beside this folder under VisualEffect and are wired in below. (FTC-209)
--==================================================================================--

local RunService = game:GetService("RunService")

local WeatherSignals = require(script:WaitForChild("WeatherSignals"))
local CloudSystem = require(script:WaitForChild("CloudSystem"))
local StarDome = require(script:WaitForChild("StarDome"))

-- siblings under the VisualEffect folder (script.Parent == VisualEffect)
local VisualEffect = script.Parent
local ScreenRain = require(VisualEffect:WaitForChild("ScreenRain"))

-- Meteor impact juice: listens to the server's StarfallImpact RemoteEvent and adds camera
-- shake + light flash, distance-attenuated. Pairs with the server MeteorService. (FTC-209)
local MeteorImpact = require(VisualEffect:WaitForChild("MeteorImpact"))
MeteorImpact.Start()

-- The old box-shell RainSystem (camera-walls + its reflective cylinder puddles/impacts) is
-- RETIRED — NewRain.client.lua (a ParticleEmitter system beside this script) replaces it
-- entirely, including its own ParticleEmitter puddles. WeatherSignals still drives NewRain +
-- ScreenRain. (FTC-209)

WeatherSignals.Start() -- idempotent; each system's Start also calls it, first caller wins
CloudSystem.Start() -- procedural clouds + faked ground shadow
StarDome.Start() -- night star field + deterministic shooting stars

-- Sun lens flare. This is a side-effecting module: requiring it builds the flare part,
-- binds its render steps, and starts tracking the (single, never-replaced) camera. It
-- owns the sun/exposure grade; the RainSystem "lens" layer stays disabled so they don't
-- fight over Atmosphere/exposure. (FTC-209)
--
-- It depends on an ART container at ReplicatedStorage.LensFlare.Assets.Default (the
-- ParticleEmitter flare sprites — a Studio instance, NOT code). If that model isn't in the
-- place, the require throws; isolate it so the rest of the weather stack still boots, and
-- say exactly what's missing.
local okFlare, errFlare = pcall(function()
	require(VisualEffect:WaitForChild("LenFlare"))
end)
if not okFlare then
	warn("[Weather] Sun lens flare disabled — likely missing ReplicatedStorage.LensFlare.Assets.Default "
		.. "(the ParticleEmitter flare sprites). Error: " .. tostring(errFlare))
end

-- Screen-space rain distortion: glass droplets on the lens (boatbomber's ScreenRain).
-- It self-gates on graphics quality, camera pitch, and being under cover; we drive its
-- spawn rate from how hard it's actually raining where the player stands (effRain), so
-- it ramps in/out with the storm instead of being on/off.
local SCREEN_RAIN_BASE_RATE = 16
ScreenRain:Enable({ Rate = 0 })

local lastRate = -1
RunService.RenderStepped:Connect(function()
	local rate = SCREEN_RAIN_BASE_RATE * WeatherSignals.effRain
	if math.abs(rate - lastRate) > 0.25 then -- avoid re-Configuring every frame
		lastRate = rate
		ScreenRain:Configure({ Rate = rate })
	end
end)

--==================================================================================--
--  DEBUG  ·  live weather readout
--==================================================================================--
--  Flip WEATHER_DEBUG to false to silence. Prints the shared brain's state ~once a second
--  so you can see what the weather actually is (and whether /rain /storm are landing).
--  effRain is what drives the camera rain shell + screen distortion; rain is the raw
--  downfall before indoor shelter; override is the server attribute (-1 = natural noise).
local Workspace = game:GetService("Workspace")
local WEATHER_DEBUG = false
if WEATHER_DEBUG then
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc < 1 then
			return
		end
		acc = 0
		local S = WeatherSignals
		local ov = Workspace:GetAttribute(WeatherSignals.Config.overrideAttr)
		warn(string.format(
			"[Weather] rain=%.2f effRain=%.2f wetness=%.2f cover=%.2f sheltered=%.2f wind=%.1f override=%s",
			S.rain, S.effRain, S.wetness, S.cover, S.sheltered, S.windSpeed, tostring(ov)
		))
	end)
end
