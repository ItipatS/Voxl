-- ReplicatedStorage/WorldGen.luau
--!strict

local WorldGen = {}

local CHUNK_SIZE = 16
local WORLD_HEIGHT = 256
local BLOCK_SIZE = 3.5

local BASE_SEED = 1339

WorldGen.BLOCK = {
    Air   = 0,
    Grass = 1,
    Dirt  = 2,
    Sand  = 3,
    Stone = 4,
    Snow = 5
}
local WATER_LEVEL = 60

local BLOCK = WorldGen.BLOCK

local function idx3(x: number, y: number, z: number): number
    -- (x,z) ∈ [0,15], y ∈ [0, WORLD_HEIGHT-1]
    return x + (y * CHUNK_SIZE) + (z * CHUNK_SIZE * WORLD_HEIGHT)
    -- note: 0-based index here, Blink key is u32, Lua key = idx+1 or idx, your choice
end

local function n01(n: number): number
    return 0.5 * (n + 1)
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
}

local Biomes: { [number]: BiomeDef } = {
    [1] = { -- Plains
        name = "Plains",
        top = BLOCK.Grass,
        under = BLOCK.Dirt,
        soilDepth = 4,
        minHeight = 58,
        maxHeight = 72,
    },

    [2] = { -- Desert
        name = "Desert",
        top = BLOCK.Sand,
        under = BLOCK.Sand,
        soilDepth = 5,
        minHeight = 56,
        maxHeight = 70,
    },

    [3] = { -- Forest
        name = "Forest",
        top = BLOCK.Grass,
        under = BLOCK.Dirt,
        soilDepth = 5,
        minHeight = 60,
        maxHeight = 85,
    },

    [4] = { -- Mountains
        name = "Mountains",
        top = BLOCK.Stone,
        under = BLOCK.Stone,
        soilDepth = 3,
        minHeight = 90,
        maxHeight = 155,   -- before was 200
    },

    [5] = { -- Snow Highlands
        name = "SnowHighlands",
        top = BLOCK.Snow,
        under = BLOCK.Stone,
        soilDepth = 3,
        minHeight = 120,
        maxHeight = 190,   -- before was 240
    },
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
    
    return n01(n) -- 0..1
end

local function sampleTempNoise(wx: number, wz: number): number
    -- smaller biomes → higher frequency
    local scale = 0.006 -- was 0.0015
    return n01(noise2D(BASE_SEED + 300, wx * scale, wz * scale))
end

local function sampleHumidityNoise(wx: number, wz: number): number
    local scale = 0.007 -- was 0.0018
    return n01(noise2D(BASE_SEED + 400, wx * scale, wz * scale))
end

local function pickBiome(temp: number, humid: number, baseHeight01: number): number
    -- high alt → mountains / snow
    if baseHeight01 > 0.55 then
        if temp < 0.45 then
            return 5 -- SnowHighlands
        else
            return 4 -- Mountains
        end
    end

    -- hot & dry → desert
    if temp > 0.7 and humid < 0.4 then
        return 2 -- Desert
    end

    -- wet → forest
    if humid > 0.6 then
        return 3 -- Forest
    end

    -- default → plains
    return 1
end

-- simple cave noise
local function sampleCaveNoise(wx: number, y: number, wz: number): number
    local scale = 0.035
    return noise3D(BASE_SEED + 500, wx * scale, y * scale, wz * scale)
end

export type ChunkFull = {
    cx: number,
    cz: number,
    blocks: { [number]: number }, -- key = u32 index, value = blockId
    heightfields: { [number]: number },
}

local function computeColumnHeight(
    wx: number,
    wz: number,
    biomeId: number,
    base01: number
): number
    local biome = Biomes[biomeId]

    -- Base height within biome range
    local h = biome.minHeight + base01 * (biome.maxHeight - biome.minHeight)

    -- ==== Biome-specific shaping ====

    -- Plains → very smooth, gentle rolling
    if biomeId == 1 then -- Plains
        local smooth = n01(noise2D(BASE_SEED + 901, wx * 0.003, wz * 0.003))
        smooth = smooth ^ 2            -- more flat, bumps mostly in mid
        h = biome.minHeight + smooth * (biome.maxHeight - biome.minHeight)
    end

    -- Desert → low variation + dunes
    if biomeId == 2 then -- Desert
        -- Big flat-ish desert floor
        local desertBase = n01(noise2D(BASE_SEED + 902, wx * 0.002, wz * 0.002))
        h = biome.minHeight + desertBase * (biome.maxHeight - biome.minHeight)

        -- Dunes: directional medium-frequency waves
        local dune = noise2D(BASE_SEED + 903, wx * 0.015, wz * 0.005)
        h = h + dune * 6 -- +/- 6 blocks of dunes
    end

    -- Forest → a bit rougher than plains, but still climbable
    if biomeId == 3 then -- Forest
        local rough = n01(noise2D(BASE_SEED + 904, wx * 0.004, wz * 0.004))
        rough = rough ^ 1.5
        h = biome.minHeight + rough * (biome.maxHeight - biome.minHeight)
    end

    -- Mountains (stone) → use ridged/mountain noise extra
    if biomeId == 4 then -- Mountains
        local ridged = math.abs(noise2D(BASE_SEED + 905, wx * 0.002, wz * 0.002)) ^ 3
        h = h + ridged * 40  -- was 80, now 40 for 256 world height
    end

    if biomeId == 5 then -- SnowHighlands
        local ridged = math.abs(noise2D(BASE_SEED + 906, wx * 0.002, wz * 0.002)) ^ 4
        h = h + ridged * 60  -- was 120, now 60
    end

    -- Lakes / basins: flatten low-lying areas near water level
    -- (This keeps broad lakes instead of jagged, noisy holes.)
    if h < WATER_LEVEL - 4 then
        -- Blend upwards a bit so bottoms aren't crazy noisy
        local t = (WATER_LEVEL - 4 - h) / 16 -- how far below lake floor
        t = math.clamp(t, 0, 1)
        h = h * (1 - t) + (WATER_LEVEL - 8) * t
    end

    -- Clamp to world
    if h < 0 then
        h = 0
    end
    if h > WORLD_HEIGHT - 1 then
        h = WORLD_HEIGHT - 1
    end

    return math.floor(h)
end

function WorldGen.generateChunkFull(cx: number, cz: number): ChunkFull
    local heightFields = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)
    local biomeField  = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)

    -- 1) height + biome per (x,z)
    for lz = 0, CHUNK_SIZE - 1 do
        for lx = 0, CHUNK_SIZE - 1 do
            local wx = cx * CHUNK_SIZE + lx
            local wz = cz * CHUNK_SIZE + lz

            local base01 = sampleHeightNoise(wx, wz)
            local temp   = sampleTempNoise(wx, wz)
            local humid  = sampleHumidityNoise(wx, wz)

            local biomeId = pickBiome(temp, humid, base01)
            biomeField[lx + lz * CHUNK_SIZE + 1] = biomeId

            local height = computeColumnHeight(wx, wz, biomeId, base01)

            local i = lx + lz * CHUNK_SIZE + 1
            heightFields[i] = height
        end
    end

    -- 2) full 3D, but sparse: only store non-air
    local blocks: { [number]: number } = {}

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
                    local linear = idx3(lx, y, lz) -- 0-based key
                    blocks[linear] = blockId
                end

            end
        end
    end
    return {
        cx = cx,
        cz = cz,
        blocks = blocks,
        heightfields = heightFields,
    }
    
end

WorldGen.CHUNK_SIZE = CHUNK_SIZE
WorldGen.WORLD_HEIGHT = WORLD_HEIGHT
WorldGen.BLOCK_SIZE = BLOCK_SIZE

return WorldGen
