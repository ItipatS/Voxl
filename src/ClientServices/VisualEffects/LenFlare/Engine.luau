--[[
	LensFlare
	10/20/2025
	@gluGPU
	
	OOP module for Lens Flare Effects.
--]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local lensFlareDir = ReplicatedStorage.LensFlare
local assets = lensFlareDir.Assets
local Configuration = require(script.Parent.Config)

local ERROR_HEADER = "LensFlare:"
local TAG_NAME = "IgnoreLensFlare"

local NUM_RAYS = Configuration.NUMBER_OF_RAYCASTS
local TEST_RADIUS = Configuration.RAYCAST_RADIUS
local TRANSPARENCY_THRESHOLD = Configuration.TRANSPARENCY_THRESHOLD
local BASE_RESOLUTION = Vector2.new(1920, 1080)

local PART_ATTRIBUTES = {
	LensFlareStrength = 1,
	LensFlareDistance = 0,
}

local ATTRIBUTES = {
	ColorBlend = 0,
	Position = vector.create(1, 1, 1),
	PositionMult = 1,
	Rotates = false,
	SizeFade = NumberSequence.new(1),
	SquashFade = NumberSequence.new(0),
	TransparencyFade = NumberSequence.new(0),
}

local ATTACHMENT_PROPERTIES = {
	"Position"
}

local PROPERTIES = {
	"Size",
	"Squash",
	"Transparency",
	"LocalTransparencyModifier",
	"Color",
	"Rotation",
	"ZOffset",
	"Lifetime",
}

local pi2 = math.pi * 2
local rayOffsets: {[number]: {[number]: number}} = table.create(NUM_RAYS)

for i = 1, NUM_RAYS do
	local angle = pi2 * ((i - 1) / NUM_RAYS)
	rayOffsets[i] = {math.cos(angle) * TEST_RADIUS, math.sin(angle) * TEST_RADIUS}
end

local p = Instance.new("ParticleEmitter")
local emit = p.Emit
local clear = p.Clear

export type LensFlare = {
	_id: string,

	Enabled: boolean,

	Camera: Camera,
	Part: BasePart | Attachment,

	Attachments: {Attachment},
	FlareEmitters: {ParticleEmitter},
	_attributeCache: {[Instance]: {[string]: any}},
	_attributeConns: {RBXScriptConnection},
	_propertyCache: {[Instance]: {[string]: any}},
	
	Alpha: number,
	_forceRecompute: boolean,

	RaycastParams: RaycastParams,

	_connections: {
		CollectionServiceConn: RBXScriptConnection
	},
}

local LensFlare = {}
LensFlare.__index = LensFlare



-- util functions

-- Returns value on given numbersequence at time
-- taken from https://create.roblox.com/docs/reference/engine/datatypes/NumberSequence
local function evalNumberSequence(sequence: NumberSequence, time: number)
	-- If time is 0 or 1, return the first or last value respectively
	if time == 0 then
		return sequence.Keypoints[1].Value
	elseif time == 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	-- Otherwise, step through each sequential pair of keypoints
	for i = 1, #sequence.Keypoints - 1 do
		local currKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]
		if time >= currKeypoint.Time and time < nextKeypoint.Time then
			-- Calculate how far alpha lies between the points
			local alpha = (time - currKeypoint.Time) / (nextKeypoint.Time - currKeypoint.Time)
			-- Return the value between the points using alpha
			return currKeypoint.Value + (nextKeypoint.Value - currKeypoint.Value) * alpha
		end
	end
end



-- // Script API

