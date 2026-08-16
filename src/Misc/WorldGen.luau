-- ReplicatedStorage/WorldGen.luau
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Blocks = require(ReplicatedStorage.Misc.Blocks)
local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)

local WorldGen = {}

-- BAKED mode (doc 23): a star whose terrain was IMPORTED, not generated. When
-- applyPrebaked() has been called, the three queries every consumer goes through
-- (getColumn / getSurfaceHeight / blockAt) read the baked blob instead of the
-- noise field — so the mesher, block editing, spawn and locks all work unchanged.
local baked: PrebakedMap.Map? = nil

local CHUNK_SIZE = 16
local WORLD_HEIGHT = 256
local BLOCK_SIZE = 3.5

local BASE_SEED = 1339 -- active noise seed; a bounded star overrides this per-world (applyStar)

-- Bounded-STAR mode (the explore-and-claim per-star world, doc 21). When applyStar() is
-- called (in the Star/ResourceStar place), generation becomes a bounded disc seeded per
-- star with a RESTRICTED biome palette. Unset = legacy infinite continent. Both server +
-- client call applyStar with the SAME config (std/starconfig) so terrain matches.
local starRadius: number? = nil -- island radius in BLOCKS (star centre at world 0,0)
local starBiomes: { number }? = nil -- the star's biome palette (ids), sorted low-tier → high-tier

-- Block ids live in the registry (Blocks.luau); WorldGen just references them.
WorldGen.BLOCK = Blocks.ID
local WATER_LEVEL = 60

local BLOCK = WorldGen.BLOCK

local function idx3(x: number, y: number, z: number, height: number): number
    -- (x,z) ∈ [0,15], y ∈ [0, height-1]. Z-stride is the chunk's own height so the
    -- backing buffer is only as tall as the terrain (dense, contiguous 0..CHUNK_SIZE^2*height-1).
    return x + (y * CHUNK_SIZE) + (z * CHUNK_SIZE * height)
end

local function n01(n: number): number
    return 0.5 * (n + 1)
end

-- Perlin noise bunches near 0.5; stretch a 0..1 value toward the extremes so the
-- climate grid (and elevation) actually reaches deserts, jungles, peaks, etc.
local function spread(v: number, amount: number): number
    return math.clamp((v - 0.5) * amount + 0.5, 0, 1)
end

local function noise2D(seed: number, x: number, z: number): number
    return math.noise(x + seed * 13.37, z + seed * 42.69)
end

local function noise3D(seed: number, x: number, y: number, z: number): number
    return math.noise(x + seed * 3.17, y + seed * 7.31, z + seed * 11.13)
end

type BiomeDef = {
    name: string,
    top: number,
    under: number,
    soilDepth: number,
    minHeight: number,
    maxHeight: number,
    flatness: number,    -- exponent on the base 0..1: >1 flattens lowlands
    hilliness: number,   -- amplitude (blocks) of medium-frequency bumps
    ridged: number,      -- extra ridged height (blocks); >0 for mountains
    treeDensity: number, -- 0..100 chance a candidate grid cell has a tree
    grass: Color3?,      -- biome grass tint (nil = non-grass top), from BoP palette
}

-- Biome ids (append-only). Climate-placed by temperature x humidity, with high
-- elevations overriding to highland/mountain variants. Grass colours adapted from
-- Biomes O' Plenty.
local B_PLAINS = 1
local B_DESERT = 2
local B_FOREST = 3
local B_CRAG = 4
local B_SNOW_HIGH = 5
local B_SAVANNA = 6
local B_JUNGLE = 7
local B_SWAMP = 8
local B_SEASONAL = 9
local B_TAIGA = 10
local B_TUNDRA = 11
local B_SNOWY_FOREST = 12
local B_COLD_DESERT = 13
local B_HIGHLAND = 14
local B_SNOWY_PEAKS = 15

-- Star-ladder rungs (doc 21): the 25-biome grid is 5 families × 5 tiers. Nine of the rungs
-- reuse the legacy defs above (Forest/Jungle/Crag/Highland/Desert/Taiga/Tundra/Swamp); the
-- 16 below fill the calm T1s, the wild T4s and the surreal T5 show-stoppers. Append-only.
local B_MEADOW = 16        -- Flora T1
local B_ANCIENT_GROVE = 17 -- Flora T4
local B_WILDWOOD = 18      -- Flora T5
local B_ROCKLAND = 19      -- Stone T1
local B_PEAKS = 20         -- Stone T4 (snowless SnowyPeaks)
local B_MONOLITHS = 21     -- Stone T5
local B_DUNES = 22         -- Sand  T1
local B_BADLANDS = 23      -- Sand  T3
local B_MESA = 24          -- Sand  T4
local B_GLASS_SEA = 25     -- Sand  T5
local B_FROSTFIELD = 26    -- Frost T1
local B_GLACIER = 27       -- Frost T4
local B_AURORA_SHELF = 28  -- Frost T5
local B_MARSH = 29         -- Bog   T1
local B_FEN = 30           -- Bog   T3
local B_MIRE = 31          -- Bog   T4
local B_SPORE_HOLLOW = 32  -- Bog   T5

