--!strict
-- Client renderer for the STREAMED asteroid hazard field. The server streams each
-- rock's pos + velocity ONCE when it enters range (AsteroidStream); we clone a random
-- mesh from ReplicatedStorage.Assets.Astroids, scale it to the rock's world size, give
-- it a faint Highlight (visible in line-of-sight so a careful flier can spot + dodge —
-- NOT a wallhack, and a booster is going too fast to react), and DEAD-RECKON its
-- position each frame from pos + vel*t (constant velocity, so this is exact). Collision
-- + damage are the server's job (systems/asteroids); this module is pure visuals.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local blink = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("ClientNet"))

local rng = Random.new()

local shapes: { BasePart } = {}
do
	local src = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Astroids")
	for _, d in src:GetChildren() do
		if d:IsA("BasePart") then
			shapes[#shapes + 1] = d
		end
	end
end

local folder = Instance.new("Folder")
folder.Name = "AsteroidField"
folder.Parent = Workspace

type Rock = {
	part: BasePart,
	pos: Vector3,
	vel: Vector3,
	recv: number,
	spinAxis: Vector3,
	spinSpeed: number,
	angle: number,
}
local byId: { [number]: Rock } = {}

local function spawn(id: number, dp: Vector3, vel: Vector3, size: number, shape: number)
	if #shapes == 0 then
		return
	end
	local part = shapes[math.clamp(shape, 1, #shapes)]:Clone() :: BasePart
	local mag = part.Size.Magnitude
	if mag > 1e-3 then
		part.Size *= (size * 2) / mag -- uniform scale to the rock's world diameter
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true

	--[[local hl = Instance.new("Highlight")
	hl.FillTransparency = 1 -- outline only — a faint edge, not a filled blob
	hl.OutlineTransparency = 0.55
	hl.OutlineColor = Color3.fromRGB(255, 120, 80) -- warm hazard tint
	hl.DepthMode = Enum.HighlightDepthMode.Occluded -- only when actually in view (dodgeable, not x-ray)
	hl.Adornee = part
	hl.Parent = part]]

	part.Parent = folder
	byId[id] = {
		part = part,
		pos = dp,
		vel = vel,
		recv = os.clock(),
		spinAxis = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)).Unit,
		spinSpeed = rng:NextNumber(0.1, 0.5),
		angle = rng:NextNumber(0, 6.28),
	}
end

blink.AsteroidStream.On(function(states)
	for _, s in states do
		local r = byId[s.id]
		if r then
			r.pos, r.vel, r.recv = s.dp, s.vel, os.clock() -- refresh dead-reckon anchor
		else
			spawn(s.id, s.dp, s.vel, s.size, s.shape)
		end
	end
end)

blink.AsteroidUnload.On(function(ids)
	for _, id in ids do
		local r = byId[id]
		if r then
			r.part:Destroy()
			byId[id] = nil
		end
	end
end)

-- Reused scratch buffers: we move every rock in ONE Workspace:BulkMoveTo call per
-- frame instead of N per-part .CFrame writes (each of those hits the property/replication
-- path individually). Buffers persist across frames and get trimmed to the live count.
local parts: { BasePart } = {}
local cframes: { CFrame } = {}

RunService.RenderStepped:Connect(function(dt: number)
	local now = os.clock()
	local n = 0
	for _, r in byId do
		r.angle += r.spinSpeed * dt
		local cur = r.pos + r.vel * (now - r.recv) -- exact: constant velocity
		n += 1
		parts[n] = r.part
		cframes[n] = CFrame.new(cur) * CFrame.fromAxisAngle(r.spinAxis, r.angle)
	end
	for i = #parts, n + 1, -1 do -- drop stale entries from a previously larger frame
		parts[i] = nil
		cframes[i] = nil
	end
	if n > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end)

return {}
