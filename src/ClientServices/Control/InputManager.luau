local InputManager = {}

local UIManager = require(script.Parent.Parent.UI.UI)

local UIS = game:GetService("UserInputService")

local player = game.Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local hum = char.Humanoid
local mouse = player:GetMouse()

local inputConnection
local actions = {}
local inputBindings = {}

local function getTargetUnderCursor()
	local target = mouse.Target
	if target and target.Parent then
		local humanoid = target.Parent:FindFirstChild("Humanoid")
		if humanoid then
			return target.Parent
		end
	end
	return nil
end

local function handleInput(input, processed)
	if processed then return end

	local actionName = inputBindings[input.KeyCode] or inputBindings[input.UserInputType]
	if actionName and actions[actionName] then
		actions[actionName]()
	end
end

local function connectInput()
	if inputConnection then
		inputConnection:Disconnect()
	end

	inputConnection = UIS.InputBegan:Connect(handleInput)
end

local function Initialize()
	print("init InputManager")
	-- Define actions and bindings here
	actions = {
		ToggleMenu = function()
			local menu = UIManager:GetUIElement("quickMenu")
			if menu then
				UIManager:ToggleUI(menu, "quickMenu")
			else
				warn(menu, " is not cached!")
			end
		end,
		ToggleInventory = function()
			local inventoryGroup = {"Inventory", "Equipments"}
			UIManager:ToggleCompositeUI(inventoryGroup, "InventoryGroup")
		end,
	}

	inputBindings = {
		[Enum.KeyCode.B] = "ToggleMenu",
		[Enum.KeyCode.Backquote] = "ToggleInventory",
	}

	-- Connect input handler
	connectInput()
end

player.CharacterAdded:Connect(Initialize)
Initialize()

return InputManager
	