-- The biome every column of a BAKED star reports. It grows no trees (the map
-- brought its own) and carries a neutral grass tint for the mesher.
local B_IMPORTED = 33

local Biomes: { [number]: BiomeDef } = {
    [B_PLAINS] = { name = "Plains", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 60, maxHeight = 70, flatness = 2.2, hilliness = 2, ridged = 0,
        treeDensity = 6, grass = Color3.fromRGB(143, 192, 90) },
    [B_DESERT] = { name = "Desert", top = BLOCK.Sand, under = BLOCK.Sand, soilDepth = 6,
        minHeight = 58, maxHeight = 70, flatness = 1.6, hilliness = 5, ridged = 0,
        treeDensity = 0, grass = nil },
    [B_FOREST] = { name = "Forest", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 5,
        minHeight = 62, maxHeight = 84, flatness = 1.2, hilliness = 5, ridged = 0,
        treeDensity = 55, grass = Color3.fromRGB(121, 192, 90) },
    [B_CRAG] = { name = "Crag", top = BLOCK.Stone, under = BLOCK.Stone, soilDepth = 3,
        minHeight = 92, maxHeight = 150, flatness = 1, hilliness = 8, ridged = 46,
        treeDensity = 0, grass = nil },
    [B_SNOW_HIGH] = { name = "SnowHighlands", top = BLOCK.Snow, under = BLOCK.Stone, soilDepth = 3,
        minHeight = 110, maxHeight = 180, flatness = 1, hilliness = 8, ridged = 58,
        treeDensity = 0, grass = nil },
    [B_SAVANNA] = { name = "Savanna", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 60, maxHeight = 72, flatness = 2, hilliness = 3, ridged = 0,
        treeDensity = 10, grass = Color3.fromRGB(191, 183, 85) },
    [B_JUNGLE] = { name = "Jungle", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 5,
        minHeight = 62, maxHeight = 86, flatness = 1.2, hilliness = 6, ridged = 0,
        treeDensity = 78, grass = Color3.fromRGB(89, 201, 60) },
    [B_SWAMP] = { name = "Swamp", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 58, maxHeight = 64, flatness = 3, hilliness = 2, ridged = 0,
        treeDensity = 28, grass = Color3.fromRGB(106, 143, 78) },
    [B_SEASONAL] = { name = "SeasonalForest", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 5,
        minHeight = 62, maxHeight = 82, flatness = 1.3, hilliness = 5, ridged = 0,
        treeDensity = 45, grass = Color3.fromRGB(183, 152, 74) },
    [B_TAIGA] = { name = "Taiga", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 64, maxHeight = 88, flatness = 1.2, hilliness = 6, ridged = 0,
        treeDensity = 50, grass = Color3.fromRGB(134, 184, 127) },
    [B_TUNDRA] = { name = "Tundra", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 60, maxHeight = 72, flatness = 2, hilliness = 3, ridged = 0,
        treeDensity = 4, grass = Color3.fromRGB(168, 168, 110) },
    [B_SNOWY_FOREST] = { name = "SnowyForest", top = BLOCK.Snow, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 64, maxHeight = 90, flatness = 1.2, hilliness = 6, ridged = 0,
        treeDensity = 40, grass = nil },
    [B_COLD_DESERT] = { name = "ColdDesert", top = BLOCK.Sand, under = BLOCK.Sand, soilDepth = 5,
        minHeight = 58, maxHeight = 70, flatness = 1.6, hilliness = 4, ridged = 0,
        treeDensity = 0, grass = nil },
    [B_HIGHLAND] = { name = "Highland", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 3,
        minHeight = 86, maxHeight = 128, flatness = 1, hilliness = 7, ridged = 20,
        treeDensity = 8, grass = Color3.fromRGB(143, 181, 106) },
    [B_SNOWY_PEAKS] = { name = "SnowyPeaks", top = BLOCK.Snow, under = BLOCK.Stone, soilDepth = 3,
        minHeight = 130, maxHeight = 200, flatness = 1, hilliness = 9, ridged = 66,
        treeDensity = 0, grass = nil },

    -- ===== Star-ladder rungs (doc 21) — the 16 authored biomes =====
    -- FLORA (green, organic): Meadow → [Forest] → [Jungle] → Ancient Grove → Wildwood
    [B_MEADOW] = { name = "Meadow", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 60, maxHeight = 68, flatness = 2.6, hilliness = 2, ridged = 0,
        treeDensity = 4, grass = Color3.fromRGB(150, 200, 100) },
    [B_ANCIENT_GROVE] = { name = "Ancient Grove", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 6,
        minHeight = 64, maxHeight = 98, flatness = 1.1, hilliness = 7, ridged = 8,
        treeDensity = 92, grass = Color3.fromRGB(110, 150, 72) },
    [B_WILDWOOD] = { name = "Bioluminescent Wildwood", top = BLOCK.MossBlock, under = BLOCK.Dirt, soilDepth = 5,
        minHeight = 66, maxHeight = 122, flatness = 1, hilliness = 9, ridged = 30,
        treeDensity = 70, grass = Color3.fromRGB(80, 210, 165) },

    -- STONE (grey/brown, mineral): Rockland → [Crag] → [Highland] → Peaks → Floating Monoliths
    [B_ROCKLAND] = { name = "Rockland", top = BLOCK.Stone, under = BLOCK.Stone, soilDepth = 2,
        minHeight = 62, maxHeight = 80, flatness = 1.6, hilliness = 6, ridged = 6,
        treeDensity = 0, grass = nil },
    [B_PEAKS] = { name = "Peaks", top = BLOCK.Stone, under = BLOCK.Stone, soilDepth = 3,
        minHeight = 120, maxHeight = 190, flatness = 1, hilliness = 9, ridged = 62,
        treeDensity = 0, grass = nil },
    [B_MONOLITHS] = { name = "Floating Monoliths", top = BLOCK.Andesite, under = BLOCK.Stone, soilDepth = 3,
        minHeight = 100, maxHeight = 200, flatness = 1, hilliness = 10, ridged = 82,
        treeDensity = 0, grass = nil },

    -- SAND (tan/ochre, silica): Dunes → [Desert] → Badlands → Mesa → Glass Sea
    [B_DUNES] = { name = "Dunes", top = BLOCK.Sand, under = BLOCK.Sand, soilDepth = 6,
        minHeight = 58, maxHeight = 72, flatness = 1.5, hilliness = 6, ridged = 0,
        treeDensity = 0, grass = nil },
    [B_BADLANDS] = { name = "Badlands", top = BLOCK.RedSand, under = BLOCK.RedSandstone, soilDepth = 5,
        minHeight = 64, maxHeight = 112, flatness = 1.1, hilliness = 6, ridged = 42,
        treeDensity = 0, grass = nil },
    [B_MESA] = { name = "Mesa", top = BLOCK.RedSand, under = BLOCK.RedSandstone, soilDepth = 6,
        minHeight = 80, maxHeight = 152, flatness = 1, hilliness = 7, ridged = 56,
        treeDensity = 0, grass = nil },
    [B_GLASS_SEA] = { name = "Glass Sea", top = BLOCK.Ice, under = BLOCK.PackedIce, soilDepth = 4,
        minHeight = 60, maxHeight = 66, flatness = 3, hilliness = 1, ridged = 0,
        treeDensity = 0, grass = nil },

    -- FROST (white/blue, cryo): Frostfield → [Taiga] → [Tundra] → Glacier → Aurora Shelf
    [B_FROSTFIELD] = { name = "Frostfield", top = BLOCK.Snow, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 60, maxHeight = 70, flatness = 2.4, hilliness = 2, ridged = 0,
        treeDensity = 2, grass = nil },
    [B_GLACIER] = { name = "Glacier", top = BLOCK.Snow, under = BLOCK.PackedIce, soilDepth = 3,
        minHeight = 110, maxHeight = 178, flatness = 1, hilliness = 8, ridged = 56,
        treeDensity = 0, grass = nil },
    [B_AURORA_SHELF] = { name = "Aurora Shelf", top = BLOCK.Ice, under = BLOCK.PackedIce, soilDepth = 4,
        minHeight = 66, maxHeight = 132, flatness = 1, hilliness = 9, ridged = 26,
        treeDensity = 0, grass = nil },

    -- BOG (murky green/brown, decay): Marsh → [Swamp] → Fen → Mire → Spore Hollow
    [B_MARSH] = { name = "Marsh", top = BLOCK.Grass, under = BLOCK.Mud, soilDepth = 4,
        minHeight = 58, maxHeight = 63, flatness = 3.2, hilliness = 2, ridged = 0,
        treeDensity = 6, grass = Color3.fromRGB(120, 150, 86) },
    [B_FEN] = { name = "Fen", top = BLOCK.Mud, under = BLOCK.Mud, soilDepth = 5,
        minHeight = 57, maxHeight = 66, flatness = 2.6, hilliness = 3, ridged = 0,
        treeDensity = 20, grass = Color3.fromRGB(96, 112, 62) },
    [B_MIRE] = { name = "Mire", top = BLOCK.Mud, under = BLOCK.CoarseDirt, soilDepth = 5,
        minHeight = 56, maxHeight = 72, flatness = 2, hilliness = 4, ridged = 8,
        treeDensity = 30, grass = Color3.fromRGB(104, 130, 70) },
    [B_SPORE_HOLLOW] = { name = "Spore Hollow", top = BLOCK.MossBlock, under = BLOCK.Mud, soilDepth = 5,
        minHeight = 58, maxHeight = 112, flatness = 1.2, hilliness = 8, ridged = 22,
        treeDensity = 40, grass = nil },

    [B_IMPORTED] = { name = "Imported", top = BLOCK.Grass, under = BLOCK.Dirt, soilDepth = 4,
        minHeight = 60, maxHeight = 70, flatness = 2, hilliness = 0, ridged = 0,
        treeDensity = 0, grass = Color3.fromRGB(125, 178, 84) },
}


