--!strict
--==================================================================================--
--  MeteorImpact  ·  client impact juice (LENS/feel layer · client)
--==================================================================================--
--  Listens to the StarfallImpact RemoteEvent (fired by MeteorService on the server when
--  a meteorite lands) and adds the *feel*: camera shake, a light flash, an optional
--  near-hit screen pop, and a distance-delayed boom.
--
--  Everything is DISTANCE-ATTENUATED from the camera to the impact point — a strike
--  1000 studs away barely registers; one next to you slams. Multiple close hits STACK.
--
--  Composes cleanly with the rest of the stack:
--    • shake is applied AFTER the camera updates (BindToRenderStep > Camera), so it
--      offsets whatever camera system you run instead of fighting it.
--    • the flash uses its OWN ColorCorrectionEffect, so it never clobbers RainSystem's
--      weather grade (that one writes Lighting every frame).
--==================================================================================--

local RunService = game:GetService("RunService")
local Lighting   = game:GetService("Lighting")
local Players    = game:GetService("Players")
local Debris     = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace  = game:GetService("Workspace")

local MeteorImpact = {}

--==================================================================================--
--  CONFIG
--==================================================================================--
local CONFIG = {
	shake = {
		maxDist     = 900,      -- past this, no shake
		falloff     = 2.0,      -- >1 = sharper drop-off with distance
		traumaPerHit = 0.9,     -- trauma added by a point-blank hit (0..1)
		decay       = 1.6,      -- trauma units lost per second
		maxPitch    = math.rad(4),
		maxYaw      = math.rad(4),
		maxRoll     = math.rad(6),   -- roll reads punchiest for impacts
		maxMove     = 1.5,           -- positional kick (studs)
		freq        = 22,            -- shake noise frequency (higher = buzzier)
	},

	flash = {
		maxDist   = 1400,
		falloff   = 1.6,
		brightness = 0.45,      -- peak ColorCorrection.Brightness add at a near hit
		contrast   = 0.10,
		tint       = Color3.fromRGB(255, 220, 170),  -- warm meteor-fire tint
		decay      = 6.0,       -- flash fades fast
	},

	screenFlash = {
		enabled  = true,
		nearDist = 300,         -- only near hits whiten the screen
		maxAlpha = 0.5,
		color    = Color3.fromRGB(255, 240, 210),
		decay    = 7.0,
	},

	sound = {
		enabled = false,        -- set true once you have an asset
		id      = "rbxassetid://0",
		speed   = 340,          -- studs/sec → far booms arrive late, like thunder
		volume  = 1,
		maxDist = 1600,
	},
}
MeteorImpact.Config = CONFIG

--==================================================================================--
--  state
--==================================================================================--
local trauma, flash, screenAlpha = 0, 0, 0
local clock = 0
local cc: ColorCorrectionEffect
local flashFrame: Frame?

local function n11(seed: number): number        -- noise in -1..1
	return math.noise(seed, clock * CONFIG.shake.freq) * 2
end

function MeteorImpact.AddTrauma(x: number)
	trauma = math.clamp(trauma + x, 0, 1)
end

