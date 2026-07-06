-- ServerScriptService/EventManager.lua
local Lighting = game:GetService("Lighting")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ServerScriptService.net)

local EventDefinitions = require(script.EventDefinitions)
local MoonPhase = require(script.MoonPhase)

type Phase = Net.DayPhase
type Events = Net.EventPackage

local activeEvents: Events = {}
local eventIdCounter = 0
local eventDirty = false

-- ===== Day/Night settings (minutes per phase) =====
local settings = {
	dayDuration = 5,   -- minutes
	nightDuration = 5, -- minutes
}

-- We map Day = 06:00 -> 18:00 (12 hours), Night = 18:00 -> 06:00 (12 hours)
local DAY_START = 6.0
local NIGHT_START = 18.0
local HALF_DAY_HOURS = 12.0

local currentPhase: Phase = "Day"
local currentMoonPhase: Net.MoonPhase = MoonPhase.GetPhaseName()

-- Random event scheduler
local randomEventCheckInterval = 60 -- seconds (your original comment says "in-game hour" but it's real seconds)
local timeSinceLastCheck = 0

-- ===== Storm override (FTC-209) =====
-- Continuous rain is computed client-side by WeatherSignals from the synced clock + SEED;
-- the server only FORCES a storm by setting this workspace attribute (auto-replicated,
-- late-join-safe). -1 = release back to natural deterministic noise; 0..1 = forced rain.
local RAIN_OVERRIDE_ATTR = "RainOverride" -- must match WeatherSignals.Config.overrideAttr
local STORM_CHANCE = 0.25 -- probability per roll, when not already storming
local STORM_MIN_DURATION = 45 -- seconds
local STORM_MAX_DURATION = 120 -- seconds
local STORM_CHECK_INTERVAL = 90 -- seconds between storm rolls
local STORM_INTENSITY = 1.0 -- forced RainOverride value (0..1)

local stormActive = false
local stormEndsAt = 0
local stormNextCheckAt = 0
local manualHold = false -- when a dev forces weather, suppress the auto storm scheduler

-- ===== Ambient client signals (FTC-209) =====
-- Replicated, late-join-safe workspace attributes — same pattern as RainOverride. The client
-- rain/weather VFX READ these instead of subscribing to Net.Event (one listener, owned by the
-- client EventHandler). ActiveWeatherEvent = the single headline event the rain should react to
-- ("" = none, by priority); MoonPhase = current moon, for night-rain mood.
local WEATHER_EVENT_ATTR = "ActiveWeatherEvent"
local MOON_PHASE_ATTR = "MoonPhase"
local WEATHER_EVENT_PRIORITY = { BloodMoon = 3, LunarEclipse = 2, SolarEclipse = 1 }
local lastWeatherEvent: string? = nil

local function setRainOverride(value: number)
	workspace:SetAttribute(RAIN_OVERRIDE_ATTR, value)
end

-- pick the highest-priority active event and publish it (only when it changes, to avoid
-- replicating an attribute write every tick)
local function publishWeatherEvent()
	local best, bestPriority = "", 0
	for _, ev in pairs(activeEvents) do
		local p = WEATHER_EVENT_PRIORITY[ev.Name]
		if p and p > bestPriority then
			best, bestPriority = ev.Name, p
		end
	end
	if best ~= lastWeatherEvent then
		lastWeatherEvent = best
		workspace:SetAttribute(WEATHER_EVENT_ATTR, best)
	end
end

local function updateStorm()
	if manualHold then
		return -- a tester is holding a forced override; don't auto-roll storms
	end
	local now = workspace:GetServerTimeNow()
	if stormActive then
		if now >= stormEndsAt then
			stormActive = false
			setRainOverride(-1) -- release: clients fall back to natural noise
		end
		return
	end
	if now < stormNextCheckAt then
		return
	end
	stormNextCheckAt = now + STORM_CHECK_INTERVAL
	if math.random() < STORM_CHANCE then
		stormActive = true
		stormEndsAt = now + math.random(STORM_MIN_DURATION, STORM_MAX_DURATION)
		setRainOverride(STORM_INTENSITY)
	end
end

local function markEventDirty()
	eventDirty = true
end

local function getEventState(): Events
	return activeEvents
end

-- ===== TimeSync (replicate only these) =====
local timeSyncFolder = ReplicatedStorage:FindFirstChild("TimeSync") :: Folder?
if not timeSyncFolder then
	timeSyncFolder = Instance.new("Folder")
	timeSyncFolder.Name = "TimeSync"
	timeSyncFolder.Parent = ReplicatedStorage
end

local Clock0 = timeSyncFolder:FindFirstChild("Clock0")
if not Clock0 then
	Clock0 = Instance.new("NumberValue")
	Clock0.Name = "Clock0"
	Clock0.Parent = timeSyncFolder
end

local T0 = timeSyncFolder:FindFirstChild("T0")
if not T0 then
	T0 = Instance.new("NumberValue")
	T0.Name = "T0"
	T0.Parent = timeSyncFolder
end

local Speed = timeSyncFolder:FindFirstChild("Speed")
if not Speed then
	Speed = Instance.new("NumberValue")
	Speed.Name = "Speed"
	Speed.Parent = timeSyncFolder
end

local PhaseEndClock = timeSyncFolder:FindFirstChild("PhaseEndClock")
if not PhaseEndClock then
	PhaseEndClock = Instance.new("NumberValue")
	PhaseEndClock.Name = "PhaseEndClock"
	PhaseEndClock.Parent = timeSyncFolder
end

local function hoursPerSecondForPhase(phase: Phase): number
	local minutes = (phase == "Day") and settings.dayDuration or settings.nightDuration
	local seconds = math.max(minutes * 60, 0.001)
	return HALF_DAY_HOURS / seconds -- 12 hours spread across phase seconds
end

local function setTimeSync(clockStart: number, phase: Phase)
	Clock0.Value = clockStart
	T0.Value = workspace:GetServerTimeNow()
	Speed.Value = hoursPerSecondForPhase(phase)
	PhaseEndClock.Value = (clockStart + HALF_DAY_HOURS) % 24
end

local function getClockTimeNow(): number
	local now = workspace:GetServerTimeNow()
	local elapsed = now - T0.Value
	return (Clock0.Value + elapsed * Speed.Value) % 24
end

-- Initialize time at Day start
setTimeSync(DAY_START, "Day")

-- Start with no forced weather: clients run on natural deterministic noise until a storm.
setRainOverride(-1)
-- Seed the ambient signals so late joiners read a valid value immediately.
workspace:SetAttribute(WEATHER_EVENT_ATTR, "")
workspace:SetAttribute(MOON_PHASE_ATTR, currentMoonPhase)

-- ===== Events (authoritative on server) =====
local function TriggerEvent(eventName: string, duration: number, source: string): number
	eventIdCounter += 1
	local id = eventIdCounter

	local now = workspace:GetServerTimeNow()
	activeEvents[id] = {
		Name = eventName,
		StartTime = now,
		EndTime = now + duration,
		Duration = duration,
		Source = source,
	}

	markEventDirty()
	return id
end

local function RemoveEvent(eventId: number)
	if activeEvents[eventId] ~= nil then
		activeEvents[eventId] = nil
		markEventDirty()
	end
end

local function UpdateEvents()
	local now = workspace:GetServerTimeNow()
	local changed = false
	for id, ev in pairs(activeEvents) do
		if ev.EndTime <= now then
			activeEvents[id] = nil
			changed = true
		end
	end
	if changed then
		markEventDirty()
	end
end

local function sendIfChanged()
	if eventDirty then
		Net.Event.FireAll(activeEvents)
		eventDirty = false
	end
end

local lastEventAt: {[string]: number} = {}
local EVENT_COOLDOWN = 3.0

local function tryTriggerRandomEvent()
	local now = workspace:GetServerTimeNow()

	for eventName, def in pairs(EventDefinitions) do
		-- Phase check
		local allowed = false
		for _, phase in ipairs(def.allowedPhases) do
			if phase == currentPhase then
				allowed = true
				break
			end
		end
		if not allowed then
			continue
		end

		-- Min interval check
		if now - def.lastTriggered < def.minInterval then
			continue
		end

		-- Already active check (IMPORTANT: use pairs, not ipairs)
		local alreadyActive = false
		for _, ev in pairs(activeEvents) do
			if ev.Name == eventName then
				alreadyActive = true
				break
			end
		end
		if alreadyActive then
			continue
		end

		-- Optional extra cooldown guard (if you want)
		local last = lastEventAt[eventName] or -math.huge
		if now - last < EVENT_COOLDOWN then
			continue
		end

		if math.random() < 0.15 then
			local duration = math.random(def.minDuration, def.maxDuration)
			TriggerEvent(eventName, duration, "random")
			def.lastTriggered = now
			lastEventAt[eventName] = now
		end
	end
end

-- ===== Phase switching based on computed clocktime =====
local function advancePhase()
    warn("Advancing phase from", currentPhase)
	if currentPhase == "Day" then
		currentPhase = "Night"
		currentMoonPhase = MoonPhase.Next()
		setTimeSync(NIGHT_START, "Night")

        --MoonPhase update
        Lighting.Sky.MoonTextureId = MoonPhase.GetTextureId()
        workspace:SetAttribute(MOON_PHASE_ATTR, currentMoonPhase)
	else
		currentPhase = "Day"
		setTimeSync(DAY_START, "Day")
	end
end

local function HeartBeatUpdate(dt: number)
	timeSinceLastCheck += dt

	UpdateEvents()
	updateStorm()
	publishWeatherEvent()

	-- random event check
	if timeSinceLastCheck >= randomEventCheckInterval then
		tryTriggerRandomEvent()
		timeSinceLastCheck = 0
	end

	-- Phase switch: if we've reached the end clock for this phase
	-- We avoid float equality issues by checking "past end" using modular logic:
	-- Since each phase is exactly 12 hours, easiest is to switch when elapsed time >= phaseSeconds
	local phaseSeconds = ((currentPhase == "Day") and settings.dayDuration or settings.nightDuration) * 60
	local elapsed = workspace:GetServerTimeNow() - T0.Value

	if elapsed >= phaseSeconds then
		advancePhase()
	end

	sendIfChanged()
end

local function PlayerAdded(player)
	Net.Event.Fire(player, getEventState())
end

-- ===== Dev director API (FTC-209) =====
-- Manual levers for testing the weather/event stack. `manualHold` suppresses the auto
-- storm scheduler so a tester's forced weather isn't clobbered by a random roll.
local function SetStorm(intensity: number?, duration: number?)
	manualHold = false -- timed storm uses the auto-release path in updateStorm()
	stormActive = true
	stormEndsAt = workspace:GetServerTimeNow() + (duration or 60)
	setRainOverride(math.clamp(intensity or 1, 0, 1))
end

local function SetRain(value: number?)
	manualHold = true -- hold indefinitely until ClearWeather
	stormActive = false
	setRainOverride(math.clamp(value or 0.5, 0, 1))
end

local function ClearWeather()
	manualHold = false
	stormActive = false
	setRainOverride(-1) -- back to natural deterministic noise
end

local function SetPhase(phase: string)
	if phase == "Night" then
		currentPhase = "Night"
		currentMoonPhase = MoonPhase.Next()
		setTimeSync(NIGHT_START, "Night")
		local sky = Lighting:FindFirstChildOfClass("Sky")
		if sky then
			sky.MoonTextureId = MoonPhase.GetTextureId()
		end
		workspace:SetAttribute(MOON_PHASE_ATTR, currentMoonPhase)
	else
		currentPhase = "Day"
		setTimeSync(DAY_START, "Day")
	end
end

local function ForceEvent(name: string, duration: number?)
	local def = EventDefinitions[name]
	local dur = duration or (def and math.random(def.minDuration, def.maxDuration)) or 60
	return TriggerEvent(name, dur, "dev")
end

local function InstallDevCommands()
	local DevCommands = require(script.DevCommands)
	DevCommands.Install({
		SetStorm = SetStorm,
		SetRain = SetRain,
		ClearWeather = ClearWeather,
		SetPhase = SetPhase,
		ForceEvent = ForceEvent,
	})
end

return {
	HeartBeatUpdate = HeartBeatUpdate,
	PlayerAdded = PlayerAdded,
	TriggerEvent = TriggerEvent,
	RemoveEvent = RemoveEvent,
	GetEventState = getEventState,
	-- dev director
	SetStorm = SetStorm,
	SetRain = SetRain,
	ClearWeather = ClearWeather,
	SetPhase = SetPhase,
	ForceEvent = ForceEvent,
	InstallDevCommands = InstallDevCommands,
}
