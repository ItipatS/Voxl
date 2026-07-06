--!strict
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("TimeSync")
local Clock0 = folder:WaitForChild("Clock0") :: NumberValue
local T0 = folder:WaitForChild("T0") :: NumberValue
local Speed = folder:WaitForChild("Speed") :: NumberValue

RunService.RenderStepped:Connect(function()
	local now = workspace:GetServerTimeNow()
	local ct = (Clock0.Value + (now - T0.Value) * Speed.Value) % 24
	Lighting.ClockTime = ct
end)

return 0