-- Create a new <code>LensFlare</code> object
function LensFlare.new(camera: Camera, flareStyle: string, part: BasePart | Attachment): LensFlare
	local flareFolder = assets:FindFirstChild(flareStyle)
	assert(flareFolder, `{ERROR_HEADER} No lens flare folder called {flareStyle} under LensFlare.Assets`)

	local assets = flareFolder:GetChildren()

	local self: LensFlare = setmetatable({}, LensFlare)

	local id = HttpService:GenerateGUID(false)

	self._id = id
	self.Enabled = true

	self.Camera = camera
	self.Part = part

	self.Attachments = table.create(#assets)
	self.FlareEmitters = table.create(#assets)
	
	self.Alpha = 0
	self._forceRecompute = false

	local idx = 1
	local cache: {[Instance]: {[string]: any}} = {}
	local conns: {RBXScriptConnection} = {}
	local propsCache: {[Instance]: {[string]: any}} = {}
	
	local partCache: {[string]: any} = {}
	for attributeName: string, defaultValue: any in PART_ATTRIBUTES do
		local attribute = part:GetAttribute(attributeName) or defaultValue
		partCache[attributeName] = attribute
		
		local connection = part:GetAttributeChangedSignal(attributeName):Connect(function()
			local new = part:GetAttribute(attributeName) or defaultValue
			partCache[attributeName] = new
			self._forceRecompute = true
		end)

		table.insert(conns, connection)
	end
	
	cache[part] = partCache
	
	for _, flareAsset: ParticleEmitter in assets do
		if flareAsset:IsA("ParticleEmitter") then
			local attachment = Instance.new("Attachment")
			attachment.Name = `LensFlare_{flareStyle}_{flareAsset.Name}`
			attachment.Parent = camera

			self.Attachments[idx] = attachment
			
			propsCache[attachment] = {attachment.Position}
			
			

			local newEmitter = Instance.fromExisting(flareAsset)
			newEmitter.ZOffset = 0
			newEmitter.Enabled = false
			newEmitter.Parent = attachment

			self.FlareEmitters[idx] = newEmitter
			
			
			-- caching stuff
			local eCache: {[string]: any} = {}
			local color = part:IsA("BasePart") and part.Color or Color3.new(1, 1, 1)
			local hue, saturation = color:ToHSV()
			
			for attributeName: string, defaultValue: any in ATTRIBUTES do
				local attribute = newEmitter:GetAttribute(attributeName) or defaultValue
				eCache[attributeName] = attribute
				
				local connection = newEmitter:GetAttributeChangedSignal(attributeName):Connect(function()
					local new = newEmitter:GetAttribute(attributeName) or defaultValue
					eCache[attributeName] = new
					self._forceRecompute = true
					
					if attributeName == "ColorBlend" then
						eCache._color = ColorSequence.new(
							Color3.fromHSV(hue, new, 1)
						)
					end
				end)
				
				table.insert(conns, connection)
			end
			
			-- Calculate color blend
			if eCache.ColorBlend and eCache.ColorBlend > 0 then
				eCache._color = ColorSequence.new(
					Color3.fromHSV(hue, saturation * eCache.ColorBlend, 1)
				)
				
				if part:IsA("BasePart") then
					table.insert(conns, part:GetPropertyChangedSignal("Color"):Connect(function()
						local color = part.Color
						local hue, saturation = color:ToHSV()
						
						eCache._color = ColorSequence.new(
							Color3.fromHSV(hue, saturation * eCache.ColorBlend, 1)
						)
						self._forceRecompute = true
					end))
				end
			end
			
			
			-- cache previous properties.
			local pCache = {}
			for _, propertyName in PROPERTIES do
				local value = newEmitter[propertyName]
				pCache[propertyName] = value
			end
			
			cache[newEmitter] = eCache
			propsCache[newEmitter] = pCache

			idx += 1
		end
	end
	
	self._attributeCache = cache
	self._attributeConns = conns
	self._propertyCache = propsCache

	-- ray params
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {part, CollectionService:GetTagged(TAG_NAME)}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true

	self.RaycastParams = rayParams

	-- event connections
	self._connections = {
		CollectionServiceConn = CollectionService:GetInstanceAddedSignal(TAG_NAME):Connect(function(object: Instance)
			self.RaycastParams:AddToFilter(object)
		end),
	}
	
	RunService:BindToRenderStep(`LensFlare_{id}`, Enum.RenderPriority.Camera.Value + 10, function(delta: number)
		if not self.Enabled then return end
		self:Update(delta)
	end)

	return self
end

-- Destroy the <code>LensFlare</code> object
function LensFlare.Destroy(self: LensFlare)
	for _, connection: RBXScriptConnection in self._connections do
		connection:Disconnect()
		connection = nil
	end
	
	for _, connection: RBXScriptConnection in self._attributeConns do
		connection:Disconnect()
		connection = nil
	end

	RunService:UnbindFromRenderStep(`LensFlare_{self._id}`)

	for _, emitter in self.FlareEmitters do
		emitter:Destroy()
	end

	for _, attachment in self.Attachments do
		attachment:Destroy()
	end

	table.clear(self)
	setmetatable(self, nil)
end

-- Update the <code>LensFlare</code> emitters
function LensFlare.Update(self: LensFlare, delta: number)
	debug.profilebegin(`LensFlareUpdate_{self._id}`)
	
	local camera = self.Camera
	local part = self.Part
	local partPos = part:IsA("Attachment") and part.WorldPosition or part.Position

	local cameraPos = camera.CFrame.Position

	-- calculate camera values
	local dir = (partPos - cameraPos)
	local dist = vector.magnitude(dir)
	
	local cache = self._attributeCache
	local propsCache = self._propertyCache
	
	local partsCache = cache[part]
	local distSetting: number = partsCache.LensFlareDistance
	local strengthSetting: number = partsCache.LensFlareStrength
	
	if strengthSetting and strengthSetting <= 0 then
		return
	end

	if distSetting and distSetting > 0 and dist > distSetting then
		return
	end
	
	local alpha = math.clamp(vector.angle(camera.CFrame.LookVector, dir) / math.rad(camera.DiagonalFieldOfView) * 2, 0, 1)
	if distSetting and distSetting > 0 then
		alpha += (dist / distSetting)
	end
	
	if alpha >= 1 then
		return
	end
	
	local screenPos = camera:WorldToViewportPoint(partPos)
	local pos = camera:ViewportPointToRay(screenPos.X, screenPos.Y, 1).Origin

	local offsetCFrame = camera.CFrame:ToObjectSpace(CFrame.new(pos))
	local offset = offsetCFrame.Position

	-- Testing for visiblity.
	local rayParams = self.RaycastParams
	local numRaysHit = 0

	local screenSize = camera.ViewportSize
	local normalizedPixels = (screenSize / BASE_RESOLUTION).Magnitude
	
	debug.profilebegin(`LensFlareUpdate_{self._id}_RaycastStep`)
	for i, offsetPoints in rayOffsets do
		local x, y = offsetPoints[1] * normalizedPixels, offsetPoints[2] * normalizedPixels
		
		local ray = camera:ViewportPointToRay(screenPos.X + x, screenPos.Y + y, 1)
		local raycast = workspace:Raycast(ray.Origin, ray.Direction * dist, rayParams)
		
		if raycast then
			local rayInstance = raycast.Instance
			if rayInstance:IsA("BasePart") and (rayInstance.Transparency > TRANSPARENCY_THRESHOLD or rayInstance.LocalTransparencyModifier > TRANSPARENCY_THRESHOLD) then
				rayParams:AddToFilter(rayInstance)
			else
				numRaysHit += 1
			end
		end
	end
	debug.profileend()

	local hitAlpha = numRaysHit / NUM_RAYS

	-- reposition attachments
	local attachments = self.Attachments
	local flareEmitters = self.FlareEmitters
	
	
	local newAlpha = (strengthSetting) * (1 - alpha) * (1 - hitAlpha)
	local lastAlpha = self.Alpha -- This hasn't been updated yet, we can use it as the previous alpha.
	
	if hitAlpha < 1 and alpha < 1 then
		-- If alpha is same as before, don't recompute, just re-emit
		if newAlpha == lastAlpha and not self._forceRecompute then
			for _, emitter in flareEmitters do
				clear(emitter)
				
				local ePropsCache = propsCache[emitter]

				local eLifetime: number = ePropsCache.Lifetime
				local lifetime = NumberRange.new(delta * 3)
				if eLifetime ~= lifetime then
					emitter.Lifetime = lifetime
					ePropsCache.Lifetime = lifetime
				end
				
				emit(emitter, 1)
			end
			
			return
		end
		
		for i = 1, #flareEmitters do
			local attachment = attachments[i]
			local emitter = flareEmitters[i]

			clear(emitter)
			
			local eCache = cache[emitter]
			local ePropsCache = propsCache[emitter]
			
			local eColorBlend: number = eCache.ColorBlend
			local eColor: ColorSequence = eCache._color
			local ePos: vector = eCache.Position
			local ePosMult: number = eCache.PositionMult
			local eRotates: boolean = eCache.Rotates
			local eSizeFade: NumberSequence = eCache.SizeFade
			local eSquashFade: NumberSequence = eCache.SquashFade
			local eTransFade: NumberSequence = eCache.TransparencyFade

			local x, y = offset.X * ePos.x * ePosMult, offset.Y * ePos.y * ePosMult
			local newPos = vector.create(x, y, offset.Z)
			attachment.Position = vector.create(x, y, offset.Z)

			-- set emitter
			local size = NumberSequence.new(evalNumberSequence(eSizeFade, alpha))
			local squash = NumberSequence.new(evalNumberSequence(eSquashFade, alpha))
			local transparency = NumberSequence.new(math.lerp(evalNumberSequence(eTransFade, alpha), 1, hitAlpha))
			local transModifier = 1 - strengthSetting
			
			if size ~= ePropsCache.Size then
				emitter.Size = size
				ePropsCache.Size = size
			end

			if squash ~= ePropsCache.Squash then
				emitter.Squash = squash
				ePropsCache.Squash = squash
			end

			if transparency ~= ePropsCache.Transparency then
				emitter.Transparency = transparency
				ePropsCache.Transparency = transparency
			end

			if transModifier ~= ePropsCache.LocalTransparencyModifier then
				emitter.LocalTransparencyModifier = 1 - strengthSetting
				ePropsCache.LocalTransparencyModifier = transModifier
			end

			if eColor and eColor ~= ePropsCache.Color then
				emitter.Color = eColor
				ePropsCache.Color = eColor
			end

			if eRotates then
				local rotation = NumberRange.new(math.deg(math.atan2(offset.Y, offset.X)))
				if rotation ~= ePropsCache.Rotation then
					emitter.Rotation = rotation
					ePropsCache.Rotation = rotation
				end
			end

			local zOffset = math.min(-attachment.Position.Z * 0.8, 0)
			if zOffset ~= ePropsCache.ZOffset then
				emitter.ZOffset = zOffset
				ePropsCache.ZOffset = zOffset
			end
			
			local eLifetime: number = ePropsCache.Lifetime
			local lifetime = NumberRange.new(delta * 3)
			if eLifetime ~= lifetime then
				emitter.Lifetime = lifetime
				ePropsCache.Lifetime = lifetime
			end

			emit(emitter, 1)
		end
	end
	
	self.Alpha = newAlpha
	
	debug.profileend()
end

return LensFlare