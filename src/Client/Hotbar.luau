-- StarterPlayerScripts/Hotbar.luau
-- Drives the always-visible HotBar (Interface.HotBar, Slot1..Slot9). Each slot is
-- one placeable block, shown as a small 3D block preview in its ViewportFrame.
-- Click a slot or press its number to select; the selection is what BlockEdit
-- places. This is the first 9 "slots" of the eventual block inventory, surfaced
-- outside the inventory window — quantities hook in once persistence/mining land.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local BlockPreview = require(script.Parent:WaitForChild("BlockPreview"))
local BlockInventory = require(script.Parent:WaitForChild("BlockInventory"))
local BLOCK = WorldGen.BLOCK

local localPlayer = Players.LocalPlayer

local Hotbar = {}

-- Slot order (extend freely; empty slots stay blank).
local PALETTE: { number } = {
    BLOCK.Grass, BLOCK.Dirt, BLOCK.Stone, BLOCK.Sand, BLOCK.Snow, BLOCK.OakLog, BLOCK.OakLeaves,
}
local SLOTS = 9
local selected = 1

local hotbar = localPlayer:WaitForChild("PlayerGui"):WaitForChild("Interface"):WaitForChild("HotBar")

local function slotFor(i: number): Instance?
    return hotbar:FindFirstChild("Slot" .. i)
end

-- Show a block preview in a slot's ViewportFrame.
local function fillSlot(slot: Instance, blockId: number)
    local vpf = slot:FindFirstChild("ViewportFrame") :: ViewportFrame?
    if vpf then
        BlockPreview.build(vpf, blockId)
    end
end

-- Reflect owned counts on each slot's Quantity label; dim slots you can't place.
local function updateCounts()
    for i = 1, SLOTS do
        local slot = slotFor(i)
        if slot then
            local block = PALETTE[i]
            local q = slot:FindFirstChild("Quantity") :: TextLabel?
            if block then
                local count = BlockInventory.getCount(block)
                if q then
                    q.Text = tostring(count)
                    q.Visible = true
                end
                if slot:IsA("ImageButton") then
                    slot.ImageTransparency = if count > 0 then 0 else 0.55
                end
            else
                if q then
                    q.Text = ""
                    q.Visible = false
                end
            end
        end
    end
end

local function highlight(active: number)
    for i = 1, SLOTS do
        local slot = slotFor(i)
        if slot then
            local stroke = slot:FindFirstChild("SelStroke") :: UIStroke?
            if not stroke then
                stroke = Instance.new("UIStroke")
                stroke.Name = "SelStroke"
                stroke.Color = Color3.fromRGB(255, 233, 120)
                stroke.Thickness = 0
                stroke.Parent = slot
            end
            stroke.Thickness = if i == active then 3 else 0
        end
    end
end

local function select(i: number)
    if PALETTE[i] then
        selected = i
        highlight(i)
    end
end

function Hotbar.getSelectedBlock(): number
    return PALETTE[selected] or BLOCK.Stone
end

for i = 1, SLOTS do
    local slot = slotFor(i)
    if slot then
        if PALETTE[i] then
            fillSlot(slot, PALETTE[i])
        end
        if slot:IsA("GuiButton") then
            (slot :: GuiButton).MouseButton1Click:Connect(function()
                select(i)
            end)
        end
    end
end
highlight(selected)

BlockInventory.onChanged(updateCounts)
updateCounts()

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    local kv = input.KeyCode.Value
    if kv >= Enum.KeyCode.One.Value and kv <= Enum.KeyCode.Nine.Value then
        select(kv - Enum.KeyCode.One.Value + 1)
    end
end)

return Hotbar
