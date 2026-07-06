-- StarterPlayerScripts/Prompts.luau
-- Styled ProximityPrompt UI via expressive-prompts (Packages/expressive-prompts).
-- Init ONCE; after this, any ProximityPrompt with Style = Custom renders with the
-- animated billboard. Used for world interactions (resource-star entry, future
-- planet-visit, node-gather, …) — just create a ProximityPrompt and it looks great.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ExpressivePrompts = require(ReplicatedStorage.Packages:WaitForChild("expressive-prompts"))

ExpressivePrompts.Init()

-- House style (Config entries are reactive Values → set .Value). Note: the library's
-- text uses Enum.Font (not FontFace), so prompts can't use our Silkscreen FontFace.
local C = ExpressivePrompts.Config
C.BackgroundColor.Value = Color3.fromRGB(16, 16, 24)
C.BackgroundTransparency.Value = 0.3
C.TextColor.Value = Color3.fromRGB(235, 240, 255)
C.SubTextColor.Value = Color3.fromRGB(150, 160, 185)
C.ProgressBarColor.Value = Color3.fromRGB(120, 200, 255)
C.ProgressBarTransparency.Value = 0.15
C.CornerRadius.Value = 10

return {}
