--!strict
-- Lobby BGM: shuffle-cycle the SoundService.Musics playlist (cozy ambient/piano).
-- Client-side so each player gets their own shuffle; playing the local replica of
-- a SoundService Sound is independent per client. Respects each track's authored
-- Volume; only forces Looped = false so we can advance on Ended.

local SoundService = game:GetService("SoundService")

local musicsFolder = SoundService:WaitForChild("Musics")
local rng = Random.new()

local tracks: { Sound } = {}
for _, s in musicsFolder:GetChildren() do
	if s:IsA("Sound") then
		s.Looped = false
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

local idx = 0
local function playNext()
	idx = idx % #tracks + 1
	tracks[idx]:Play()
end

-- Advance when the current track finishes (loop the playlist forever).
for _, s in tracks do
	s.Ended:Connect(function()
		if tracks[idx] == s then
			playNext()
		end
	end)
end

playNext()

return {}
