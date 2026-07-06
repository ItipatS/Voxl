--!strict
-- Asteroid HIT response (client feel). The server detects the collision, applies the
-- damage, and owns the i-frame window (systems/asteroids); it fires AsteroidHit here
-- with a knockback direction + stun time. We turn that into: a brief INPUT FREEZE, a
-- decaying KNOCKBACK shove, an i-frame FLASH on the character, and an impact SFX.
-- FlightController consults FlightStun.stunned() / FlightStun.knock(dt) each frame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local blink = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("ClientNet"))
local FlightBoost = require(script.Parent:WaitForChild("FlightBoost"))
local player = Players.LocalPlayer

local KNOCK_SPEED = 260 -- initial shove (studs/s) along the hit direction
local KNOCK_DAMP = 2.2 -- how fast the shove bleeds off (per second)

local M = {}
local stunUntil = 0
local knockVel = Vector3.zero

function M.stunned(): boolean
	return os.clock() < stunUntil
end

-- Current knockback velocity to ADD to flight this frame; decays each call. Call once
-- per frame (FlightController does).
function M.knock(dt: number): Vector3
	local v = knockVel
	knockVel *= math.exp(-KNOCK_DAMP * dt)
	if knockVel.Magnitude < 1 then
		knockVel = Vector3.zero
	end
	return v
end

-- i-frame flash: strobe the local character's transparency for the stun duration
-- (LocalTransparencyModifier is client-only + auto-resets, but we clear it to be safe).
local function flash(dur: number)
	local char = player.Character
	if not char then
		return
	end
	local t0 = os.clock()
	while os.clock() - t0 < dur do
		local on = (math.floor((os.clock() - t0) / 0.1) % 2) == 0
		for _, d in char:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = if on then 0.7 else 0
			end
		end
		RunService.RenderStepped:Wait()
	end
	local c2 = player.Character
	if c2 then
		for _, d in c2:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = 0
			end
		end
	end
end

local function playImpact()
	local sfx = SoundService:FindFirstChild("SFX")
	local eff = sfx and sfx:FindFirstChild("Effect")
	if not eff then
		return
	end
	-- Boosting into a rock = a heavy "Hit"; drifting or standing into one = a lighter "Miss".
	local s = eff:FindFirstChild(if FlightBoost.boosting() then "Hit" else "Miss")
	if s and s:IsA("Sound") then
		local c = s:Clone()
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		c.Parent = if root and root:IsA("BasePart") then root else SoundService -- on the player = reliable
		c:Play()
		Debris:AddItem(c, 3)
	end
end

blink.AsteroidHit.On(function(impact)
	local dir = impact.dir
	if dir.Magnitude > 1e-3 then
		knockVel = dir.Unit * KNOCK_SPEED
	end
	stunUntil = os.clock() + impact.stun
	playImpact()
	task.spawn(flash, impact.stun)
end)

return M
