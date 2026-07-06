--[[
	InitLensFlare
	10/20/25
	@gluGPU
	
	Initiates the LensFlare Module.
--]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")


local LensFlare = require(script.Engine)
local Configuration = require(script.Config)

local camera = workspace.CurrentCamera

local SUN_DISTANCE = 5000

local SUN_EXPOSURE_ADJUST = Configuration.SUN_EXPOSURE_ADJUSTMENT
local SUN_EXPOSURE_SMOOTH_TIME = Configuration.SUN_EXPOSURE_TIME

local SUN_BRIGHTNESS_THRESHOLD = Configuration.SUN_BRIGHTNESS_THRESHOLD
local SUN_ANGLE_THRESHOLD = Configuration.SUN_ANGLE_THRESHOLD

-- Sun Lens Flare
local sunPart = Instance.new("Part")
sunPart.Anchored = true
sunPart.CanCollide = false
sunPart.CanQuery = false
sunPart.CanTouch = false
sunPart.Transparency = 0.5
sunPart.Size = vector.create(1, 1, 1)
sunPart.Name = "SunFlareTestPart"
sunPart.Parent = workspace

sunPart:SetAttribute("LensFlareStrength", 1)

local sunFlare = LensFlare.new(camera, "Default", sunPart)

local function updateColor()
	sunPart.Color = Lighting.ColorShift_Top
end

updateColor()
Lighting:GetPropertyChangedSignal("ColorShift_Top"):Connect(updateColor)

local function updateStrength()
	local sunAngle = Lighting:GetSunDirection().Y * 90
	local sunAlpha = math.clamp(sunAngle / SUN_ANGLE_THRESHOLD, 0, 1)
	local brightnessAlpha = math.clamp(Lighting.Brightness / SUN_BRIGHTNESS_THRESHOLD, 0, 1)
	local totalAlpha = sunAlpha * brightnessAlpha
	
	sunFlare.Enabled = totalAlpha > 0
	
	sunPart:SetAttribute("LensFlareStrength", totalAlpha)
end

updateStrength()
Lighting:GetPropertyChangedSignal("Brightness"):Connect(updateStrength)
Lighting:GetPropertyChangedSignal("ClockTime"):Connect(updateStrength)

RunService:BindToRenderStep("UpdateLensFlarePart", Enum.RenderPriority.Camera.Value + 9, function()
	sunPart.Position = camera.CFrame.Position + (Lighting:GetSunDirection() * SUN_DISTANCE)
end)

local alpha, vel = 0, 0
RunService:BindToRenderStep("UpdateExposure", Enum.RenderPriority.Camera.Value + 11, function(delta: number)
	Lighting.ExposureCompensation -= (alpha * SUN_EXPOSURE_ADJUST)
	alpha, vel = TweenService:SmoothDamp(alpha, sunFlare.Alpha^2, vel, SUN_EXPOSURE_SMOOTH_TIME, nil, delta)
	Lighting.ExposureCompensation += (alpha * SUN_EXPOSURE_ADJUST)
end)


local parts = {}
for _, part in CollectionService:GetTagged("LensFlare") do
	if part:IsA("BasePart") or part:IsA("Attachment") and not parts[part] then
		local flare = LensFlare.new(camera, part:GetAttribute("LensFlareStyle"), part)
		parts[part] = flare
	end
end

CollectionService:GetInstanceAddedSignal("LensFlare"):Connect(function(object: Instance)
	if object:IsA("BasePart") or object:IsA("Attachment") and not parts[object] then
		local flare = LensFlare.new(camera, object:GetAttribute("LensFlareStyle"), object)
		parts[object] = flare
	end
end)

CollectionService:GetInstanceRemovedSignal("LensFlare"):Connect(function(object: Instance)
	if parts[object] then
		parts[object]:Destroy()
		parts[object] = nil
	end
end)

-- This is a side-effecting module (it builds the flare + binds render steps above). It is
-- required as a ModuleScript, so it MUST return a value or you get "Module code did not
-- return exactly one value". (FTC-209)
return true