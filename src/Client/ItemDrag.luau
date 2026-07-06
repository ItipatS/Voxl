-- StarterPlayerScripts/ItemDrag.luau
-- The Minecraft/Terraria cursor: left-click a slot to pick up its stack onto the
-- cursor, click another slot to drop (server swaps/merges), right-click to consume.
-- Shared across the inventory grid AND the hotbar — but only ACTIVE while the
-- inventory is open (that's the "hotbar drag only when inventory open" context, doc 20).
-- The pick is client-visual (a "ghost" the renderers hide); the authoritative
-- MoveItem is sent on drop, so closing while holding just returns the stack.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local blink = require(ReplicatedStorage.std.ClientNet)
local ItemMirror = require(script.Parent.ItemMirror)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local ItemDrag = {}

local heldFrom = 0
local listeners: { () -> () } = {}

local function invOpen(): boolean
	return UI.Controller.isOpen("Inventory")
end

local function notify()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

-- Renderers subscribe to redraw the ghost (held) slot as empty.
function ItemDrag.onChanged(fn: () -> ())
	table.insert(listeners, fn)
end
function ItemDrag.isGhost(slot: number): boolean
	return heldFrom == slot
end
function ItemDrag.holding(): boolean
	return heldFrom ~= 0
end

-- ---- cursor = a CLONE of the picked-up slot frame (in the DragableLayer) -----
local interface = player:WaitForChild("PlayerGui"):WaitForChild("Interface")
local layer = interface:WaitForChild("DragableLayer")

local cursor: GuiObject? = nil
-- Strip selection/feedback artifacts so the floating copy is just the item visual.
local STRIP = { "SelDim", "HoldDim", "SelScale", "UIHover", "UIPop", "Grade" }

local function makeCursor(sourceFrame: GuiObject)
	if cursor then
		cursor:Destroy()
	end
	local c = sourceFrame:Clone()
	c.Name = "Held"
	c.AnchorPoint = Vector2.new(0.5, 0.5)
	c.Size = UDim2.fromOffset(sourceFrame.AbsoluteSize.X, sourceFrame.AbsoluteSize.Y)
	c.ZIndex = 50
	c.Active = false
	c:SetAttribute("UIFeedback", true) -- keep the registry's buttonFX off the clone
	for _, name in STRIP do
		local x = c:FindFirstChild(name)
		if x then
			x:Destroy()
		end
	end
	c.Parent = layer
	cursor = c
end

local function destroyCursor()
	if cursor then
		cursor:Destroy()
		cursor = nil
	end
end

-- ---- interactions -----------------------------------------------------------
-- `sourceFrame` is the slot's GUI frame — we clone it as the drag cursor.
function ItemDrag.click(slot: number, sourceFrame: GuiObject?)
	if not invOpen() then
		return -- dragging is only allowed with the inventory open
	end
	if heldFrom == 0 then
		local s = ItemMirror.getSlot(slot)
		if s and sourceFrame then
			heldFrom = slot
			makeCursor(sourceFrame)
			UI.Sound.play("select")
			notify()
		end
	else
		if slot ~= heldFrom then
			blink.MoveItem.Fire({ from = heldFrom, to = slot })
		end
		heldFrom = 0
		destroyCursor()
		UI.Sound.play("select")
		notify()
	end
end

function ItemDrag.rightClick(slot: number)
	if not invOpen() or heldFrom ~= 0 then
		return
	end
	blink.UseSlot.Fire(slot) -- server: Consumables only
end

local function cancel()
	if heldFrom ~= 0 then
		heldFrom = 0
		destroyCursor()
		notify()
	end
end
ItemDrag.cancel = cancel

RunService.RenderStepped:Connect(function()
	-- Drop the held stack back if the inventory closed underneath us.
	if heldFrom ~= 0 and not invOpen() then
		cancel()
	end
	if cursor then
		local m = UserInputService:GetMouseLocation()
		cursor.Position = UDim2.fromOffset(m.X - layer.AbsolutePosition.X, m.Y - layer.AbsolutePosition.Y)
	end
end)

return ItemDrag
