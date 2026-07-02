-- ServerScriptService/systems/WorldStore.luau
--!strict

-- Persistence for the world's player edits. The world is base (WorldGen) ⊕ diff;
-- only the diff is stored. On boot we load the diff from ProfileStore, apply it to
-- the authoritative WorldDiff, and stream it to each joining client (so saved
-- builds show up). Every edit is recorded back into the profile, which
-- ProfileStore autosaves. v1: one shared world; world-per-name slots in via
-- WORLD_NAME. In Studio without API access, ProfileStore transparently mocks.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileStore = require(ServerScriptService.DevPackages.profilestore)
local WorldDiff = require(ReplicatedStorage.Misc.WorldDiff)
local blink = require(ServerScriptService.ServerNet)

local WorldStore = {}

local WORLD_NAME = "MainWorld"
local SYNC_BATCH = 2000 -- edits per network packet when syncing a client

type EditMap = { [string]: number } -- "wx,y,wz" -> blockId
export type Claim = { owner: number, wx: number, wz: number, radius: number }
local store = ProfileStore.New("VoxlWorld_v1", { edits = {} :: EditMap, claims = {} :: { Claim } })

local profile: any = nil
local loaded = false
local pending: EditMap = {} -- edits applied before the profile finished loading
local readyCallbacks: { (claims: { Claim }) -> () } = {}

local function cellKey(wx: number, y: number, wz: number): string
    return wx .. "," .. y .. "," .. wz
end

local function parseKey(key: string): (number?, number?, number?)
    local sx, sy, sz = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
    if not sx then
        return nil, nil, nil
    end
    return tonumber(sx), tonumber(sy), tonumber(sz)
end

-- Claims (land locks) persist alongside edits.
function WorldStore.addClaim(claim: Claim)
    if profile then
        local list = profile.Data.claims
        list[#list + 1] = claim
    end
end

-- Called with the persisted claims once the world profile has loaded (fires
-- immediately if already loaded).
function WorldStore.onReady(fn: (claims: { Claim }) -> ())
    if loaded and profile then
        fn(profile.Data.claims)
    else
        readyCallbacks[#readyCallbacks + 1] = fn
    end
end

-- Record an applied edit so it persists.
function WorldStore.record(wx: number, y: number, wz: number, block: number)
    local key = cellKey(wx, y, wz)
    if profile then
        profile.Data.edits[key] = block
    else
        pending[key] = block
    end
end

local function syncTo(player: Player)
    if not profile then
        return
    end
    local batch = {}
    for key, block in profile.Data.edits do
        local wx, y, wz = parseKey(key)
        if wx then
            batch[#batch + 1] = { wx = wx, y = y, wz = wz, block = block }
            if #batch >= SYNC_BATCH then
                blink.SyncDiff.Fire(player, batch)
                batch = {}
            end
        end
    end
    if #batch > 0 then
        blink.SyncDiff.Fire(player, batch)
    end
end

Players.PlayerAdded:Connect(function(player)
    if loaded then
        syncTo(player)
    end
end)

task.spawn(function()
    local p = store:StartSessionAsync(WORLD_NAME, { Steal = true })
    if not p then
        warn("[WorldStore] could not start world session; edits won't persist this run")
        return
    end
    p:Reconcile()
    p.OnSessionEnd:Connect(function()
        profile = nil
        loaded = false
    end)

    -- Apply saved edits to the authoritative diff.
    local n = 0
    for key, block in p.Data.edits do
        local wx, y, wz = parseKey(key)
        if wx then
            WorldDiff.set(wx, y, wz, block)
            n += 1
        end
    end
    -- Fold in any edits that landed while we were loading.
    for key, block in pending do
        p.Data.edits[key] = block
    end
    table.clear(pending)

    profile = p
    loaded = true
    print(`[WorldStore] loaded {n} edits, {#p.Data.claims} claims for '{WORLD_NAME}'`)

    -- Restore claims now that the profile is loaded.
    for _, fn in readyCallbacks do
        task.spawn(fn, p.Data.claims)
    end
    table.clear(readyCallbacks)

    -- Sync anyone already in-game.
    for _, player in Players:GetPlayers() do
        syncTo(player)
    end
end)

return WorldStore
