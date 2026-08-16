-- ServerScriptService/systems/daynight.luau  (Star place)
--!strict

-- The day/night cycle. Server owns the clock and the moon; the client integrates
-- it into Lighting.ClockTime every frame (ClientServices/EventHandler/DayNightRenderer).
--
-- This is a REVIVAL, not a new system. The cycle was written months ago and has
-- been dead the whole time — `services/EventManager` was never required by anything,
-- and would have errored on its first line if it had been (it requires
-- `ServerScriptService.net`, which does not exist; the generated module is
-- `ServerNet`). Its moon table survived intact and is reused here unchanged.
--
-- What is deliberately NOT revived: EventManager's eclipse/blood-moon events, storm
-- scheduler and BGM hooks. They depend on Blink events that were never declared
-- (`Net.DayNight`, `Net.Event`) and on client consumers that disagree with the
-- server about their own payload shape — EventRenderer reads `data[1]` from a map
-- keyed by event id. That is a half-finished feature and reviving it is a separate
-- job from making day and night work.
--
-- REPLICATION is by ReplicatedStorage values and workspace attributes, not Blink,
-- and that is the right call here rather than a shortcut: both are late-join-safe.
-- A player arriving 4 minutes into a night gets the correct clock from the same
-- values everyone else is reading, with no join handshake to get wrong.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local MoonPhase = require(ServerScriptService.services.EventManager.MoonPhase)

-- Real minutes per phase. [TUNE] — 5 and 5 is what the original cycle shipped with:
-- long enough that night is an event, short enough to see both in one playtest.
local DAY_MINUTES = 5
local NIGHT_MINUTES = 5

-- Day runs 06:00 -> 18:00 and night 18:00 -> 06:00, so each phase is 12 in-game
-- hours regardless of how many real minutes it is given.
local DAY_START = 6.0
local NIGHT_START = 18.0
local HALF_DAY_HOURS = 12.0

local MOON_PHASE_ATTR = "MoonPhase"

local M = {}

-- ---- the replicated clock -----------------------------------------------------
-- Clock0/T0/Speed describe a LINE, not a position: the client computes
-- (Clock0 + (now - T0) * Speed) % 24 itself, every frame. Pushing a time value
-- instead would mean either a stuttering clock or a flood of updates.
local folder = ReplicatedStorage:FindFirstChild("TimeSync") :: Folder?
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "TimeSync"
	folder.Parent = ReplicatedStorage
end
local sync = folder :: Folder

local function value(name: string): NumberValue
	local v = sync:FindFirstChild(name) :: NumberValue?
	if not v then
		v = Instance.new("NumberValue")
		v.Name = name
		v.Parent = sync
	end
	return v :: NumberValue
end

local Clock0 = value("Clock0") -- in-game hour this phase began at
local T0 = value("T0") -- server time it began
local Speed = value("Speed") -- in-game hours per real second
local PhaseEndClock = value("PhaseEndClock") -- in-game hour it ends at

local phase: "Day" | "Night" = "Day"
local phaseEndsAt = 0 -- server time

local function beginPhase(which: "Day" | "Night")
	phase = which
	local startClock = if which == "Day" then DAY_START else NIGHT_START
	local seconds = (if which == "Day" then DAY_MINUTES else NIGHT_MINUTES) * 60
	local now = Workspace:GetServerTimeNow()

	Clock0.Value = startClock
	T0.Value = now
	Speed.Value = HALF_DAY_HOURS / seconds
	PhaseEndClock.Value = (startClock + HALF_DAY_HOURS) % 24
	phaseEndsAt = now + seconds
end

-- ---- the moon -----------------------------------------------------------------
-- The star place clones its sky in from ReplicatedStorage.Skybox, so the Sky is
-- named "Planet", not "Sky". The original code said `Lighting.Sky.MoonTextureId`,
-- a NAMED lookup, which would have thrown on the first nightfall the moment anyone
-- wired it up.
local function applyMoon()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky then
		sky.MoonTextureId = MoonPhase.GetTextureId()
	end
	Workspace:SetAttribute(MOON_PHASE_ATTR, MoonPhase.GetPhaseName())
end

-- The sky is installed by `starworld` at boot and can be replaced later; re-apply
-- rather than assuming we ran second.
Lighting.ChildAdded:Connect(function(child)
	if child:IsA("Sky") then
		applyMoon()
	end
end)

local function advance()
	if phase == "Day" then
		MoonPhase.Next() -- the moon turns over once per night, not per day
		beginPhase("Night")
		applyMoon()
	else
		beginPhase("Day")
	end
end

RunService.Heartbeat:Connect(function()
	if Workspace:GetServerTimeNow() >= phaseEndsAt then
		advance()
	end
end)

-- ---- dev / debug ---------------------------------------------------------------
-- Waiting five real minutes to see whether nightfall works is not a way to test it.
function M.setPhase(which: "Day" | "Night")
	if which == "Night" and phase == "Day" then
		MoonPhase.Next()
	end
	beginPhase(which)
	applyMoon()
end

function M.phase(): string
	return phase
end

beginPhase("Day")
applyMoon()
print(`[daynight] cycle running — {DAY_MINUTES}m day / {NIGHT_MINUTES}m night, moon at {MoonPhase.GetPhaseName()}`)

return M
