--!strict
-- Parallax proxies for ALL celestial landmarks (black hole + starter stars),
-- with their rings spun. Each landmark's REAL position lives on the server
-- (config, for gameplay); the client renders a local proxy cloned from
-- ReplicatedStorage.Assets[template], kept a short distance in FRONT of the
-- camera toward the real position and scaled for perspective — so a star 6,000
-- studs away renders close + crisp with no huge geometry.
--
-- Perspective is exact: proxy of size `baseScale * dist/d` at distance
-- `dist = min(proxyDist, d)` looks like a real object of size baseScale at the
-- real position (d = camera→landmark distance). Apparent size is baseScale/d —
-- INDEPENDENT of proxyDist. So proxyDist doesn't set how big a landmark looks; it
-- sets its render DEPTH (for occlusion vs planets) and how close the camera sits to
-- the geometry. Two consequences drive the per-landmark proxyDist in `constellation`:
--   • Stars: pushed FAR (18000, beyond the universe render distance) so real planets
--     draw IN FRONT of them instead of the proxy covering everything.
--   • Black hole: kept CLOSE. Its accretion VFX are ParticleEmitters, and Roblox
--     distance-culls particles a few thousand studs out — at 18000 they never render.
--     It sits alone in the empty maw void (nothing to occlude it), so near is free.
--
-- Rings (the model's UnionOperations) are spun about THEIR OWN centre each frame,
-- re-derived from the proxy's current position + scale — so the parallax move +
-- scale doesn't fling them off-axis (the old StarRings captured world pivots once
-- and broke as soon as the proxy started moving).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))
local Assets = ReplicatedStorage:WaitForChild("Assets")

-- Per-ring spin axis (world) + angular speed (rad/s), cycled across a model's rings.
local RING_AXES = {
	Vector3.new(0, 1, 0),
	Vector3.new(1, 0, 0.35).Unit,
	Vector3.new(0.4, 1, 0.7).Unit,
}
local RING_SPEEDS = { 0.3, -0.5, 0.7 }

type Ring = { part: BasePart, offset: Vector3, rot: CFrame, axis: Vector3, speed: number, angle: number }
type Proxy = { model: Model, pos: Vector3, baseScale: number, proxyDist: number, rings: { Ring } }
local proxies: { Proxy } = {}

for _, L in constellation.LANDMARKS do
	local template = Assets:FindFirstChild(L.template)
	if template and template:IsA("Model") then
		local m = template:Clone()
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
			end
		end
		m.Parent = Workspace

		-- Capture ring Unions relative to the model pivot (at scale 1).
		local pivotInv = m:GetPivot():Inverse()
		local rings: { Ring } = {}
		for _, d in m:GetDescendants() do
			if d:IsA("UnionOperation") then
				local local_ = pivotInv * d.CFrame
				local i = #rings + 1
				rings[i] = {
					part = d,
					offset = local_.Position,
					rot = local_.Rotation,
					axis = RING_AXES[(i - 1) % #RING_AXES + 1],
					speed = RING_SPEEDS[(i - 1) % #RING_SPEEDS + 1],
					angle = 0,
				}
			end
		end

		proxies[#proxies + 1] =
			{ model = m, pos = L.pos, baseScale = L.baseScale, proxyDist = L.proxyDist, rings = rings }
	else
		warn(`[SpaceProxies] ReplicatedStorage.Assets.{L.template} missing — skipping its proxy.`)
	end
end

-- Bind AFTER the camera (CameraController binds at RenderPriority.Camera). A proxy
-- is rendered close to the camera, so its apparent position is hyper-sensitive to
-- the camera position — if we placed it against a camera that then moves later in
-- the frame, the error scales with speed and the proxy visibly shakes. Running one
-- priority tick after the camera guarantees we read the frame's FINAL camera CFrame.
RunService:BindToRenderStep("SpaceProxies", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	for _, p in proxies do
		local toC = p.pos - camPos
		local d = toC.Magnitude
		if d > 1e-3 then
			local dist = math.min(p.proxyDist, d)
			local scale = p.baseScale * dist / d
			local proxyPos = camPos + toC.Unit * dist
			p.model:ScaleTo(scale)
			p.model:PivotTo(CFrame.new(proxyPos))

			-- Spin each ring about its own (scaled, current) centre around a world axis.
			for _, r in p.rings do
				r.angle += r.speed * dt
				local ringPos = proxyPos + r.offset * scale
				r.part.CFrame = CFrame.new(ringPos) * CFrame.fromAxisAngle(r.axis, r.angle) * r.rot
			end
		end
	end
end)

return {}
