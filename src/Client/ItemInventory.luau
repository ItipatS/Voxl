-- StarterPlayerScripts/ItemInventory.luau
-- The inventory window: a STATIC 45-slot grid (mirror slots 10-54) in
-- Interface.Inventory.ItemSlots. Left-click = pick up / drop (ItemDrag), right-click
-- = consume (Consumables). Each occupied slot shows its item (3D model / icon /
-- debug), quantity, grade-tinted border + grade name (rainbow for the ultimate Star
-- Seed), and a hover tooltip. Plus a weight bar. VIEW ONLY — server is authoritative.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local itemdb = require(ReplicatedStorage.std.itemdb)
local BlockPreview = require(script.Parent:WaitForChild("BlockPreview"))
local ItemMirror = require(script.Parent.ItemMirror)
local ItemDrag = require(script.Parent.ItemDrag)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")
local interface = gui:WaitForChild("Interface", 10)
local inventory = interface and interface:FindFirstChild("Inventory")
local itemSlots = inventory and inventory:FindFirstChild("ItemSlots")
local templates = StarterGui:FindFirstChild("ItemTemplate")
local slotTemplate = templates and templates:FindFirstChild("ItemTemplate")
local infoTemplate = templates and templates:FindFirstChild("InformationFrame")

if not (itemSlots and slotTemplate and infoTemplate) then
	warn("[ItemInventory] Interface/ItemTemplate not found here; inventory UI disabled")
	return {}
end

local INV_START, INV_END = 10, 54 -- 45 inventory slots (hotbar 1-9 is ItemHotbar)
local ITEMS = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Items")

-- ---- shared tooltip ---------------------------------------------------------
local info = infoTemplate:Clone()
info.Visible = false
info.TextLabel.RichText = true -- full-spec body uses coloured <font> tags
info.Parent = interface
local infoStops: any = nil

