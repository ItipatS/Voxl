-- StarterPlayerScripts/InventoryToggle.luau
-- Minimal open/close for the authored inventory window (the RPG UIManager that
-- normally does this isn't running in Voxl). Hidden by default; toggled by the
-- quickMenu Bag button, the window's Exit button, or the E key.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local interface = localPlayer:WaitForChild("PlayerGui"):WaitForChild("Interface")
local inventory = interface:WaitForChild("Inventory")
local equipments = interface:FindFirstChild("Equipments")
local quickMenu = interface:FindFirstChild("quickMenu")

local open = false

local function setOpen(value: boolean)
    open = value
    inventory.Visible = value
    if equipments then
        equipments.Visible = value
    end
end

setOpen(false)

local function toggle()
    setOpen(not open)
end

if quickMenu then
    local bag = quickMenu:FindFirstChild("Bag")
    if bag and bag:IsA("GuiButton") then
        bag.MouseButton1Click:Connect(toggle)
    end
end

local exit = inventory:FindFirstChild("Exit")
if exit and exit:IsA("GuiButton") then
    exit.MouseButton1Click:Connect(function()
        setOpen(false)
    end)
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    if input.KeyCode == Enum.KeyCode.E then
        toggle()
    end
end)

return {}
