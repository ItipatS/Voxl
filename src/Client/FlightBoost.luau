-- StarterPlayerScripts/FlightBoost.luau  (Lobby)
-- Hold LeftShift while flying to BOOST (faster, drains stamina; regens when off).
-- Cosmetics: a stamina bar billboard around the player's legs, feet particles
-- (Assets.Particles.Boost), camera speed particles (Assets.Particles.BoostCam), and
-- the Boost SFX whose PITCH rises as stamina drops. FlightController multiplies its
-- cruise speed by FlightBoost.mult(). See doc 06 (flight).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local blink = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("ClientNet"))

local BOOST_MULT = 2.4
local STAMINA_MAX = 100
local DRAIN = 30 -- per second while boosting
local REGEN = 16 -- per second while not
local PITCH_RISE = 0.9 -- extra PlaybackSpeed added at 0 stamina

local M = {}
local stamina = STAMINA_MAX -- this bar IS the "star fuel" — dust refills it (DustField)
local depleted = false -- once empty, must fully refill before boosting again
local mult = 1
local wasBoosting = false
local serverFuel: number? = nil -- authoritative value from the server; we reconcile toward it
local RECONCILE = 3 -- how fast predicted fuel is pulled to the server value
function M.mult(): number
	return mult
end

-- Server pushes its authoritative star fuel (~4Hz); we reconcile the predicted bar to it.
blink.PlayerStateSync.On(function(s)
	serverFuel = s.fuel
end)

-- Grant star fuel (collected from dust). Refuelling also lifts the deplete-lock once
-- there's a usable amount, so scooping dust lets you boost again without a full refill.
function M.addFuel(n: number)
	stamina = math.min(STAMINA_MAX, stamina + n)
	if stamina > 15 then
		depleted = false
	end
end

-- ---- particle + sound templates ---------------------------------------------
local particles = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Particles")
local feetTemplate = particles:WaitForChild("Boost") :: ParticleEmitter
local camTemplate = particles:WaitForChild("BoostCam") :: BasePart

local function setEmitters(root: Instance, on: boolean)
	for _, e in root:GetDescendants() do
		if e:IsA("ParticleEmitter") or e:IsA("Trail") or e:IsA("Beam") then
			e.Enabled = on
		end
	end
end

-- Camera speed particles (a part that rides the camera).
local camFx = camTemplate:Clone()
camFx.Anchored = true
camFx.CanCollide = false
camFx.CanQuery = false
camFx.Transparency = 1
setEmitters(camFx, false)
camFx.Parent = Workspace

-- Boost sound (looped; pitch scales with stamina).
local boostSound = (SoundService.SFX.Effect.Spaceboost :: Sound):Clone()
boostSound.Looped = true
boostSound.Parent = SoundService

-- ---- per-character cosmetics (feet emitters + leg bar) ----------------------
local feetEmitters: { ParticleEmitter } = {}
local bar: BillboardGui? = nil
local fill: Frame? = nil

-- The actual animated leg parts. We attach the exhaust to THESE, not the
-- HumanoidRootPart: the HRP orientation is driven by AlignOrientation (it faces
-- travel) and does NOT rotate with the animation, so an emitter on it fires the
-- same world direction no matter how the visible rig is posed. The real legs move
-- with the anim, so the plume tracks the feet.
local function legParts(char: Model, humanoid: Humanoid): { BasePart }
	local names = if humanoid.RigType == Enum.HumanoidRigType.R6
		then { "Left Leg", "Right Leg" }
		else { "LeftFoot", "RightFoot" }
	local out: { BasePart } = {}
	for _, n in names do
		local p = char:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			out[#out + 1] = p
		end
	end
	return out
end

local function setupChar(char: Model)
	local hrp = char:WaitForChild("HumanoidRootPart") :: BasePart
	local humanoid = char:WaitForChild("Humanoid") :: Humanoid

	feetEmitters = {}
	for _, leg in legParts(char, humanoid) do
		local att = Instance.new("Attachment")
		att.Name = "BoostFeet"
		-- Emit out the sole. EmissionDirection=Top is the attachment's +Y, so flip 180°
		-- about X to point it along the leg's −Y (down). This is now relative to the
		-- ANIMATED leg, so it follows the foot. Tune this rotation if the aim is off.
		att.CFrame = CFrame.new(0, -1, 0) * CFrame.Angles(math.pi, 0, 0)
		att.Parent = leg
		local e = feetTemplate:Clone()
		e.Enabled = false
		e.VelocityInheritance = 0 -- don't let travel velocity fling the plume forward
		e.Parent = att
		feetEmitters[#feetEmitters + 1] = e
	end

	local bg = Instance.new("BillboardGui")
	bg.Name = "BoostBar"
	bg.Adornee = hrp
	bg.Size = UDim2.fromOffset(130, 12)
	bg.StudsOffset = Vector3.new(0, -3.2, 0) -- around the legs
	bg.AlwaysOnTop = true
	bg.Parent = char

	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	back.BackgroundTransparency = 0.35
	back.BorderSizePixel = 0
	back.Parent = bg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = back

	fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(1, 0)
	fc.Parent = fill

	bar = bg
end

player.CharacterAdded:Connect(setupChar)
if player.Character then
	setupChar(player.Character)
end

-- ---- boost loop -------------------------------------------------------------
local MOVE = {
	Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
	Enum.KeyCode.Space, Enum.KeyCode.LeftControl, Enum.KeyCode.RightShift,
}
local function moving(): boolean
	for _, k in MOVE do
		if UserInputService:IsKeyDown(k) then
			return true
		end
	end
	return false
end

RunService.RenderStepped:Connect(function(dt: number)
	-- Boost only if NOT depleted; hitting 0 locks it until fully refilled.
	local boosting = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and not depleted and stamina > 0 and moving()
	if boosting ~= wasBoosting then
		wasBoosting = boosting
		blink.BoostState.Fire(boosting) -- edge only (start/stop), so the server can sim fuel
	end
	if boosting then
		stamina = math.max(0, stamina - DRAIN * dt)
		mult = BOOST_MULT
	else
		stamina = math.min(STAMINA_MAX, stamina + REGEN * dt)
		mult = 1
	end
	-- Reconcile the predicted value toward the server's authority (corrects drift + picks up
	-- grants/rejected collects). Gentle so it doesn't fight the local drain.
	if serverFuel then
		stamina += (serverFuel - stamina) * math.clamp(RECONCILE * dt, 0, 1)
		stamina = math.clamp(stamina, 0, STAMINA_MAX)
	end
	if stamina <= 0 then
		depleted = true
	elseif stamina >= STAMINA_MAX then
		depleted = false
	end
	local frac = stamina / STAMINA_MAX

	if fill then
		fill.Size = UDim2.fromScale(frac, 1)
		-- red the whole recharge while locked; blue once it's usable again
		fill.BackgroundColor3 = if depleted then Color3.fromRGB(235, 90, 90) else Color3.fromRGB(120, 200, 255)
	end
	if bar then
		bar.Enabled = boosting or frac < 0.999 -- show while boosting or refilling
	end
	for _, e in feetEmitters do
		e.Enabled = boosting
	end
	setEmitters(camFx, boosting)
	camFx.CFrame = Workspace.CurrentCamera.CFrame * CFrame.new(0, 0, -4) -- behind camera

	if boosting then
		if not boostSound.IsPlaying then
			boostSound:Play()
		end
		boostSound.PlaybackSpeed = 1 + (1 - frac) * PITCH_RISE -- lower stamina → higher pitch
	elseif boostSound.IsPlaying then
		boostSound:Stop()
	end
end)

return M
