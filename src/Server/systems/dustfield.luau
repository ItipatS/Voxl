-- ServerScriptService/systems/dustfield.luau
-- Server-authoritative star-dust COLLECTION. The dust itself is never stored or
-- simulated here — positions are seed-derived (std/dust), identical for everyone. The
-- ONLY state is a cooldown ledger of collected motes (bucketed by cell). We never loop
-- the field: the client tells us WHICH mote it flew through (MoteRef), we hash that one
-- mote to validate proximity, mark it cooling, grant star fuel, and broadcast the dim to
-- nearby players. Enter-sync: when a player crosses into a new cell we resend the cooling
-- motes around them so late arrivals see the same dimmed dust.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local dust = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("dust"))

local SYNC_RADIUS = 1400 -- broadcast/enter-sync range (≈ client render range)
local COLLECT_SLACK = 12 -- proximity tolerance over COLLECT_RADIUS (client moves between ticks)
local PRUNE_EVERY = 5 -- seconds between expired-entry sweeps

-- cooling[cellKey][idx] = expiry (os.clock seconds). Bucketed by cell so enter-sync is
-- O(cells near a player), never O(all cooling).
local cooling: { [string]: { [number]: number } } = {}

local function cellKey(cx: number, cy: number, cz: number): string
	return `{cx},{cy},{cz}`
end

local function rootPos(plr: Player): Vector3?
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- ---- collect (client requests, server validates the single mote) ------------
blink.DustCollect.On(function(plr: Player, ref)
	local mote = dust.moteAt(ref.cx, ref.cy, ref.cz, ref.idx)
	if not mote then
		return -- that index doesn't exist (culled / bad ref)
	end
	local pp = rootPos(plr)
	if not pp or (mote.pos - pp).Magnitude > dust.COLLECT_RADIUS + COLLECT_SLACK then
		return -- not actually near it → ignore (anti-cheat)
	end

	local key = cellKey(ref.cx, ref.cy, ref.cz)
	local bucket = cooling[key]
	local now = os.clock()
	if bucket and bucket[ref.idx] and bucket[ref.idx] > now then
		return -- already cooling → someone beat them to it
	end
	if not bucket then
		bucket = {}
		cooling[key] = bucket
	end
	bucket[ref.idx] = now + dust.COOLDOWN

	-- Confirm to the collector (grant fuel + burst + dim) and dim it for onlookers.
	blink.DustCollected.Fire(plr, ref)
	local cool = { { ref = ref, remaining = math.floor(dust.COOLDOWN * 10) } }
	for _, other in Players:GetPlayers() do
		if other ~= plr then
			local op = rootPos(other)
			if op and (mote.pos - op).Magnitude < SYNC_RADIUS then
				blink.DustCooldown.Fire(other, cool)
			end
		end
	end
end)

-- ---- enter-sync: on crossing into a new cell, resend nearby cooling motes ----
local lastCell: { [Player]: string } = {}
Players.PlayerRemoving:Connect(function(plr)
	lastCell[plr] = nil
end)

local CELL_SPAN = math.ceil(SYNC_RADIUS / dust.CELL_SIZE) -- cells each way to cover the sync range

local function syncPlayer(plr: Player, pp: Vector3)
	local cx, cy, cz = dust.cellOf(pp)
	local now = os.clock()
	local batch: { { ref: any, remaining: number } } = {}
	for dx = -CELL_SPAN, CELL_SPAN do
		for dy = -CELL_SPAN, CELL_SPAN do
			for dz = -CELL_SPAN, CELL_SPAN do
				local bucket = cooling[cellKey(cx + dx, cy + dy, cz + dz)]
				if bucket then
					local kx, ky, kz = cx + dx, cy + dy, cz + dz
					for idx, expiry in bucket do
						local rem = expiry - now
						if rem > 0 then
							batch[#batch + 1] = {
								ref = { cx = kx, cy = ky, cz = kz, idx = idx },
								remaining = math.floor(math.min(rem, 6553) * 10),
							}
						end
					end
				end
			end
		end
	end
	if #batch > 0 then
		blink.DustCooldown.Fire(plr, batch)
	end
end

RunService.Heartbeat:Connect(function()
	for _, plr in Players:GetPlayers() do
		local pp = rootPos(plr)
		if pp then
			local cx, cy, cz = dust.cellOf(pp)
			local ck = cellKey(cx, cy, cz)
			if lastCell[plr] ~= ck then
				lastCell[plr] = ck
				syncPlayer(plr, pp)
			end
		end
	end
end)

-- ---- prune expired entries (keep the ledger bounded) ------------------------
task.spawn(function()
	while true do
		task.wait(PRUNE_EVERY)
		local now = os.clock()
		for key, bucket in cooling do
			local any = false
			for idx, expiry in bucket do
				if expiry <= now then
					bucket[idx] = nil
				else
					any = true
				end
			end
			if not any then
				cooling[key] = nil
			end
		end
	end
end)

return {}