-- ===================== Bounded-star helpers (doc 21) =====================
-- Radial island falloff: 1 in the interior, smoothstep down to 0 at the rim, void beyond
-- (star centre = world origin). Applied to column height so the disc slopes into the void.
local function islandFactor(wx: number, wz: number): number
    local rad = starRadius :: number
    local r = math.sqrt(wx * wx + wz * wz)
    local inner = rad * 0.72
    if r <= inner then
        return 1
    elseif r >= rad then
        return 0
    end
    local t = (r - inner) / (rad - inner)
    return 1 - t * t * (3 - 2 * t)
end

-- Pick a biome from the star's palette. The palette is sorted low-tier → high-tier, and the
-- field blends a low-freq region noise (for organic patch shapes) with an INWARD radial bias:
-- near the rim the field is small → the common low-tier rungs (which also carry more weight);
-- toward the island's heart the field swells → the rare high-tier rung surfaces as a central
-- locus. So you cross ordinary terrain and *discover* the star's payoff biome at its core
-- (doc 21: "the T5, if any, is a single special locus, often central"). Deterministic.
local function pickStarBiome(wx: number, wz: number): number
    local list = starBiomes :: { number }
    local n = #list
    if n <= 1 then
        return list[1] or 1
    end
    local rad = starRadius :: number
    local rr = math.clamp(math.sqrt(wx * wx + wz * wz) / rad, 0, 1) -- 0 centre .. 1 rim
    local region = n01(noise2D(BASE_SEED + 800, wx * 0.012, wz * 0.012))
    local field = region * 0.6 + (1 - rr) * 0.4 -- inward bias toward the heart
    -- Weighted CDF: earlier (lower-tier) rungs cover exponentially more area.
    local total = 0
    for i = 1, n do
        total += 0.5 ^ (i - 1)
    end
    local acc = 0
    for i = 1, n do
        acc += (0.5 ^ (i - 1)) / total
        if field < acc then
            return list[i]
        end
    end
    return list[n]
