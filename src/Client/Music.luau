--!strict
-- BGM for BOTH places: shuffle-cycle the SoundService.Musics playlist (cozy
-- ambient/piano). Nothing here is lobby-specific — it reads one authored playlist
-- and has no idea where it is — so the star place runs the same module rather than
-- a second copy of it.
-- Client-side so each player gets their own shuffle. Each track FADES in, FADES out near
-- its end, then there's a random SILENCE before the next — so it breathes instead of
-- looping wall-to-wall. Respects each track's authored Volume as the fade-in target.

local SoundService = game:GetService("SoundService")

local musicsFolder = SoundService:WaitForChild("Musics")
local rng = Random.new()

local FADE = 2.5 -- fade in / out seconds
local PAUSE_MIN, PAUSE_MAX = 6, 20 -- silence between tracks (seconds) [TUNE]

local tracks: { Sound } = {}
local baseVol: { [Sound]: number } = {}
for _, s in musicsFolder:GetChildren() do
	if s:IsA("Sound") then
		s.Looped = false
		baseVol[s] = s.Volume -- authored volume = fade-in target
		tracks[#tracks + 1] = s
	end
end
if #tracks == 0 then
	warn("[Music] no Sounds under SoundService.Musics; no BGM.")
	return {}
end

-- Fisher–Yates shuffle for a fresh order each session.
for i = #tracks, 2, -1 do
	local j = rng:NextInteger(1, i)
	tracks[i], tracks[j] = tracks[j], tracks[i]
end

local function fade(s: Sound, from: number, to: number, dur: number)
	local t0 = os.clock()
	while true do
		local a = math.min((os.clock() - t0) / dur, 1)
		s.Volume = from + (to - from) * a
		if a >= 1 then
			break
		end
		task.wait(0.03)
	end
end

local idx = 0
task.spawn(function()
	while true do
		idx = idx % #tracks + 1
		local s = tracks[idx]
		local vol = baseVol[s]
		s.TimePosition = 0
		s.Volume = 0
		s:Play()
		fade(s, 0, vol, FADE)

		-- play until it's time to fade out (TimeLength known once loaded) or it ends on its own
		while s.IsPlaying do
			local len = s.TimeLength
			if len > 0 and s.TimePosition >= len - FADE then
				fade(s, s.Volume, 0, FADE)
				break
			end
			task.wait(0.25)
		end
		s:Stop()
		s.Volume = vol -- restore for next time

		task.wait(rng:NextNumber(PAUSE_MIN, PAUSE_MAX)) -- silence between tracks
	end
end)

return {}
