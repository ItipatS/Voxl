-- StarterPlayerScripts/UISound.luau
-- The one place UI sound is played. Sounds live as named Sound instances under
-- SoundService.SFX/<category> (UI, Effect, …) — swap the asset/volume/pitch in
-- Studio and code never changes. Lookup is recursive-by-name + cached, so
-- reorganising folders never breaks a call.
--
-- Two ways to play:
--   * a SEMANTIC event ("open", "hover", "confirm"…) → mapped to a sound name here,
--     so re-skinning "the open sound" is a one-line change.
--   * a raw sound name ("Teleport", "ZoneNoti") for one-offs.

local SoundService = game:GetService("SoundService")

local SFX = SoundService:WaitForChild("SFX")

local UISound = {}

-- Semantic UI events → sound names (edit here to re-skin an interaction globally).
local EVENT: { [string]: string } = {
	open = "OpenUI",
	close = "Cancel",
	select = "Select", -- button click / confirm-advance
	hover = "MouseHover",
	confirm = "Confirm",
	cancel = "Cancel",
	error = "Error",
	notify = "Noti",
	zone = "ZoneNoti",
	skill = "SkillNoti",
	star = "StarClick",
}

local found: { [string]: Sound? } = {}

local function resolve(nameOrEvent: string): Sound?
	local name = EVENT[nameOrEvent] or nameOrEvent
	local cached = found[name]
	if cached ~= nil then
		return cached
	end
	local s = SFX:FindFirstChild(name, true) :: Sound? -- recursive; folder-layout agnostic
	if not s then
		warn(`[UISound] no sound '{name}' under SoundService.SFX`)
	end
	found[name] = s
	return s
end

-- Debounce: the SAME sound won't retrigger within this window, so rapid events
-- (sweeping a slot grid, mashing a button) don't stack into noise.
local COOLDOWN = 0.05
local lastPlayed: { [string]: number } = {}

-- Play a UI sound (semantic event or raw name). Cloned so overlaps don't cut off.
function UISound.play(nameOrEvent: string)
	local src = resolve(nameOrEvent)
	if not src then
		return
	end
	local now = os.clock()
	if now - (lastPlayed[src.Name] or 0) < COOLDOWN then
		return
	end
	lastPlayed[src.Name] = now
	local s = src:Clone()
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(12, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

-- Wire the standard hover/click feedback onto a button in one call.
function UISound.bind(button: GuiButton)
	button.MouseEnter:Connect(function()
		UISound.play("hover")
	end)
	button.MouseButton1Click:Connect(function()
		UISound.play("select")
	end)
end

return UISound
