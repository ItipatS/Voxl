-- ModuleScript: MoonPhase
local MoonPhase = {}
local current = 1

local Phases = {
	[1] = "FullMoon",
	[2] = "WaningGibbous",
	[3] = "ThirdQuarter",
	[4] = "WaningCrescent",
	[5] = "NewMoon",
	[6] = "WaxingCrescent",
	[7] = "FirstQuarter",
	[8] = "WaxingGibbous",
}

local TextureId = {
	FullMoon = "rbxassetid://74638689287771",
	WaningGibbous = "rbxassetid://128530517436854",
	ThirdQuarter = "rbxassetid://100991411069643",
	WaningCrescent = "rbxassetid://78485789235703",
	NewMoon = "rbxassetid://120843472879803",
	WaxingCrescent = "rbxassetid://130392763537586",
	FirstQuarter = "rbxassetid://124877668033819",
	WaxingGibbous = "rbxassetid://92714015949622",
}

function MoonPhase.Next()
	current += 1
	if current > 8 then
		current = 1
	end
	return Phases[current]
end

function MoonPhase.GetPhaseName()
	return Phases[current]
end

function MoonPhase.GetTextureId()
	return TextureId[Phases[current]]
end
return MoonPhase