end

-- The 25-biome LADDER (doc 21): family → its 5-rung tier list of biome ids (T1..T5). This is
-- the canonical grid the star palette draws from — a star's rolled {type,tier} biomes map
-- straight through here. Nine rungs reuse the legacy climate defs; the rest are authored above.
local LADDER: { [string]: { number } } = {
    Flora = { B_MEADOW,     B_FOREST,  B_JUNGLE,   B_ANCIENT_GROVE, B_WILDWOOD },
    Stone = { B_ROCKLAND,   B_CRAG,    B_HIGHLAND, B_PEAKS,         B_MONOLITHS },
    Sand  = { B_DUNES,      B_DESERT,  B_BADLANDS, B_MESA,          B_GLASS_SEA },
    Frost = { B_FROSTFIELD, B_TAIGA,   B_TUNDRA,   B_GLACIER,       B_AURORA_SHELF },
    Bog   = { B_MARSH,      B_SWAMP,   B_FEN,      B_MIRE,          B_SPORE_HOLLOW },
}

local function sampleHeightNoise(wx: number, wz: number): number
    -- 1) Very low freq = continents / big basins
    local cScale = 0.0004
    local continents = noise2D(BASE_SEED, wx * cScale, wz * cScale)

    -- mid-scale ridges (abs → ridged, ^3 → sharper peaks at top)
    local rScale = 0.0012
    local ridges = noise2D(BASE_SEED + 101, wx * rScale, wz * rScale)

    -- fine detail
    local dScale = 0.01
    local detail = noise2D(BASE_SEED + 202, wx * dScale, wz * dScale)

    local n =
        continents * 0.55 +
        ridges     * 0.35 +
        detail     * 0.1

    return spread(n01(n), 1.5) -- 0..1, stretched so highlands/peaks actually occur
end

local function sampleTempNoise(wx: number, wz: number): number
    -- smaller biomes → higher frequency
    local scale = 0.006 -- was 0.0015
    return spread(n01(noise2D(BASE_SEED + 300, wx * scale, wz * scale)), 1.9)
end

local function sampleHumidityNoise(wx: number, wz: number): number
    local scale = 0.007 -- was 0.0018
    return spread(n01(noise2D(BASE_SEED + 400, wx * scale, wz * scale)), 1.9)
end

