--!strict
-- Integrates the server's replicated clock into Lighting.ClockTime, every frame.
--
-- The server (systems/daynight) publishes a LINE — the hour a phase started, the
-- server time it started, and how many in-game hours pass per real second — and
-- every client evaluates it independently. So the clock is smooth, costs no
-- network traffic while it runs, and a player joining mid-night computes the same
-- time as everyone already there.

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The lobby is deep space and runs no cycle, and a server build without the
-- daynight system would leave this waiting forever. An infinite yield here is
-- invisible — no error, no log, the sky simply never moves — so it gets a timeout
-- and says what happened.
local folder = ReplicatedStorage:WaitForChild("TimeSync", 10) :: Folder?
if not folder then
	warn("[DayNightRenderer] no ReplicatedStorage.TimeSync after 10s — "
		.. "the server's daynight system is not running; leaving Lighting alone")
	return 0
end

local Clock0 = folder:WaitForChild("Clock0") :: NumberValue
local T0 = folder:WaitForChild("T0") :: NumberValue
local Speed = folder:WaitForChild("Speed") :: NumberValue

RunService.RenderStepped:Connect(function()
	local now = workspace:GetServerTimeNow()
	Lighting.ClockTime = (Clock0.Value + (now - T0.Value) * Speed.Value) % 24
end)

return 0
