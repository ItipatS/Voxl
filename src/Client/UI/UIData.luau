-- UIData.lua (Place this in ReplicatedStorage.Modules or a similar shared location)
local UIData = {}

-- Global UI font: Silkscreen (the pixel font on HotBarText), Regular weight — NEVER
-- bold. UIRegistry stamps this on every text element under Interface; Notifier + any
-- code-built label use it too. Swap the asset here to restyle all text at once.
UIData.Font = Font.new("rbxassetid://12187371840", Enum.FontWeight.Regular, Enum.FontStyle.Normal)

function UIData.Bordercalculate(num)
	local baseX = 0       -- Starting x-coordinate
	local baseY = 0       -- Starting y-coordinate
	local blockSizeX = 64  -- Width of each block
	local blockSizeY = 64  -- Height of each block
	local rowLength = 10   -- Number of numbers in a row

	local row = math.floor((num - 1) / rowLength)
	local offset = (num - 1) % rowLength

	local x = baseX + offset * blockSizeX
	local y = baseY + row * blockSizeY

	return Vector2.new(x, y)
end

-- Rarity GRADE → look. One table, keyed by grade name (itemdb.Grade). Each entry is
-- EITHER a static Color3 OR an animated effect table. Each animated grade opts INTO the
-- text effects it wants (cumulative up the ladder): colorLoop (rare+), gradient (epic+),
-- glow (legendary+). `direction`/`duration` tune the running gradient. Grade (rarity) is
-- separate from an item's numeric `tier` (level). Add fancier grades here later.
-- (ColorSequence rule: first keypoint time 0, last time 1, strictly ascending.)
UIData.Grade = {
	common = Color3.fromRGB(235, 235, 235), -- plain white
	uncommon = Color3.fromRGB(120, 230, 130), -- green

	rare = { -- colorLoop
		colorSequence = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(9, 108, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 0, 207)),
		}),
		direction = "bounce",
		duration = 1.5,
		colorLoop = true,
	},
	epic = { -- colorLoop + gradient
		colorSequence = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 110, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(148, 0, 211)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(75, 0, 130)),
		}),
		direction = "bounce",
		duration = 1.5,
		colorLoop = true,
		gradient = true,
	},
	legendary = { -- colorLoop + gradient + glow (iridescent)
		colorSequence = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.166, Color3.fromRGB(255, 165, 0)),
			ColorSequenceKeypoint.new(0.333, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 128, 0)),
			ColorSequenceKeypoint.new(0.666, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.833, Color3.fromRGB(75, 0, 130)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(148, 0, 211)),
		}),
		direction = "bounce",
		duration = 1.5,
		colorLoop = true,
		gradient = true,
		glow = true,
	},
	mythical = { -- all three (cosmic starlight) — the Star Seed
		colorSequence = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(120, 200, 255)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(200, 120, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 220, 140)),
		}),
		direction = "bounce",
		duration = 2.5,
		colorLoop = true,
		gradient = true,
		glow = true,
	},
}

-- The look (Color3 or animated effect table) for a grade; defaults to common.
function UIData:GetGradeLook(grade)
	return self.Grade[grade] or self.Grade.common
end

-- Static slot-border tile per GRADE, as a 1-based INDEX into the "Ram Border All"
-- tileset (10 cols × 8 rows of 64px): 1 = (0,0), 2 = (64,0), … via Bordercalculate.
-- No entry = default 384,0 (common). mythical randomises its tile (UI.borderFX).
UIData.Border = {
	uncommon = 1,
	rare = 8,
	epic = 19,
	legendary = 17,
	-- mythical → random tile (animated)
}

return UIData
