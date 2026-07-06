-- StarterPlayerScripts/CameraController.luau  (Lobby)
-- Custom third-person camera so scroll can drive the hotbar and the camera pans by
-- cursor (shiftlock) instead of hold-right-click. Spec:
--   * shiftlock by DEFAULT: mouse locked to centre, moving it pans the camera; a
--     custom crosshair replaces the OS cursor.
--   * plain scroll → hotbar (ItemHotbar handles it; we don't consume it).
--   * Alt + scroll → zoom in/out.
--   * hold Alt, OR any interface open → free the cursor (normal mouse) + stop panning.
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

local yaw, pitch = 0, -12
local dist = 28
local altHeld = false
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
-- Cursor is free (normal mouse, no panning) when Alt is held or a UI is open.
local function cursorFree(): boolean
	return altHeld or UI.Controller.gameplayBlocked() or UI.Controller.isOpen("Inventory")
end

-- ---- input ------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		altHeld = true
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
		-- Over-the-shoulder: shift the camera + aim point to the right so the character
		-- sits off-centre (left) rather than dead-centre.
		local subject = root.Position + Vector3.new(0, 2, 0)
		local rot = CFrame.fromEulerAnglesYXZ(math.rad(pitch), math.rad(yaw), 0)
		local shoulder = rot * Vector3.new(2.2, 0.4, 0)
		local eye = subject + shoulder + rot * Vector3.new(0, 0, dist)
		cam.CFrame = CFrame.lookAt(eye, subject + shoulder)
	end
end)

return {}
