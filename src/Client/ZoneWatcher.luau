-- StarterPlayerScripts/ZoneWatcher.luau  (Lobby)
-- Announces the zone you're flying through — a biome resource-star's airspace, the
-- black hole's pull, or open Cluster — via Notifier.zone when it CHANGES. The first
-- zone at spawn is set silently (no title spam on join). Poll-based + debounced.
-- See .claude/19-ui-conventions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local constellation = require(ReplicatedStorage.std.constellation)
local Notifier = require(script.Parent.UI).Notify

local player = Players.LocalPlayer
local BH = constellation.BLACKHOLE
local ZONE_RADIUS = 1600 -- how close to a starter star counts as "in its airspace"

-- Returns (id, title, subtitle). id drives change-detection; title/subtitle display.
local function zoneAt(pos: Vector3): (string, string, string?)
	if (pos - BH.pos).Magnitude < BH.radius then
		return "maw", "The Maw", "Nothing escapes"
	end
	for _, lm in constellation.LANDMARKS do
		if lm.template ~= "BlackHole" and (pos - lm.pos).Magnitude < ZONE_RADIUS then
			local biome = (lm.template :: string):gsub("Star$", "")
			return lm.template, biome, "Starter Star"
		end
	end
	return "cluster", "Cluster", nil
end

local current: string? = nil

task.spawn(function()
	while true do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local id, title, subtitle = zoneAt(root.Position)
			if id ~= current then
				if current ~= nil then -- silent on the very first detection (spawn)
					Notifier.zone(title, subtitle)
				end
				current = id
			end
		end
		task.wait(0.4)
	end
end)

return {}
