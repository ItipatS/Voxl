--!strict
--==================================================================================--
--  DevCommands  ·  in-chat test console for the weather/event director (FTC-209)
--==================================================================================--
--  Registers TextChatService.TextChatCommands so you can drive the director from the
--  chat bar while playtesting. Gated to Studio by default (+ an optional live allowlist).
--
--  Commands:
--    /storm [intensity=1] [seconds=60]   force a timed storm, then auto-release
--    /rain  [value=0.5]                  hold a fixed rain level (no auto-release)
--    /clear                              release weather → natural deterministic noise
--    /day                               jump to Day phase
--    /night                             jump to Night phase (advances the moon)
--    /event <Name> [seconds]            fire a discrete event (BloodMoon/LunarEclipse/SolarEclipse)
--
--  REQUIRES the modern TextChatService (not LegacyChatService). If the chat is legacy,
--  these commands won't appear — flip TextChatService.ChatVersion to TextChatService.
--==================================================================================--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local DevCommands = {}

-- add live-game tester UserIds here; Studio is always allowed
local ALLOWED_USERIDS: { [number]: boolean } = {}

local function isAllowed(userId: number): boolean
	if RunService:IsStudio() then
		return true
	end
	return ALLOWED_USERIDS[userId] == true
end

export type Director = {
	SetStorm: (intensity: number?, duration: number?) -> (),
	SetRain: (value: number?) -> (),
	ClearWeather: () -> (),
	SetPhase: (phase: string) -> (),
	ForceEvent: (name: string, duration: number?) -> any,
}

-- "/storm 1 60" → { "1", "60" }  (the leading alias token is dropped)
local function parseArgs(text: string): { string }
	local args = {}
	for token in string.gmatch(text, "%S+") do
		table.insert(args, token)
	end
	table.remove(args, 1)
	return args
end

local function makeCommand(alias: string, handler: (Player, { string }) -> ())
	local cmd = Instance.new("TextChatCommand")
	cmd.Name = "Dev_" .. (alias:gsub("/", ""))
	cmd.PrimaryAlias = alias
	cmd.AutocompleteVisible = RunService:IsStudio()
	cmd.Triggered:Connect(function(source: TextSource, unfilteredText: string)
		local player = source and Players:GetPlayerByUserId(source.UserId)
		if not player or not isAllowed(player.UserId) then
			return
		end
		local ok, err = pcall(handler, player, parseArgs(unfilteredText))
		if not ok then
			warn("[EventManager DevCommands] '" .. alias .. "' failed: " .. tostring(err))
		end
	end)
	cmd.Parent = TextChatService
end

function DevCommands.Install(director: Director)
	makeCommand("/storm", function(_, args)
		director.SetStorm(tonumber(args[1]), tonumber(args[2]))
	end)

	makeCommand("/rain", function(_, args)
		director.SetRain(tonumber(args[1]))
	end)

	makeCommand("/clear", function()
		director.ClearWeather()
	end)

	makeCommand("/day", function()
		director.SetPhase("Day")
	end)

	makeCommand("/night", function()
		director.SetPhase("Night")
	end)

	makeCommand("/event", function(_, args)
		local name = args[1]
		if name then
			director.ForceEvent(name, tonumber(args[2]))
		end
	end)
end

return DevCommands
