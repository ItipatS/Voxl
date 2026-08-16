--!strict
-- Star place: a FLY toggle (default F).
--
-- Walking a 896-block imported map is not a way to inspect it, and falling off it
-- is a death — so this is the survey tool.
--
-- The flight itself is the LOBBY'S, copied from FlightController: PlatformStand +
-- AutoRotate off, a LinearVelocity for travel and an AlignOrientation for facing,
-- with the velocity lerped so it eases in and out. Same feel, same controls, same
-- code shape — there is no reason for a second way of flying to exist. What differs
-- is only what a star needs: it TOGGLES (the lobby is always flying), it hands
-- gravity and walking back when you switch off, and it runs at a walking-scale
-- speed so distances still read honestly.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local TOGGLE_KEY = Enum.KeyCode.F
local SPEED = 60 -- studs/s ≈ 17 blocks/s: crosses the map, still reads as a place
local BOOST = 4 -- shift multiplier
local ACCEL = 6 -- velocity lerp rate, as in FlightController

-- Typing in the inventory shouldn't fly you across the island. The UI framework
-- owns that answer; if it isn't up yet, assume not blocked.
local UIController: any = nil
task.spawn(function()
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("UI"):WaitForChild("UIController")) :: any
	end)
	if ok then
		UIController = mod
	end
end)
local function blocked(): boolean
	return UIController ~= nil and UIController.gameplayBlocked and UIController.gameplayBlocked()
end

type Rig = {
	humanoid: Humanoid,
	hrp: BasePart,
	att: Attachment,
	lv: LinearVelocity,
	ao: AlignOrientation,
	walkSpeed: number,
	jumpHeight: number,
	animate: LocalScript?,
}

local rig: Rig? = nil
local targetVel = Vector3.zero

local function stopFlying()
	local r = rig
	rig = nil
	targetVel = Vector3.zero
	if not r then
		return
	end
	-- The movers are parented to the ROOT, not the attachment, so destroy each.
	if r.lv.Parent then
		r.lv:Destroy()
	end
	if r.ao.Parent then
		r.ao:Destroy()
	end
	if r.att.Parent then
		r.att:Destroy()
	end
	if r.humanoid.Parent then
		r.humanoid.PlatformStand = false
		r.humanoid.AutoRotate = true
		r.humanoid.WalkSpeed = r.walkSpeed
		r.humanoid.JumpHeight = r.jumpHeight
	end
	if r.animate then
		r.animate.Disabled = false
	end
end

local function startFlying()
	local char = player.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not (hrp and hrp:IsA("BasePart") and humanoid) then
		return
	end

	-- Remember what walking was, so switching off restores the server's tuning
	-- rather than a guess.
	local walkSpeed = humanoid.WalkSpeed
	local jumpHeight = humanoid.JumpHeight

	local animate = char:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		animate.Disabled = true
	end

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0

	local att = Instance.new("Attachment")
	att.Name = "StarFlyAtt"
	att.Parent = hrp

	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Parent = hrp

	local ao = Instance.new("AlignOrientation")
	ao.Attachment0 = att
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.RigidityEnabled = false
	ao.Responsiveness = 30
	ao.MaxTorque = math.huge
	ao.CFrame = hrp.CFrame
	ao.Parent = hrp

	targetVel = Vector3.zero
	rig = {
		humanoid = humanoid,
		hrp = hrp,
		att = att,
		lv = lv,
		ao = ao,
		walkSpeed = walkSpeed,
		jumpHeight = jumpHeight,
		animate = if animate and animate:IsA("LocalScript") then animate else nil,
	}
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= TOGGLE_KEY or blocked() then
		return
	end
	if rig then
		stopFlying()
	else
		startFlying()
	end
end)

-- A respawn is a fresh character: drop the old rig rather than driving a corpse.
player.CharacterAdded:Connect(function()
	rig = nil
	targetVel = Vector3.zero
end)

RunService.RenderStepped:Connect(function(dt: number)
	local r = rig
	if not r then
		return
	end
	if not (r.hrp.Parent and r.humanoid.Parent and r.lv.Parent) then
		stopFlying()
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camCF = cam.CFrame

	local off = blocked()
	local down = UserInputService.IsKeyDown
	local fwd = if off then 0 else (down(UserInputService, Enum.KeyCode.W) and 1 or 0)
		- (down(UserInputService, Enum.KeyCode.S) and 1 or 0)
	local strafe = if off then 0 else (down(UserInputService, Enum.KeyCode.D) and 1 or 0)
		- (down(UserInputService, Enum.KeyCode.A) and 1 or 0)
	local vert = if off then 0 else (down(UserInputService, Enum.KeyCode.Space) and 1 or 0)
		- (down(UserInputService, Enum.KeyCode.LeftControl) and 1 or 0)

	local dir = camCF.LookVector * fwd + camCF.RightVector * strafe + Vector3.yAxis * vert
	local moving = dir.Magnitude > 0.05
	if moving then
		dir = dir.Unit
	end

	local speed = SPEED
	if not off and down(UserInputService, Enum.KeyCode.LeftShift) then
		speed *= BOOST
	end
	local want = if moving then dir * speed else Vector3.zero
	targetVel = targetVel:Lerp(want, math.clamp(ACCEL * dt, 0, 1))
	r.lv.VectorVelocity = targetVel

	local pos = r.hrp.Position
	if moving then
		r.ao.CFrame = CFrame.lookAt(pos, pos + dir, camCF.UpVector)
	end
end)

return {}
