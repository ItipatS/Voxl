local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.net)

local DayNightRenderer = require(script.DayNightRenderer)
local EventRenderer = require(script.EventRenderer)
local BGMService = require(script.Parent.SoundHandler.BGMService)
local AmbientService = require(script.Parent.SoundHandler.AmbientService)


Net.DayNight.On(function(Data)
     print("DayNight Data", Data)
    BGMService.updateBGM(Data)
    AmbientService.updateAmbient(Data)
end)

Net.Event.On(function(Data)
    print("Events Data", Data)
    BGMService.updateBGM(Data)
    AmbientService.updateAmbient(Data)
    EventRenderer.applyEvents(Data)
end)

return {}