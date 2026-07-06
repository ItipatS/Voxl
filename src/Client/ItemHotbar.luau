-- StarterPlayerScripts/ItemHotbar.luau  (Lobby)
-- The hotbar = mirror slots 1-9 in Interface.HotBar. Context-sensitive (doc 20):
--   inventory CLOSED → 1-9 / scroll / click SELECTS a slot (scales up, dims the item
--     image to read as "in hand") and equips it as a held Tool (EquipItem).
--   inventory OPEN   → clicks are drag (ItemDrag) so you can move items in/out.
-- Quantity is hidden unless the item is stackable AND count > 1.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local blink = require(ReplicatedStorage.std.ClientNet)
local itemdb = require(ReplicatedStorage.std.itemdb)
local ItemMirror = require(script.Parent.ItemMirror)
local ItemDrag = require(script.Parent.ItemDrag)
local UI = require(script.Parent.UI)

local ITEMS = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Items")
local player = Players.LocalPlayer
local interface = player:WaitForChild("PlayerGui"):WaitForChild("Interface")
local hotbar = interface:WaitForChild("HotBar")
local hbText = interface:FindFirstChild("HotBarText") -- Minecraft-style selected-item name

local SLOTS = 9
local held = 1 -- the hotbar slot currently held in-hand (was "selected")

local function slotFrame(i: number): ImageButton?
	return hotbar:FindFirstChild("Slot" .. i) :: ImageButton?
end
local function invOpen(): boolean
	return UI.Controller.isOpen("Inventory")
end

local function child(frame: GuiObject, class: string, name: string): Instance
	local c = frame:FindFirstChild(name)
	if not c then
		c = Instance.new(class)
		c.Name = name
		c.Parent = frame
	end
	return c
end

-- Grade shown on the slot image itself (animated for the ultimate seed). We skip the
-- universal buttonFX on hotbar slots (below) so borderFX owns ImageColor3.
local borderStops: { [Instance]: (() -> ())? } = {}
local function clearBorder(slot: GuiObject)
	if borderStops[slot] then
		borderStops[slot]()
		borderStops[slot] = nil
	end
end

-- The HELD slot (item currently in hand) is marked with a plain GRAY dim over its
-- image — no scale, nothing else. That + HotBarText is all the feedback we want.
local function dimOverlay(frame: GuiObject): Frame
	local d = frame:FindFirstChild("HoldDim") :: Frame?
	if not d then
		d = Instance.new("Frame")
		d.Name = "HoldDim"
		d.Size = UDim2.fromScale(1, 1)
		d.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
		d.BackgroundTransparency = 0.45
		d.BorderSizePixel = 0
		d.ZIndex = 5
		d.Visible = false
		d.Parent = frame
	end
	return d :: Frame
end

local function renderModel(vp: ViewportFrame, modelName: string): boolean
	vp:ClearAllChildren()
	local asset = ITEMS:FindFirstChild(modelName)
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

local function fill(i: number)
	local slot = slotFrame(i)
	if not slot then
		return
	end
	local entry = if ItemDrag.isGhost(i) then nil else ItemMirror.getSlot(i)
	local vp = slot:FindFirstChild("ViewportFrame") :: ViewportFrame?
	local q = slot:FindFirstChild("Quantity") :: TextLabel?

	if not entry then
		if vp then vp:ClearAllChildren(); vp.Visible = false end
		if q then q.Text = "" end
		clearBorder(slot)
		slot.ImageColor3 = Color3.new(1, 1, 1)
		return
	end
	local def = itemdb.byKey(entry.key)
	if not def then
		return
	end
	if vp then
		vp.Visible = if def.model and renderModel(vp, def.model) then true else false
	end
	if q then
		q.Text = if def.stack > 1 and entry.count > 1 then `x{entry.count}` else ""
	end
	clearBorder(slot)
	borderStops[slot] = UI.borderFX(slot, def.grade)
end

local function applyHeldVisual()
	for n = 1, SLOTS do
		local slot = slotFrame(n)
		if slot then
			dimOverlay(slot).Visible = (n == held) -- gray dim on the held slot only, no scale
		end
	end
end

local lastEquip = -1
local function equipHeld()
	local entry = ItemMirror.getSlot(held)
	local id = if entry then (itemdb.byKey(entry.key) :: any).id else 0
	if id ~= lastEquip then
		lastEquip = id
		blink.EquipItem.Fire(id)
	end
