--!strict
-- Maw danger warning (client-only visual). A big ForceField "bubble" around the black
-- hole's VOID zone (radius = constellation.VOID_RADIUS = event horizon + 2000). Dust +
-- collectable stars stop generating inside it (std/dust + collectables cull), so as you
-- approach the maw the field THINS OUT and this ominous shimmering shell appears — "something
-- is wrong" — well before the point-of-no-return event horizon at BLACKHOLE.radius.
--
-- Built as a Part + SpecialMesh(Sphere), NOT a SelectionSphere (no Radius; capped to its
-- adornee's ≤2048-stud size) and NOT a Ball Part (also 2048-capped): SpecialMesh.Scale
-- bypasses the size limit, and ForceField material renders the translucent energy shell from
-- any angle (inside + outside).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

local DIAMETER = constellation.VOID_RADIUS * 2 -- 28000

local sphere = Instance.new("Part")
sphere.Name = "MawWarning"
sphere.Anchored = true
sphere.CanCollide = false
sphere.CanQuery = false
sphere.CanTouch = false
sphere.Locked = true
sphere.CastShadow = false
sphere.Material = Enum.Material.ForceField
sphere.Color = Color3.fromRGB(255, 60, 60) -- ominous red energy
sphere.Size = Vector3.one -- the SpecialMesh drives the visual size, not this
sphere.CFrame = CFrame.new(constellation.CENTER)

local mesh = Instance.new("SpecialMesh")
mesh.MeshType = Enum.MeshType.Sphere
mesh.Scale = Vector3.new(DIAMETER, DIAMETER, DIAMETER)
mesh.Parent = sphere

sphere.Parent = Workspace

-- A subtle breathing pulse so the boundary reads as "alive / dangerous", not just decor.
RunService.RenderStepped:Connect(function()
	sphere.Transparency = 0.3 + math.sin(os.clock() * 1.5) * 0.08
end)

return {}
