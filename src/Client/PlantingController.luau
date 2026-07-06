-- StarterPlayerScripts/PlantingController.luau
-- Star-seed planting mode (Lobby). Flow:
--   begin() → a ghost Planet overlay snaps to the nearest grid cell as you fly,
--             green when plantable / red when not.
--   [F]     → lock that cell + open the CreatePlanet name prompt.
--   prompt  → on confirm, fire PlantStar{name,cx,cz}; the SERVER re-validates the
--             cell + name uniqueness and replies PlantStarResult. Success finalises
--             the overlay; failure (name/cell taken) shows in the prompt's log.
--   [X] / prompt-cancel → back out.
-- The client only PROPOSES a cell; the server owns the commit (no client authority).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local blink = require(ReplicatedStorage.std.ClientNet)
local planting = require(ReplicatedStorage.std.planting)
local constellation = require(ReplicatedStorage.std.constellation)
local UIController = require(script.Parent.UI).Controller
local CreatePlanet = require(script.Parent.CreatePlanetController)

local player = Players.LocalPlayer
local planetAsset = ReplicatedStorage:WaitForChild("Assets"):FindFirstChild("Planet")

local M = {}

if not planetAsset then
	warn("[Planting] ReplicatedStorage.Assets.Planet not found; planting disabled")
	function M.begin() end
	return M
end

local GREEN = Color3.fromRGB(90, 220, 120)
local RED = Color3.fromRGB(220, 80, 80)
local CENTER_Y = constellation.CENTER.Y

local active = false
local locked = false -- true while the name prompt is open (cell frozen)
local lockedCx, lockedCz = 0, 0
local overlay: Model? = nil
local overlayParts: { BasePart } = {}
local hud: TextLabel? = nil
local currentValid = false
local pendingReport: ((boolean, string?) -> ())? = nil
local renderConn: RBXScriptConnection? = nil
local inputConn: RBXScriptConnection? = nil

local function rootPos(): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root and root.Position or nil
end

local function tint(color: Color3)
	for _, p in overlayParts do
		p.Color = color
	end
end

local function buildOverlay()
	local m = planetAsset:Clone() :: Model
	overlayParts = {}
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Transparency = 0.5
			d.Material = Enum.Material.Neon
			table.insert(overlayParts, d)
		end
	end
	m.Parent = workspace
	local ext = m:GetExtentsSize()
	m:ScaleTo((planting.CELL * 0.4) / math.max(ext.Magnitude, 1))
	overlay = m
end

local function buildHud()
	local t = Instance.new("TextLabel")
	t.Name = "PlantingHud"
	t.AnchorPoint = Vector2.new(0.5, 1)
	t.Position = UDim2.new(0.5, 0, 1, -40)
	t.Size = UDim2.new(0, 420, 0, 30)
	t.BackgroundTransparency = 0.35
	t.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextScaled = true
	t.Font = Enum.Font.GothamMedium
	t.Text = "Fly to a spot  •  [F] place  •  [X] cancel"
	t.Parent = player:WaitForChild("PlayerGui"):WaitForChild("Interface")
	hud = t
end

local function update()
	if locked then
		return -- cell frozen while naming
	end
	local pos = rootPos()
	if not pos or not overlay then
		return
	end
	local cx, cz = planting.cellIndex(pos)
	local center = planting.centerFromIndex(cx, cz)
	center = Vector3.new(center.X, CENTER_Y, center.Z)
	overlay:PivotTo(CFrame.new(center))
	currentValid = planting.isPlantable(center)
	tint(if currentValid then GREEN else RED)
	if hud then
		hud.Text = if currentValid
			then "Plantable  •  [F] place  •  [X] cancel"
			else "Too close to a star/black hole  •  [X] cancel"
	end
end

local function finalize()
	-- Success: leave a solid local planet as immediate feedback. (Authoritative
	-- replicated render of planted stars is the neighbour-preview feature — doc 14.)
	if overlay then
		for _, p in overlayParts do
			p.Transparency = 0
			p.Material = Enum.Material.SmoothPlastic
			p.Color = Color3.fromRGB(180, 180, 200)
		end
		overlay.Name = "PlantedStar"
		overlay = nil -- keep it in workspace; don't destroy on stop
	end
	M.stop()
end

function M.stop()
	active = false
	locked = false
	pendingReport = nil
	if renderConn then renderConn:Disconnect(); renderConn = nil end
	if inputConn then inputConn:Disconnect(); inputConn = nil end
	if CreatePlanet then CreatePlanet.close() end
	if overlay then overlay:Destroy(); overlay = nil end
	if hud then hud:Destroy(); hud = nil end
	overlayParts = {}
end

local function tryPlace()
	if locked or not currentValid or not overlay then
		if not currentValid then
			UIController.sound("Error")
		end
		return
	end
	local pos = rootPos()
	if not pos then
		return
	end
	lockedCx, lockedCz = planting.cellIndex(pos)
	locked = true

	CreatePlanet.open({
		onSubmit = function(name, report)
			pendingReport = report
			blink.PlantStar.Fire({ name = name, cx = lockedCx, cz = lockedCz })
		end,
		onCancel = function()
			locked = false -- re-pick a spot (overlay follows again); [X] fully exits
		end,
	})
end

-- Server's verdict on a PlantStar request → route to the prompt's report callback.
blink.PlantStarResult.On(function(res)
	local report = pendingReport
	pendingReport = nil
	if report then
		report(res.ok, res.reason)
	end
	if res.ok then
		finalize()
	end
end)

function M.begin()
	if active then
		return
	end
	active = true
	locked = false
	buildOverlay()
	buildHud()
	renderConn = RunService.RenderStepped:Connect(update)
	inputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not active then
			return
		end
		if input.KeyCode == Enum.KeyCode.F then
			tryPlace()
		elseif input.KeyCode == Enum.KeyCode.X then
			if not locked then
				M.stop()
			end
		end
	end)
end

-- Star Seed click (from the inventory) enters planting mode.
require(script.Parent.ItemUse).register("plant_star", function()
	M.begin()
end)

return M
