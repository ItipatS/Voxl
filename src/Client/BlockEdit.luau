-- StarterPlayerScripts/BlockEdit.luau
-- Client block editing: aim at the terrain, left-click breaks the targeted block,
-- right-click places the selected block on the face you're pointing at. Number
-- keys pick the block. Server-authoritative — we only send the request; the block
-- appears when the server's BlockEdited broadcast comes back (ChunkClient re-meshes).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local blink = require(ReplicatedStorage.std.ClientNet)
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local Hotbar = require(script.Parent:WaitForChild("Hotbar"))

local BLOCK_SIZE = WorldGen.BLOCK_SIZE
local BLOCK = WorldGen.BLOCK
local REACH = 10 * BLOCK_SIZE

local localPlayer = Players.LocalPlayer

-- Target cell outline.
local Chunks = Workspace:WaitForChild("Chunks")
local marker = Instance.new("Part")
marker.Name = "BlockTarget"
marker.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
marker.Anchored = true
marker.CanCollide = false
marker.CanQuery = false
marker.CanTouch = false
marker.Transparency = 1
marker.Parent = Workspace
local box = Instance.new("SelectionBox")
box.Adornee = marker
box.LineThickness = 0.04
box.Color3 = Color3.new(0, 0, 0)
box.SurfaceColor3 = Color3.new(1, 1, 1)
box.SurfaceTransparency = 0.9
box.Visible = false
box.Parent = marker

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { Chunks }

local function cellOf(p: Vector3): (number, number, number)
    return math.floor(p.X / BLOCK_SIZE), math.floor(p.Y / BLOCK_SIZE), math.floor(p.Z / BLOCK_SIZE)
end

-- Raycast from the camera through the cursor; returns hit + the break/place cells.
local function aim()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local m = UserInputService:GetMouseLocation()
    local ray = cam:ViewportPointToRay(m.X, m.Y)
    return Workspace:Raycast(ray.Origin, ray.Direction * REACH, rayParams)
end

local function updateMarker()
    local hit = aim()
    if not hit then
        box.Visible = false
        return
    end
    -- the solid cell just inside the hit face
    local inside = hit.Position - hit.Normal * (BLOCK_SIZE * 0.5)
    local bx, by, bz = cellOf(inside)
    marker.Position = Vector3.new((bx + 0.5) * BLOCK_SIZE, (by + 0.5) * BLOCK_SIZE, (bz + 0.5) * BLOCK_SIZE)
    box.Visible = true
end

local function breakBlock()
    local hit = aim()
    if not hit then return end
    local inside = hit.Position - hit.Normal * (BLOCK_SIZE * 0.5)
    local bx, by, bz = cellOf(inside)
    blink.EditBlock.Fire({ wx = bx, y = by, wz = bz, block = BLOCK.Air })
end

local function placeBlock()
    local hit = aim()
    if not hit then return end
    local outside = hit.Position + hit.Normal * (BLOCK_SIZE * 0.5)
    local bx, by, bz = cellOf(outside)
    blink.EditBlock.Fire({ wx = bx, y = by, wz = bz, block = Hotbar.getSelectedBlock() })
end

RunService.RenderStepped:Connect(updateMarker)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        breakBlock()
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        placeBlock()
    end
    -- Block selection (number keys / slot clicks) is owned by Hotbar.
end)

return {}
