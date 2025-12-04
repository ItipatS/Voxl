-- WorldGen.luau
--!strict
local Biome = require(script.Biome)

-- ReplicatedStorage/WorldGen.luau
--!strict

local WorldGen = {}

local CHUNK_SIZE = 16
local WORLD_HEIGHT = 256
local BASE_SEED = 1337

local function idx2(x: number, z: number): number
    return x + z * CHUNK_SIZE + 1
end

local function n01(n: number): number
    return 0.5 * (n + 1)
end

local function noise2D(seed: number, x: number, z: number): number
    return math.noise(x + seed * 13.37, z + seed * 42.69)
end

local function sampleHeight(wx: number, wz: number): number
    local scale = 0.005
    local continents = noise2D(BASE_SEED, wx * scale, wz * scale)
    local detail     = noise2D(BASE_SEED + 100, wx * scale * 4, wz * scale * 4)
    return n01(continents * 0.7 + detail * 0.3)
end

local function sampleTemp(wx: number, wz: number): number
    local scale = 0.002
    return n01(noise2D(BASE_SEED + 200, wx * scale, wz * scale))
end

local function sampleHumidity(wx: number, wz: number): number
    local scale = 0.0025
    return n01(noise2D(BASE_SEED + 300, wx * scale, wz * scale))
end

export type ChunkFields = {
    cx: number,
    cz: number,
    heightField: { number }, -- u16-ish
    biomeField: { number },  -- u8
}

function WorldGen.generateChunkFields(cx: number, cz: number): ChunkFields
    local heightField = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)
    local biomeField  = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)

    local minH, maxH = 40, 120

    for lz = 0, CHUNK_SIZE - 1 do
        for lx = 0, CHUNK_SIZE - 1 do
            local wx = cx * CHUNK_SIZE + lx
            local wz = cz * CHUNK_SIZE + lz

            local hNoise = sampleHeight(wx, wz)
            local temp   = sampleTemp(wx, wz)
            local humid  = sampleHumidity(wx, wz)

            local height = math.floor(minH + hNoise * (maxH - minH))
            if height < 0 then height = 0 end
            if height > WORLD_HEIGHT - 1 then height = WORLD_HEIGHT - 1 end

            local biomeId = Biome.pickBiome(temp, humid, hNoise)

            local i = idx2(lx, lz)
            heightField[i] = height
            biomeField[i]  = biomeId
        end
    end

    return {
        cx = cx,
        cz = cz,
        heightField = heightField,
        biomeField  = biomeField,
    }
end

WorldGen.CHUNK_SIZE = CHUNK_SIZE
WorldGen.WORLD_HEIGHT = WORLD_HEIGHT

return WorldGen
