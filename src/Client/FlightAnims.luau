--!strict
-- StarterPlayerScripts/FlightAnims.luau
-- The flight animation set + its little state machine, shared by the lobby's
-- FlightController and the star place's StarFly.
--
-- It lives here because those two cannot require each other: FlightController
-- self-starts on require (it hooks CharacterAdded at the bottom), so pulling it in
-- from the star place would start zero-g lobby flight on the ground. The choice was
-- a shared module or the same four asset ids pasted in two files, drifting the first
-- time one set is re-exported.

local M = {}

-- R6 and R15 have different skeletons, so each needs its own animations; the set is
-- chosen from Humanoid.RigType at spawn.
M.ANIM = {
	R6 = {
		Idle = "rbxassetid://84857892156947", -- idle float
		Forward = "rbxassetid://129532865648136", -- jet forward (rig rotated toward travel)
		Ascend = "rbxassetid://82374562787820", -- Space, no WASD
		Descend = "rbxassetid://82374562787820", -- Shift/Ctrl, no WASD
	},
	R15 = {
		Idle = "rbxassetid://76548149812258",
		Forward = "rbxassetid://89525532104243",
		Ascend = "rbxassetid://140220722327217",
		Descend = "rbxassetid://140220722327217",
	},
}

M.FADE = 1.5 -- crossfade between states, seconds

export type Rig = {
	set: (state: string) -> (), -- "Forward" | "Ascend" | "Descend" | "Idle"
	stop: () -> (), -- stop everything (leaving flight / respawn)
}

-- Load this humanoid's flight tracks and return a state setter. Missing ids are
-- skipped rather than erroring, so a half-filled ANIM table still flies.
function M.attach(humanoid: Humanoid): Rig
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local set = if humanoid.RigType == Enum.HumanoidRigType.R6 then M.ANIM.R6 else M.ANIM.R15

	local function load(id: string): AnimationTrack?
		if id == "" then
			return nil
		end
		local a = Instance.new("Animation")
		a.AnimationId = id
		local track = animator:LoadAnimation(a)
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Movement
		return track
	end

	local tracks: { [string]: AnimationTrack? } = {
		Forward = load(set.Forward),
		Ascend = load(set.Ascend),
		Descend = load(set.Descend),
		Idle = load(set.Idle),
	}

	local current: string? = nil

	local function setState(state: string)
		if current == state then
			return
		end
		local old = if current then tracks[current] else nil
		if old then
			old:Stop(M.FADE)
		end
		local new = tracks[state]
		if new and not new.IsPlaying then
			new:Play(M.FADE)
		end
		current = state
	end

	local function stop()
		for _, t in tracks do
			if t and t.IsPlaying then
				t:Stop(0.2)
			end
		end
		current = nil
	end

	return { set = setState, stop = stop }
end

return M
