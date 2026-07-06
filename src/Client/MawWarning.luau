--!strict
-- Maw danger warning (client-only visual). A big faint-red SelectionSphere around the
-- black hole's VOID zone (radius = constellation.VOID_RADIUS = event horizon + 2000).
-- Dust + collectable stars stop generating inside it (std/dust + collectables cull), so as
-- you approach the maw the field THINS OUT and this ominous shell appears — "something is
-- wrong" — well before the point-of-no-return event horizon at BLACKHOLE.radius.
--
-- SelectionSphere renders from any angle (unlike a backface-culled mesh) and isn't bound
-- by the 2048-stud part-size limit, so it can be this big. It pulses slightly for menace.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

-- A tiny invisible anchor at the real maw centre — SelectionSphere adorns to it.
local anchor = Instance.new("Part")
anchor.Name = "MawWarning"
anchor.Anchored = true
anchor.CanCollide = false
anchor.CanQuery = false
anchor.CanTouch = false
anchor.Transparency = 1
anchor.Size = Vector3.one
anchor.CFrame = CFrame.new(constellation.CENTER)
anchor.Parent = Workspace

local sphere = Instance.new("SelectionSphere")
sphere.Adornee = anchor
sphere.Radius = constellation.VOID_RADIUS
sphere.SurfaceColor3 = Color3.fromRGB(140, 20, 20) -- ominous red fill
sphere.SurfaceTransparency = 0.86 -- faint, so you can still see through toward the maw
sphere.Color3 = Color3.fromRGB(255, 70, 70) -- brighter rim
sphere.Transparency = 0.35
sphere.Parent = anchor

-- A subtle breathing pulse so the boundary reads as "alive / dangerous", not just decor.
RunService.RenderStepped:Connect(function()
	local pulse = 0.82 + math.sin(os.clock() * 1.5) * 0.06
	sphere.SurfaceTransparency = pulse
end)

return {}
