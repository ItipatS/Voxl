-- ServerScriptService/systems/RegionSeed.luau
--!strict
-- The resource stars' regional seed lives in MemoryStore and rotates DAILY: every
-- server of a biome that day shares one seed (world consistent within the day),
-- and it changes at midnight (fresh terrain + nodes each day). Random per day (not
-- date-derived) so tomorrow's world can't be datamined. Server-only.
--
-- Note (doc 12 L2): a daily *shared* seed gives renewal but does NOT stop
-- server-hopping for fresh nodes within a day — pair it with a per-account daily
-- depletion record so "gathered today" follows the account, not the server.

local MemoryStoreService = game:GetService("MemoryStoreService")

local M = {}

local map = MemoryStoreService:GetSortedMap("RegionSeeds")
local TTL = 90000 -- ~25h: the day's seed outlives the day, then expires

local function dayNumber(): number
	return math.floor(os.time() / 86400)
end

-- Deterministic fallback (MemoryStore unavailable — e.g. Studio without API
-- access) so the world is still consistent across servers within the day.
local function derived(biome: string, day: number): number
	local h = 0
	for i = 1, #biome do
		h = (h * 31 + string.byte(biome, i)) % 2147483647
	end
	return (day * 1000003 + h) % 2147483646 + 1
end

-- The regional seed for `biome` today. First server to ask sets a random one
-- (atomically via UpdateAsync); everyone else that day reads the same value.
function M.get(biome: string): number
	local day = dayNumber()
	local key = biome .. ":" .. day
	local ok, seed = pcall(function()
		return map:UpdateAsync(key, function(existing: number?)
			if existing ~= nil then
				return existing
			end
			return Random.new():NextInteger(1, 2147483647)
		end, TTL)
	end)
	if ok and type(seed) == "number" then
		return seed
	end
	warn("[RegionSeed] MemoryStore unavailable; using a derived daily seed")
	return derived(biome, day)
end

return M
