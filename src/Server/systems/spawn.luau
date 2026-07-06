-- ServerScriptService/systems/spawn.luau
-- The world has no server-side terrain (blocks are meshed on each client), so the
-- default SpawnLocation floats in the void far above the ground. Reposition it onto
-- the deterministic surface height at startup so both the server's view of players and
-- the raw spawn point sit on the terrain. Actual anti-fall handling is client-side
-- (the client owns character physics and knows when its local chunk is meshed).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)

local SPAWN_CLEARANCE = 5 -- studs above the surface block's top face

local function surfaceTopY(x: number, z: number): number
    local wx = math.floor(x / WorldGen.BLOCK_SIZE)
    local wz = math.floor(z / WorldGen.BLOCK_SIZE)
    local surfaceY = WorldGen.getSurfaceHeight(wx, wz)
    return (surfaceY + 1) * WorldGen.BLOCK_SIZE
end

local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation")
if spawn then
    -- Bounded stars are centred at world origin, so spawn on the island centre; the legacy
    -- infinite world keeps the authored spawn XZ.
    local sx, sz = spawn.Position.X, spawn.Position.Z
    if WorldGen.isStar() then
        sx, sz = 0, 0
    end
    spawn.CFrame = CFrame.new(sx, surfaceTopY(sx, sz) + SPAWN_CLEARANCE, sz)
    spawn.Anchored = true
end

return {}