--==================================================================================--
--  the impact handler
--==================================================================================--
local function onImpact(pos: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local dist = (cam.CFrame.Position - pos).Magnitude

	-- shake
	local sk = math.clamp(1 - dist / CONFIG.shake.maxDist, 0, 1) ^ CONFIG.shake.falloff
	MeteorImpact.AddTrauma(CONFIG.shake.traumaPerHit * sk)

	-- flash
	local fk = math.clamp(1 - dist / CONFIG.flash.maxDist, 0, 1) ^ CONFIG.flash.falloff
	flash = math.min(1, flash + fk)

	-- near-hit screen pop
	if CONFIG.screenFlash.enabled and dist < CONFIG.screenFlash.nearDist then
		screenAlpha = math.min(1, screenAlpha + (1 - dist / CONFIG.screenFlash.nearDist))
	end

	-- delayed boom (sound travels slower than the event)
	if CONFIG.sound.enabled and dist < CONFIG.sound.maxDist then
		local vk = math.clamp(1 - dist / CONFIG.sound.maxDist, 0, 1)
		task.delay(dist / CONFIG.sound.speed, function()
			local part = Instance.new("Part")
			part.Anchored, part.CanCollide, part.CanQuery, part.Transparency = true, false, false, 1
			part.Size, part.CFrame = Vector3.one, CFrame.new(pos)
			part.Parent = Workspace
			local s = Instance.new("Sound")
			s.SoundId = CONFIG.sound.id
			s.Volume = CONFIG.sound.volume * vk
			s.RollOffMaxDistance = CONFIG.sound.maxDist
			s.Parent = part
			s:Play()
			Debris:AddItem(part, 6)
		end)
	end
end

--==================================================================================--
--  per-frame: decay everything, then offset the camera AFTER it has updated
--==================================================================================--
local function onRender(dt: number)
	clock += dt

	-- decay
	trauma      = math.max(0, trauma - CONFIG.shake.decay * dt)
	flash       = math.max(0, flash - CONFIG.flash.decay * dt)
	screenAlpha = math.max(0, screenAlpha - CONFIG.screenFlash.decay * dt)

	-- flash → our own ColorCorrection (neutral at rest, so no conflict with the weather grade)
	local sh = flash  -- already 0..1
	cc.Brightness = sh * CONFIG.flash.brightness
	cc.Contrast = sh * CONFIG.flash.contrast
	cc.TintColor = Color3.new(1, 1, 1):Lerp(CONFIG.flash.tint, sh)

	-- screen pop
	if flashFrame then
		flashFrame.BackgroundColor3 = CONFIG.screenFlash.color
		flashFrame.BackgroundTransparency = 1 - screenAlpha * CONFIG.screenFlash.maxAlpha
	end

	-- camera shake (trauma² is the perceptual curve)
	if trauma > 0 then
		local cam = Workspace.CurrentCamera
		if cam then
			local s = trauma * trauma
			local c = CONFIG.shake
			local off = Vector3.new(n11(1) * c.maxMove, n11(2) * c.maxMove, 0) * s
			cam.CFrame = cam.CFrame
				* CFrame.new(off)
				* CFrame.Angles(n11(3) * c.maxPitch * s, n11(4) * c.maxYaw * s, n11(5) * c.maxRoll * s)
		end
	end
end

--==================================================================================--
--  lifecycle
--==================================================================================--
function MeteorImpact.Start()
	if MeteorImpact._running then return end
	MeteorImpact._running = true

	-- our own grade channel, neutral until a flash spikes it
	cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "MeteorImpactFlash"
	cc.Brightness, cc.Contrast = 0, 0
	cc.Parent = Lighting

	if CONFIG.screenFlash.enabled then
		local gui = Instance.new("ScreenGui")
		gui.Name = "MeteorImpactFlash"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 999
		local f = Instance.new("Frame")
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = CONFIG.screenFlash.color
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Active = false  -- never eats input
		f.Parent = gui
		flashFrame = f
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	end

	local remote = ReplicatedStorage:WaitForChild("StarfallImpact")
	MeteorImpact._sig = remote.OnClientEvent:Connect(onImpact)

	-- run AFTER the camera has been positioned, so we offset it rather than get overwritten
	RunService:BindToRenderStep("MeteorImpact", Enum.RenderPriority.Camera.Value + 10, onRender)
end

function MeteorImpact.Stop()
	if not MeteorImpact._running then return end
	MeteorImpact._running = false
	RunService:UnbindFromRenderStep("MeteorImpact")
	if MeteorImpact._sig then MeteorImpact._sig:Disconnect() end
	if cc then cc:Destroy() end
	if flashFrame then flashFrame.Parent:Destroy(); flashFrame = nil end
	trauma, flash, screenAlpha = 0, 0, 0
end

-- feel it without waiting for a real meteor:
function MeteorImpact.Test()
	local cam = Workspace.CurrentCamera
	if cam then onImpact(cam.CFrame.Position + cam.CFrame.LookVector * 120) end
end

return MeteorImpact

--==================================================================================--
--  INSTALL  ·  a LocalScript in StarterPlayerScripts:
--      require(game.ReplicatedStorage.MeteorImpact).Start()
--  Then test instantly from the client console:  require(...).Test()
--==================================================================================--
