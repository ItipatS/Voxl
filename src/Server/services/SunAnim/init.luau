--!strict
-- ServerScriptService/SunAnim/init.luau
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local sky = Lighting:WaitForChild("Sky") :: Sky

type Clip = {
	Frames: {string},
	Sequence: {number},
	StepTime: number,
	Loop: boolean,
	EndHold: number?,
}

-- ===== State =====
local mode: "Idle" | "Event" = "Idle"
local currentClip: string = nil
local frameIndex: number = 1
local acc: number = 0
local holdEnd: number = 0 -- extra pause after animation ends

local lastAppliedFrame: string = nil

local DefualtSunTextureId: string = "rbxassetid://120747516590659"

local Clips: {[string]: Clip} = {
	IdleBlinkRight = {
		Frames = {"rbxassetid://89082897620389", "rbxassetid://135858883851997", "rbxassetid://107258034170465", "rbxassetid://108913647025422", "rbxassetid://113799495050283"},
		Sequence = {1,2,3,4,5,5,4,3,2,1}, -- noticeable + ping-pong + holds
		StepTime = 0.15, -- seconds per step (lower = faster)
		Loop = false,
	},
	IdleBlinkLeft = {
		Frames = {"rbxassetid://133156237883865", "rbxassetid://80844742332898","rbxassetid://113444069879107","rbxassetid://90065108988567", "rbxassetid://131856162050362"},
		Sequence = {1,2,3,4,5,5,4,3,2,1}, -- noticeable + ping-pong + holds
		StepTime = 0.15, -- seconds per step (lower = faster)
		Loop = false,
	},
	IdleBlink = {
		Frames = {"rbxassetid://97428258719477", "rbxassetid://82503036062528","rbxassetid://84849189267658","rbxassetid://104562539550698"},
		Sequence = {1,2,3,4,4,4,4,4,4,4,4,4,4,4,3,2,1}, -- noticeable + ping-pong + holds
		StepTime = 0.15, -- seconds per step (lower = faster)
		Loop = false,
	},
	IdleRelax = {
		Frames = {"rbxassetid://97428258719477", "rbxassetid://82503036062528","rbxassetid://84849189267658","rbxassetid://104562539550698", "rbxassetid://82565579462433"},
		Sequence = {1,2,3,4,5,5,4,3,2,1}, -- noticeable + ping-pong + holds
		StepTime = 0.15, -- seconds per step (lower = faster)
		Loop = false,
	},
}

-- idle randomness
local nextIdleDecision: number = 0
local function scheduleIdleDecision()
	nextIdleDecision = os.clock() + (2 + math.random() * 4) -- 2-6 sec
end
scheduleIdleDecision()

-- event anti-spam
local lastEventAt: {[string]: number} = {}
local EVENT_COOLDOWN: number = 3.0 -- seconds

local function applySun(frameId: string)
	if lastAppliedFrame == frameId then return end
	lastAppliedFrame = frameId
	sky.SunTextureId = frameId
end

local SetDefaultSun = function()
    applySun(DefualtSunTextureId)
end

local function playClip(name: string, newMode: "Idle" | "Event")
	local clip = Clips[name]
	if not clip then return end
	currentClip = name
	mode = newMode
	frameIndex = 1
	acc = 0
	local firstFrame: string = clip.Frames[clip.Sequence[1]]
	applySun(firstFrame)
end

local function stopClip()
	currentClip = nil
	frameIndex = 1
	acc = 0
    SetDefaultSun()
end

-- ===== Public-ish API (just functions in this script) =====
local function PlayEvent(name: string)
	local clip = Clips[name]
	if not clip then return end

	-- cooldown (prevents spam if multiple triggers fire)
	local now = os.clock()
	local last = lastEventAt[name] or -math.huge
	if now - last < EVENT_COOLDOWN then return end
	lastEventAt[name] = now

	playClip(name, "Event")
end

local function StopEvent()
	if mode == "Event" then
		mode = "Idle"
		stopClip()
	end
end

SetDefaultSun()
-- ===== Main loop =====
RunService.Heartbeat:Connect(function(dt)
	-- Random idle only if no event playing and no clip currently active
	if mode == "Idle" and currentClip == nil and os.clock() >= nextIdleDecision then
        local ran = math.random()
		if ran < 0.30 then
			local r = math.random()
            if r < 0.33 then
                playClip("IdleBlink", "Idle")
			elseif r < 0.66 then
                playClip("IdleBlinkLeft", "Idle")
			else
				playClip("IdleBlinkRight", "Idle")
            end
        elseif ran < 0.50 then
			playClip("IdleRelax", "Idle")
		end
		scheduleIdleDecision()
	end

	if not currentClip then
        SetDefaultSun()
        return
    end

	local clip = Clips[currentClip]
	if not clip then
		stopClip()
		return
	end

    if holdEnd > 0 then
		holdEnd -= dt
		if holdEnd <= 0 then stopClip() end
		return
	end

	acc += dt
	while acc >= clip.StepTime do
		acc -= clip.StepTime
		frameIndex += 1

		if frameIndex > #clip.Sequence then
			if clip.Loop then
				frameIndex = 1
			else
				local pause = clip.EndHold or 0.3
				holdEnd = pause
				return
			end
		end

        local frameId = clip.Frames[clip.Sequence[frameIndex]]
		applySun(frameId)
	end
end)

return {
    PlayEvent = PlayEvent,
    StopEvent = StopEvent,
}