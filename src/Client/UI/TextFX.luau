-- TweenManager.lua
local TweenManager = {}
local TweenService = game:GetService("TweenService")

local activeTweens = {}

-- Add a tween with a unique key. Cancels any previous tween with the same key.
function TweenManager.AddTweenFor(instance, tweenType, tween)
	activeTweens[instance] = activeTweens[instance] or {}
	if activeTweens[instance][tweenType] then
		activeTweens[instance][tweenType]:Cancel()
	end
	activeTweens[instance][tweenType] = tween
	tween:Play()
end

function TweenManager.CancelTweenFor(instance, tweenType)
	if activeTweens[instance] and activeTweens[instance][tweenType] then
		activeTweens[instance][tweenType]:Cancel()
		activeTweens[instance][tweenType] = nil
		-- Remove subtable if empty:
		if next(activeTweens[instance]) == nil then
			activeTweens[instance] = nil
		end
	end
end

function TweenManager.StartColorSequenceLoop(textLabel, options)
	options = options or {}
	-- Use the provided ColorSequence or fallback to a default rainbow sequence.
	local colorSequence = options.colorSequence or ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255,0,0)),
		ColorSequenceKeypoint.new(0.166, Color3.fromRGB(255,165,0)),
		ColorSequenceKeypoint.new(0.333, Color3.fromRGB(255,255,0)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0,128,0)),
		ColorSequenceKeypoint.new(0.666, Color3.fromRGB(0,0,255)),
		ColorSequenceKeypoint.new(0.833, Color3.fromRGB(75,0,130)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(148,0,211))
	})
	local duration = 0.5

	-- Extract keypoints (they are already sorted by Time).
	local keypoints = colorSequence.Keypoints
	local numKeypoints = #keypoints

	local tweenLoopActive = true
	local currentIndex = 1

	coroutine.wrap(function()
		while tweenLoopActive and textLabel and textLabel.Parent do
			-- Get the target color from the current keypoint.
			local targetColor = keypoints[currentIndex].Value
			TweenManager.CancelTweenFor(textLabel, "color")
			local tween = TweenService:Create(textLabel, TweenInfo.new(duration, Enum.EasingStyle.Linear), {TextColor3 = targetColor})
			TweenManager.AddTweenFor(textLabel, "color", tween)
			tween.Completed:Wait()
			currentIndex = currentIndex + 1
			if currentIndex > numKeypoints then
				currentIndex = 1
			end
		end
	end)()

	-- Return a function to stop this loop.
	return function()
		tweenLoopActive = false 
		TweenManager.CancelTweenFor(textLabel, "color")
	end
end


-- Glow Effect: Applies a looping glow tween to a UI element.
function TweenManager.StartGlow(textLabel)
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Parent = textLabel
	uiStroke.Color = Color3.new(1, 1, 1)
	uiStroke.Thickness = 2
	uiStroke.Transparency = 0.5
	uiStroke.LineJoinMode = "Miter"

	local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
	local tween = TweenService:Create(uiStroke, tweenInfo, {Thickness = 3, Transparency = 0})
	TweenManager.AddTweenFor(textLabel, "glow", tween)
	-- Return a stop function for the glow effect.
	return function()
		TweenManager.CancelTweenFor(textLabel, "glow")
		if uiStroke then
			uiStroke:Destroy()
		end
	end
end

-- Rainbow Text Gradient Runner: Runs a gradient across a TextLabel.
-- Options:
--   colorSequence: a ColorSequence (default: rainbow colors)
--   direction: "forward" (resets after reaching right) or "bounce" (runs back and forth)
--   duration: tween duration in seconds (default is 2 seconds)
function TweenManager.StartTextGradientEffect(textLabel, options)
	options = options or {}
	local colorSequence = options.colorSequence or ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0))
	})
	local direction = options.direction or "forward"  -- "forward" or "bounce"
	local duration = options.duration or 2

	-- Create a UIGradient on the TextLabel
	local uiGradient = Instance.new("UIGradient")
	uiGradient.Parent = textLabel
	uiGradient.Color = colorSequence
	uiGradient.Rotation = 0

	local running = true
	coroutine.wrap(function()
		while running and textLabel and textLabel.Parent do
			if direction == "bounce" then
				-- Animate from left-to-right then back to left.
				local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
				local tween = TweenService:Create(uiGradient, tweenInfo, {Offset = Vector2.new(.1, 0)})
				TweenManager.AddTweenFor(uiGradient, "gradient", tween)
				tween.Completed:Wait()
				if not running then break end
				tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
				tween = TweenService:Create(uiGradient, tweenInfo, {Offset = Vector2.new(0, 0)})
				TweenManager.AddTweenFor(uiGradient, "gradient", tween)
				tween.Completed:Wait()
			else
				-- Forward loop: animate from left-to-right then instantly reset.
				local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
				local tween = TweenService:Create(uiGradient, tweenInfo, {Offset = Vector2.new(.1, 0)})
				TweenManager.AddTweenFor(uiGradient, "gradient", tween)
				tween.Completed:Wait()
				if not running then break end
				uiGradient.Offset = Vector2.new(0, 0)
			end 	
		end
	end)()

	-- Return a function to stop this gradient effect.
	return function()
		running = false
		TweenManager.CancelTweenFor(uiGradient, "gradient")
		if uiGradient then uiGradient:Destroy() end
	end
end


return TweenManager