end

-- HotBarText: name (with grade effect) + description + icon, shown on select then
-- auto-hidden (Minecraft). Border/text effect inherit the grade (Star Seed = ultimate).
local hbLabel = hbText and hbText:FindFirstChild("Label") :: TextLabel?
local hbDesc = hbText and hbText:FindFirstChild("Description") :: TextLabel?
local hbBG = hbText and hbText:FindFirstChild("BG") :: ImageLabel?
if hbBG then
	hbBG.ZIndex = 1 -- BG behind the text (was fighting / occluding at equal ZIndex)
end
if hbLabel then
	hbLabel.ZIndex = 3
end
if hbDesc then
	hbDesc.ZIndex = 3
end

local hbStops: any = nil -- current grade effect (MUST be cleared, else it runs forever)
local hbToken = 0
local hbKey: string? = nil -- what's currently shown (debounce: same item won't restart the effect)

local function fadeHb(show: boolean)
	if not hbText then
		return
	end
	local a = if show then 0 else 1
	if show then
		hbText.Visible = true
	end
	local ti = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if hbLabel then TweenService:Create(hbLabel, ti, { TextTransparency = a }):Play() end
	if hbDesc then TweenService:Create(hbDesc, ti, { TextTransparency = a }):Play() end
	if hbBG then TweenService:Create(hbBG, ti, { ImageTransparency = a }):Play() end
end

local function clearHb()
	if hbStops then
		UI.clearGrade(hbStops, hbLabel, Color3.new(1, 1, 1)) -- stop the loop + reset colour
		hbStops = nil
	end
end

local function hideHotbarText()
	if not hbText then
		return
	end
	hbToken += 1
	local t = hbToken
	clearHb()
	fadeHb(false)
	hbKey = nil
	task.delay(0.25, function()
		if t == hbToken then
			hbText.Visible = false
		end
	end)
end

local function showHotbarText(entry)
	if not hbText then
		return
	end
	local def = entry and itemdb.byKey(entry.key)
	if not def then
		hideHotbarText()
		return
	end
	hbToken += 1
	local t = hbToken
	-- Debounce: only rebuild text + restart the grade effect when the item CHANGES.
	if def.key ~= hbKey then
		hbKey = def.key
		if hbLabel then hbLabel.Text = def.name end
		if hbDesc then hbDesc.Text = table.concat(def.desc, "  ") end
		clearHb()
		if hbLabel then hbStops = UI.grade(hbLabel, def.grade) end
	end
	fadeHb(true)
	task.delay(3, function()
		if t == hbToken then
			hideHotbarText()
		end
	end)
end

local function setHeld(i: number)
	held = i
	applyHeldVisual()
	equipHeld()
	showHotbarText(ItemMirror.getSlot(i))
	UI.Sound.play("select")
end

local function render()
	for i = 1, SLOTS do
		fill(i)
	end
	applyHeldVisual()
	equipHeld() -- keep the held item in sync if the held slot's content changed
end

-- ---- input ------------------------------------------------------------------
local KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local i = KEYS[input.KeyCode]
	if i then
		setHeld(i)
	end
end)

-- Scroll cycles the selection (only when the inventory is closed; when open the
-- wheel scrolls the inventory).
UserInputService.InputChanged:Connect(function(input, processed)
	if processed or invOpen() then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		-- Alt + scroll is camera zoom (CameraController) — leave the hotbar alone.
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
			return
		end
		local dir = if input.Position.Z > 0 then -1 else 1 -- wheel up = previous
		setHeld(((held - 1 + dir) % SLOTS) + 1)
	end
end)

for i = 1, SLOTS do
	local slot = slotFrame(i)
	if slot and slot:IsA("GuiButton") then
		slot:SetAttribute("NoButtonColor", true) -- borderFX owns ImageColor3 (buttonFX still scales)
		slot.MouseButton1Click:Connect(function()
			if invOpen() then
				ItemDrag.click(i, slot)
			else
				setHeld(i)
			end
		end)
		slot.MouseButton2Click:Connect(function()
			if invOpen() then
				ItemDrag.rightClick(i)
			end
		end)
	end
end

ItemMirror.onChanged(render)
ItemDrag.onChanged(render)
render()

return {}
