--[=[
    @Module: MenuService
    @description: Server side of the main-menu flow, built around StreamingEnabled.

    A character MUST exist for GUI to copy into PlayerGui and for the world to stream,
    so players DO spawn on join (CharacterAutoLoads stays on). Until they deploy we
    **hold the character anchored inside `workspace.MenuHold`** (a black box placed near
    the menu camera so the menu vista stays streamed) — invisible to the player, who
    sees the menu camera vista instead.

    The framework still registers the player on spawn (data loads), but plot assignment
    + teleport are **deferred to deploy** so plot selection is real — that logic lives in
    `PlacementComponent:Deploy(plotName)` (an authorized Session RPC the client calls).
    This service only owns the spawn-hold; `PlacementComponent:Deploy` releases the char
    (unanchor + teleport to the chosen plot) and marks the player `Deployed`.

    Slots are placeholder for now (single flat profile until Phase 8 — see
    .claude/plans/gdd-implementation-roadmap.md).
]=]

-- / Services:

local Players = game:GetService("Players")

-- / Constants:

local IDENTIFIER = "MenuService"
local MENU_HOLD_NAME = "MenuHold"

-- / State:

local MenuService = {}

local _initialized = false

-- / Private:

local function _holdCharacter(player, character)
    -- Skip if the player has already deployed (post-deploy respawns route to the plot
    -- via PlacementComponent._SetupPlotSpawn, not back into the box).
    if player:GetAttribute("Deployed") then return end

    local root = character:WaitForChild("HumanoidRootPart", 5)
    if not root then return end

    local hold = workspace:FindFirstChild(MENU_HOLD_NAME)
    if hold then
        character:PivotTo(hold.CFrame)
    end

    root.Anchored = true
end

local function _onCharacterAdded(player, character)
    -- defer so the humanoid is fully parented before we pivot/anchor it
    task.defer(function()
        _holdCharacter(player, character)
    end)
end

local function _hookPlayer(player)
    player.CharacterAdded:Connect(function(character)
        _onCharacterAdded(player, character)
    end)
    if player.Character then
        _onCharacterAdded(player, player.Character)
    end
end

-- / Public:

function MenuService.Initialize()
    if _initialized then return end
    _initialized = true

    -- StreamingEnabled needs a character for GUI + world streaming, so spawn on join.
    Players.CharacterAutoLoads = true

    Players.PlayerAdded:Connect(_hookPlayer)
    for _, player in Players:GetPlayers() do
        _hookPlayer(player)
    end
end

return MenuService
