-- ReplicatedStorage/WorldGen.luau
--!strict

local WorldGen = {}

local CHUNK_SIZE = 16
local WORLD_HEIGHT = 256
local BASE_SEED = 1337

WorldGen.BLOCK = {
    Air   = 0,
    Grass = 1,
    Dirt  = 2,
    Sand  = 3,
    Stone = 4,
}

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

local Biomes = {
    [1] = { name = "Plains", top = 1, under = 2 },
    [2] = { name = "Desert", top = 3, under = 3 },
    [3] = { name = "Forest", top = 1, under = 2 },
}

local function pickBiome(temp: number, humid: number, height01: number): number
    if temp > 0.7 and humid < 0.4 then
        return 2
    elseif humid > 0.6 then
        return 3
    else
        return 1
    end
end

local function sampleHeightNoise(wx: number, wz: number): number
    local scale = 0.005
    local continents = noise2D(BASE_SEED, wx * scale, wz * scale)
    local detail     = noise2D(BASE_SEED + 100, wx * scale * 4, wz * scale * 4)
    return n01(continents * 0.7 + detail * 0.3)
end

local function sampleTempNoise(wx: number, wz: number): number
    local scale = 0.002
    return n01(noise2D(BASE_SEED + 200, wx * scale, wz * scale))
end

local function sampleHumidityNoise(wx: number, wz: number): number
    local scale = 0.0025
    return n01(noise2D(BASE_SEED + 300, wx * scale, wz * scale))
end

export type ChunkFull = {
    cx: number,
    cz: number,
    blocks: { [number]: number }, -- key = u32 index, value = blockId
}

function WorldGen.generateChunkFull(cx: number, cz: number): ChunkFull
    local heightField = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)
    local biomeField  = table.create(CHUNK_SIZE * CHUNK_SIZE, 0)

    local minH, maxH = 40, 120

    -- 1) height + biome per (x,z)
    for lz = 0, CHUNK_SIZE - 1 do
        for lx = 0, CHUNK_SIZE - 1 do
            local wx = cx * CHUNK_SIZE + lx
            local wz = cz * CHUNK_SIZE + lz

            local hNoise = sampleHeightNoise(wx, wz)
            local temp   = sampleTempNoise(wx, wz)
            local humid  = sampleHumidityNoise(wx, wz)

            local height = math.floor(minH + hNoise * (maxH - minH))
            if height < 0 then height = 0 end
            if height > WORLD_HEIGHT - 1 then height = WORLD_HEIGHT - 1 end

            local i = lx + lz * CHUNK_SIZE + 1
            heightField[i] = height

            local biomeId = pickBiome(temp, humid, hNoise)
            biomeField[i]  = biomeId
        end
    end

    -- 2) full 3D, but sparse: only store non-air
    local blocks: { [number]: number } = {}

    for lz = 0, CHUNK_SIZE - 1 do
        for lx = 0, CHUNK_SIZE - 1 do
            local colIndex = lx + lz * CHUNK_SIZE + 1
            local height = heightField[colIndex]
            local biome  = Biomes[biomeField[colIndex]]

            for y = 0, WORLD_HEIGHT - 1 do
                local blockId = WorldGen.BLOCK.Air

                if y <= height then
                    if y == height then
                        blockId = biome.top
                    elseif y >= height - 3 then
                        blockId = biome.under
                    else
                        blockId = WorldGen.BLOCK.Stone
                    end
                end

                if blockId ~= WorldGen.BLOCK.Air then
                    -- choose 0-based or 1-based key, but be consistent!
                    local linear = idx3(lx, y, lz) -- 0-based
                    blocks[linear] = blockId
                end
            end
        end
    end

    return {
        cx = cx,
        cz = cz,
        blocks = blocks,
    }
end

WorldGen.CHUNK_SIZE = CHUNK_SIZE
WorldGen.WORLD_HEIGHT = WORLD_HEIGHT

return WorldGen
