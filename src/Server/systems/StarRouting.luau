-- ServerScriptService/systems/StarRouting.luau
--!strict

-- SINGLE-LIVE ROUTING: every visitor of one star lands on the SAME server.
--
-- Without this, `TeleportAsync` to a public place gives each entry a fresh server,
-- so two people who walked into Aldermoor together arrive in two different copies
-- of it — and worse, `starworld` configures from the FIRST joiner only, so a server
-- that happened to collect two players entering different stars would silently give
-- the second player the first one's world.
--
-- The fix is a reserved server per star, remembered in MemoryStore:
--
--   starId  ->  reserved server access code
--
-- A reserved access code names a PRIVATE SERVER, not a running process. Joining one
-- whose instance has since shut down simply starts a fresh instance with the same
-- code — so a stale entry costs a world reload (seed + WorldStore edits, both
-- durable), never a wrong world. That property is what makes the whole thing safe
-- to leave lying in a key-value store with a TTL.
--
-- Required directly by `starentry`, not listed as a boot system — same as WorldStore
-- and LockService under BlockEditServer.

local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")

local M = {}

local MAP = MemoryStoreService:GetHashMap("StarServers_v1")

-- How long a star's server mapping survives without being touched.
--
-- Long, because the failure mode of EXPIRING while people are still inside is the
-- bad one: the next arrival reserves a second server and the star splits in two.
-- The failure mode of an entry OUTLIVING its server is harmless (see above). The
-- star place refreshes this while anyone is home, so in practice it only expires on
-- a star nobody has visited for a day.
local TTL = 86400 -- 1 day

-- ---- star ids ---------------------------------------------------------------
-- The routing key. It must name the WORLD, not the trip, and two players who walk
-- into the same place must produce the same string character-for-character.

-- Hubs are permanent geography: index is enough, and it must NOT include the week,
-- or every hub would move to a new server each Monday.
function M.hubId(index: number): string
	return `hub:{index}`
end

-- Frontier stars are rerolled weekly (universe.starAt takes a week), so a slot names
-- a DIFFERENT star each week and the week belongs in the key. Without it, week 2's
-- star would inherit week 1's server and generate the wrong world from a config that
-- no longer matches.
function M.starId(cx: number, cy: number, cz: number, week: number): string
	return `slot:{cx}:{cy}:{cz}:{week}`
end

-- ---- the mapping ------------------------------------------------------------

-- The access code for a star, reserving one if this is the first visitor.
-- Returns nil if MemoryStore or ReserveServer is unavailable (Studio), so the
-- caller can fall back to an ordinary public teleport rather than refusing entry.
local function accessCodeFor(starId: string, placeId: number): string?
	local ok, existing = pcall(function()
		return MAP:GetAsync(starId)
	end)
	if ok and type(existing) == "string" and existing ~= "" then
		return existing
	end

	local reserved: string? = nil
	local rok, err = pcall(function()
		reserved = (TeleportService:ReserveServer(placeId))
	end)
	if not rok or not reserved then
		warn(`[StarRouting] could not reserve a server for {starId}: {err}`)
		return nil
	end

	-- Two players entering an empty star in the same second both reach here, and
	-- both have reserved. UpdateAsync is atomic and its transform keeps whichever
	-- code got there first, so both end up returning the SAME one — the loser's
	-- reservation is simply never joined, and a reserved server nobody joins never
	-- starts. That is a wasted API call, not a wasted server.
	local uok, winner = pcall(function()
		return MAP:UpdateAsync(starId, function(old)
			return if type(old) == "string" and old ~= "" then old else reserved
		end, TTL)
	end)
	if uok and type(winner) == "string" and winner ~= "" then
		return winner
	end
	warn(`[StarRouting] could not record the server for {starId}: {winner}`)
	return reserved -- we have one; use it even though it is not shared
end

-- Send a player to `starId`'s server, creating it if nobody is there yet.
-- `data` is the TeleportData table; the access code is added to it so the star
-- server can keep the mapping alive (see M.keepAlive).
-- Returns ok, err.
function M.send(plr: Player, placeId: number, starId: string, data: { [string]: any }): (boolean, string?)
	local code = accessCodeFor(starId, placeId)

	local opts = Instance.new("TeleportOptions")
	data.starId = starId
	if code then
		opts.ReservedServerAccessCode = code
		data.starAccess = code
	end
	opts:SetTeleportData(data)

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placeId, { plr }, opts)
	end)
	return ok, if ok then nil else tostring(err)
end

-- Called by the STAR place, which knows its own starId and access code because both
-- rode in on the teleport. Without this a star that stays busy for longer than the
-- TTL would quietly lose its mapping and the next arrival would open a second copy
-- of a world that already has people standing in it.
function M.keepAlive(starId: string, accessCode: string)
	task.spawn(function()
		while true do
			task.wait(TTL / 4) -- refresh well inside the window, not at the edge
			local ok, err = pcall(function()
				MAP:SetAsync(starId, accessCode, TTL)
			end)
			if not ok then
				warn(`[StarRouting] keepAlive failed for {starId}: {err}`)
			end
		end
	end)
end

return M
