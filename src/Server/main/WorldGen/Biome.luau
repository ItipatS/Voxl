-- ========= BIOME DEFINITIONS =========
-- Very simple for now; you can expand this table.

local Biome = {}

Biome.Biomes  = {
	[1] = {
		name = "Plains",
		topBlock = 1,   -- grass
		underBlock = 2, -- dirt
	},
	[2] = {
		name = "Desert",
		topBlock = 3,   -- sand
		underBlock = 3, -- sand
	},
	[3] = {
		name = "Forest",
		topBlock = 1,   -- grass
		underBlock = 2, -- dirt
	},
} :: {[number]: {
	name: string,
	topBlock: number,
	underBlock: number}}


function Biome.pickBiome(temp: number, humid: number, height01: number): number
	-- super dumb logic for now
	if temp > 0.7 and humid < 0.4 then
		return 2 -- Desert
	elseif humid > 0.6 then
		return 3 -- Forest
	else
		return 1 -- Plains
	end
end


return Biome