local function pickBiome(temp: number, humid: number, baseHeight01: number): number
    -- High elevation overrides the climate grid.
    if baseHeight01 > 0.74 then
        return if temp < 0.35 then B_SNOWY_PEAKS else B_CRAG
    elseif baseHeight01 > 0.60 then
        return if temp < 0.35 then B_SNOW_HIGH else B_HIGHLAND
    end

    -- Lowland climate grid: temperature (rows) x humidity (cols), BoP-style.
    if temp < 0.30 then -- cold
        if humid < 0.35 then return B_COLD_DESERT
        elseif humid < 0.62 then return B_TUNDRA
        else return B_SNOWY_FOREST end
    elseif temp < 0.55 then -- cool
        if humid < 0.32 then return B_PLAINS
        elseif humid < 0.62 then return B_TAIGA
        else return B_SEASONAL end
    elseif temp < 0.78 then -- warm
        if humid < 0.30 then return B_SAVANNA
        elseif humid < 0.60 then return B_FOREST
        else return B_SWAMP end
    else -- hot
        if humid < 0.35 then return B_DESERT
        elseif humid < 0.62 then return B_SAVANNA
        else return B_JUNGLE end
    end
end

-- Star-aware biome pick: a bounded star uses its restricted region palette; the legacy
-- infinite world uses the climate grid.
local function resolveBiome(wx: number, wz: number, temp: number, humid: number, base01: number): number
    if starBiomes then
        return pickStarBiome(wx, wz)
    end
    return pickBiome(temp, humid, base01)
end

-- simple cave noise
local function sampleCaveNoise(wx: number, y: number, wz: number): number
    local scale = 0.035
    return noise3D(BASE_SEED + 500, wx * scale, y * scale, wz * scale)
end

-- Low-frequency 2D field marking scattered regions where caves are allowed to
-- breach the surface (cave entrances). Elsewhere caves stay capped underground.
local function sampleEntranceNoise(wx: number, wz: number): number
    local scale = 0.02
    return n01(noise2D(BASE_SEED + 600, wx * scale, wz * scale))
end

-- Cave carving parameters (module-level so client-side generation matches).
local CAVE_START_Y = 20
local CAVE_END_OFFSET = 6      -- caves stop this many blocks below the surface...
local CAVE_THRESHOLD = 0.45
local ENTRANCE_THRESHOLD = 0.62 -- ...except in these regions, where they open up

-- ===================== Trees (deterministic decoration) =====================
-- Trees are generated, not stored: both client & server derive them from coords.
-- The world is tiled into TREE_CELL×TREE_CELL cells; each cell has one hashed
-- candidate position. A candidate becomes a tree only in a grass biome above
-- water. blockAt() adds trunk/leaf blocks into the air above the surface, so the
-- mesher must raise its Y range by TREE_MAX_H over grass to fit the canopy.
local TREE_CELL = 5
local TREE_MAX_H = 10 -- tallest trunk (6) + canopy above (~3), + margin

local function hash2(x: number, z: number): number
    local h = bit32.band(x * 0x1f1f3d1f + z * 0x9e3779b1, 0xffffffff)
    h = bit32.bxor(h, bit32.rshift(h, 16))
    h = bit32.band(h * 0x85ebca6b, 0xffffffff)
    h = bit32.bxor(h, bit32.rshift(h, 13))
    return h
end

local function hash3(x: number, y: number, z: number): number
    return hash2(hash2(x, z) + y * 0x27d4eb2f, y)
end

-- Block a tree rooted at its origin contributes at offset (dx,dy,dz); dy is height
-- above the origin's surface. Trunk is a column; canopy is a trimmed sphere.
local function treeShape(dx: number, dy: number, dz: number, seed: number, wx: number, y: number, wz: number): number
    local H = 5 + (seed % 3) -- trunk height 5..7
    if dx == 0 and dz == 0 and dy >= 1 and dy <= H then
        return BLOCK.OakLog
    end
    -- Full, rounded canopy: a fat ellipsoid wrapping the top few trunk blocks
    -- (from 3 below the top to 2 above), only lightly trimmed at the very edge.
    local vy = dy - H
    if vy >= -3 and vy <= 2 then
        local d2 = dx * dx + dz * dz + vy * vy * 1.15
        local rad = 2.9
        if d2 <= rad * rad then
            if d2 > (rad - 0.8) * (rad - 0.8) and (hash3(wx, y, wz) % 100) < 22 then
                return BLOCK.Air
            end
            return BLOCK.OakLeaves
        end
    end
    return BLOCK.Air
end

