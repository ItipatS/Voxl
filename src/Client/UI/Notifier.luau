-- StarterPlayerScripts/Notifier.luau
-- Transient, non-interactive messaging on its own high-layer ScreenGui (above the
-- HUD). Two kinds, matching the house style:
--   Notifier.zone(title, subtitle)  — a BIG title that scales up + fades (entering a
--                                     biome/zone). One at a time; newest wins.
--   Notifier.toast(text, kind)      — a small message that stacks in the corner and
--                                     auto-dismisses (pickups, skill-ups, warnings).
-- Built programmatically so it needs no authored GUI. See .claude/19-ui-conventions.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UISound = require(script.Parent.Sound)
local UIData = require(script.Parent.UIData)

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

local Notifier = {}

-- ---- root -------------------------------------------------------------------
local screen = Instance.new("ScreenGui")
screen.Name = "Notifications"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 50
screen.Parent = pg

-- ---- zone title -------------------------------------------------------------
local zoneHolder = Instance.new("Frame")
zoneHolder.Name = "Zone"
zoneHolder.BackgroundTransparency = 1
zoneHolder.AnchorPoint = Vector2.new(0.5, 0.5)
zoneHolder.Position = UDim2.fromScale(0.5, 0.32)
zoneHolder.Size = UDim2.new(0.8, 0, 0, 150)
zoneHolder.Visible = false
zoneHolder.Parent = screen

local zoneScale = Instance.new("UIScale")
zoneScale.Parent = zoneHolder

local function bigLabel(size: number, y: number, weight: Enum.FontWeight): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.new(1, 0, 0, size)
	t.Position = UDim2.fromOffset(0, y)
	t.FontFace = UIData.Font -- Silkscreen (no bold)
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeColor3 = Color3.new(0, 0, 0)
	t.TextScaled = true
	t.Parent = zoneHolder
	return t
end

local zoneTitle = bigLabel(66, 0, Enum.FontWeight.Heavy)
local zoneSub = bigLabel(26, 82, Enum.FontWeight.Medium)

local IN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OUT = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local zoneGen = 0

-- Announce a zone/biome. subtitle optional.
function Notifier.zone(title: string, subtitle: string?)
	zoneGen += 1
	local gen = zoneGen
	zoneTitle.Text = title
	zoneSub.Text = subtitle or ""
	zoneSub.Visible = subtitle ~= nil
	UISound.play("zone")

	zoneTitle.TextTransparency, zoneTitle.TextStrokeTransparency = 1, 1
	zoneSub.TextTransparency = 1
	zoneScale.Scale = 0.85
	zoneHolder.Visible = true

	TweenService:Create(zoneScale, IN, { Scale = 1 }):Play()
	TweenService:Create(zoneTitle, IN, { TextTransparency = 0, TextStrokeTransparency = 0.35 }):Play()
	TweenService:Create(zoneSub, IN, { TextTransparency = 0.1 }):Play()

	task.delay(2.2, function()
		if gen ~= zoneGen then
			return
		end
		TweenService:Create(zoneTitle, OUT, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(zoneSub, OUT, { TextTransparency = 1 }):Play()
		local t = TweenService:Create(zoneScale, OUT, { Scale = 1.06 })
		t.Completed:Once(function()
			if gen == zoneGen then
				zoneHolder.Visible = false
			end
		end)
		t:Play()
	end)
end

-- ---- toasts -----------------------------------------------------------------
local toastHolder = Instance.new("Frame")
toastHolder.Name = "Toasts"
toastHolder.BackgroundTransparency = 1
toastHolder.AnchorPoint = Vector2.new(1, 0)
toastHolder.Position = UDim2.new(1, -18, 0, 90)
toastHolder.Size = UDim2.new(0, 320, 1, -180)
toastHolder.Parent = screen

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 8)
list.HorizontalAlignment = Enum.HorizontalAlignment.Right
list.VerticalAlignment = Enum.VerticalAlignment.Top
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = toastHolder

local toastSeq = 0
local lastToastText, lastToastAt = "", 0

-- Small stacked message. kind: "notify" (default) | "skill" | "error".
function Notifier.toast(text: string, kind: string?)
	-- Debounce identical toasts fired in quick succession.
	local now = os.clock()
	if text == lastToastText and now - lastToastAt < 1.5 then
		return
	end
	lastToastText, lastToastAt = text, now
	toastSeq += 1
	UISound.play(if kind == "skill" then "skill" elseif kind == "error" then "error" else "notify")

	local card = Instance.new("TextLabel")
	card.Name = "Toast"
	card.LayoutOrder = -toastSeq -- newest on top
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.Size = UDim2.new(1, 0, 0, 34)
	card.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	card.BackgroundTransparency = 1
	card.TextColor3 = if kind == "error" then Color3.fromRGB(240, 120, 120) else Color3.new(1, 1, 1)
	card.FontFace = UIData.Font
	card.TextSize = 18
	card.TextTransparency = 1
	card.Text = "  " .. text .. "  "
	card.TextXAlignment = Enum.TextXAlignment.Right
	card.Parent = toastHolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = card

	TweenService:Create(card, TweenInfo.new(0.25), { TextTransparency = 0, BackgroundTransparency = 0.25 }):Play()

	task.delay(3, function()
		local tw = TweenService:Create(card, TweenInfo.new(0.4), { TextTransparency = 1, BackgroundTransparency = 1 })
		tw.Completed:Once(function()
			card:Destroy()
		end)
		tw:Play()
	end)
end

return Notifier
