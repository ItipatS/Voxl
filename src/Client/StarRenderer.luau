--!strict
-- Client renderer for the STREAMED collectable star field. The server streams
-- near-player star positions (Blink StarStream / StarUnload); we clone a local
-- model per id, interpolate toward the streamed position (no snapping), dim its
-- light by distance, and offer a "Catch" prompt that requests a server-validated
-- catch (StarCatch). On StarCaught we play the burst + sound and remove it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local blink = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("ClientNet"))
local player = Players.LocalPlayer

local template = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Star")
local UISound = require(script.Parent:WaitForChild("UI")).Sound
local burstTemplate = template:FindFirstChild("Part") and template.Part:FindFirstChild("ParticleEmitter")

local CATCH_RADIUS = 16
local DIM_RADIUS = 60
local DIM_NEAR = 12
local MIN_BRIGHT = 0.1
local LERP = 12 -- position smoothing

local folder = Instance.new("Folder")
folder.Name = "StarField"
folder.Parent = Workspace

type LocalStar =
	{ model: Model, part: BasePart?, pivotOffset: CFrame, light: PointLight?, base: number, target: Vector3, cur: Vector3 }
local byId: { [number]: LocalStar } = {}

local function spawn(id: number, pos: Vector3)
	local m = template:Clone()
	local light: PointLight? = nil
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
		elseif d:IsA("PointLight") then
			light = d
		end
	end
	m:PivotTo(CFrame.new(pos))

	-- Star is a single-part model, so we move its ONE part directly (via a bulk move in
	-- the render loop) instead of model:PivotTo per star. pivotOffset reproduces PivotTo
	-- exactly: part.CFrame = CFrame.new(cur) * pivotOffset. It's invariant under PivotTo.
	local part = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
	local pivotOffset = CFrame.identity
	if part then
		pivotOffset = m:GetPivot():Inverse() * part.CFrame
		local prompt = Instance.new("ProximityPrompt")
		prompt.Style = Enum.ProximityPromptStyle.Custom -- expressive-prompts (Prompts) renders it
		prompt.ActionText = "Catch"
		prompt.ObjectText = "Star"
		prompt.HoldDuration = 0.2
		prompt.MaxActivationDistance = CATCH_RADIUS
		prompt.RequiresLineOfSight = false
		prompt.Parent = part
		prompt.Triggered:Connect(function()
			blink.StarCatch.Fire(id) -- server validates proximity + awards
		end)
	end

	m.Parent = folder
	byId[id] = {
		model = m,
		part = part,
		pivotOffset = pivotOffset,
		light = light,
		base = if light then light.Brightness else 2,
		target = pos,
		cur = pos,
	}
end

blink.StarStream.On(function(states)
	for _, s in states do
		local ls = byId[s.id]
		if ls then
			ls.target = s.dp
		else
			spawn(s.id, s.dp)
		end
	end
end)

blink.StarUnload.On(function(ids)
	for _, id in ids do
		local ls = byId[id]
		if ls then
			ls.model:Destroy()
			byId[id] = nil
		end
	end
end)

blink.StarCaught.On(function(id)
	local ls = byId[id]
	if not ls then
		return
	end
	local pos = ls.cur
	ls.model:Destroy()
	byId[id] = nil

	-- catch burst + sound at the spot (independent temp part)
	local fx = Instance.new("Part")
	fx.Anchored = true
	fx.CanCollide = false
	fx.CanQuery = false
	fx.Transparency = 1
	fx.Size = Vector3.one
	fx.CFrame = CFrame.new(pos)
	fx.Parent = folder
	if burstTemplate then
		local pe = burstTemplate:Clone() :: ParticleEmitter
		pe.Enabled = false
		pe.Parent = fx
		pe:Emit(30)
	end
	UISound.play("Star Catch") -- recursive lookup: survives the SFX subfolder reorg
	task.delay(3, function()
		fx:Destroy()
	end)
end)

-- Reused scratch buffers: move all streamed stars in ONE Workspace:BulkMoveTo per
-- frame instead of a model:PivotTo each. Persist across frames, trimmed to live count.
local parts: { BasePart } = {}
local cframes: { CFrame } = {}

RunService.RenderStepped:Connect(function(dt: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local pp = if root and root:IsA("BasePart") then root.Position else nil
	local a = math.clamp(LERP * dt, 0, 1)
	local n = 0
	for _, ls in byId do
		ls.cur = ls.cur:Lerp(ls.target, a)
		if ls.part then
			n += 1
			parts[n] = ls.part
			cframes[n] = CFrame.new(ls.cur) * ls.pivotOffset
		end
		if ls.light and pp then
			local d = (ls.cur - pp).Magnitude
			local f = 1
			if d < DIM_RADIUS then
				f = MIN_BRIGHT + (1 - MIN_BRIGHT) * math.clamp((d - DIM_NEAR) / (DIM_RADIUS - DIM_NEAR), 0, 1)
			end
			ls.light.Brightness = ls.base * f
		end
	end
	for i = #parts, n + 1, -1 do -- trim stale entries from a previously larger frame
		parts[i] = nil
		cframes[i] = nil
	end
	if n > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end)

return {}
