-- Client/UI/Tooltip.luau
-- The FULL-SPEC inventory tooltip BODY (RichText). The item NAME + its grade
-- colour/animation are on the NameLabel (via UI.grade); this builds the body under it:
--   header:  "<Grade> <Kind>  ·  Tier N"   (coloured by grade)
--   desc:    the description lines
--   footer:  Weight · Stacks-to (dim)
-- The hotbar shows a COMPACT version (name + one description line) — same data, less.
-- (Was a big RPG stat builder — replaced with the Voxl spec; grow sections as items gain stats.)

local Tooltip = {}

local DIM = "#9AA0A6"

function Tooltip.Color3ToHex(color: Color3): string
	return string.format("#%02X%02X%02X", math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255))
end

local function titleCase(s: string): string
	return (s:gsub("^%l", string.upper))
end

-- itemData: { Category (kind), Grade, Tier, GradeColor (Color3), DescriptionLines, Weight, Stack }.
function Tooltip.BuildTooltip(itemData, _modData, _uiData): string
	local lines = {}

	-- header: grade + kind + tier, coloured by the grade's representative colour.
	local hex = if itemData.GradeColor then Tooltip.Color3ToHex(itemData.GradeColor) else "#FFFFFF"
	local header = ""
	if itemData.Grade then
		header = titleCase(itemData.Grade)
	end
	if itemData.Category and itemData.Category ~= "" then
		header = if header ~= "" then `{header} {itemData.Category}` else itemData.Category
	end
	if itemData.Tier then
		header = if header ~= "" then `{header}  ·  Tier {itemData.Tier}` else `Tier {itemData.Tier}`
	end
	if header ~= "" then
		table.insert(lines, `<font color="{hex}">{header}</font>`)
	end

	-- description
	if itemData.DescriptionLines and #itemData.DescriptionLines > 0 then
		table.insert(lines, "")
		for _, line in ipairs(itemData.DescriptionLines) do
			table.insert(lines, line)
		end
	end

	-- stats footer
	local stats = {}
	if itemData.Weight then
		table.insert(stats, `Weight {itemData.Weight}`)
	end
	if itemData.Stack and itemData.Stack > 1 then
		table.insert(stats, `Stacks to {itemData.Stack}`)
	end
	if #stats > 0 then
		table.insert(lines, "")
		table.insert(lines, `<font color="{DIM}">{table.concat(stats, "   ·   ")}</font>`)
	end

	return table.concat(lines, "\n")
end

return Tooltip
