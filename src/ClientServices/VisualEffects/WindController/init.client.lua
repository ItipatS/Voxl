local WIND_DIRECTION = Vector3.new(1, 0, 0.3)
local WIND_SPEED = 20
local WIND_POWER = 0.5
local SHAKE_DISTANCE = 150

local WindLines = require(script.WindLines)
local WindShake = require(script.WindShake)

WindLines:Init({
	Direction = WIND_DIRECTION,
	Speed = WIND_SPEED,
	Lifetime = 1.5,
	SpawnRate = 11,
	Color = Color3.fromRGB(235, 245, 255), -- the sea-breeze block below recolours this live near the beach
})

WindShake:SetDefaultSettings({
	WindSpeed = WIND_SPEED,
	WindDirection = WIND_DIRECTION,
	WindPower = WIND_POWER,
})
WindShake:Init({
	MatchWorkspaceWind = true,
})

-- We told it to match the workspace wind, so it'll have computed
-- new default settings based on workspace.GlobalWind.
-- To make sure our dev guis match this, we'll read back the default settings.
WIND_SPEED = script.WindShake:GetAttribute("WindSpeed")
WIND_DIRECTION = script.WindShake:GetAttribute("WindDirection")
WIND_POWER = script.WindShake:GetAttribute("WindPower")