-- Whether a grid cell holds a tree is fixed & expensive to decide (needs the
-- origin column's biome/height), so memoize it per cell. blockAt() hits the same
-- ~9 cells for every Y in a column, so this collapses thousands of getColumn calls
-- per chunk down to a couple dozen. Deterministic → the cache never invalidates.
type TreeInfo = { wx0: number, wz0: number, surf0: number, seed: number }
local treeCache: { [number]: { [number]: TreeInfo | false } } = {}
local treeCacheN = 0

local function treeAtCell(gx: number, gz: number): TreeInfo | false
    local col = treeCache[gx]
    if col then
        local c = col[gz]
        if c ~= nil then
            return c
        end
    else
        col = {}
        treeCache[gx] = col
    end

    local h = hash2(gx, gz)
    local result: TreeInfo | false = false
    if (h % 100) < 60 then -- cheap gate before the costlier column lookup
        local wx0 = gx * TREE_CELL + (h % TREE_CELL)
        local wz0 = gz * TREE_CELL + (math.floor(h / TREE_CELL) % TREE_CELL)
        local surf0, biome0 = WorldGen.getColumn(wx0, wz0)
        -- Per-biome density; nothing below water. (Grass/dirt-top biomes only —
        -- desert/stone/snow biomes have treeDensity 0.)
        if surf0 >= WATER_LEVEL and surf0 >= 55 then
            local density = Biomes[biome0].treeDensity
            if density > 0 and (math.floor(h / 100) % 100) < density then
                result = { wx0 = wx0, wz0 = wz0, surf0 = surf0, seed = h }
            end
        end
    end

    if treeCacheN > 20000 then
        table.clear(treeCache)
        treeCacheN = 0
        treeCache[gx] = col
    end
    col[gz] = result
    treeCacheN += 1
    return result
end

-- Tree block (or Air) at a world cell, scanning candidate trees in the 3×3 cell
-- neighbourhood (a canopy can reach a couple of blocks past its origin).
local function treeBlockAt(wx: number, y: number, wz: number): number
    local gx0 = math.floor(wx / TREE_CELL)
    local gz0 = math.floor(wz / TREE_CELL)
    for dgz = -1, 1 do
        for dgx = -1, 1 do
            local t = treeAtCell(gx0 + dgx, gz0 + dgz)
            if t then
                local b = treeShape(wx - t.wx0, y - t.surf0, wz - t.wz0, t.seed, wx, y, wz)
                if b ~= BLOCK.Air then
                    return b
                end
            end
        end
    end
    return BLOCK.Air
end

export type ChunkFull = {
    cx: number,
    cz: number,
    minY: number,           -- lowest surface height in the chunk
    maxY: number,           -- highest surface height in the chunk (buffer is maxY+1 tall)
    blocks: buffer,         -- dense, 1 byte per block, indexed by idx3(lx,y,lz, maxY+1)
}

local function computeColumnHeight(
    wx: number,
    wz: number,
    biomeId: number,
    base01: number
): number
    local biome = Biomes[biomeId]
    local range = biome.maxHeight - biome.minHeight

    -- Base height, flattened toward the low end by the biome's flatness exponent
    -- (plains/savanna stay low & smooth, forests/jungles roll more).
    local shaped = base01 ^ biome.flatness
    local h = biome.minHeight + shaped * range

    -- Medium-frequency bumps scaled by hilliness.
    h = h + noise2D(BASE_SEED + 901, wx * 0.018, wz * 0.018) * biome.hilliness

    -- Ridged peaks for mountains / highlands.
    if biome.ridged > 0 then
        h = h + math.abs(noise2D(BASE_SEED + 905, wx * 0.0025, wz * 0.0025)) ^ 3 * biome.ridged
    end

    -- Lakes / basins: flatten low-lying areas near water level (broad lakes, not
    -- jagged holes).
    if h < WATER_LEVEL - 4 then
        local t = math.clamp((WATER_LEVEL - 4 - h) / 16, 0, 1)
        h = h * (1 - t) + (WATER_LEVEL - 8) * t
    end

    -- Bounded star: taper the disc edge down into the void; beyond the rim there's nothing.
    if starRadius then
        local f = islandFactor(wx, wz)
        if f <= 0 then
            return -1 -- void column (no terrain here)
        end
        h = -1 + (h + 1) * f
    end

    if h < -1 then
        h = -1
    elseif h > WORLD_HEIGHT - 1 then
        h = WORLD_HEIGHT - 1
    end
    return math.floor(h)
end

function WorldGen.generateChunkFull(cx: number, cz: number): ChunkFull
    local heightFields = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)
    local biomeField  = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)

    -- 1) height + biome per (x,z)
    local minY = WORLD_HEIGHT - 1
    local maxY = 0
    for lz = 0, CHUNK_SIZE - 1 do
        for lx = 0, CHUNK_SIZE - 1 do
            local wx = cx * CHUNK_SIZE + lx
            local wz = cz * CHUNK_SIZE + lz

            local base01 = sampleHeightNoise(wx, wz)
            local temp   = sampleTempNoise(wx, wz)
            local humid  = sampleHumidityNoise(wx, wz)

            local biomeId = resolveBiome(wx, wz, temp, humid, base01)
            biomeField[lx + lz * CHUNK_SIZE + 1] = biomeId

            local height = computeColumnHeight(wx, wz, biomeId, base01)

            local i = lx + lz * CHUNK_SIZE + 1
            heightFields[i] = height

            if height >= 0 then -- skip star void columns (-1) so min/max stay sane
                if height < minY then minY = height end
                if height > maxY then maxY = height end
            end
        end
    end

    -- 2) dense block buffer, only as tall as the terrain in this chunk
    local chunkHeight = maxY + 1
    local blocks = buffer.create(CHUNK_SIZE * CHUNK_SIZE * chunkHeight)

    local CAVE_START_Y = 20
    local CAVE_END_OFFSET = 6 -- keep caves away from immediate surface
    local CAVE_THRESHOLD = 0.45

    for lz = 0, CHUNK_SIZE - 1 do
        for lx = 0, CHUNK_SIZE - 1 do
            local colIndex = lx + lz * CHUNK_SIZE + 1
            local surfaceY = heightFields[colIndex]
            local biomeId  = biomeField[colIndex]
            local biome    = Biomes[biomeId]

            local wx = cx * CHUNK_SIZE + lx
            local wz = cz * CHUNK_SIZE + lz

             local soilDepth = biome.soilDepth

            for y = 0, surfaceY do
                local blockId = BLOCK.Air

                 local isSurface = (y == surfaceY)
                local depthBelowSurface = surfaceY - y

                if isSurface then
                    -- Beaches / lowlands with sand
                    if surfaceY < 55 then
                        blockId = BLOCK.Sand
                    else
                        blockId = biome.top
                    end
                elseif depthBelowSurface <= soilDepth then
                    blockId = biome.under
                else
                    blockId = BLOCK.Stone
                end

                 if blockId == BLOCK.Stone and
                    y >= CAVE_START_Y and
                    y <= surfaceY - CAVE_END_OFFSET then

                    local caveN = sampleCaveNoise(wx, y, wz)
                    -- math.noise is [-1,1], so check > threshold
                    if caveN > CAVE_THRESHOLD then
                        blockId = BLOCK.Air
                    end
                end

                if blockId ~= BLOCK.Air then
                    local linear = idx3(lx, y, lz, chunkHeight) -- 0-based buffer offset
                    buffer.writeu8(blocks, linear, blockId)
                end

            end
        end
    end
    return {
        cx = cx,
        cz = cz,
        minY = minY,
        maxY = maxY,
        blocks = blocks,
    }

