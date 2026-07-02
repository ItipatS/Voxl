-- StarterPlayerScripts/BlockPreview.luau
-- Builds a small isometric 3D block inside a ViewportFrame (hotbar + inventory).
-- The block is scaled to ~0.75 of the framed size (some padding), and the three
-- faces the isometric camera sees — Top, Right, Back — are textured (Front too,
-- so no bare plastic face can ever show).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Mesher = require(ReplicatedStorage.Misc.Mesher)

local BlockPreview = {}

local SIZE = 0.75

function BlockPreview.build(vpf: ViewportFrame, blockId: number)
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
    part.Size = Vector3.new(SIZE, SIZE, SIZE)
    part.CFrame = CFrame.new()
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    local function face(nid: Enum.NormalId, img: string)
        local t = Instance.new("Texture")
        t.Texture = img
        t.Face = nid
        t.StudsPerTileU = SIZE
        t.StudsPerTileV = SIZE
        t.Parent = part
    end
    face(Enum.NormalId.Top, tex.top)
    face(Enum.NormalId.Right, tex.side)
    face(Enum.NormalId.Back, tex.side)
    face(Enum.NormalId.Front, tex.side)
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

return BlockPreview
