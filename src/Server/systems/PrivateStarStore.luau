-- ServerScriptService/systems/PrivateStarStore.luau
--!strict
-- Persistence for player-owned private stars (planets), via ProfileStore. Each
-- player owns ONE star, keyed `star_<UserId>`, stored as seed + edited-voxel
-- delta only (doc 06/13) — the base recomputes from the seed, so an unbuilt star
-- costs almost nothing.
--
-- Two access modes:
--   * OWNER in the lobby → StartSessionAsync (session-locked, single-live): they
--     can edit their star; ProfileStore autosaves + save-on-leave.
--   * PREVIEW a neighbour's planet you fly near → GetAsync (read-only, no lock):
--     render it without stealing their session (works even if the owner's offline).
--
-- (In Studio without API access, ProfileStore transparently mocks.)

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.DevPackages.profilestore)

local M = {}

type EditMap = { [string]: number } -- "wx,y,wz" -> blockId (the delta)
export type StarData = {
	owner: number,
	name: string,
	seed: number, -- permanent; base terrain derives from it
	plot: { number }, -- {x,y,z} permanent plot in the constellation; {0,0,0} = not planted yet
	biome: string, -- set at plant = nearest resource star's biome (flavor + tier-1 nodes)
	expandTier: number, -- 0..5 → {footprint, height} via config; the star-size progression lever
	constellation: string,
	edits: EditMap,
	createdAt: number,
}

local TEMPLATE: StarData = {
	owner = 0,
	name = "",
	seed = 0,
	plot = { 0, 0, 0 },
	biome = "",
	expandTier = 0,
	constellation = "",
	edits = {},
	createdAt = 0,
}

local store = ProfileStore.New("VoxlStar_v1", TEMPLATE)
local rng = Random.new()

local function keyFor(userId: number): string
	return "star_" .. userId
end

-- ---- owner sessions (editable, single-live) --------------------------------
local sessions: { [number]: any } = {} -- userId -> live profile

local function startOwnerSession(player: Player)
	local uid = player.UserId
	local p = store:StartSessionAsync(keyFor(uid), { Steal = true })
	if not p then
		warn(`[PrivateStarStore] no session for {player.Name}; their star won't persist`)
		return
	end
	p:Reconcile()
	p.OnSessionEnd:Connect(function()
		sessions[uid] = nil
	end)
	if player.Parent ~= Players then
		p:EndSession()
		return
	end
	-- First time: mint the star (seed is permanent; base terrain derives from it).
	if p.Data.owner == 0 then
		p.Data.owner = uid
		p.Data.name = player.DisplayName .. "'s Star"
		p.Data.seed = rng:NextInteger(1, 2 ^ 31 - 1)
		p.Data.createdAt = os.time()
	end
	sessions[uid] = p
end

Players.PlayerAdded:Connect(startOwnerSession)
Players.PlayerRemoving:Connect(function(player)
	local p = sessions[player.UserId]
	if p then
		p:EndSession()
	end
end)
for _, player in Players:GetPlayers() do
	task.spawn(startOwnerSession, player)
end

-- The live editable profile for a player's own star (nil until loaded).
function M.getSession(userId: number)
	return sessions[userId]
end

-- Record an edit into the owner's star (persisted by ProfileStore autosave).
function M.record(userId: number, cellKey: string, block: number)
	local p = sessions[userId]
	if p then
		p.Data.edits[cellKey] = block
	end
end

-- Set the permanent plot when a star is planted (doc 13). Caller validates the
-- spot first (constellation.canPlantAt + no overlap).
function M.setPlot(userId: number, x: number, y: number, z: number)
	local p = sessions[userId]
	if p then
		p.Data.plot = { x, y, z }
	end
end

-- Has this player already planted their star? (plot ~= {0,0,0})
function M.isPlanted(userId: number): boolean
	local p = sessions[userId]
	if not p then
		return false
	end
	local plot = p.Data.plot
	return plot[1] ~= 0 or plot[2] ~= 0 or plot[3] ~= 0
end

-- Commit a plant: set the permanent plot + biome + name in one shot. Returns false
-- if the session isn't loaded or the star is already planted (one star per player).
-- The CALLER (PlantService) owns validation + name/cell reservation (doc 18).
function M.plant(userId: number, x: number, y: number, z: number, biome: string, name: string): boolean
	local p = sessions[userId]
	if not p then
		return false
	end
	local plot = p.Data.plot
	if plot[1] ~= 0 or plot[2] ~= 0 or plot[3] ~= 0 then
		return false
	end
	p.Data.plot = { x, y, z }
	p.Data.biome = biome
	p.Data.name = name
	return true
end

-- ---- read-only preview of ANY star (for rendering neighbours) ---------------
-- Uses the live session if we own it, else a read-only GetAsync (no lock).
function M.previewData(userId: number): StarData?
	local live = sessions[userId]
	if live then
		return live.Data
	end
	local ok, p = pcall(function()
		return store:GetAsync(keyFor(userId))
	end)
	if ok and p then
		return p.Data
	end
	return nil
end

return M
