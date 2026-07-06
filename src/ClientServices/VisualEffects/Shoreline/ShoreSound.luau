--!strict
--==================================================================================--
--  Shoreline · ShoreSound  ·  looped beach ambience, volume fades with distance to shore
--==================================================================================--
--  Clones ReplicatedStorage.Assets.Beach, loops it, and drives its Volume each frame from
--  the listener's distance to the NEAREST shore segment's waterline (full near, silent far) —
--  so it swells as you walk onto any beach and fades as you leave. Lifts a little when the sea
--  is rough (storm). Manual volume (not 3D rolloff) because the shore is a set of long strips.
--==================================================================================--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local ShoreSound = {}

type Line = { ox: number, oz: number, lx: number, lz: number, half: number }

local sound: Sound?
local lines: { Line } = {}
local nearDist, fadeSpan, maxVol, stormBoost = 0, 1, 0, 0

function ShoreSound.init(Config, bake): boolean
	local node: Instance? = ReplicatedStorage
	for _, name in Config.sound.assetPath do
		node = node and node:FindFirstChild(name)
	end
	if not (node and node:IsA("Sound")) then
		warn(`[Shoreline] Beach sound not found at ReplicatedStorage.{table.concat(Config.sound.assetPath, ".")}`)
		return false
	end

	local s = (node :: Sound):Clone()
	s.Looped = true
	s.Volume = 0
	s.Parent = SoundService
	s:Play()
	sound = s

	-- each segment's sand-edge line (centre + along-shore dir + half length)
	table.clear(lines)
	for _, seg in bake.segments do
		lines[#lines + 1] =
			{ ox = seg.origin.X, oz = seg.origin.Y, lx = seg.longDir.X, lz = seg.longDir.Y, half = seg.longHalf }
	end
	nearDist = Config.sound.nearDist
	fadeSpan = math.max(Config.sound.farDist - Config.sound.nearDist, 1)
	maxVol = Config.sound.maxVolume
	stormBoost = Config.sound.stormBoost
	return true
end

-- listenerPos = camera/char world position; storm in 0..1.
function ShoreSound.update(listenerPos: Vector3?, storm: number)
	local s = sound
	if not (s and listenerPos) then
		return
	end
	-- distance to the NEAREST segment's waterline (point-to-segment, clamped to its length)
	local px, pz = listenerPos.X, listenerPos.Z
	local best = math.huge
	for _, ln in lines do
		local proj = math.clamp((px - ln.ox) * ln.lx + (pz - ln.oz) * ln.lz, -ln.half, ln.half)
		local dx = px - (ln.ox + ln.lx * proj)
		local dz = pz - (ln.oz + ln.lz * proj)
		local d = dx * dx + dz * dz
		if d < best then
			best = d
		end
	end
	local near = math.clamp(1 - (math.sqrt(best) - nearDist) / fadeSpan, 0, 1)
	s.Volume = maxVol * near * (1 + storm * stormBoost)
end

return ShoreSound
