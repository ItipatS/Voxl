-- StarterPlayerScripts/InventoryRender.luau
-- Fills the inventory window's ItemSlots with the blocks the player owns (block
-- preview + count), driven by the synced BlockInventory. Clones the authored
-- ItemTemplate for each block so it matches the GUI style and the grid layout.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local BlockPreview = require(script.Parent:WaitForChild("BlockPreview"))
local BlockInventory = require(script.Parent:WaitForChild("BlockInventory"))
local BLOCK = WorldGen.BLOCK

local localPlayer = Players.LocalPlayer
local pg = localPlayer:WaitForChild("PlayerGui")
local interface = pg:WaitForChild("Interface")
local itemSlots = interface:WaitForChild("Inventory"):WaitForChild("ItemSlots")
local template = pg:WaitForChild("ItemTemplate"):WaitForChild("ItemTemplate")

-- Stable display order.
local ORDER = {
    BLOCK.Grass, BLOCK.Dirt, BLOCK.Stone, BLOCK.Sand, BLOCK.Snow, BLOCK.OakLog, BLOCK.OakLeaves,
}

local frames: { [number]: Instance } = {}

local function render()
    for order, block in ORDER do
        local count = BlockInventory.getCount(block)
        local frame = frames[block]
        if count > 0 then
            if not frame then
                frame = template:Clone()
                frame.Name = "Block_" .. block
                frame:SetAttribute("LayoutOrder", order)
                if frame:IsA("GuiObject") then
                    frame.LayoutOrder = order
                    frame.Visible = true
                end
                local vpf = frame:FindFirstChild("ViewportFrame") :: ViewportFrame?
                if vpf then
                    BlockPreview.build(vpf, block)
                end
                frame.Parent = itemSlots
                frames[block] = frame
            end
            local q = frame:FindFirstChild("Quantity") :: TextLabel?
            if q then
                q.Text = "x" .. count
                q.Visible = true
            end
        elseif frame then
            frame:Destroy()
            frames[block] = nil
        end
    end
end

BlockInventory.onChanged(render)
render()

return {}
