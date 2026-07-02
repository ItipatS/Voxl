-- Client bootstrap. WaitForChild dependencies explicitly (Rojo live-sync can run
-- this before the tree is replicated).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Packages")
ReplicatedStorage:WaitForChild("std")
ReplicatedStorage:WaitForChild("Misc")

-- ChunkClient wires the terrain networking (blink.LoadChunks) + meshing loop.
require(script.Parent:WaitForChild("ChunkClient"))
