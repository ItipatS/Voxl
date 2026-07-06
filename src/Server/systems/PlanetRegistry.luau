--!strict
-- Global uniqueness for planted stars. A planet NAME and a grid CELL are each
-- one-per-owner across ALL servers, so two players can never take the same one.
-- Reserved atomically with UpdateAsync: the transform never returns nil (so it
-- never aborts) — it writes our id when the key is free/ours, or writes the
-- existing owner back unchanged; we compare the returned value to know who won.
--
-- In Studio without API access, DataStore calls throw. We FAIL OPEN (allow + warn)
-- so planting is testable offline. [TUNE] to fail-closed if strict dedup is required
-- even during outages. See .claude/18-planting + doc 15.

local DataStoreService = game:GetService("DataStoreService")

local M = {}

local names = DataStoreService:GetDataStore("PlanetNames_v1") -- lower(name) -> ownerUserId
local cells = DataStoreService:GetDataStore("PlanetCells_v1") -- cellKey    -> ownerUserId

-- Atomic claim. Returns (reservedByUs, hadError).
local function claim(store: DataStore, key: string, userId: number): (boolean, boolean)
	local ok, result = pcall(function()
		return store:UpdateAsync(key, function(cur)
			if cur ~= nil and cur ~= userId then
				return cur -- someone else owns it → leave unchanged
			end
			return userId
		end)
	end)
	if not ok then
		return false, true
	end
	return result == userId, false
end

local function release(store: DataStore, key: string, userId: number)
	pcall(function()
		if store:GetAsync(key) == userId then
			store:RemoveAsync(key)
		end
	end)
end

-- Reserve a name for userId. true = now owned by them; false = taken by someone else.
function M.reserveName(name: string, userId: number): boolean
	local reserved, err = claim(names, string.lower(name), userId)
	if err then
		warn(`[PlanetRegistry] name reserve failed (Studio API off?); allowing '{name}'`)
		return true
	end
	return reserved
end

function M.reserveCell(cellKey: string, userId: number): boolean
	local reserved, err = claim(cells, cellKey, userId)
	if err then
		warn(`[PlanetRegistry] cell reserve failed (Studio API off?); allowing '{cellKey}'`)
		return true
	end
	return reserved
end

-- Roll back a reservation (used if the second claim fails after the first succeeded).
function M.releaseName(name: string, userId: number)
	release(names, string.lower(name), userId)
end

function M.releaseCell(cellKey: string, userId: number)
	release(cells, cellKey, userId)
end

return M