end

-- Deterministic surface height (in block units) for a world column.
-- Shared by server & client so both agree on where the ground is without any data transfer.
function WorldGen.getSurfaceHeight(wx: number, wz: number): number
    if baked then
        return baked.columnTop(wx, wz)
    end
    local base01 = sampleHeightNoise(wx, wz)
    local temp   = sampleTempNoise(wx, wz)
    local humid  = sampleHumidityNoise(wx, wz)
    local biomeId = resolveBiome(wx, wz, temp, humid, base01)
    return computeColumnHeight(wx, wz, biomeId, base01)
end

-- Surface height AND biome for a column, computed together (the biome is needed
-- for materials and comes for free while computing the height). This is the basis
-- for client-side generation: the server only has to send chunk coordinates.
function WorldGen.getColumn(wx: number, wz: number): (number, number)
    if baked then
        return baked.columnTop(wx, wz), B_IMPORTED
    end
    local base01 = sampleHeightNoise(wx, wz)
    local temp   = sampleTempNoise(wx, wz)
    local humid  = sampleHumidityNoise(wx, wz)
    local biomeId = resolveBiome(wx, wz, temp, humid, base01)
    return computeColumnHeight(wx, wz, biomeId, base01), biomeId
end

-- Material of a solid cell, given its column's surface height + biome. Caves are
-- intentionally ignored: they sit >= CAVE_END_OFFSET below the surface, are fully
-- internal, and never appear in the meshed surface shell.
function WorldGen.materialAt(y: number, surfaceY: number, biomeId: number): number
    if baked then
        -- No column coords here, so this can only answer the shape question. Baked
        -- callers use blockAt(); this stays honest about solid-vs-air.
        return if y > surfaceY then BLOCK.Air else BLOCK.Stone
    end
    if y > surfaceY then
        return BLOCK.Air
    end
    local biome = Biomes[biomeId]
    if y == surfaceY then
        if surfaceY < 55 then
            return BLOCK.Sand
        end
        return biome.top
    elseif (surfaceY - y) <= biome.soilDepth then
        return biome.under
    end
    return BLOCK.Stone
end

-- Full cave-aware block at a cell (carves caves out of the terrain). Used by the
-- client to render the true 3D terrain (surface + caves) with no data transfer.
function WorldGen.blockAt(wx: number, y: number, wz: number, surfaceY: number, biomeId: number): number
    if baked then
        return baked.blockAt(wx, y, wz)
    end
    local mat = WorldGen.materialAt(y, surfaceY, biomeId)
    if mat == BLOCK.Air then
        -- air above the surface: a tree (trunk/leaves) may occupy this cell
        return treeBlockAt(wx, y, wz)
    end
    if y < CAVE_START_Y then
        return mat
    end
    -- In entrance regions the carve reaches the surface and cuts through soil too,
    -- so caves open to the sky; elsewhere they stay capped a few blocks down and
    -- only hollow out stone.
    local entrance = sampleEntranceNoise(wx, wz) > ENTRANCE_THRESHOLD
    local caveTop = if entrance then surfaceY else surfaceY - CAVE_END_OFFSET
    if y <= caveTop and (entrance or mat == BLOCK.Stone) then
        if sampleCaveNoise(wx, y, wz) > CAVE_THRESHOLD then
            return BLOCK.Air
        end
    end
    return mat
