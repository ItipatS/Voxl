-- ServerScriptService/systems/BlockEditServer.luau
--!strict

-- Server-authoritative block editing. Receives an EditBlock request, validates it
-- (reach + a known block id), applies it to the authoritative world diff, and
-- broadcasts the change to everyone. v1: unclaimed-land freedom — no lock checks
-- yet (those slot in right here), no persistence yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local blink = require(game:GetService("ServerScriptService").ServerNet)
local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)
local WorldStore = require(script.Parent.WorldStore)

local BLOCK_SIZE = WorldGen.BLOCK_SIZE
local BLOCK = WorldGen.BLOCK
local REACH_STUDS = 10 * BLOCK_SIZE -- how far a player can edit from their root

-- Blocks a client is allowed to place (Air = break is always allowed).
local PLACEABLE: { [number]: boolean } = {
    [BLOCK.Grass] = true,
    [BLOCK.Dirt] = true,
    [BLOCK.Sand] = true,
    [BLOCK.Stone] = true,
    [BLOCK.Snow] = true,
    [BLOCK.OakLog] = true,
    [BLOCK.OakLeaves] = true,
}

blink.EditBlock.On(function(player: Player, edit)
    local block = edit.block
    if block ~= BLOCK.Air and not PLACEABLE[block] then
        return -- unknown/disallowed block
    end

    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then
        return
    end

    -- Reach check against the cell centre.
    local cell = Vector3.new(
        (edit.wx + 0.5) * BLOCK_SIZE,
        (edit.y + 0.5) * BLOCK_SIZE,
        (edit.wz + 0.5) * BLOCK_SIZE
    )
    if (root.Position - cell).Magnitude > REACH_STUDS + BLOCK_SIZE then
        return -- too far
    end

    -- TODO: lock/claim permission check goes here (unclaimed land is free for now).

    WorldDiff.set(edit.wx, edit.y, edit.wz, block)
    WorldStore.record(edit.wx, edit.y, edit.wz, block)
    blink.BlockEdited.FireAll({ { wx = edit.wx, y = edit.y, wz = edit.wz, block = block } })
end)

return 0
