local ReplicatedStorage = game:GetService("ReplicatedStorage")
local start = require(ReplicatedStorage.std.start)

local systems = script.Parent:WaitForChild("systems"):GetChildren()
local ok, err = pcall(start, systems)
if not ok then
    warn("[main] start() failed:", err)
end
