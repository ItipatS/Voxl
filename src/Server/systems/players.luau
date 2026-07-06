local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std = ReplicatedStorage.std
local ref = require(std.ref)

local cts = require(std.components)
local world = require(std.world)
local Player = cts.Player
local Character = cts.Character

local conn = {}

local function playersAdded(player: Player)
	local e = ref(player.UserId)
	world:set(e, Player, player)
	local characterAdd = player.CharacterAdded
	conn[e] = characterAdd:Connect(function(rig)
		while rig.Parent ~= workspace do
			task.wait()
		end
		rig.Humanoid.WalkSpeed = 200
		rig.Humanoid.JumpHeight = 100
		world:set(e, Character, rig)
	end)
end

local function playersRemoved(player: Player)
	local e = ref(player.UserId)
	-- Delete the whole entity (full cleanup), guarded — the entity may already be
	-- gone, and world:clear/delete on a missing entity throws in jecs (was spamming
	-- an error + a stack trace on every leave, and leaking the connection below).
	pcall(world.delete, world, e)
	local connection = conn[e]
	if connection then
		connection:Disconnect()
		conn[e] = nil
	end
end

local scheduler = require(std.scheduler)
local phases = require(std.phases)
scheduler.SYSTEM(playersAdded, phases.PlayerAdded)
scheduler.SYSTEM(playersRemoved, phases.PlayerRemoved)

return 0