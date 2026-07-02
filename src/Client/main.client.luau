-- Client bootstrap. WaitForChild dependencies explicitly (Rojo live-sync can run
-- this before the tree is replicated).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Packages")
ReplicatedStorage:WaitForChild("std")
ReplicatedStorage:WaitForChild("Misc")

-- ChunkClient wires the terrain networking (blink.LoadChunks) + meshing loop.
require(script.Parent:WaitForChild("ChunkClient"))
-- Hotbar drives block selection; BlockEdit wires dig/place input.
require(script.Parent:WaitForChild("Hotbar"))
require(script.Parent:WaitForChild("BlockEdit"))
-- Inventory window open/close (Bag button / Exit / E key).
require(script.Parent:WaitForChild("InventoryToggle"))
