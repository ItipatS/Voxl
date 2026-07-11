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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))

local player = Players.LocalPlayer

local DIAMETER = constellation.VOID_RADIUS * 2 -- 28000

-- The shell is only worth showing as you close in on the void boundary — otherwise it's a
-- giant red bubble hanging in the sky from across the map. Fade + pulse it in over the last
-- APPROACH_MARGIN studs before VOID_RADIUS; fully hidden beyond that, fully lit once inside.
local APPROACH_MARGIN = 1000 -- [TUNE] how far out the warning starts fading in
local TRIGGER_RADIUS = constellation.VOID_RADIUS + APPROACH_MARGIN -- 18000

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

-- Only appear (and pulse) as the player nears the void: proximity `t` ramps 0→1 across the last
-- APPROACH_MARGIN studs, staying 1 once inside VOID_RADIUS. t=0 → fully transparent (hidden).
RunService.RenderStepped:Connect(function()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local origin = if root then root.Position else Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position
	if not origin then
		sphere.Transparency = 1
		return
	end

	local dist = (origin - constellation.CENTER).Magnitude
	local t = math.clamp((TRIGGER_RADIUS - dist) / APPROACH_MARGIN, 0, 1)
	if t <= 0 then
		sphere.Transparency = 1 -- far off: fully hidden, no pulse
		return
	end

	-- A subtle breathing pulse so the boundary reads as "alive / dangerous", not just decor —
	-- blended from invisible (t=0) toward the lit, pulsing shell (t=1).
	local pulse = 0.3 + math.sin(os.clock() * 1.5) * 0.08
	sphere.Transparency = 1 - t * (1 - pulse)
end)

return {}