end

-- Biome grass tint (nil for non-grass biomes), for the mesher to colour grass.
function WorldGen.biomeGrassColor(biomeId: number): Color3?
    local b = Biomes[biomeId]
    return if b then b.grass else nil
end

-- Biomes that grow trees (treeDensity > 0), so the mesher only extends its Y
-- range for canopies where trees can actually appear.
local TREE_BIOMES: { [number]: boolean } = {}
for id, b in Biomes do
    if b.treeDensity > 0 then
        TREE_BIOMES[id] = true
    end
end
WorldGen.TREE_BIOMES = TREE_BIOMES

-- ---- bounded-star config (doc 21): both server + client call the SAME applyStar ----
function WorldGen.applyStar(seed: number, radiusBlocks: number, biomeIds: { number })
    baked = nil -- a generated star replaces any baked one
    BASE_SEED = seed
    starRadius = radiusBlocks
    starBiomes = biomeIds
    table.clear(treeCache) -- seed changed → old tree decisions are stale
    treeCacheN = 0
end

-- CANONICAL palette entry (doc 21): the universe's rolled `{type,tier}` biomes → ladder ids.
-- Sorted low-tier → high-tier so the common rungs cover the disc and the rare rung is central
-- (see pickStarBiome). `applyStarByTypes` is the tier-less fallback for direct/Studio joins.
export type StarBiome = { type: string, tier: number }
function WorldGen.applyStarByBiomes(seed: number, radiusBlocks: number, biomes: { StarBiome })
    local sorted = table.clone(biomes)
    table.sort(sorted, function(a, b)
        return a.tier < b.tier
    end)
    local ids: { number } = {}
    for _, b in sorted do
        local rung = LADDER[b.type]
        ids[#ids + 1] = (rung and rung[b.tier]) or B_MEADOW
    end
    if #ids == 0 then
        ids[1] = B_MEADOW
    end
    WorldGen.applyStar(seed, radiusBlocks, ids)
end

-- Tier-less fallback: each rolled TYPE becomes its classic T2 rung (used when only the star's
-- resource types are known — e.g. a direct/Studio join with no per-biome tier data).
function WorldGen.applyStarByTypes(seed: number, radiusBlocks: number, types: { string })
    local biomes: { StarBiome } = {}
    for _, t in types do
        biomes[#biomes + 1] = { type = t, tier = 2 }
    end
    WorldGen.applyStarByBiomes(seed, radiusBlocks, biomes)
end

-- ---- baked star (doc 23): terrain comes from an imported blob, not from noise ----
-- Takes an already-built map because the two sides build theirs differently: the
-- server opens the blob it holds privately in ServerStorage, the client starts with
-- an empty receiver and is fed chunks as it walks. Everything downstream of here is
-- identical either way.
function WorldGen.applyPrebaked(map: PrebakedMap.Map)
    baked = map
    starRadius = map.radius -- bounded like any star (spawn/lock code asks isStar())
    starBiomes = nil
    table.clear(treeCache)
    treeCacheN = 0
end

-- The active baked map, for the systems that stream it (nil on a generated star).
function WorldGen.bakedMap(): PrebakedMap.Map?
    return baked
end

-- Lowest y the mesher needs to look at for a chunk; below it the world is solid
-- and invisible. Procedurally the answer is the cave floor. A baked map knows
-- better — its columns record where the island interior starts — and answering
-- honestly is worth a lot, because a map whose sea level sits high would
-- otherwise have every chunk scan ~70 levels of nothing. The 3×3 neighbourhood
-- is taken so the mesher's one-block border into adjacent chunks stays truthful
-- (a lower neighbour must not get culled away as "solid").
function WorldGen.meshFloor(cx: number, cz: number): number
    if not baked then
        return CAVE_START_Y - 1
    end
    local map = baked :: PrebakedMap.Map
    local lo = 255
    for dz = -1, 1 do
        for dx = -1, 1 do
            local f = map.chunkFloor(cx + dx, cz + dz)
            if f < lo then
                lo = f
            end
        end
    end
    return math.max(0, lo - 1)
end

function WorldGen.isBaked(): boolean
    return baked ~= nil
end

function WorldGen.bakedName(): string?
    return if baked then baked.name else nil
end

function WorldGen.isStar(): boolean
    return starRadius ~= nil
end

WorldGen.CAVE_START_Y = CAVE_START_Y
WorldGen.TREE_MAX_H = TREE_MAX_H
WorldGen.CHUNK_SIZE = CHUNK_SIZE
WorldGen.WORLD_HEIGHT = WORLD_HEIGHT
WorldGen.BLOCK_SIZE = BLOCK_SIZE

return WorldGen
