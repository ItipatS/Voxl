--!strict
-- StarterPlayerScripts/StarExit.luau  (Star place)
-- QuickMenu → Back → confirm → leave the star for the Cluster.
--
-- Leaving is irreversible from the player's side (they land in the lobby and have
-- to fly back), so it goes through the authored `Promt` frame rather than firing on
-- the first click. The Back button is one slot away from Bag on the same menu.
--
-- The client only ASKS. `systems/starexit` owns the teleport — see the note there
-- about why a client that picks its own destination is a problem.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local blink = require(ReplicatedStorage.std.ClientNet)
local transition = require(ReplicatedStorage.std.transition)
local UIController = require(script.Parent:WaitForChild("UI"):WaitForChild("Controller"))
local Notifier = require(script.Parent.UI:WaitForChild("Notifier"))

local interface = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Interface")

-- Authored in Studio; spelled "Promt" there, and renaming an instance out from
-- under the place file is a worse idea than matching it.
local prompt = interface:WaitForChild("Promt", 10) :: Frame?
local quickMenu = interface:FindFirstChild("QuickMenu") :: Frame?

if not prompt or not quickMenu then
	warn(`[StarExit] missing UI (Promt={prompt ~= nil}, QuickMenu={quickMenu ~= nil}) — `
		.. "no way to leave the star")
	return {}
end

local back = quickMenu:FindFirstChild("Back")
local label = prompt:FindFirstChild("Label") :: TextLabel?
local log = prompt:FindFirstChild("Log") :: TextLabel?

-- Confirm/Cancel are ImageLabels with a TextButton inside doing the clicking.
local function buttonIn(name: string): GuiButton?
	local holder = prompt:FindFirstChild(name)
	if not holder then
		return nil
	end
	if holder:IsA("GuiButton") then
		return holder
	end
	return holder:FindFirstChildWhichIsA("GuiButton", true)
end

local confirm = buttonIn("Confirm")
local cancel = buttonIn("Cancel")

-- Modal: it must take the input context so Esc closes it and gameplay (mining,
-- flying) doesn't run underneath a confirmation dialog.
UIController.register("LeavePrompt", { frames = { "Promt" }, modal = true })

local asking = false

local function ask()
	if asking then
		return
	end
	asking = true
	if label then
		label.Text = "Leave this star?"
	end
	if log then
		log.Text = "You'll return to the Cluster."
	end
	UIController.open("LeavePrompt")
end

local function dismiss()
	asking = false
	UIController.close("LeavePrompt")
end

if back and back:IsA("GuiButton") then
	back:SetAttribute("UISoundOwned", true) -- the prompt's own open sound is the feedback
	back.MouseButton1Click:Connect(ask)
else
	warn("[StarExit] QuickMenu.Back is not a button — nothing opens the leave prompt")
end

if cancel then
	cancel.MouseButton1Click:Connect(dismiss)
end

if confirm then
	confirm.MouseButton1Click:Connect(function()
		if not asking then
			return
		end
		asking = false
		UIController.close("LeavePrompt")
		-- Close the iris BEFORE the teleport so the last thing seen is the
		-- transition, not a frozen world — same as entering a star does.
		transition.close({ name = "The Cluster", subtitle = "Returning…" })
		blink.LeaveStar.Fire()
	end)
else
	warn("[StarExit] Promt has no Confirm button — the prompt cannot be accepted")
end

-- The server refused (unset lobby place id, or Studio, where TeleportAsync does
-- not work). Reopen the world rather than leaving the player behind a closed iris
-- wondering whether the game hung.
blink.LeaveDenied.On(function(reason: string)
	transition.open()
	Notifier.toast(reason, "error")
end)

return {}
