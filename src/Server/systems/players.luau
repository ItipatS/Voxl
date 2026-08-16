local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std = ReplicatedStorage.std
local ref = require(std.ref)

local cts = require(std.components)
local world = require(std.world)
local Player = cts.Player
local Character = cts.Character

local placemode = require(std.placemode)

-- Movement is tuned PER PLACE, because the two places move completely differently.
-- In the LOBBY FlightController takes the character over and zeroes WalkSpeed, so
-- whatever is set here never shows. In the STAR you actually walk — and the shared
-- value used to be 200 studs/s, which at BLOCK_SIZE 3.5 is 57 blocks a second.
--
-- 16 studs/s ≈ 4.6 blocks/s, near Minecraft's 4.3. JumpHeight clears one block and
-- not two, which is a gameplay rule as much as a feel one: you step up a ledge, you
-- don't hop a wall. [TUNE]
local IS_STAR = placemode.Mode == "ResourceStar"
local WALK_SPEED = if IS_STAR then 16 else 200
local JUMP_HEIGHT = if IS_STAR then 5.2 else 100

local conn = {}

local function playersAdded(player: Player)
	local e = ref(player.UserId)
	world:set(e, Player, player)
	local characterAdd = player.CharacterAdded
	conn[e] = characterAdd:Connect(function(rig)
		while rig.Parent ~= workspace do
			task.wait()
		end
		-- WaitForChild, not a direct index: a rig is parented before it is fully
		-- assembled, so `rig.Humanoid` is intermittently nil here and the whole
		-- handler throws — taking the Character component with it.
		local humanoid = rig:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			humanoid.WalkSpeed = WALK_SPEED
			humanoid.JumpHeight = JUMP_HEIGHT
		else
			warn(`[players] {player.Name} spawned a rig with no Humanoid after 10s`)
		end
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