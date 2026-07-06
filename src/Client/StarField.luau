--!strict
-- Lobby dust VFX (client-only): a dense, sparse-feeling firefly dust that
-- toroidally WRAPS around the camera so a fixed pool reads as an endless field
-- (any speck more than FIELD_RADIUS away teleports to the far side — you always
-- fly through fresh dust). Each speck gets a random firefly colour (pure random,
-- no rarity) and a gentle per-particle wobble. No drift, no player-avoid, no
-- transparency fade — the stars (server collectables) do the reactive stuff.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local rng = Random.new()

--=====================================================================
local DUST_COUNT   = 900           -- more, to fill the bigger wrap volume
local FIELD_RADIUS = 1200          -- half-size of the cube around the camera. Bigger =
                                    -- dust is farther = parallaxes SLOWER (fixes "too fast")

local DUST_SIZE    = NumberRange.new(4, 16)     -- bigger, so distant specks still read
local DUST_TRANSP  = NumberRange.new(0.0, 0.25)  -- static, subtle depth

local WOBBLE_INTENSITY = 1.5        -- studs of gentle per-speck wobble

-- Firefly palette (from Roblox-Server-Simulation std/firefly), flattened — each
-- speck picks one uniformly at random (no rarity).
local DUST_PALETTE = {
	Color3.fromRGB(43, 253, 88), Color3.fromRGB(182, 252, 77), Color3.fromRGB(38, 255, 164),
	Color3.fromRGB(253, 102, 43), Color3.fromRGB(252, 220, 77), Color3.fromRGB(255, 152, 84),
	Color3.fromRGB(255, 0, 0), Color3.fromRGB(255, 90, 99), Color3.fromRGB(175, 15, 68),
	Color3.fromRGB(44, 30, 247), Color3.fromRGB(160, 200, 255), Color3.fromRGB(120, 180, 255),
	Color3.fromRGB(217, 64, 255), Color3.fromRGB(255, 31, 199), Color3.fromRGB(255, 32, 99),
	Color3.fromRGB(255, 255, 255),
}
--=====================================================================

-- Toroidal wrap of one axis into [-r, r). Returns v unchanged while in range.
local function wrap(v: number, r: number): number
	return ((v + r) % (r * 2)) - r
end

-- Dust SHAPE variety: authored mesh templates (ReplicatedStorage.Assets.Stars — a
-- handful of little space shapes incl. a ring). Each speck clones a random one,
-- uniformly scaled to a random dust size (keeps the mesh's aspect). Falls back to a
-- neon ball if the folder's empty.
local dustTemplates: { BasePart } = {}
do
	local src = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Stars")
	for _, d in src:GetChildren() do
		if d:IsA("BasePart") then
			dustTemplates[#dustTemplates + 1] = d
		end
	end
end

local function makeSpeck(): BasePart
	local target = rng:NextNumber(DUST_SIZE.Min, DUST_SIZE.Max)
	if #dustTemplates > 0 then
		local p = dustTemplates[rng:NextInteger(1, #dustTemplates)]:Clone() :: BasePart
		local mag = p.Size.Magnitude
		if mag > 1e-3 then
			p.Size *= target / mag -- uniform scale → target diameter, aspect preserved
		end
		return p
	end
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Size = Vector3.one * target
	return p
end

local folder = Instance.new("Folder")
folder.Name = "StarField"
folder.Parent = Workspace

type Speck = { part: BasePart, pos: Vector3, offset: number, rot: CFrame }
local pool: { Speck } = {}

-- Seed around the camera once it's settled on the player.
task.wait(1)
local center0 = (Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position) or Vector3.zero

for _ = 1, DUST_COUNT do
	local p = makeSpeck()
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Material = Enum.Material.Neon
	p.Color = DUST_PALETTE[rng:NextInteger(1, #DUST_PALETTE)] -- firefly tint over the mesh
	p.Transparency = rng:NextNumber(DUST_TRANSP.Min, DUST_TRANSP.Max)
	local pos = center0
		+ Vector3.new(
			rng:NextNumber(-FIELD_RADIUS, FIELD_RADIUS),
			rng:NextNumber(-FIELD_RADIUS, FIELD_RADIUS),
			rng:NextNumber(-FIELD_RADIUS, FIELD_RADIUS)
		)
	-- Random orientation for variety; kept so the bulk move each frame re-applies it.
	local rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28))
	p.CFrame = CFrame.new(pos) * rot
	p.Parent = folder
	pool[#pool + 1] = { part = p, pos = pos, offset = rng:NextNumber(0, 100), rot = rot }
end

-- Stable parts list (pool never changes) + a reused CFrame buffer, so each frame is
-- ONE Workspace:BulkMoveTo instead of DUST_COUNT per-part .Position writes.
local parts: { BasePart } = {}
for i, e in pool do
	parts[i] = e.part
end
local cframes: { CFrame } = {}

RunService.RenderStepped:Connect(function()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local center = cam.CFrame.Position
	local now = os.clock()
	for i, e in pool do
		-- keep the base position within the wrap cube around the camera
		local rel = e.pos - center
		local nrel = Vector3.new(wrap(rel.X, FIELD_RADIUS), wrap(rel.Y, FIELD_RADIUS), wrap(rel.Z, FIELD_RADIUS))
		if nrel ~= rel then
			e.pos = center + nrel
		end
		-- gentle per-speck wobble (does not move the camera — these are dust)
		local t = now + e.offset
		local wob = Vector3.new(math.sin(t * 1.5), math.cos(t * 2) * 0.5, math.sin(t * 1.2)) * WOBBLE_INTENSITY
		cframes[i] = CFrame.new(e.pos + wob) * e.rot
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)

return {}