local function showTooltip(slot: GuiObject, def)
	local look = UI.Data:GetGradeLook(def.grade)
	-- Representative grade colour for the header (last keypoint of an animated grade).
	local gradeColor = if typeof(look) == "Color3"
		then look
		else look.colorSequence.Keypoints[#look.colorSequence.Keypoints].Value
	info.TextLabel.Text = UI.tooltip({
		Category = def.kind,
		Grade = def.grade,
		Tier = def.tier,
		GradeColor = gradeColor,
		DescriptionLines = def.desc,
		Weight = def.weight,
		Stack = def.stack,
	})
	info.NameLabel.Text = def.name
	UI.clearGrade(infoStops, info.NameLabel, if typeof(look) == "Color3" then look else nil)
	infoStops = UI.grade(info.NameLabel, def.grade)
	info.Position = UDim2.fromOffset(slot.AbsolutePosition.X + slot.AbsoluteSize.X / 2, slot.AbsolutePosition.Y)
	info.Visible = true
end

-- ---- slot visuals -----------------------------------------------------------
local function renderModel(vp: ViewportFrame, modelName: string): boolean
	vp:ClearAllChildren()
	local asset = ITEMS and ITEMS:FindFirstChild(modelName)
	if not asset then
		return false
	end
	local m = asset:Clone()
	for _, p in m:GetDescendants() do
		if p:IsA("ParticleEmitter") or p:IsA("Beam") or p:IsA("Trail") then
			p.Enabled = false
		end
	end
	m.Parent = vp
	local cam = Instance.new("Camera")
	cam.Parent = vp
	vp.CurrentCamera = cam
	local pivot, size
	if m:IsA("Model") then
		pivot, size = m:GetBoundingBox()
	elseif m:IsA("BasePart") then
		pivot, size = m.CFrame, m.Size
	else
		pivot, size = CFrame.identity, Vector3.one * 4
	end
	cam.CFrame = CFrame.lookAt(pivot.Position + Vector3.new(0.5, 0.4, 1).Unit * math.max(size.Magnitude, 2) * 1.1, pivot.Position)
	return true
end

local function iconLabel(slot: GuiObject): ImageLabel
	local icon = slot:FindFirstChild("Icon") :: ImageLabel?
	if not icon then
		icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromScale(1, 1)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = slot
	end
	return icon
end

local SLOT_IMAGE = "rbxassetid://111907724412912" -- slot tileset (border is the slot image itself)
local SLOT_RECT = Vector2.new(64, 64)
local SLOT_BASE_OFFSET = Vector2.new(384, 0) -- the plain-slot tile

local slotStops: { [Instance]: any } = {}
local borderStops: { [Instance]: (() -> ())? } = {} -- per-slot grade border animation stop

local function clearBorder(slot: ImageButton)
	if borderStops[slot] then
		borderStops[slot]()
		borderStops[slot] = nil
	end
end

local function clearStops(nameLabel: Instance)
	if slotStops[nameLabel] then
		UI.clearGrade(slotStops[nameLabel])
		slotStops[nameLabel] = nil
	end
end

-- Fill a static slot with an entry (or clear it to empty).
local function fill(slot: ImageButton, entry)
	local vp = slot:FindFirstChild("ViewportFrame") :: ViewportFrame?
	local q = slot:FindFirstChild("Quantity") :: TextLabel?
	local icon = slot:FindFirstChild("Icon") :: ImageLabel?
	local name = slot:FindFirstChild("ItemName") :: TextLabel?

	if not entry then
		if vp then vp:ClearAllChildren(); vp.Visible = false end
		if icon then icon.Visible = false end
		if q then q.Text = "" end
		if name then name.Text = ""; clearStops(name) end
		clearBorder(slot)
		slot.ImageColor3 = Color3.new(1, 1, 1)
		return
	end

	local def = itemdb.byKey(entry.key)
	if not def then
		return
	end
	-- visual: block cube > 3D model > icon > debug
	if def.placesBlock and vp then
		-- A block draws itself. ~190 blocks would otherwise need ~190 hand-made
		-- sprites, and the cube is always right because it IS the block.
		BlockPreview.build(vp, def.placesBlock)
		vp.Visible = true
		if icon then icon.Visible = false end
	elseif def.model and vp and renderModel(vp, def.model) then
		vp.Visible = true
		if icon then icon.Visible = false end
	else
		if vp then vp.Visible = false end
		local ic = iconLabel(slot)
		ic.Image = if def.icon then def.icon else itemdb.DEBUG_ICON
		ic.Visible = true
	end
	if q then
		q.Text = if def.stack > 1 and entry.count > 1 then `x{entry.count}` else ""
	end
	-- grade border on the slot image (static colour, or animated for the ultimate seed)
	clearBorder(slot)
	borderStops[slot] = UI.borderFX(slot, def.grade)
	if not name then
		name = Instance.new("TextLabel")
		name.Name = "ItemName"
		name.BackgroundTransparency = 1
		name.Size = UDim2.fromScale(1, 0.28)
		name.Position = UDim2.fromScale(0, 0.72)
		name.ZIndex = slot.ZIndex + 2
		name.TextScaled = true
		name.Font = Enum.Font.GothamMedium
		name.Parent = slot
	end
	name.Text = def.name
	clearStops(name)
	slotStops[name] = UI.grade(name, def.grade)
end

-- ---- build 45 static slots once ---------------------------------------------
local frames: { [number]: ImageButton } = {}
for i = INV_START, INV_END do
	local slot = slotTemplate:Clone() :: ImageButton
	slot.Name = "Slot" .. i
	slot.LayoutOrder = i
	slot.Visible = true
	-- Slot background/border from the tileset; our grade borderFX owns ImageColor3,
	-- so skip the universal buttonFX colour (keep only a hover scale).
	slot.Image = SLOT_IMAGE
	slot.ImageRectSize = SLOT_RECT
	slot.ImageRectOffset = SLOT_BASE_OFFSET
	slot:SetAttribute("NoButtonColor", true) -- borderFX owns ImageColor3 (buttonFX still scales)
	slot.MouseButton1Click:Connect(function()
		ItemDrag.click(i, slot)
	end)
	slot.MouseButton2Click:Connect(function()
		ItemDrag.rightClick(i)
	end)
	slot.MouseEnter:Connect(function()
		local s = ItemMirror.getSlot(i)
		if s then
			local def = itemdb.byKey(s.key)
			if def then showTooltip(slot, def) end
		end
	end)
	slot.MouseLeave:Connect(function()
		info.Visible = false
	end)
	slot.Parent = itemSlots
	frames[i] = slot
end

-- ---- weight bar -------------------------------------------------------------
local weightBar = Instance.new("Frame")
weightBar.Name = "WeightBar"
weightBar.AnchorPoint = Vector2.new(0.5, 1)
weightBar.Position = UDim2.new(0.5, 0, 0, -6)
weightBar.Size = UDim2.new(0.9, 0, 0, 18)
weightBar.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
weightBar.BorderSizePixel = 0
weightBar.Parent = inventory
local weightFill = Instance.new("Frame")
weightFill.BorderSizePixel = 0
weightFill.BackgroundColor3 = Color3.fromRGB(90, 200, 255)
weightFill.Size = UDim2.fromScale(0, 1)
weightFill.Parent = weightBar
local weightLabel = Instance.new("TextLabel")
weightLabel.BackgroundTransparency = 1
weightLabel.Size = UDim2.fromScale(1, 1)
weightLabel.TextScaled = true
weightLabel.Font = Enum.Font.GothamMedium
weightLabel.TextColor3 = Color3.new(1, 1, 1)
weightLabel.Parent = weightBar

local function render()
	for i = INV_START, INV_END do
		local entry = if ItemDrag.isGhost(i) then nil else ItemMirror.getSlot(i)
		fill(frames[i], entry)
	end
	local w, cap = ItemMirror.getWeight(), ItemMirror.getCapacity()
	local frac = if cap > 0 then math.clamp(w / cap, 0, 1) else 0
	weightFill.Size = UDim2.fromScale(frac, 1)
	weightFill.BackgroundColor3 = if w > cap then Color3.fromRGB(230, 70, 70) else Color3.fromRGB(90, 200, 255)
	weightLabel.Text = `{w} / {cap}`
end

ItemMirror.onChanged(render)
ItemDrag.onChanged(render)
render()

return {}
