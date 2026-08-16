--!strict
-- StarterPlayerScripts/CameraToggle.luau  (Star place)
-- Tab switches between first and third person.
--
-- Both views earn their place on the ground: third person to see your character and
-- judge a jump or a build, first person to place a block exactly where you mean to.
-- Neither is right for everything, so it is the player's call rather than ours.
--
-- STAR PLACE ONLY. The lobby runs its own CameraController (custom shiftlock,
-- scroll-drives-hotbar), and writing Player.CameraMode underneath it would be two
-- systems fighting one camera.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Notifier = require(script.Parent:WaitForChild("UI"):WaitForChild("Notifier"))

local player = Players.LocalPlayer

-- Tab, and it is genuinely free: nothing else in the codebase binds it (the keys in
-- use are WASD/Space/Ctrl/Shift/Alt for movement, 1-9 for the hotbar, E inventory,
-- F fly, Esc for modals).
local TOGGLE_KEY = Enum.KeyCode.Tab

-- How far back third person sits, and the floor it cannot be scrolled past. Holding
-- the minimum ABOVE zero is what keeps the two modes distinct: without it, scrolling
-- all the way in lands you in first person while the toggle still says third, and
-- the key appears to do nothing on the next press.
local THIRD_DIST = 14
local MAX_ZOOM = 128 -- matches StarterPlayer.CameraMaxZoomDistance in the project file

-- The UI framework decides whether gameplay input is live (a modal open, a text box
-- focused). Tab is a common "next field" key, so this matters more here than for
-- most binds. If the framework hasn't loaded yet, assume not blocked.
local UIController: any = nil
task.spawn(function()
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("UI"):WaitForChild("Controller")) :: any
	end)
	if ok then
		UIController = mod
	end
end)
local function blocked(): boolean
	return UIController ~= nil and UIController.gameplayBlocked and UIController.gameplayBlocked()
end

local firstPerson = false

local function apply(notify: boolean)
	if firstPerson then
		player.CameraMinZoomDistance = 0.5
		player.CameraMaxZoomDistance = 0.5
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		player.CameraMode = Enum.CameraMode.Classic
		-- Order matters: raise the ceiling before the floor, or setting a minimum
		-- above the current maximum clamps to the old max and the camera stays in.
		player.CameraMaxZoomDistance = MAX_ZOOM
		player.CameraMinZoomDistance = THIRD_DIST
	end
	if notify then
		Notifier.toast(if firstPerson then "First person" else "Third person")
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= TOGGLE_KEY or blocked() then
		return
	end
	firstPerson = not firstPerson
	apply(true)
end)

-- CameraMode is a Player property and survives respawns, but the zoom bounds are
-- worth re-asserting: anything that touches them (a cutscene, a future controller)
-- would otherwise leave the mode and the camera disagreeing.
player.CharacterAdded:Connect(function()
	apply(false)
end)

apply(false)

return {}
