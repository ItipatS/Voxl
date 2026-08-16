--!strict
-- Custom place-load / arrival screen (runs before anything renders). Replaces Roblox's default
-- loading screen with our black cover + a PLANET CARD (name · resources · explorers here), then
-- irises OPEN once the world is ready — the other half of the Lobby's iris-close, so a teleport
-- reads as one continuous cartoon wipe. Also handles direct joins (no teleport data).
--
-- On the Star place we wait for the server-published world config + the character to spawn onto
-- terrain before revealing, so you never see the world pop in behind the card.

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

-- Kill the default loading screen ASAP (before we yield on anything replicated).
pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local std = ReplicatedStorage:WaitForChild("std")
local transition = require(std:WaitForChild("transition")) :: any
local placemode = require(std:WaitForChild("placemode")) :: any

local player = Players.LocalPlayer

-- Build the card info from the teleport data if we arrived via a star Enter; else a generic
-- title (direct join / first Lobby load).
local function gatherInfo(): any
	local data: any = TeleportService:GetLocalPlayerTeleportData()
	if placemode.Mode == "ResourceStar" then
		local name = (data and data.starName) or "Uncharted Star"
		local types = data and data.starTypes
		return { name = name, types = types, subtitle = "Arriving…", primary = types and types[1] }
	end
	-- Lobby (or unknown): just a clean intro wipe, no planet card clutter.
	return { name = "The Cluster", subtitle = "Entering…" }
end

transition.cover(gatherInfo())

-- ---- wait until the world is actually ready, then reveal ---------------------
while not game:IsLoaded() do
	task.wait()
end

if placemode.Mode == "ResourceStar" then
	-- The server publishes the star's config (starworld) before it loads characters; wait for
	-- it + the character on terrain so the reveal lands on a built world, not empty void.
	local t0 = os.clock()
	while ReplicatedStorage:GetAttribute("StarSeed") == nil and os.clock() - t0 < 8 do
		task.wait(0.05)
	end
	local char = player.Character or player.CharacterAdded:Wait()
	char:WaitForChild("HumanoidRootPart", 8)

	-- Hold until ChunkClient says the ground under the character actually exists.
	-- This used to be a flat 0.4s, which is a guess: on a baked star the terrain has
	-- to stream over the wire first, so the reveal landed on empty void and the
	-- player fell through it. ChunkClient keeps the character anchored for exactly
	-- this window, so the screen and the freeze lift together.
	local t0 = os.clock()
	while not player:GetAttribute("WorldReady") and os.clock() - t0 < 45 do
		task.wait(0.1)
	end
	if not player:GetAttribute("WorldReady") then
		warn("[LoadingScreen] revealing without a ready world after 45s — terrain never arrived")
	end
end

-- Refresh the "explorers here" count now that players have replicated, then iris open.
transition.setLive({ players = #Players:GetPlayers() })
task.wait(0.05)
transition.open()
