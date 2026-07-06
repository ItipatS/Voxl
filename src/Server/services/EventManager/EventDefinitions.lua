-- ModuleScript: EventDefinitions

local EventDefinitions = {
    ["LunarEclipse"] = {
        allowedPhases = {"Night"},
        minDuration = 60,
        maxDuration = 120,
        minInterval = 600,
        lastTriggered = 0,
    },
    ["SolarEclipse"] = {
        allowedPhases = {"Day"},
        minDuration = 45,
        maxDuration = 90,
        minInterval = 900,
        lastTriggered = 0,
    },
    -- NOTE: "Rain" is no longer a discrete replicated event. Continuous weather is now
    -- computed deterministically client-side by WeatherSignals; storms are FORCED by the
    -- server via the workspace.RainOverride attribute (see EventManager storm scheduler). FTC-209
    ["BloodMoon"] = {
        allowedPhases = {"Night"},
        minDuration = 60,
        maxDuration = 180,
        minInterval = 1200,
        lastTriggered = 0,
    },
}

return EventDefinitions 