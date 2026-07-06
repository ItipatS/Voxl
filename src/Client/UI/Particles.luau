-- StarterPlayerScripts/UI/Particles.luau
-- 2D UI particle bursts via the Emitter2D engine. That engine
-- (StarterPlayerScripts.Emitter2D, plugin-flavored) auto-activates ANY GUI object
-- tagged "Emitter2D" (CollectionService) as an emitter and gives it an `Emit`
-- BindableEvent. So we DON'T require the module (requiring it directly trips its
-- IsPlugin path) — we just clone a config, tag it, and fire a one-shot burst.
--
-- Author named emitter configs (via the Emitter2D plugin) under
-- `ReplicatedStorage.Assets.Emitters`; falls back to the default
-- `ReplicatedStorage.Emitter2D.Emitter`. Exposed as `UI.burst(target, name, count)`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

local TAG = "Emitter2D"

local function assets(): Instance?
	return ReplicatedStorage:FindFirstChild("Assets")
end

local function templateFor(name: string?): Instance?
	if name then
		-- A NAMED burst only fires if that authored config exists (no falling back to
		-- the big untuned default — so wiring UI.burst(el,"Sparkle") is a safe no-op
		-- until you author "Sparkle" under Assets.Emitters, then it lights up).
		local root = assets()
		local folder = root and root:FindFirstChild("Emitters")
		return folder and folder:FindFirstChild(name)
	end
	local mod = ReplicatedStorage:FindFirstChild("Emitter2D")
	return mod and mod:FindFirstChild("Emitter") -- plugin default config
end

-- One-shot burst of `count` particles inside `target` (a GuiObject under PlayerGui).
-- Safe no-op if the engine/config isn't present.
function M.burst(target: GuiObject, name: string?, count: number?)
	local src = templateFor(name)
	if not src or not target then
		return
	end
	local e = src:Clone()
	e:SetAttribute("Enabled", false) -- one-shot: we fire Emit ourselves, no streaming
	e:AddTag(TAG) -- the running engine initiates it + adds the Emit event
	e.Parent = target
	task.spawn(function()
		local emit = e:WaitForChild("Emit", 2) :: BindableEvent?
		if emit then
			emit:Fire(count or 24)
		end
	end)
	task.delay(4, function()
		if e.Parent then
			e:Destroy()
		end
	end)
end

return M
