--!strict
-- Zero-gravity jet flight (The Cluster lobby).
--
-- The client owns its character, so movement + animation are driven here per
-- frame. No gravity: you fly in the camera's facing direction, and the RIG IS
-- ROTATED toward travel (jet-like) so "forward" is always where you're going.
--
-- Animation state machine (crossfaded):
--   * WASD (any horizontal thrust) -> Forward   (rig faces travel direction)
--   * Space only                   -> Ascend    (rig faces camera-forward)
--   * Shift only                   -> Descend    (rig faces camera-forward)
--   * no input                     -> Idle       (+ a slow space wobble)
--
-- W follows the full camera look (pitch included), so look up + W climbs while
-- playing Forward; Space/Shift are pure vertical thrust with their own anims.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local constellation = require(game:GetService("ReplicatedStorage"):WaitForChild("std"):WaitForChild("constellation"))
local UIController = require(script.Parent:WaitForChild("UI")).Controller
local FlightBoost = require(script.Parent:WaitForChild("FlightBoost"))
local FlightStun = require(script.Parent:WaitForChild("FlightStun"))
local FlightAnims = require(script.Parent:WaitForChild("FlightAnims"))

--=====================================================================
-- CONFIG — tune the feel here; the animation ids live in FlightAnims.
--=====================================================================
-- The animation set + state machine live in FlightAnims, shared with the star
-- place's StarFly (which cannot require THIS file: it self-starts on require, so
-- pulling it in on the ground would begin zero-g lobby flight).
local SPEED        = 160        -- cruise velocity (studs/s); halved for calmer travel (boost ×2.4 on Shift)
local ACCEL        = 8          -- velocity smoothing (higher = snappier)
local ROT_RESPONSE = 8        -- rig turn responsiveness (AlignOrientation)

--=====================================================================

