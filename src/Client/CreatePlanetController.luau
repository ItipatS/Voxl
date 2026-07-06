-- StarterPlayerScripts/CreatePlanetController.luau
-- The "name your star" prompt (Interface.CreatePlanet), a UIController modal panel.
-- Two states on the SAME Confirm/Cancel buttons:
--   INPUT   → type a name. Confirm validates locally (bad → red log + error sound,
--             stay). Cancel (or Esc) closes the prompt (→ onCancel).
--   CONFIRM → Log turns green "Plant \"name\"?", Confirm breathes, a Confirm sound
--             plays. Confirm commits (onSubmit); Cancel returns to INPUT (stays open).
-- UIController handles the pop/sound/exclusivity/Esc; the onClose hook cleans our
-- state so a close from ANY path (Esc, another panel) still cancels correctly.
-- The owner does the async commit and reports back via report(ok, message).

local Players = game:GetService("Players")

local UIFramework = require(script.Parent.UI)
local UIController = UIFramework.Controller
local UISound = UIFramework.Sound

local interface = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Interface")
local panel = interface:FindFirstChild("CreatePlanet")

local M = {}

if not panel then
	warn("[CreatePlanet] Interface.CreatePlanet not found; prompt disabled")
	function M.open() end
	function M.close() end
	return M
end

local textbox = panel.TextInput.TextBox :: TextBox
local confirmImg = panel.Confirm :: ImageLabel
local confirmBtn = panel.Confirm.Button :: TextButton
local cancelBtn = panel.Cancel.Button :: TextButton
local log = panel.Log :: TextLabel
panel.Visible = false

local GREEN = Color3.fromRGB(120, 230, 130)
local RED = Color3.fromRGB(232, 96, 96)
local DIM = Color3.fromRGB(180, 180, 190)

local state: "input" | "confirm" = "input"
local pendingName: string? = nil
local busy = false
local breath: Tween? = nil
local onSubmit: ((string, (boolean, string?) -> ()) -> ())? = nil
local onCancel: (() -> ())? = nil
local closingAfterSuccess = false

local function setLog(text: string, color: Color3)
	log.Text = text
	log.TextColor3 = color
end

local function stopBreath()
	if breath then
		breath:Cancel()
		breath = nil
	end
	confirmImg.ImageTransparency = 0
end

-- Local name rules (server still owns uniqueness). Returns (ok, errorOrTrimmed).
local function validate(raw: string): (boolean, string)
	local name = (raw:gsub("^%s+", ""):gsub("%s+$", ""))
	if #name < 3 then
		return false, "Name too short (min 3)."
	elseif #name > 18 then
		return false, "Name too long (max 18)."
	elseif not name:match("^[%w %-']+$") then
		return false, "Letters, numbers, spaces only."
	end
	return true, name
end

local function toInput(clearText: boolean?)
	state = "input"
	pendingName = nil
	busy = false
	stopBreath()
	textbox.TextEditable = true
	if clearText then
		textbox.Text = ""
	end
	setLog("Name your star.", DIM)
	textbox:CaptureFocus()
end

local function toConfirm(name: string)
	state = "confirm"
	pendingName = name
	textbox.TextEditable = false
	textbox:ReleaseFocus()
	setLog(`Plant "{name}"?  Confirm again.`, GREEN)
	UISound.play("confirm")
	breath = UIController.breathe(confirmImg, "ImageTransparency", 0, 0.5, 0.7)
	-- Flourish on reaching the confirm state. No-op until you author an emitter config
	-- named "ConfirmSparkle" under ReplicatedStorage.Assets.Emitters (via the plugin).
	UIFramework.burst(confirmImg, "ConfirmSparkle", 14)
end

-- Called by UIController on ANY close (Esc, group, or code) → clean up + cancel.
local function onClosed()
	stopBreath()
	textbox:ReleaseFocus()
	busy = false
	state = "input"
	pendingName = nil
	local cancelCb = onCancel
	onSubmit, onCancel = nil, nil
	if not closingAfterSuccess and cancelCb then
		cancelCb()
	end
	closingAfterSuccess = false
end

UIController.register("CreatePlanet", { group = "main", modal = true, onClose = onClosed })
-- We own these buttons' sounds (confirm chime / cancel), so the universal feedback
-- binder skips their click sound (checked at click time — order-independent).
confirmBtn:SetAttribute("UISoundOwned", true)
cancelBtn:SetAttribute("UISoundOwned", true)

function M.open(cbs: { onSubmit: (string, (boolean, string?) -> ()) -> (), onCancel: (() -> ())? })
	onSubmit = cbs.onSubmit
	onCancel = cbs.onCancel
	closingAfterSuccess = false
	UIController.open("CreatePlanet")
	toInput(true)
end

function M.close()
	UIController.close("CreatePlanet")
end

local function finishSuccess()
	closingAfterSuccess = true
	UIController.close("CreatePlanet")
end

-- Confirm: INPUT→CONFIRM (validate), or commit in CONFIRM.
confirmBtn.MouseButton1Click:Connect(function()
	if busy then
		return
	end
	UIController.press(confirmImg)
	if state == "input" then
		local ok, result = validate(textbox.Text)
		if not ok then
			setLog(result, RED)
			UISound.play("error")
			return
		end
		toConfirm(result)
	elseif state == "confirm" and pendingName then
		busy = true
		stopBreath()
		UISound.play("select")
		setLog("Planting…", DIM)
		local name = pendingName
		local handler = onSubmit
		if handler then
			handler(name, function(success: boolean, message: string?)
				if not UIController.isOpen("CreatePlanet") then
					return -- prompt closed underneath us
				end
				if success then
					finishSuccess()
				else
					setLog(message or "Couldn't plant here.", RED)
					UISound.play("error")
					toInput(false) -- keep the typed name so they can tweak it
				end
			end)
		end
	end
end)

-- Cancel: CONFIRM→INPUT (stay), or INPUT→close (full cancel via onClosed).
cancelBtn.MouseButton1Click:Connect(function()
	if busy then
		return
	end
	UIController.press(panel.Cancel)
	UISound.play("cancel")
	if state == "confirm" then
		toInput(false)
	else
		M.close()
	end
end)

return M
