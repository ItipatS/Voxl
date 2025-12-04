local ReplicatedStorage = game:GetService("ReplicatedStorage")
local start = require(ReplicatedStorage.std.start)

--start(script.Parent:WaitForChild("systems"):GetChildren())

-- ServerScriptService/TestWorldGen.server.lua


local Workspace = game:GetService("Workspace")
local WorldGen = require(script.WorldGen)

local rootFolder = Instance.new("Folder")
rootFolder.Name = "GeneratedWorld"
rootFolder.Parent = Workspace

-- generate a small area: from -2..2 chunks in X and Z
for cz = -2, 2 do
	for cx = -2, 2 do
		WorldGen.spawnChunkColumn(cx, cz, rootFolder)
		task.wait(0.05) -- tiny delay to avoid frame spike
	end
end
