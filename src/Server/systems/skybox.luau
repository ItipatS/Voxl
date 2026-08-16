-- ServerScriptService/systems/skybox.luau  (both places)
-- Pick the Sky for this place out of ReplicatedStorage.Skybox and put it in
-- Lighting. Server-side, because Lighting replicates — one decision, every client.
--
-- The two places are the same build, so without this they share one authored Sky:
-- the lobby is deep space, and the star inherited that starfield-at-midnight, which
-- is why standing on the ground felt like standing in orbit at night.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local placemode = require(ReplicatedStorage.std.placemode)

local WANTED = if placemode.Mode == "ResourceStar" then "Forest" else "Lobby"

local folder = ReplicatedStorage:FindFirstChild("Skybox")
if not folder then
	warn("[skybox] ReplicatedStorage.Skybox is missing — keeping the authored Sky")
	return {}
end

local template = folder:FindFirstChild(WANTED)
if not template or not template:IsA("Sky") then
	local have = {}
	for _, c in folder:GetChildren() do
		table.insert(have, c.Name)
	end
	warn(`[skybox] no Sky named "{WANTED}" in ReplicatedStorage.Skybox (found: {table.concat(have, ", ")})`)
	return {}
end

-- Clear whatever Sky is already there before adding ours, or Lighting ends up with
-- two and picks whichever it likes.
for _, child in Lighting:GetChildren() do
	if child:IsA("Sky") then
		child:Destroy()
	end
end

local sky = template:Clone()
sky.Name = "Sky" -- SunAnim and anything else looking for a Sky expect this name
sky.Parent = Lighting
print(`[skybox] using Skybox.{WANTED}`)

return {}