-- ============================================================================
-- ONSHORE SEA BREEZE (aesthetic). Near the beach the wind always blows IN from the
-- ocean (onshore = the nearest shore strip's -LookVector; its Front faces the sea).
-- It drives workspace.GlobalWind — WindShake (foliage) follows that LIVE — plus the
-- WindLines direction + colour. Away from the shore it eases to a gentle ambient wind.
--
-- HOW "near the beach" is measured: straight-line XZ distance from the CAMERA to the
-- nearest point ON a shore strip (clamped along the strip's length, so a long beach
-- counts as near ANYWHERE along it, not just its midpoint). dist <= `enterDist` => full
-- breeze; dist >= `fadeDist` => full ambient; linear blend between the two.
--
-- WIND STRENGTH = the GlobalWind MAGNITUDE (the `*Speed` knobs). WindShake's foliage
-- power grows fast with magnitude, so keep these LOW — ~2-4 is a gentle sway, 15+ whips
-- every tree. These are the dials to calm down / intensify the foliage + grass.
-- ============================================================================
do
	local RunService = game:GetService("RunService")
	local Workspace = game:GetService("Workspace")

	local SEA_BREEZE = {
		enterDist = 160, -- <= this many studs from the beach => FULL onshore breeze
		fadeDist = 380, -- >= this => fully back to the ambient wind
		breezeSpeed = 3, -- GlobalWind magnitude AT the beach (foliage strength — keep low)
		ambientSpeed = 2, -- GlobalWind magnitude away from the beach (the everywhere-else wind)
		turnRate = 1.5, -- how fast the wind eases toward its target (per second)
		ambientColor = Color3.fromRGB(235, 245, 255), -- wind-line colour away from the beach
		seaColor = Color3.fromRGB(150, 232, 240), -- wind-line colour at the beach (sea cyan)
	}

	-- ambient wind: keep the place's wind DIRECTION but use our own gentle SPEED
	local ambientDir = Workspace.GlobalWind
	ambientDir = (ambientDir.Magnitude > 0.05 and ambientDir.Unit)
		or (typeof(WIND_DIRECTION) == "Vector3" and WIND_DIRECTION.Unit)
		or Vector3.new(1, 0, 0.3).Unit
	local ambientWind = ambientDir * SEA_BREEZE.ambientSpeed
	local current = ambientWind

	local strips = {}
	task.spawn(function()
		local beach = Workspace:WaitForChild("Beach", 20)
		local lines = beach and beach:WaitForChild("ShoreLines", 20)
		if not lines then
			return
		end
		local function refresh()
			table.clear(strips)
			for _, c in lines:GetChildren() do
				if c:IsA("BasePart") and c.Name == "ShoreStrip" then
					strips[#strips + 1] = c
				end
			end
		end
		refresh()
		lines.ChildAdded:Connect(refresh)
		lines.ChildRemoved:Connect(refresh)
	end)

	RunService.Heartbeat:Connect(function(dt)
		local cam = Workspace.CurrentCamera
		local pos = cam and cam.CFrame.Position
		local target = ambientWind
		local t = 0
		if pos and #strips > 0 then
			local bestD, onshore = math.huge, nil
			for _, sp in strips do
				-- nearest point on the strip's LONG axis (RightVector), then planar XZ distance
				local right = sp.CFrame.RightVector
				local rlen = math.sqrt(right.X * right.X + right.Z * right.Z)
				if rlen > 1e-4 then
					local rx, rz = right.X / rlen, right.Z / rlen
					local half = sp.Size.X * 0.5
					local along = math.clamp((pos.X - sp.Position.X) * rx + (pos.Z - sp.Position.Z) * rz, -half, half)
					local dx = pos.X - (sp.Position.X + rx * along)
					local dz = pos.Z - (sp.Position.Z + rz * along)
					local d = math.sqrt(dx * dx + dz * dz)
					if d < bestD then
						bestD = d
						local lv = sp.CFrame.LookVector
						onshore = Vector3.new(-lv.X, 0, -lv.Z) -- -Look faces the land = wind blows onshore
					end
				end
			end
			if onshore and onshore.Magnitude > 1e-4 then
				t = math.clamp((SEA_BREEZE.fadeDist - bestD) / (SEA_BREEZE.fadeDist - SEA_BREEZE.enterDist), 0, 1)
				target = ambientWind:Lerp(onshore.Unit * SEA_BREEZE.breezeSpeed, t)
			end
		end
		current = current:Lerp(target, math.clamp(dt * SEA_BREEZE.turnRate, 0, 1))
		-- write only when it actually moved (no per-frame GlobalWind churn once settled)
		if (current - Workspace.GlobalWind).Magnitude > 0.03 then
			Workspace.GlobalWind = current
			if current.Magnitude > 1e-4 then
				WindLines.Direction = current.Unit
			end
		end
		-- wind lines tint ambient -> sea cyan as you near the beach (new lines pick up the change)
		WindLines.Color = SEA_BREEZE.ambientColor:Lerp(SEA_BREEZE.seaColor, t)
	end)
end

-- Demo dynamic settings

--[[local Gui = Instance.new("ScreenGui")

local CountLabel = Instance.new("TextLabel")
CountLabel.Text = string.format("Leaf Count: %d Active, %d Inactive, 77760 Total", 0, 0)
CountLabel.BackgroundTransparency = 0.3
CountLabel.BackgroundColor3 = Color3.new()
CountLabel.TextStrokeTransparency = 0.8
CountLabel.Size = UDim2.new(0.6, 0, 0, 27)
CountLabel.Position = UDim2.new(0.2, 0, 0, -35)
CountLabel.Font = Enum.Font.RobotoMono
CountLabel.TextSize = 25
CountLabel.TextColor3 = Color3.new(1, 1, 1)
CountLabel.Parent = Gui

local SpeedInput = Instance.new("TextBox")
SpeedInput.Text = string.format("Wind Speed: %.1f", WIND_SPEED)
SpeedInput.PlaceholderText = "Input Speed"
SpeedInput.BackgroundTransparency = 0.8
SpeedInput.TextStrokeTransparency = 0.8
SpeedInput.Size = UDim2.new(0.2, 0, 0, 20)
SpeedInput.Position = UDim2.new(0, 5, 0.45, 0)
SpeedInput.Font = Enum.Font.RobotoMono
SpeedInput.TextXAlignment = Enum.TextXAlignment.Left
SpeedInput.TextSize = 18
SpeedInput.TextColor3 = Color3.new(1, 1, 1)
SpeedInput.FocusLost:Connect(function()
	local newSpeed = tonumber(SpeedInput.Text:match("[%d%.]+"))
	if newSpeed then
		WIND_SPEED = math.clamp(newSpeed, 0, 50)
		WindLines.Speed = WIND_SPEED
		WindShake:UpdateAllObjectSettings({ WindSpeed = WIND_SPEED })
		WindShake:SetDefaultSettings({ WindSpeed = WIND_SPEED })
	end
	SpeedInput.Text = string.format("Wind Speed: %.1f", WIND_SPEED)
end)
SpeedInput.Parent = Gui

local PowerInput = Instance.new("TextBox")
PowerInput.Text = string.format("Wind Power: %.1f", WIND_POWER)
PowerInput.PlaceholderText = "Input Power"
PowerInput.BackgroundTransparency = 0.8
PowerInput.TextStrokeTransparency = 0.8
PowerInput.Size = UDim2.new(0.2, 0, 0, 20)
PowerInput.Position = UDim2.new(0, 5, 0.45, 25)
PowerInput.Font = Enum.Font.RobotoMono
PowerInput.TextXAlignment = Enum.TextXAlignment.Left
PowerInput.TextSize = 18
PowerInput.TextColor3 = Color3.new(1, 1, 1)
PowerInput.FocusLost:Connect(function()
	local newPower = tonumber(PowerInput.Text:match("[%d%.]+"))
	if newPower then
		WIND_POWER = math.clamp(newPower, 0, 10)
		WindShake:UpdateAllObjectSettings({ WindPower = WIND_POWER })
		WindShake:SetDefaultSettings({ WindPower = WIND_POWER })
	end
	PowerInput.Text = string.format("Wind Power: %.1f", WIND_POWER)
end)
PowerInput.Parent = Gui

local DirInput = Instance.new("TextBox")
DirInput.Text = string.format("Wind Direction: %.1f,%.1f,%.1f", WIND_DIRECTION.X, WIND_DIRECTION.Y, WIND_DIRECTION.Z)
DirInput.PlaceholderText = "Input Direction"
DirInput.BackgroundTransparency = 0.8
DirInput.TextStrokeTransparency = 0.8
DirInput.Size = UDim2.new(0.2, 0, 0, 20)
DirInput.Position = UDim2.new(0, 5, 0.45, 50)
DirInput.Font = Enum.Font.RobotoMono
DirInput.TextXAlignment = Enum.TextXAlignment.Left
DirInput.TextSize = 18
DirInput.TextColor3 = Color3.new(1, 1, 1)
DirInput.FocusLost:Connect(function()
	local Inputs = table.create(3)
	for Num in string.gmatch(DirInput.Text, "%-?[%d%.]+") do
		Inputs[#Inputs + 1] = tonumber(Num)
	end

	local newDir =
		Vector3.new(Inputs[1] or WIND_DIRECTION.X, Inputs[2] or WIND_DIRECTION.Y, Inputs[3] or WIND_DIRECTION.Z).Unit
	if newDir then
		WIND_DIRECTION = newDir
		WindLines.Direction = newDir
		WindShake:UpdateAllObjectSettings({ WindDirection = newDir })
		WindShake:SetDefaultSettings({ WindDirection = newDir })
	end

	DirInput.Text =
		string.format("Wind Direction: %.1f, %.1f, %.1f", WIND_DIRECTION.X, WIND_DIRECTION.Y, WIND_DIRECTION.Z)
end)
DirInput.Parent = Gui

local DistanceInput = Instance.new("TextBox")
DistanceInput.Text = string.format("Shake Distance: %.1f", SHAKE_DISTANCE)
DistanceInput.PlaceholderText = "Input Distance"
DistanceInput.BackgroundTransparency = 0.8
DistanceInput.TextStrokeTransparency = 0.8
DistanceInput.Size = UDim2.new(0.2, 0, 0, 20)
DistanceInput.Position = UDim2.new(0, 5, 0.45, 75)
DistanceInput.Font = Enum.Font.RobotoMono
DistanceInput.TextXAlignment = Enum.TextXAlignment.Left
DistanceInput.TextSize = 18
DistanceInput.TextColor3 = Color3.new(1, 1, 1)
DistanceInput.FocusLost:Connect(function()
	local newDistance = tonumber(DistanceInput.Text:match("[%d%.]+"))
	if newDistance then
		SHAKE_DISTANCE = math.clamp(newDistance, 5, 500)
		WindShake.RenderDistance = SHAKE_DISTANCE
	end
	DistanceInput.Text = string.format("Shake Distance: %.1f", SHAKE_DISTANCE)
end)
DistanceInput.Parent = Gui

Gui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")

task.defer(function()
	while task.wait(0.1) do
		local Active, Handled = WindShake.Active, WindShake.Handled
		CountLabel.Text = string.format(
			"Leaf Count: %d Active, %d Inactive, %d Not Streamed In (77760 Total)",
			Active,
			Handled - Active,
			77760 - Handled
		)
	end
end)]]
--
