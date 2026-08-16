--!strict
-- Star place: a FLY toggle (default F).
--
-- Walking a 896-block imported map is not a way to inspect it, and falling off it
-- is a death — so this is the survey tool. It is deliberately NOT the lobby's
-- FlightController: that is a jet with its own animation state machine and no
-- gravity anywhere, whereas this is ordinary walking with a toggle that lifts you
-- out of it and hands the ground back when you switch off.
--
-- Speed matches the walk speed so distances still read honestly; hold shift to
-- move faster when crossing the map.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local TOGGLE_KEY = Enum.KeyCode.F
local SPEED = 60 -- studs/s (~17 blocks/s: fast enough to cross, slow enough to look)
local BOOST = 4 -- shift multiplier
local RISE_KEY = Enum.KeyCode.Space
local FALL_KEY = Enum.KeyCode.LeftControl

local flying = false
local mover: LinearVelocity? = nil
local attachment: Attachment? = nil

local function humanoidOf(): (Humanoid?, BasePart?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	return hum, (if root and root:IsA("BasePart") then root else nil)
end

local function stopFlying()
	flying = false
	if mover then
		mover:Destroy()
		mover = nil
	end
	if attachment then
		attachment:Destroy()
		attachment = nil
	end
	local hum = humanoidOf()
	if hum then
		hum.PlatformStand = false
	end
end

local function startFlying()
	local hum, root = humanoidOf()
	if not hum or not root then
		return
	end
	flying = true
	-- PlatformStand rather than changing the humanoid state: it suspends walking and
	-- the fall/landing animations without fighting the state machine every frame.
	hum.PlatformStand = true

	local a = Instance.new("Attachment")
	a.Parent = root
	attachment = a

	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = a
	lv.MaxForce = math.huge
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root
	mover = lv
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= TOGGLE_KEY then
		return
	end
	if flying then
		stopFlying()
	else
		startFlying()
	end
end)

-- A new character (respawn) never inherits the flight.
player.CharacterAdded:Connect(function()
	flying = false
	mover = nil
	attachment = nil
end)

RunService.RenderStepped:Connect(function()
	if not flying then
		return
	end
	local lv = mover
	local hum, root = humanoidOf()
	if not lv or not lv.Parent or not hum or not root then
		if flying then
			stopFlying()
		end
		return
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local look = cam.CFrame.LookVector
	local right = cam.CFrame.RightVector

	local dir = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += look end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= look end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += right end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= right end
	if UserInputService:IsKeyDown(RISE_KEY) then dir += Vector3.yAxis end
	if UserInputService:IsKeyDown(FALL_KEY) then dir -= Vector3.yAxis end

	local speed = SPEED
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
		speed *= BOOST
	end
	lv.VectorVelocity = if dir.Magnitude > 0 then dir.Unit * speed else Vector3.zero
end)

print(`[StarFly] press {TOGGLE_KEY.Name} to fly (space/ctrl up-down, shift to boost)`)

return {}
