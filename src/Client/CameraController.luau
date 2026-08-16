-- StarterPlayerScripts/CameraController.luau  (Lobby AND star place)
-- Custom third-person camera so scroll can drive the hotbar and the camera pans by
-- cursor (shiftlock) instead of hold-right-click.
--
-- It runs on the ground too, and the reason is the scroll wheel: Roblox default
-- camera claims it for zoom, so the hotbar never sees it and 1-9 becomes the only
-- way to change slots. Nothing in here is flight-specific — it follows
-- HumanoidRootPart and pans by mouse — so the star place gets the same camera
-- rather than a second one that behaves almost the same.
--
-- Spec:
--   * shiftlock by DEFAULT: mouse locked to centre, moving it pans the camera; a
--     custom crosshair replaces the OS cursor.
--   * plain scroll → hotbar (ItemHotbar handles it; we don't consume it).
--   * Alt + scroll → zoom in/out.
--   * hold Alt, OR any interface open → free the cursor (normal mouse) + stop panning.
--   * T toggles FIRST person (same pan, camera at the head, body hidden).
--   * touch (mobile): drag to pan; cursor stays free. (Flight thumbstick is a TODO.)
-- FlightController reads the camera LookVector for travel direction, so aiming = flying.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local SENS = 0.25 -- degrees per pixel (mouse)
local TOUCH_SENS = 0.4
local MIN_ZOOM, MAX_ZOOM = 10, 70
local ZOOM_STEP = 5
local PITCH_MIN, PITCH_MAX = -74, 74
-- T, not Tab: Tab belongs to Roblox's leaderboard and never reaches us.
local FIRST_PERSON_KEY = Enum.KeyCode.T

local yaw, pitch = 0, -12
local dist = 28
local altHeld = false
local firstPerson = false
local isTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

Workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
player.CharacterAdded:Connect(function()
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
end)

-- ---- custom crosshair -------------------------------------------------------
local screen = Instance.new("ScreenGui")
screen.Name = "Crosshair"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 40
screen.Parent = player:WaitForChild("PlayerGui")

local dot = Instance.new("Frame")
dot.AnchorPoint = Vector2.new(0.5, 0.5)
dot.Position = UDim2.fromScale(0.5, 0.5)
dot.Size = UDim2.fromOffset(6, 6)
dot.BackgroundColor3 = Color3.new(1, 1, 1)
dot.BackgroundTransparency = 0.15
dot.BorderSizePixel = 0
dot.Visible = false
dot.Parent = screen
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(1, 0)
corner.Parent = dot

-- ---- state ------------------------------------------------------------------
local function getRoot(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end
-- Hide/show your own body for first person. LocalTransparencyModifier is local-only
-- (nobody else sees you vanish) and Roblox resets it as the camera subject changes,
-- so it is re-asserted every frame rather than set once on toggle. Cheap: a rig is
-- ~20 parts. HumanoidRootPart is skipped because it is already invisible, and a held
-- Tool is skipped because you SHOULD see what is in your hand.
local bodyHidden: boolean? = nil
local bodyParts: { Instance } = {}
local bodyChar: Model? = nil

-- Everything on the rig that should vanish in first person. Cached, because this is
-- re-applied EVERY FRAME (see below) and GetDescendants would allocate a table per
-- frame to say the same thing. HumanoidRootPart is skipped (already invisible), and
-- anything under a Tool is skipped because you should see what is in your hand.
local function collectBody(char: Model)
	table.clear(bodyParts)
	for _, d in char:GetDescendants() do
		local hideable = (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal")
		if hideable and not d:FindFirstAncestorWhichIsA("Tool") then
			bodyParts[#bodyParts + 1] = d
		end
	end
	bodyChar = char
end

local function setBodyHidden(hide: boolean)
	local char = player.Character
	if not char then
		bodyHidden, bodyChar = nil, nil
		return
	end
	if char ~= bodyChar then
		collectBody(char) -- respawn, or an accessory/tool added since
		bodyHidden = nil
	end
	if not hide and bodyHidden == false then
		return -- already visible and nothing is fighting us for it
	end
	-- LocalTransparencyModifier is local-only (nobody else sees you vanish), and the
	-- default PlayerModule resets it as the camera subject moves — the same reason
	-- CameraType has to be re-asserted below. So this runs per frame while hidden.
	local t = if hide then 1 else 0
	for _, d in bodyParts do
		(d :: any).LocalTransparencyModifier = t
	end
	bodyHidden = hide
end

-- Declared AFTER the cache above on purpose: this closure writes bodyChar, and up
-- with the other CharacterAdded hook it would have written a GLOBAL of that name
-- instead — the cache would never invalidate and a respawned rig would stay hidden.
player.CharacterAdded:Connect(function(char)
	bodyChar = nil -- rebuild the first-person body cache for the new rig
	char.DescendantAdded:Connect(function()
		bodyChar = nil -- an accessory or hat arrived; recollect before hiding again
	end)
end)

-- Cursor is free (normal mouse, no panning) when Alt is held or a UI is open.
local function cursorFree(): boolean
	return altHeld or UI.Controller.gameplayBlocked() or UI.Controller.isOpen("Inventory")
end

-- ---- input ------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		altHeld = true
	elseif input.KeyCode == FIRST_PERSON_KEY and not processed
		and not UI.Controller.gameplayBlocked() then
		firstPerson = not firstPerson
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		altHeld = false
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if not isTouch and not cursorFree() then
			yaw -= input.Delta.X * SENS
			pitch = math.clamp(pitch - input.Delta.Y * SENS, PITCH_MIN, PITCH_MAX)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		if altHeld then
			dist = math.clamp(dist - input.Position.Z * ZOOM_STEP, MIN_ZOOM, MAX_ZOOM)
		end
		-- plain scroll falls through to ItemHotbar (hotbar select)
	elseif input.UserInputType == Enum.UserInputType.Touch and not gameProcessed then
		yaw -= input.Delta.X * TOUCH_SENS
		pitch = math.clamp(pitch - input.Delta.Y * TOUCH_SENS, PITCH_MIN, PITCH_MAX)
	end
end)

-- ---- per-frame: cursor mode + camera ----------------------------------------
-- Bind at the CAMERA render priority (not a plain RenderStepped:Connect) so the
-- camera CFrame is finalised at a deterministic point in the frame. Anything that
-- must follow the camera in the SAME frame (SpaceProxies parallax) binds at
-- Camera + 1 — otherwise it reads a stale camera and jitters at high speed.
RunService:BindToRenderStep("VoxlCamera", Enum.RenderPriority.Camera.Value, function()
	local free = isTouch or cursorFree()
	if not isTouch then
		UserInputService.MouseBehavior = if free then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = free
		dot.Visible = not free
	end

	local cam = Workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	local root = getRoot()
	if root then
		local rot = CFrame.fromEulerAnglesYXZ(math.rad(pitch), math.rad(yaw), 0)
		if firstPerson then
			-- Eye at the head. Roblox only hides your own body automatically under
			-- CameraMode.LockFirstPerson, and this camera is Scriptable, so we do it
			-- (see setBodyHidden) — otherwise you spend the whole time looking at the
			-- inside of your own head.
			local char = player.Character
			local head = char and char:FindFirstChild("Head") :: BasePart?
			local eye = if head then head.Position else root.Position + Vector3.new(0, 1.5, 0)
			cam.CFrame = CFrame.lookAt(eye, eye + rot.LookVector)
		else
			-- Over-the-shoulder: shift the camera + aim point to the right so the character
			-- sits off-centre (left) rather than dead-centre.
			local subject = root.Position + Vector3.new(0, 2, 0)
			local shoulder = rot * Vector3.new(2.2, 0.4, 0)
			local eye = subject + shoulder + rot * Vector3.new(0, 0, dist)
			cam.CFrame = CFrame.lookAt(eye, subject + shoulder)
		end
	end
	setBodyHidden(firstPerson)
end)

return {}
