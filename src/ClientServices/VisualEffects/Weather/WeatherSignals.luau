--!strict
--==================================================================================--
--  WeatherSignals  ·  the shared weather BRAIN
--==================================================================================--
--  ONE clock, ONE wind, ONE wetness, ONE cover value — computed once per frame and
--  READ by every visual module (RainSystem, CloudSystem, later SandstormSystem...).
--  Nothing here renders. It is pure state derived from workspace:GetServerTimeNow()
--  + SEED, so every client computes identical weather with zero replication.
--
--  USAGE: each visual module calls WeatherSignals.Start() (idempotent) at the top of
--  its own Start(), registers its FX folder via .registerIgnore(folder), then READS
--  the fields below every frame. It also exposes one shared .rayParams so every
--  module's world-rays skip every module's FX (puddles won't land on cloud shadows).
--==================================================================================--

local RunService = game:GetService("RunService")
local Lighting   = game:GetService("Lighting")
local Workspace  = game:GetService("Workspace")
local Players    = game:GetService("Players")

local WeatherSignals = {
	-- live signal fields (read these) ------------------------------------------------
	time      = 0,                       -- synced server clock
	rain      = 0,                       -- 0..1 raw downfall
	effRain   = 0,                       -- rain after indoor-shelter fade
	wetness   = 0,                       -- lagged ground wetness (rises fast, drains slow)
	cover     = 0,                       -- 0..1 cloud cover (thickens with/before rain)
	sheltered = 0,                       -- 0 outside .. 1 under cover
	windDir   = Vector2.new(1, 0.25).Unit, -- prevailing wind (XZ); everything leans on this
	windSpeed = 0,
	sunDir    = Vector3.new(0, 1, 0),    -- cached Lighting:GetSunDirection()
	rayParams = nil :: RaycastParams?,   -- shared world-ray filter (excludes all FX)
}

--==================================================================================--
--  CONFIG  ·  the weather MODEL lives here now (moved out of RainSystem)
--==================================================================================--
local CONFIG = {
	SEED         = 4242,
	overrideAttr = "RainOverride",   -- workspace attr: 0..1 forces weather, <0 = natural noise
	overrideBlend = 1.5,

	noisePeriod = 600,               -- bigger = slower weather swings (seconds)
	bias        = 0.15,
	gain        = 2.4,
	source      = nil :: (((t: number) -> number)?), -- replace the curve if you want

	baseCover     = 0.25,            -- cloud cover on a clear day
	coverRainGain = 0.70,            -- extra cover at full rain → drives cloud thickening + shadow

	windBaseDir   = Vector2.new(1, 0.25), -- THE prevailing wind; clouds + rain both align to it
	windBaseSpeed = 12,
	windRainSpeed = 34,

	wetnessRise  = 0.8,
	wetnessDrain = 0.12,

	shelterRayHeight = 220,
}
WeatherSignals.Config = CONFIG

--==================================================================================--
--  internals
--==================================================================================--
local function serverNow(): number
	local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
	return ok and t or os.clock()
end

local function approach(cur: number, target: number, rate: number, dt: number): number
	return cur + (target - cur) * math.min(dt * rate, 1)
end

local function defaultWeather(t: number): number
	local n = math.noise(t / CONFIG.noisePeriod + CONFIG.SEED, 0, 0)
	return math.clamp((n + CONFIG.bias) * CONFIG.gain, 0, 1)
end

local ignore: { Instance } = {}
function WeatherSignals.registerIgnore(inst: Instance)
	table.insert(ignore, inst)
	if WeatherSignals.rayParams then
		WeatherSignals.rayParams.FilterDescendantsInstances = ignore
	end
end

local function update(dt: number)
	local cam = Workspace.CurrentCamera
	local t = serverNow()
	WeatherSignals.time = t

	-- TARGET downfall this frame: a forced server override (0..1) wins; otherwise the
	-- deterministic noise curve. We then EASE THE PERSISTENT rain value toward that target.
	--
	-- BUG (FTC-209): the old code re-sampled `rain` from the ~0 noise baseline every frame and
	-- eased a throwaway LOCAL toward the override — so a forced storm only ever moved ~one
	-- frame's step (~0.03) and reset, never accumulating. effRain stayed ~0.04, leaving the
	-- camera rain shell ~96% transparent and puddles/impacts barely triggering. Persisting the
	-- value across frames is what lets a held override actually ramp to full and stay there.
	local target = (CONFIG.source or defaultWeather)(t)
	local ov = Workspace:GetAttribute(CONFIG.overrideAttr)
	if typeof(ov) == "number" and ov >= 0 then
		target = ov
	end
	WeatherSignals.rain = approach(WeatherSignals.rain, target, CONFIG.overrideBlend, dt)
	local rain = WeatherSignals.rain

	-- derived signals everything downstream couples to
	WeatherSignals.cover     = math.clamp(CONFIG.baseCover + rain * CONFIG.coverRainGain, 0, 1)
	WeatherSignals.windDir   = CONFIG.windBaseDir.Unit
	WeatherSignals.windSpeed = CONFIG.windBaseSpeed + rain * CONFIG.windRainSpeed
	WeatherSignals.sunDir    = Lighting:GetSunDirection()

	-- ONE shelter raycast for the whole stack (was per-module before coupling)
	local sheltered = 0
	if cam then
		local hit = Workspace:Raycast(
			cam.CFrame.Position,
			Vector3.new(0, CONFIG.shelterRayHeight, 0),
			WeatherSignals.rayParams
		)
		if hit then sheltered = 1 end
	end
	WeatherSignals.sheltered = approach(WeatherSignals.sheltered, sheltered, 6, dt)
	WeatherSignals.effRain = rain * (1 - WeatherSignals.sheltered)

	-- wetness integrator: chase effRain, fast up / slow down so puddles linger
	local rate = (WeatherSignals.effRain > WeatherSignals.wetness)
		and CONFIG.wetnessRise or CONFIG.wetnessDrain
	WeatherSignals.wetness = math.clamp(
		approach(WeatherSignals.wetness, WeatherSignals.effRain, rate, dt), 0, 1)
end

--==================================================================================--
--  lifecycle
--==================================================================================--
function WeatherSignals.Start()
	if WeatherSignals._conn then return end  -- idempotent: first caller wins

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	WeatherSignals.rayParams = rp

	-- Exclude the local character from every weather ray — ESPECIALLY the shelter probe. In a
	-- tight space Roblox zooms the camera onto the head, so the straight-up ray would hit the
	-- player's hat/hair and read "sheltered" forever (rain + effRain stuck at 0 even back
	-- outside). Refresh on respawn. (FTC-209)
	local plr = Players.LocalPlayer
	if plr then
		if plr.Character then
			WeatherSignals.registerIgnore(plr.Character)
		end
		plr.CharacterAdded:Connect(function(char)
			WeatherSignals.registerIgnore(char)
		end)
	end

	-- connected on the FIRST module's Start, so it fires before any consumer's render
	-- loop (RenderStepped handlers fire in connection order) → signals are fresh.
	WeatherSignals._conn = RunService.RenderStepped:Connect(update)
end

function WeatherSignals.Stop()
	if WeatherSignals._conn then
		WeatherSignals._conn:Disconnect()
		WeatherSignals._conn = nil
	end
end

return WeatherSignals
