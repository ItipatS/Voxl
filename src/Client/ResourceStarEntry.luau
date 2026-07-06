--!strict
-- Resource-star entry (client), APPROACH-based: fly within WARP_RADIUS of a resource
-- star and a HUD countdown starts ("Entering Forest Star…  3"); stay in range through
-- it and you warp into that biome's gathering world. Leave range and it cancels. It's
-- "fly into the star", not a click/hold prompt (that's for catching, not travel).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local constellation = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("constellation"))
local placemode = require(ReplicatedStorage.std:WaitForChild("placemode"))
local UI = require(script.Parent.UI)
local player = Players.LocalPlayer

local ENTER_SECONDS = 3
local RADIUS = constellation.WARP_RADIUS

-- Resource-star landmarks (skip the black hole). name = display biome.
type Target = { name: string, pos: Vector3 }
local targets: { Target } = {}
for _, L in constellation.LANDMARKS do
	if L.template ~= "BlackHole" then
		targets[#targets + 1] = { name = (L.template :: string):gsub("Star$", ""), pos = L.pos }
	end
end

local function enter(biome: string)
	local ok, err = pcall(function()
		local opts = Instance.new("TeleportOptions")
		opts:SetTeleportData({ biome = biome })
		TeleportService:TeleportAsync(placemode.RESOURCE_PLACE_ID, { player }, opts)
	end)
	if not ok then
		warn(`[ResourceStarEntry] warp to '{biome}' unavailable (Studio/unpublished?): {err}`)
	end
end

-- HUD
local gui = Instance.new("ScreenGui")
gui.Name = "ResourceEntryHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(0.5, 0.1)
label.Position = UDim2.fromScale(0.25, 0.16)
label.BackgroundTransparency = 1
label.TextScaled = true
label.FontFace = UI.Data.Font -- Silkscreen
label.TextColor3 = Color3.fromRGB(235, 240, 255)
label.TextStrokeTransparency = 0.4
label.Visible = false
label.Parent = gui

local current: Target? = nil
local entered: Target? = nil -- already entered this one; wait until we leave range
local timeLeft = 0

local function rootPos(): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

RunService.Heartbeat:Connect(function(dt: number)
	local pos = rootPos()
	if not pos then
		label.Visible = false
		current = nil
		return
	end

	local near: Target?, nearD = nil, RADIUS
	for _, t in targets do
		local d = (t.pos - pos).Magnitude
		if d < nearD then
			near, nearD = t, d
		end
	end

	if not near then
		current, entered = nil, nil
		label.Visible = false
		return
	end
	if near == entered then
		label.Visible = false -- already entered; wait until we leave range
		return
	end
	if current ~= near then
		current = near
		timeLeft = ENTER_SECONDS
	end
	timeLeft -= dt
	if timeLeft <= 0 then
		enter(near.name)
		entered, current = near, nil
		label.Visible = false
	else
		label.Text = `Entering The {near.name}…  {math.ceil(timeLeft)}`
		label.Visible = true
	end
end)

return {}
