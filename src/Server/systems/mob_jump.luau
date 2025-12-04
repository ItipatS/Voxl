--!strict
local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local world     = require(std.world)
local cts       = require(std.components)
local scheduler = require(std.scheduler)
local phases    = require(std.phases)

local Mob       = cts.Mob
local Transform = cts.Transform
local Hitbox    = cts.Hitbox
local AIState   = cts.AIState
local Traits    = cts.Traits
local Locomotion= cts.Locomotion

local params = RaycastParams.new()
params.CollisionGroup = "NPC"
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = {workspace.NPC_Hitboxes}

local STACKS: {[number]: {BasePart}} = {}

local StackWelds: {[BasePart]: WeldConstraint} = {}

local SavedPhysics: {[BasePart]: {
    Anchored: boolean,
    CanCollide: boolean,
    CanQuery: boolean,
    CanTouch: boolean,
    CollisionGroup: string,
}} = {}

local jumpers = world
    :query(Transform, Hitbox, AIState, Traits)
    :with(Mob)
    :cached()

local EPS = 1e-4

local function findPlayerHead(userId: number): BasePart?
    if userId == 0 then return nil end
    local plr = Players:GetPlayerByUserId(userId)
    if not plr or not plr.Character then return nil end
    return (plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart")) :: BasePart?
end

local function getStack(userId: number): {BasePart}
    local s = STACKS[userId]
    if not s then
        s = {}
        STACKS[userId] = s
    end
    return s
end

local function findInStack(stack: {BasePart}, part: BasePart): number?
    for i, p in ipairs(stack) do
        if p == part then
            return i
        end
    end
    return nil
end

local function stackOnPlayerHead(userId: number, hitbox: BasePart): WeldConstraint?
    local head = findPlayerHead(userId)
    if not head then return nil end

    if not SavedPhysics[hitbox] then
        SavedPhysics[hitbox] = {
            Anchored       = hitbox.Anchored,
            CanCollide     = hitbox.CanCollide,
            CanQuery       = hitbox.CanQuery,
            CanTouch       = hitbox.CanTouch,
            CollisionGroup = hitbox.CollisionGroup,
        }
    end

    local stack = getStack(userId)

    local baseCF: CFrame
    local baseHeight: number

    if #stack == 0 then
        baseCF = head.CFrame
        baseHeight = head.Size.Y
    else
        local top = stack[#stack]
        baseCF = top.CFrame
        baseHeight = top.Size.Y
    end

    local offsetY = (baseHeight * 0.5) + (hitbox.Size.Y * 0.5)
    local targetCF = baseCF * CFrame.new(0, offsetY, 0)

    -- while stacked, we let weld control movement, so:
    hitbox.Anchored = false
    hitbox.CanCollide = false
    hitbox.CanQuery = false
    hitbox.CanTouch = false

    hitbox.CFrame = targetCF

    local weld = Instance.new("WeldConstraint")
    weld.Part0 = hitbox:FindFirstChild("Foot")
    weld.Part1 = head:FindFirstChild("HairAttachment")
    weld.Parent = hitbox
    StackWelds[hitbox] = weld

    table.insert(stack, hitbox)

    hitbox:SetAttribute("StackRootUserId", userId)
    hitbox:SetAttribute("StackIndex", #stack)

    return weld
end


local function repackStack(userId: number)
    local head = findPlayerHead(userId)
    if not head then
        STACKS[userId] = {}
        return
    end

    local stack = STACKS[userId]
    if not stack or #stack == 0 then
        return
    end

    -- CLEANUP: remove invalid / deleted parts
    local cleaned = {}
    for _, hb in ipairs(stack) do
        if hb and hb.Parent ~= nil then
            table.insert(cleaned, hb)
        end
    end
    STACKS[userId] = cleaned
    stack = cleaned

    -- if stack is empty after cleanup
    if #stack == 0 then
        return
    end

    -- REPACK everyone downwards
    local baseCF = head.CFrame
    local baseHeight = head.Size.Y

    for i, hb in ipairs(stack) do
        local myHeight = hb.Size.Y
        local offsetY = (baseHeight * 0.5) + (myHeight * 0.5)

        local targetCF = baseCF * CFrame.new(0, offsetY, 0)
        hb.CFrame = targetCF

        hb:SetAttribute("StackRootUserId", userId)
        hb:SetAttribute("StackIndex", i)

        -- next base is this mob's position
        baseCF = targetCF
        baseHeight = myHeight
    end

    for hb, _ in pairs(SavedPhysics) do
        if hb.Parent == nil then
            SavedPhysics[hb] = nil
        end
    end

end



local function initJump(
    e: number,
    transform: {new: CFrame},
    hitbox: BasePart,
    ai: any,
    traits: any,
    playerPos: Vector3?,
    isStack: boolean
)
    local startPos = transform.new.Position
    local halfHeight = hitbox.Size.Y * 0.5

    local targetPos = startPos
    local stackUserId = 0

    if isStack and playerPos then
        -- aim slightly above head
        targetPos = Vector3.new(playerPos.X, playerPos.Y + halfHeight * 1.2, playerPos.Z)

        -- store userId for later weld
        local closestChar, closestUser = nil, 0
        for _, plr in Players:GetPlayers() do
            if plr.Character and plr.Character.PrimaryPart then
                local d = (plr.Character.PrimaryPart.Position - playerPos).Magnitude
                if d < 3 then
                    closestChar = plr.Character
                    closestUser = plr.UserId
                    break
                end
            end
        end
        stackUserId = closestUser
    elseif playerPos then
        -- normal jump: towards player, a bit in front
        local dir = (playerPos - startPos)
        dir = Vector3.new(dir.X, 0, dir.Z)
        if dir.Magnitude > EPS then
            dir = dir.Unit
            targetPos = startPos + dir * math.min(8, dir.Magnitude)
        end
    end

    ai.jumpPhase = 1
    ai.jumpT = 0
    ai.jumpDur = ai.jumpDur or math.random() * 0.3 + 0.5
    ai.jumpStart = startPos
    ai.jumpTarget = targetPos
    ai.stackTargetUserId = stackUserId

    -- optional: mark state for debug
    hitbox:SetAttribute("MobState", ai.state)

    world:set(e, AIState, ai)
end

local function tickJump(dt: number)
    for e, transform, hitbox, ai, traits in jumpers do
        if ai.state ~= "jump" and ai.state ~= "stackJump" and ai.state ~= "stacked" then
            -- not jumping
            continue
        end

        -- Phase 0: waiting until we decide start (brain just switched state)
        if ai.state ~= "stacked" and (ai.jumpPhase == nil or ai.jumpPhase == 0) then
            -- need a player position for nice arc; reuse TargetPos attribute if you want,
            -- or just use current transform forward. For now, try attribute:
            local targetPosAttr = hitbox:GetAttribute("TargetPos")
            local playerPos = (typeof(targetPosAttr) == "Vector3") and targetPosAttr or nil

            initJump(e, transform, hitbox, ai, traits, playerPos, ai.state == "stackJump")
            continue
        end

        -- Stacked: just sit there until stackDur expires
        if ai.state == "stacked" then
            ai.t = (ai.t or 0) + dt
            -- keep ECS transform synced with weld/head
            transform.new = hitbox.CFrame

            local userIdAttr = hitbox:GetAttribute("StackRootUserId")
            local userId = ai.stackTargetUserId or (typeof(userIdAttr) == "number" and userIdAttr or 0)

            if ai.dur and ai.t >= ai.dur then
                if userId ~= 0 then
                    local stack = STACKS[userId]
                    if stack then
                        local idx = findInStack(stack, hitbox)
                        if idx then
                            table.remove(stack, idx)
                        end
                    end

                    local weld = StackWelds[hitbox]
                    if weld then
                        weld:Destroy()
                    end
                    StackWelds[hitbox] = nil

                    for _, child in ipairs(hitbox:GetChildren()) do
                        if child:IsA("WeldConstraint") or child:IsA("Weld") then
                            child:Destroy()
                        end
                    end

                    local saved = SavedPhysics[hitbox]
                    if saved then
                        hitbox.Anchored       = saved.Anchored
                        hitbox.CanCollide     = saved.CanCollide
                        hitbox.CanQuery       = saved.CanQuery
                        hitbox.CanTouch       = saved.CanTouch
                        hitbox.CollisionGroup = saved.CollisionGroup
                        SavedPhysics[hitbox]  = nil
                    else
                        hitbox.Anchored = true
                        hitbox.CanCollide = true
                        hitbox.CanQuery = true
                        hitbox.CanTouch = true
                        hitbox.CollisionGroup = "NPC"
                    end

                    hitbox.CFrame = hitbox.CFrame * CFrame.new(0, hitbox.Size.Y * 0.5, 0)
                    hitbox:SetAttribute("StackRootUserId", nil)
                    hitbox:SetAttribute("StackIndex", nil)

                    repackStack(userId)
                end

                ai.state = "wander"
                ai.t = 0
                ai.dur = nil
                ai.stackTargetUserId = nil
                hitbox:SetAttribute("MobState", "wander")
                world:set(e, AIState, ai)
                return
            end

            world:set(e, AIState, ai)
            continue
        end

        -- Phase 1: in air
        if ai.jumpPhase == 1 then
            ai.jumpT += dt
            local dur = ai.jumpDur or 0.6
            local t = math.clamp(ai.jumpT / dur, 0, 1)

            local startPos = ai.jumpStart :: Vector3
            local targetPos = ai.jumpTarget :: Vector3
            if not startPos or not targetPos then
                ai.state = "wander"
                ai.jumpPhase = 0
                world:set(e, AIState, ai)
                continue
            end

            -- horizontal lerp
            local pos = startPos:Lerp(targetPos, t)

            -- vertical arc (parabola via sine)
            local jumpHeight = (traits.maxJumpHeightFactor or 1.0) * hitbox.Size.Y
            pos = Vector3.new(
                pos.X,
                math.max(startPos.Y, targetPos.Y) + math.sin(t * math.pi) * jumpHeight,
                pos.Z
            )

            -- apply
            transform.new = CFrame.new(pos, transform.new.LookVector)
            hitbox.CFrame = transform.new

            if t >= 1 then
                ai.jumpPhase = 2
                ai.jumpT = 0
            end

            world:set(e, AIState, ai)
            continue
        end

        -- Phase 2: landing / finalize
        if ai.jumpPhase == 2 then
            ai.jumpPhase = 0
            ai.jumpT = 0

            if ai.state == "stackJump" and ai.stackTargetUserId and ai.stackTargetUserId ~= 0 then
                local userId = ai.stackTargetUserId
                local weld = stackOnPlayerHead(userId, hitbox)
                if weld then
                    ai.state = "stacked"
                    ai.t = 0
                    ai.dur = math.random(10, 20)
                    hitbox:SetAttribute("MobState", "stacked")
                else
                    ai.state = "wander"
                end
            else
                ai.state = "wander"
            end

            world:set(e, AIState, ai)
        end
    end
end

-- ===== Wall detection / jump vs avoid =====
-- Run before normal movement system (in Physics phase)

local function wallCheckAndConvertToJump(dt: number)
    local movers = world:query(Transform, Hitbox, Locomotion, AIState, Traits):with(Mob):cached()

    for e, transform, hitbox, loco, ai, traits in movers do
        if loco.speed <= 0 then
            continue
        end
        if ai.state ~= "chase" and ai.state ~= "wander" and ai.state ~= "circle" then
            continue
        end

        local dir = loco.dir
        if dir.Magnitude <= EPS then
            continue
        end

        local pos = transform.new.Position
        local stepDist = loco.speed * dt
        local origin = pos + Vector3.new(0, hitbox.Size.Y * 0.5, 0)
        local result = Workspace:Raycast(origin, dir * (stepDist + 2), params)
        if not result then
            continue
        end

        local obstacleY = result.Position.Y
        local heightDiff = obstacleY - pos.Y
        if heightDiff <= 0 then
            continue
        end

        local maxJumpHeight = (traits.maxJumpHeightFactor or 1.0) * hitbox.Size.Y

        if heightDiff <= maxJumpHeight then
            -- convert to jump state
            ai.state = "jump"
            ai.t = 0
            ai.dur = math.random(0.5, 0.9)
            ai.jumpPhase = 0
            hitbox:SetAttribute("MobState", "jump")
            world:set(e, AIState, ai)
            -- movement this frame will be handled by jump system
        else
            -- too high: steer away slightly
            local up = Vector3.new(0, 1, 0)
            local side = up:Cross(dir)
            if side.Magnitude > EPS then
                side = side.Unit
                loco.dir = (dir + side * 0.5).Unit
                world:set(e, Locomotion, loco)
            end
        end
    end
end

local ACC = 0
local PHYS_HZ = 15
local PHYS_DT = 1 / PHYS_HZ

local function step(dt: number)
    ACC += dt
    if ACC < PHYS_DT then return end
    local stepDt = ACC
    ACC = 0

    wallCheckAndConvertToJump(stepDt)
    tickJump(stepDt)
end

scheduler.SYSTEM(step, phases.Physics)

return 0
