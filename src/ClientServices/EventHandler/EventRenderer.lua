-- ModuleScript: EventRenderer
local Lighting = game:GetService("Lighting")

type EventData = { [number]:{name: string,
    startTime: number,
    endTime: number}
}

local function applyEvents(data:EventData)
    local events = data[1] or {}
    for _, event in ipairs(events) do
        if event.name == "BloodMoon" then
            Lighting.FogColor = Color3.fromRGB(180, 0, 50)
            Lighting.OutdoorAmbient = Color3.fromRGB(80, 0, 0)
        end
        -- Add more event visuals as needed
    end
end

return {
    applyEvents = applyEvents
} 