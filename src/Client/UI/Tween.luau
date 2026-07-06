-- StarterPlayerScripts/UITween.luau
-- Shared UI motion. The signature Voxl feel: panels POP from a dot to full size
-- about their own anchor (grow-from-origin), overlays FADE. Uses a non-destructive
-- UIScale child so we never have to store/restore Size, and it composes with any
-- layout. Set a panel's AnchorPoint to control where it grows from (0.5,0.5 = centre).

local TweenService = game:GetService("TweenService")

local UITween = {}

local POP_IN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function scaleOf(gui: GuiObject): UIScale
	local s = gui:FindFirstChild("UIPop") :: UIScale?
	if not s then
		s = Instance.new("UIScale")
		s.Name = "UIPop"
		s.Parent = gui
	end
	return s
end

-- Pop a panel in from a dot. duration optional.
function UITween.popIn(gui: GuiObject, duration: number?)
	local s = scaleOf(gui)
	s.Scale = 0
	gui.Visible = true
	local info = if duration then TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out) else POP_IN
	TweenService:Create(s, info, { Scale = 1 }):Play()
end

-- Pop a panel out to a dot, then hide. onDone runs after.
function UITween.popOut(gui: GuiObject, onDone: (() -> ())?)
	local s = scaleOf(gui)
	local tw = TweenService:Create(s, POP_OUT, { Scale = 0 })
	tw.Completed:Once(function()
		gui.Visible = false
		s.Scale = 1 -- reset so a later popIn/plain-show is correct
		if onDone then
			onDone()
		end
	end)
	tw:Play()
end

-- Fade a text/image object in (transparency props). Best for titles/overlays.
function UITween.fadeIn(gui: GuiObject, duration: number?)
	gui.Visible = true
	local info = if duration then TweenInfo.new(duration) else FADE
	local goal: { [string]: any } = {}
	if gui:IsA("TextLabel") or gui:IsA("TextButton") then
		gui.TextTransparency = 1
		goal.TextTransparency = 0
		if gui.TextStrokeTransparency < 1 then
			gui.TextStrokeTransparency = 1
			goal.TextStrokeTransparency = 0
		end
	elseif gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
		gui.ImageTransparency = 1
		goal.ImageTransparency = 0
	end
	TweenService:Create(gui, info, goal):Play()
end

local function hoverScale(gui: GuiObject): UIScale
	local s = gui:FindFirstChild("UIHover") :: UIScale?
	if not s then
		s = Instance.new("UIScale")
		s.Name = "UIHover"
		s.Parent = gui
	end
	return s :: UIScale
end

-- Hover juice: subtle scale up on enter, back on leave. Idempotent, its own UIScale
-- ("UIHover") so it never fights popIn's "UIPop". Works on any GuiObject.
function UITween.hover(gui: GuiObject, to: number?)
	local target = to or 1.06
	local scale = hoverScale(gui)
	gui.MouseEnter:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = target }):Play()
	end)
	gui.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
end

-- Full button feedback: BRIGHTER + bigger on hover, DIMMER + smaller on press.
-- Non-destructive (captures the base colour once into an attribute so it always
-- restores exactly). For GuiButtons — the registry applies this to every button.
function UITween.buttonFX(btn: GuiButton)
	local isImage = btn:IsA("ImageButton")
	local prop = if isImage then "ImageColor3" else "BackgroundColor3"
	local stored = btn:GetAttribute("UIBaseColor")
	if stored == nil then
		stored = (btn :: any)[prop]
		btn:SetAttribute("UIBaseColor", stored)
	end
	local base = stored :: Color3
	local hoverC = base:Lerp(Color3.new(1, 1, 1), 0.18) -- brighter
	local pressC = Color3.new(base.R * 0.78, base.G * 0.78, base.B * 0.78) -- dimmer
	local scale = hoverScale(btn)

	local hovering = false
	local function set(sc: number, col: Color3)
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = sc }):Play()
		-- Elements that own their own ImageColor3 (item slots with grade borderFX) opt
		-- out of the colour tint with a NoButtonColor attribute — kept as scale-only.
		if not btn:GetAttribute("NoButtonColor") then
			TweenService:Create(btn, TweenInfo.new(0.12), { [prop] = col }):Play()
		end
	end
	btn.MouseEnter:Connect(function()
		hovering = true
		set(1.06, hoverC)
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		set(1, base)
	end)
	btn.MouseButton1Down:Connect(function()
		set(0.95, pressC)
	end)
	btn.MouseButton1Up:Connect(function()
		set(if hovering then 1.06 else 1, if hovering then hoverC else base)
	end)
end

function UITween.fadeOut(gui: GuiObject, duration: number?, onDone: (() -> ())?)
	local info = if duration then TweenInfo.new(duration) else FADE
	local goal: { [string]: any } = {}
	if gui:IsA("TextLabel") or gui:IsA("TextButton") then
		goal.TextTransparency = 1
		goal.TextStrokeTransparency = 1
	elseif gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
		goal.ImageTransparency = 1
	end
	local tw = TweenService:Create(gui, info, goal)
	tw.Completed:Once(function()
		gui.Visible = false
		if onDone then
			onDone()
		end
	end)
	tw:Play()
end

return UITween