local function flatDir(v: Vector3, fallback: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-3 then
		return fallback
	end
	return f.Unit
end

local function setup(character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator

	-- Own the animation: kill the default walk/idle Animate script.
	local animate = character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		animate.Disabled = true
	end

	-- Hand movement to us: no auto-balance, no walk, no auto-rotate.
	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0

	-- Movers: LinearVelocity drives travel, AlignOrientation drives facing.
	local att = Instance.new("Attachment")
	att.Name = "FlightAtt"
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
	ao.Responsiveness = ROT_RESPONSE
	ao.MaxTorque = math.huge
	ao.CFrame = hrp.CFrame
	ao.Parent = hrp

	-- Spawn RANDOMLY in the cluster (the residential annulus): outside the black hole,
	-- well inside the far starter-star ring — so you start among the plots, not on a
	-- star. Face OUTWARD (toward the ring/open space), away from the central hazard.
	--
	-- Unless the server published a dev spawn (systems/devspawn), in which case start
	-- there instead. This has to happen HERE: the client owns the character, so
	-- placing it server-side just gets overwritten by the line below a frame later.
	local center = constellation.CENTER
	local devPos = ReplicatedStorage:GetAttribute("DevSpawnPos")
	local spawnPos: Vector3
	local lookAt: Vector3
	if typeof(devPos) == "Vector3" then
		local devLook = ReplicatedStorage:GetAttribute("DevSpawnLook")
		spawnPos = devPos
		lookAt = if typeof(devLook) == "Vector3" then devLook else center
	else
		local bh = constellation.BLACKHOLE
		local ang = math.random() * math.pi * 2
		local r = bh.radius + 2500 + math.random() * 7000
		spawnPos = center + Vector3.new(math.cos(ang) * r, math.random(-2500, 2500), math.sin(ang) * r)
		lookAt = spawnPos + (spawnPos - center) -- outward, away from the central hazard
	end
	hrp.CFrame = CFrame.lookAt(spawnPos, lookAt)
	ao.CFrame = hrp.CFrame

	local anims = FlightAnims.attach(humanoid)
	local setState = anims.set

	local targetVel = Vector3.zero
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt: number)
		if not hrp.Parent or humanoid.Health <= 0 then
			conn:Disconnect()
			return
		end

		local cam = Workspace.CurrentCamera
		local camCF = if cam then cam.CFrame else CFrame.identity

		-- Freeze movement input while a modal UI is up (naming a star, menus). The
		-- text box grabs typed keys, but the confirm state releases focus — without
		-- this, WASD would fly you around behind the prompt.
		-- Frozen input while a modal UI is up OR while asteroid-stunned (the knockback
		-- still moves you; only WASD is cut).
		local blocked = UIController.gameplayBlocked() or FlightStun.stunned()
		local down = UserInputService.IsKeyDown
		local fwd = if blocked then 0 else (down(UserInputService, Enum.KeyCode.W) and 1 or 0)
			- (down(UserInputService, Enum.KeyCode.S) and 1 or 0)
		local strafe = if blocked then 0 else (down(UserInputService, Enum.KeyCode.D) and 1 or 0)
			- (down(UserInputService, Enum.KeyCode.A) and 1 or 0)
		local vert = if blocked then 0 else (down(UserInputService, Enum.KeyCode.Space) and 1 or 0)
			- ((down(UserInputService, Enum.KeyCode.LeftControl) or down(UserInputService, Enum.KeyCode.RightShift)) and 1 or 0)

		local dir = camCF.LookVector * fwd + camCF.RightVector * strafe + Vector3.yAxis * vert
		local hasHoriz = fwd ~= 0 or strafe ~= 0
		local moving = dir.Magnitude > 0.05
		if moving then
			dir = dir.Unit
		end

		-- Smoothed travel velocity, plus any asteroid knockback shove (decays itself).
		local knock = FlightStun.knock(dt)
		local want = (if moving then dir * SPEED * FlightBoost.mult() else Vector3.zero) + knock
		targetVel = targetVel:Lerp(want, math.clamp(ACCEL * dt, 0, 1))

		-- Black hole event horizon: inside the radius you can go DEEPER but never
		-- escape — outward velocity is cancelled and an inward pull drags you to the
		-- core, where you're consumed and respawned.
		local bh = constellation.BLACKHOLE
		local toCore = bh.pos - hrp.Position
		local dCore = toCore.Magnitude
		local inBlackHole = dCore < bh.radius and dCore > 1e-3
		if inBlackHole then
			local inward = toCore.Unit
			local vIn = targetVel:Dot(inward)
			if vIn < 0 then
				targetVel -= vIn * inward -- kill outward radial velocity (no escape)
			end
			targetVel += inward * (bh.pull * (0.35 + (1 - dCore / bh.radius)) * dt)
			if dCore < bh.coreRadius then
				humanoid.Health = 0 -- consumed → respawn (home / last resource star)
			end
		end
		lv.VectorVelocity = targetVel

		-- Facing + animation state.
		local pos = hrp.Position
		if hasHoriz then
			setState("Forward")
			-- Up-hint = camera up so the rig doesn't roll/flip when travel goes
			-- near-vertical (look up + W), keeping the forward-lean clean.
			ao.CFrame = CFrame.lookAt(pos, pos + dir, camCF.UpVector)
		elseif vert > 0 then
			setState("Ascend")
			ao.CFrame = CFrame.lookAt(pos, pos + flatDir(camCF.LookVector, hrp.CFrame.LookVector))
		elseif vert < 0 then
			setState("Descend")
			ao.CFrame = CFrame.lookAt(pos, pos + flatDir(camCF.LookVector, hrp.CFrame.LookVector))
		else
			setState("Idle")
			ao.CFrame = CFrame.lookAt(pos, pos + flatDir(camCF.LookVector, hrp.CFrame.LookVector))
			-- Hold the root perfectly still (zero velocity = no drift). The camera
			-- follows the root, so any root bob/drift moves the camera (nausea).
			-- Put the idle float in the idle ANIMATION instead — it moves the body,
			-- not the camera-followed root, so it stays lively without swaying the cam.
			-- (But don't zero it inside the black hole — the suck must keep pulling —
			-- nor while an asteroid knockback is still shoving us with no input held.)
			if not inBlackHole and knock.Magnitude < 1 then
				lv.VectorVelocity = Vector3.zero
			end
		end
	end)
end

player.CharacterAdded:Connect(function(char)
	task.spawn(setup, char)
end)
if player.Character then
	task.spawn(setup, player.Character)
end

return {}
