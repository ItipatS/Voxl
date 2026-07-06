-- Client/UI/Effect.luau
-- Applies a GRADE LOOK to a text label. A look (from UIData:GetGradeLook) is either a
-- static Color3, or an animated effect table (any table with a `colorSequence`). No
-- named-effect registry anymore — the animation is generic and driven by the table's
-- colorSequence/direction/duration. See .claude/20 (grade vs tier reframe).

local TweenManager = require(script.Parent.TextFX)

local Effect = {}

-- Animated text effect — applies ONLY the sub-effects the grade opted into
-- (look.colorLoop / .gradient / .glow, cumulative up the ladder). Returns stop-functions.
local function runAnimated(nameLabel, look)
	local options = {
		colorSequence = look.colorSequence,
		direction = look.direction,
		duration = look.duration or 2,
	}
	local stops = {}
	if look.colorLoop then
		stops.colorLoop = TweenManager.StartColorSequenceLoop(nameLabel, options)
	end
	if look.gradient then
		stops.gradient = TweenManager.StartTextGradientEffect(nameLabel, options)
	end
	if look.glow then
		stops.glow = TweenManager.StartGlow(nameLabel)
	end
	return stops
end

-- Stop any running effect (call the stop-functions) and optionally reset the colour.
local function clearEffects(stopFunctions, nameLabel, newColor)
	if stopFunctions then
		for _, stopFunc in pairs(stopFunctions) do
			stopFunc()
		end
	end
	if nameLabel and newColor and typeof(newColor) == "Color3" then
		nameLabel.TextColor3 = newColor
	end
end

-- Apply a grade look. Returns stop-functions (nil for a static colour).
function Effect.ApplyEffects(nameLabel, look)
	if typeof(look) == "Color3" then
		nameLabel.TextColor3 = look
		return nil
	elseif type(look) == "table" and look.colorSequence then
		return runAnimated(nameLabel, look)
	else
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		return nil
	end
end

Effect.ClearEffects = clearEffects

return Effect
