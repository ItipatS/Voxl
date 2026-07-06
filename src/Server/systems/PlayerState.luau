-- ServerScriptService/systems/PlayerState.luau
-- Authoritative per-player RUNTIME status — star fuel today; extend as more player
-- state moves server-side (the foundation for the explore-and-claim systems). This is
-- IN-MEMORY (resets on join; durable data lives in PlayerStore). The client predicts
-- fuel locally for instant feel (FlightBoost) and RECONCILES toward what we push here.
--
-- Authority split (decided): the client predicts drain/regen/refuel for responsiveness;
-- the SERVER owns the canonical value + validates GAINS (you can't be granted fuel you
-- didn't collect). We track drain/regen from boost START/STOP edges (BoostState) — not a
-- per-frame input stream — and grant fuel on validated dust collects (dustfield calls us).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)

local MAX = 100
local DRAIN = 30 -- per second while boosting  (match FlightBoost)
local REGEN = 16 -- per second while not
local SYNC_HZ = 4 -- replicate the value to the owner this often

local M = {}
type Status = { fuel: number, boosting: boolean }
local state: { [number]: Status } = {}

Players.PlayerAdded:Connect(function(plr)
	state[plr.UserId] = { fuel = MAX, boosting = false }
end)
Players.PlayerRemoving:Connect(function(plr)
	state[plr.UserId] = nil
end)
for _, plr in Players:GetPlayers() do
	if not state[plr.UserId] then
		state[plr.UserId] = { fuel = MAX, boosting = false }
	end
end

-- Client reports boost edges so we can simulate authoritative drain/regen.
blink.BoostState.On(function(plr: Player, on: boolean)
	local s = state[plr.UserId]
	if s then
		s.boosting = on
	end
end)

-- Grant fuel from a validated gain (dust collect). The only sanctioned way fuel rises
-- beyond regen — the anti-cheat seam.
function M.grantFuel(userId: number, n: number)
	local s = state[userId]
	if s then
		s.fuel = math.min(MAX, s.fuel + n)
	end
end

function M.getFuel(userId: number): number
	local s = state[userId]
	return if s then s.fuel else 0
end

-- ---- simulate + replicate ---------------------------------------------------
local acc = 0
local dtStep = 1 / SYNC_HZ

RunService.Heartbeat:Connect(function(dt: number)
	for _, s in state do
		if s.boosting then
			s.fuel = math.max(0, s.fuel - DRAIN * dt)
		else
			s.fuel = math.min(MAX, s.fuel + REGEN * dt)
		end
	end

	acc += dt
	if acc < dtStep then
		return
	end
	acc = 0
	for _, plr in Players:GetPlayers() do
		local s = state[plr.UserId]
		if s then
			blink.PlayerStateSync.Fire(plr, { fuel = s.fuel })
		end
	end
end)

return M
