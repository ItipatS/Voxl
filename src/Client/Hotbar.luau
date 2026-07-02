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
local Mesher = require(ReplicatedStorage.Misc.Mesher)
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

-- Build a small isometric 3D block inside a slot's ViewportFrame.
local function fillSlot(slot: Instance, blockId: number)
    local vpf = slot:FindFirstChild("ViewportFrame") :: ViewportFrame?
    if not vpf then
        return
    end
    for _, c in vpf:GetChildren() do
        if c:IsA("BasePart") or c:IsA("Camera") then
            c:Destroy()
        end
    end
    local tex = Mesher.BlockTextures[blockId]
    if not tex then
        return
    end

    local part = Instance.new("Part")
    part.Size = Vector3.new(2, 2, 2)
    part.CFrame = CFrame.new()
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    local function face(nid: Enum.NormalId, img: string)
        local t = Instance.new("Texture")
        t.Texture = img
        t.Face = nid
        t.StudsPerTileU = 2
        t.StudsPerTileV = 2
        t.Parent = part
    end
    face(Enum.NormalId.Top, tex.top)
    face(Enum.NormalId.Front, tex.side)
    face(Enum.NormalId.Right, tex.side)
    part.Parent = vpf

    local cam = Instance.new("Camera")
    cam.FieldOfView = 18
    cam.CFrame = CFrame.lookAt(Vector3.new(3.4, 2.7, 3.4), Vector3.new(0, -0.15, 0))
    vpf.CurrentCamera = cam
    cam.Parent = vpf
    vpf.Ambient = Color3.fromRGB(220, 220, 220)
    vpf.LightColor = Color3.fromRGB(255, 255, 255)
    vpf.LightDirection = Vector3.new(-1, -1, -0.6)
    vpf.BackgroundTransparency = 1
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
