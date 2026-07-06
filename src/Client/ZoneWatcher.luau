-- StarterPlayerScripts/ZoneWatcher.luau  (Lobby)
-- Announces the zone you're in (all zones declared in std/zones — THE framework) via
-- Notifier.zone whenever it changes. Fires on JOIN and on RESPAWN too — a "where am I"
-- gimmick (current resets on CharacterAdded). Poll-based + debounced by change-detection.
-- Add/define zones in std/zones, not here. See .claude/19-ui-conventions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local zones = require(ReplicatedStorage.std.zones)
local Notifier = require(script.Parent.UI).Notify

local player = Players.LocalPlayer
local POLL = 0.4

local current: string? = nil
player.CharacterAdded:Connect(function()
	current = nil -- re-announce the zone after (re)spawn
end)

task.spawn(function()
	while true do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local z = zones.at(root.Position)
			if z.id ~= current then
				current = z.id
				Notifier.zone(z.title, z.subtitle)
			end
		end
		task.wait(POLL)
	end
end)

return {}
