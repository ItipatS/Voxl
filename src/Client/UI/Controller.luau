-- StarterPlayerScripts/UIController.luau
-- The one client UI manager. Owns which panels are open (single writer → no two
-- systems fighting a frame) and bakes the house style into every open/close:
--   * POP transition (dot→large) in, pop out       (UITween)
--   * open/close sound                              (UISound)
--   * EXCLUSIVE groups   — opening a panel closes its group siblings
--   * TOGGLE-to-close    — toggle() on an open panel closes it
--   * MODAL input context — modal panels stack; Esc closes the top; gameplayBlocked()
--   * multi-FRAME panels  — one logical panel can drive several frames together
--   * a toggle KEY        — declared per panel
--
-- Panels are named frames under PlayerGui.Interface. Register them declaratively
-- (see UIRegistry); controllers just call open/close/toggle. See .claude/19.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local UISound = require(script.Parent.Sound)
local UITween = require(script.Parent.Tween)

local interface = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Interface")

local UIController = {}

export type PanelConfig = {
	frames: { string }?, -- child names this panel shows/hides together (default { name })
	group: string?, -- exclusive group: opening one closes the others
	modal: boolean?, -- captures input context (Esc closes; blocks gameplay)
	key: Enum.KeyCode?, -- optional toggle key
	openSound: string?, -- semantic event or sound name (default "open")
	closeSound: string?, -- default "close"
	onClose: (() -> ())?, -- called on ANY close (Esc, group, code) — for state cleanup
}

type Panel = { frames: { GuiObject }, cfg: PanelConfig, open: boolean }

local panels: { [string]: Panel } = {}
local modalStack: { string } = {}

-- Register a panel (idempotent). Returns whether it resolved.
function UIController.register(name: string, cfg: PanelConfig?): boolean
	if panels[name] then
		return true
	end
	cfg = cfg or {}
	local names = cfg.frames or { name }
	local frames: { GuiObject } = {}
	for _, fname in names do
		local f = interface:FindFirstChild(fname) :: GuiObject?
		if f then
			table.insert(frames, f)
		else
			warn(`[UIController] panel '{name}': no frame '{fname}' under Interface`)
		end
	end
	if #frames == 0 then
		return false
	end
	panels[name] = { frames = frames, cfg = cfg, open = false }

	if cfg.key then
		UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == cfg.key then
				UIController.toggle(name)
			end
		end)
	end
	return true
end

function UIController.isOpen(name: string): boolean
	local p = panels[name]
	return p ~= nil and p.open
end

local function popModal(name: string)
	local i = table.find(modalStack, name)
	if i then
		table.remove(modalStack, i)
	end
end

function UIController.open(name: string, _origin: GuiObject?)
	local p = panels[name]
	if not p or p.open then
		return
	end
	if p.cfg.group then
		for other, op in panels do
			if other ~= name and op.open and op.cfg.group == p.cfg.group then
				UIController.close(other)
			end
		end
	end
	p.open = true
	if p.cfg.modal then
		table.insert(modalStack, name)
	end
	for _, f in p.frames do
		UITween.popIn(f)
	end
	UISound.play(p.cfg.openSound or "open")
end

function UIController.close(name: string)
	local p = panels[name]
	if not p or not p.open then
		return
	end
	p.open = false
	popModal(name)
	if p.cfg.onClose then
		p.cfg.onClose()
	end
	for _, f in p.frames do
		UITween.popOut(f)
	end
	UISound.play(p.cfg.closeSound or "close")
end

-- Debounce rapid toggling (mashing E / the Bag button) so panels don't flicker.
-- Programmatic open()/close() are unaffected.
local lastToggle: { [string]: number } = {}

function UIController.toggle(name: string, origin: GuiObject?)
	local now = os.clock()
	if now - (lastToggle[name] or 0) < 0.15 then
		return
	end
	lastToggle[name] = now
	if UIController.isOpen(name) then
		UIController.close(name)
	else
		UIController.open(name, origin)
	end
end

-- True while any modal panel is open — gameplay controllers check this to suppress
-- movement/aim without knowing which panel it is.
function UIController.gameplayBlocked(): boolean
	return #modalStack > 0
end

-- Esc closes the top modal.
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and #modalStack > 0 then
		UIController.close(modalStack[#modalStack])
	end
end)

-- ---- shared primitives ------------------------------------------------------

function UIController.sound(nameOrEvent: string)
	UISound.play(nameOrEvent)
end

function UIController.breathe(obj: Instance, prop: string, from: number, to: number, period: number?): Tween
	(obj :: any)[prop] = from
	local info = TweenInfo.new(period or 0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local tw = TweenService:Create(obj, info, { [prop] = to })
	tw:Play()
	return tw
end

function UIController.press(obj: GuiObject)
	local base = obj.Size
	local down = UDim2.new(base.X.Scale * 0.94, base.X.Offset, base.Y.Scale * 0.94, base.Y.Offset)
	TweenService:Create(obj, TweenInfo.new(0.06), { Size = down }):Play()
	task.delay(0.07, function()
		TweenService:Create(obj, TweenInfo.new(0.08), { Size = base }):Play()
	end)
end

return UIController
