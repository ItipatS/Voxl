-- StarterPlayerScripts/UI/init.luau
-- THE UI framework facade — one require gets every UI capability, and it bootstraps
-- the registry (panels + universal button feedback) and notification layer on first
-- require. All UI code now lives under this one folder (previously split between
-- Client/ and ClientServices.UI). See .claude/19-ui-conventions.
--
-- Consumers: `local UI = require(script.Parent.UI)`, then:
--   UI.open/close/toggle/register     — panels
--   UI.sound(event) / UI.Notify.*     — audio + notices
--   UI.hover(gui) / UI.press          — feedback on any element
--   UI.grade(label, gradeKey)         — animated tier/grade visual
--   UI.tooltip(data)                  — tooltip body text
--   UI.Controller/Sound/Tween/Effect/Tooltip/Data — submodules if needed directly

local UI = {}

UI.Controller = require(script.Controller)
UI.Sound = require(script.Sound)
UI.Tween = require(script.Tween)
UI.Notify = require(script.Notifier)
UI.Data = require(script.UIData) -- grade → color/effect config
UI.Effect = require(script.Effect) -- apply/clear animated tier effects on a label
UI.Tooltip = require(script.Tooltip) -- tooltip text builder
UI.Particles = require(script.Particles) -- Emitter2D 2D particle bursts

-- ---- passthroughs (a controller uses ONE module for everything) -------------
function UI.register(name: string, cfg: any?)
	return UI.Controller.register(name, cfg)
end
function UI.open(name: string, origin: GuiObject?)
	UI.Controller.open(name, origin)
end
function UI.close(name: string)
	UI.Controller.close(name)
end
function UI.toggle(name: string, origin: GuiObject?)
	UI.Controller.toggle(name, origin)
end
function UI.isOpen(name: string): boolean
	return UI.Controller.isOpen(name)
end
function UI.gameplayBlocked(): boolean
	return UI.Controller.gameplayBlocked()
end
function UI.sound(nameOrEvent: string)
	UI.Sound.play(nameOrEvent)
end
function UI.press(gui: GuiObject)
	UI.Controller.press(gui)
end

-- ---- uniform behaviors any element can get ----------------------------------
-- Hover juice (scale + sound) for elements you build yourself (the registry already
-- auto-applies this to every button under Interface).
function UI.hover(gui: GuiObject)
	UI.Tween.hover(gui)
	gui.MouseEnter:Connect(function()
		UI.Sound.play("hover")
	end)
end

-- Apply a GDD grade's visual (static colour or animated effect) to a text label.
-- Returns stop-functions; pass them to UI.clearGrade to remove.
function UI.grade(label: TextLabel, gradeKey: string)
	return UI.Effect.ApplyEffects(label, UI.Data:GetGradeLook(gradeKey))
end
function UI.clearGrade(stopFns: any, label: TextLabel?, resetColor: Color3?)
	UI.Effect.ClearEffects(stopFns, label, resetColor)
end

-- Tooltip body text from item-ish data ({Name,Category,DescriptionLines,Tradable}).
function UI.tooltip(data: any): string
	return UI.Tooltip.BuildTooltip(data, {}, UI.Data)
end

-- Grade-driven BORDER on an image (the slot tileset frame): a plain colour for
-- static grades, or an animated colour pulse through the grade's sequence for
-- effect grades (the ultimate Star Seed). Returns a stop-function (or nil).
local RunService = game:GetService("RunService")
local function sampleSequence(cs: ColorSequence, p: number): Color3
	local kps = cs.Keypoints
	for i = 1, #kps - 1 do
		local a, b = kps[i], kps[i + 1]
		if p >= a.Time and p <= b.Time then
			return a.Value:Lerp(b.Value, (p - a.Time) / math.max(b.Time - a.Time, 1e-4))
		end
	end
	return kps[#kps].Value
end
-- Border tileset ("Ram Border All": 10 cols × 8 rows of 64px → offsets X 0..576, Y 0..448).
local TILE = 64
local MAX_COL, MAX_ROW = 9, 7 -- last tile top-left = (576, 448)
local DEFAULT_OFFSET = Vector2.new(384, 0) -- the plain slot tile (used when a grade has no border set)
function UI.borderFX(image: ImageLabel | ImageButton, gradeKey: string): (() -> ())?
	local look = UI.Data:GetGradeLook(gradeKey)
	local idx = UI.Data.Border and UI.Data.Border[gradeKey]
	local staticOffset = if idx then UI.Data.Bordercalculate(idx) else DEFAULT_OFFSET
	image.ImageRectOffset = staticOffset

	-- Static grade → fixed tile tinted by its colour.
	if typeof(look) == "Color3" then
		image.ImageColor3 = look
		return nil
	end

	-- Animated grade → border colour DRIFTS through the grade sequence. Grades with NO
	-- fixed tile (mythical) also RANDOMISE the tile every 0.5-1s.
	local cs = (look :: any).colorSequence :: ColorSequence
	local dur = (look :: any).duration or 2.5
	local randomTile = idx == nil
	local acc, changeIn = 0, 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		image.ImageColor3 = sampleSequence(cs, (acc % dur) / dur)
		if randomTile then
			changeIn -= dt
			if changeIn <= 0 then
				changeIn = 0.5 + math.random() * 0.5 -- next tile change in 0.5-1s
				image.ImageRectOffset = Vector2.new(math.random(0, MAX_COL) * TILE, math.random(0, MAX_ROW) * TILE)
			end
		end
	end)
	return function()
		conn:Disconnect()
		image.ImageColor3 = Color3.new(1, 1, 1)
		image.ImageRectOffset = staticOffset
	end
end

-- One-shot 2D particle burst inside a target GuiObject (Emitter2D). `name` picks an
-- authored config under ReplicatedStorage.Assets.Emitters (else the default).
function UI.burst(target: GuiObject, name: string?, count: number?)
	UI.Particles.burst(target, name, count)
end

-- ---- bootstrap (runs once, on first require) --------------------------------
require(script.Registry) -- registers panels + universal button feedback
-- (UI.Notify above already built the notification layer on require.)

return UI
