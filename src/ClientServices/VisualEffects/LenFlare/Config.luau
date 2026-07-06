--[[
	Lens Flare Configuration
--]]



-- // GENERAL

-- How many rays will be shot out into the world to determine lens flare obstruction.
-- Lower amount gives faster performance, but obstruction fade becomes less accurate.
local NUMBER_OF_RAYCASTS = 5

-- Spreads out raycasts in a radius around the flare source. Doesn't affect performance.
local RAYCAST_RADIUS = 7

-- How transparent a part can be before it no longer blocks lens flares.
-- A value of 1 means that even fully transparent parts will block the sun.
local TRANSPARENCY_THRESHOLD = 0.666



-- // SUN FLARE

-- The angle above the horizon at which the sun flare will begin to decrease in strength.
local SUN_ANGLE_THRESHOLD = 30

-- Threshold for Lighting.Brightness before sun flare reaches maximum strength
-- e.g. at BRIGHTNESS_THRESHOLD = 2.5 and above, the sun flare will be at full strength.
local SUN_BRIGHTNESS_THRESHOLD = 2.5

-- How much to adjust exposure by when looking directly at the sun flare. This should be
-- a negative value to get the desired effect. Unless you want things to be brighter when
-- you look at the sun but that's weird...
local SUN_EXPOSURE_ADJUSTMENT = -2.25

-- Duration of exposure adjustment when looking at sun glare.
local SUN_EXPOSURE_TIME = 1



return {
	NUMBER_OF_RAYCASTS = NUMBER_OF_RAYCASTS,
	RAYCAST_RADIUS = RAYCAST_RADIUS,
	TRANSPARENCY_THRESHOLD = TRANSPARENCY_THRESHOLD,
	
	SUN_ANGLE_THRESHOLD = SUN_ANGLE_THRESHOLD,
	SUN_BRIGHTNESS_THRESHOLD = SUN_BRIGHTNESS_THRESHOLD,
	SUN_EXPOSURE_ADJUSTMENT = SUN_EXPOSURE_ADJUSTMENT,
	SUN_EXPOSURE_TIME = SUN_EXPOSURE_TIME
}