-- ServerScriptService/systems/LockService.luau
--!strict

-- Land claims ("locks"). A lock claims a CYLINDER (radius in the XZ plane,
-- unbounded in Y) centred where the player drops it. Inside a claim, only the
-- owner may edit; unclaimed land is free. The claim is shown by the crown model
-- plus a ForceField cylinder marking the radius. Claims persist with the world.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local blink = require(ServerScriptService.ServerNet)
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local WorldStore = require(script.Parent.WorldStore)

local BLOCK_SIZE = WorldGen.BLOCK_SIZE

-- Small lock (crown at its normal size). Radius in blocks; bump for bigger tiers.
local SMALL_RADIUS = 16
local FIELD_HEIGHT = 400 -- studs; tall enough to read as "unbounded" vertically

local LockService = {}

type Claim = { owner: number, wx: number, wz: number, radius: number, visual: Model? }
local claims: { Claim } = {}

local crownTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("crown")
local claimsFolder = Instance.new("Folder")
claimsFolder.Name = "Claims"
claimsFolder.Parent = Workspace

local function spawnVisual(claim: Claim)
    local surfaceY = WorldGen.getSurfaceHeight(claim.wx, claim.wz)
    local cx = (claim.wx + 0.5) * BLOCK_SIZE
    local cz = (claim.wz + 0.5) * BLOCK_SIZE
    local groundY = (surfaceY + 1) * BLOCK_SIZE

    local model = Instance.new("Model")
    model.Name = "Claim"

    local crown = crownTemplate:Clone()
    for _, p in crown:GetDescendants() do
        if p:IsA("BasePart") then
            p.Anchored = true
            p.CanCollide = false
        end
    end
    crown:PivotTo(CFrame.new(cx, groundY + BLOCK_SIZE * 0.5, cz))
    crown.Parent = model

    local R = claim.radius * BLOCK_SIZE
    local field = Instance.new("Part")
    field.Name = "Field"
    field.Shape = Enum.PartType.Cylinder
    field.Size = Vector3.new(FIELD_HEIGHT, R * 2, R * 2)
    field.CFrame = CFrame.new(cx, groundY, cz) * CFrame.Angles(0, 0, math.rad(90))
    field.Material = Enum.Material.ForceField
    field.Color = Color3.fromRGB(90, 190, 255)
    field.Transparency = 0.55
    field.Anchored = true
    field.CanCollide = false
    field.CanQuery = false
    field.CanTouch = false
    field.CastShadow = false
    field.Parent = model

    model.Parent = claimsFolder
    claim.visual = model
end

local function claimAt(wx: number, wz: number): Claim?
    for _, c in claims do
        local dx, dz = wx - c.wx, wz - c.wz
        if dx * dx + dz * dz <= c.radius * c.radius then
            return c
        end
    end
    return nil
end

-- May this player edit this cell? Free unless it's inside someone else's claim.
function LockService.canEdit(player: Player, wx: number, wz: number): boolean
    local c = claimAt(wx, wz)
    return c == nil or c.owner == player.UserId
end

function LockService.place(player: Player)
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then
        return
    end
    local wx = math.floor(root.Position.X / BLOCK_SIZE)
    local wz = math.floor(root.Position.Z / BLOCK_SIZE)

    if claimAt(wx, wz) then
        return -- can't overlap an existing claim
    end

    local claim: Claim = { owner = player.UserId, wx = wx, wz = wz, radius = SMALL_RADIUS }
    claims[#claims + 1] = claim
    spawnVisual(claim)
    WorldStore.addClaim({ owner = claim.owner, wx = wx, wz = wz, radius = claim.radius })
end

blink.PlaceLock.On(function(player)
    LockService.place(player)
end)

-- Restore persisted claims once the world profile is loaded.
WorldStore.onReady(function(saved)
    for _, sc in saved do
        local claim: Claim = { owner = sc.owner, wx = sc.wx, wz = sc.wz, radius = sc.radius }
        claims[#claims + 1] = claim
        spawnVisual(claim)
    end
end)

return LockService
