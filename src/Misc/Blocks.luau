-- ReplicatedStorage/Misc/Blocks.luau
--!strict

-- SINGLE SOURCE OF TRUTH for every block: id + appearance + behaviour. Adding a
-- block is one entry in `defs` (+ its texture ids in `TEX`). WorldGen, the mesher,
-- editing and the UI all read from here — nothing else hardcodes block data.
--
-- Fill textures marked `FILL` with your uploaded asset ids. See docs/BLOCKS.md for
-- the full wishlist (what textures each block needs + which are non-cube plants).

local Blocks = {}

-- ===== ids (APPEND-ONLY — persisted in worlds & inventories; never renumber) =====
local ID = {
    Air = 0,
    -- original set
    Grass = 1, Dirt = 2, Sand = 3, Stone = 4, Snow = 5, OakLog = 6, OakLeaves = 7,
    -- soils
    CoarseDirt = 8, Podzol = 9, Mud = 10, MossBlock = 11,
    -- sands / desert
    RedSand = 12, Sandstone = 13, RedSandstone = 14, Terracotta = 15,
    -- stones
    Cobblestone = 16, Granite = 17, Diorite = 18, Andesite = 19, Gravel = 20, Clay = 21,
    -- ice
    Ice = 22, PackedIce = 23,
    -- woods (log + leaves pairs)
    BirchLog = 24, BirchLeaves = 25, SpruceLog = 26, SpruceLeaves = 27,
    JungleLog = 28, JungleLeaves = 29, AcaciaLog = 30, AcaciaLeaves = 31,
    -- ores (in stone)
    CoalOre = 32, IronOre = 33, CopperOre = 34, GoldOre = 35, DiamondOre = 36, EmeraldOre = 37,
    -- light emitters
    Glowstone = 38,
}
Blocks.ID = ID

-- ===== texture asset ids ("FILL" = replace with your upload) =====
local FILL = "rbxassetid://78128038044643" -- debug texture; stands in until filled
local TEX = {
    -- filled
    grassTop = "rbxassetid://99956800911799",
    grassSide = "rbxassetid://108714877040603",
    dirt = "rbxassetid://112826071106637",
    sand = "rbxassetid://75605206965672",
    stone = "rbxassetid://84046704582684",
    snow = "rbxassetid://121040441244210",
    oakTop = "rbxassetid://105200585443073",
    oakSide = "rbxassetid://120664114630276",
    oakLeaf = "rbxassetid://104131890534229",
    -- TODO: fill these
    coarseDirt = FILL, podzolTop = FILL, podzolSide = FILL, mud = FILL, mossBlock = FILL,
    redSand = FILL, sandstoneTop = FILL, sandstoneSide = FILL, redSandstoneTop = FILL,
    redSandstoneSide = FILL, terracotta = FILL,
    cobblestone = FILL, granite = FILL, diorite = FILL, andesite = FILL, gravel = FILL, clay = FILL,
    ice = FILL, packedIce = FILL,
    birchTop = FILL, birchSide = FILL, birchLeaf = FILL,
    spruceTop = FILL, spruceSide = FILL, spruceLeaf = FILL,
    jungleTop = FILL, jungleSide = FILL, jungleLeaf = FILL,
    acaciaTop = FILL, acaciaSide = FILL, acaciaLeaf = FILL,
    coalOre = FILL, ironOre = FILL, copperOre = FILL, goldOre = FILL, diamondOre = FILL, emeraldOre = FILL,
    glowstone = FILL,
}
Blocks.TEX = TEX

local C = Color3.fromRGB

export type BlockDef = {
    name: string,
    tex: { top: string, side: string, bottom: string }, -- per-face textures
    color: Color3, -- fill / fallback tint
    material: Enum.Material,
    render: string?, -- "cube" (default); "cross"/"vine"/"hang"/"fluid" arrive later
    opaque: boolean?, -- default true; false = neighbours behind it render (leaves/glass)
    alpha: number?, -- part transparency (1 = cutout via texture alpha)
    solid: boolean?, -- default true (collision)
    placeable: boolean?, -- player may place it
    tintGrass: boolean?, -- top tinted by the biome grass colour
    light: number?, -- 0..15 emission (for the future lighting pass)
}

local function cube(top: string, side: string, bottom: string)
    return { top = top, side = side, bottom = bottom }
end
local function uniform(t: string)
    return { top = t, side = t, bottom = t }
end

local W = Enum.Material.Wood
local defs: { [number]: BlockDef } = {
    [ID.Grass] = { name = "Grass", tex = cube(TEX.grassTop, TEX.grassSide, TEX.dirt), color = C(127, 178, 56), material = Enum.Material.Grass, placeable = true, tintGrass = true },
    [ID.Dirt] = { name = "Dirt", tex = uniform(TEX.dirt), color = C(140, 100, 70), material = Enum.Material.Ground, placeable = true },
    [ID.Sand] = { name = "Sand", tex = uniform(TEX.sand), color = C(235, 225, 180), material = Enum.Material.Sand, placeable = true },
    [ID.Stone] = { name = "Stone", tex = uniform(TEX.stone), color = C(130, 130, 130), material = Enum.Material.Slate, placeable = true },
    [ID.Snow] = { name = "Snow", tex = uniform(TEX.snow), color = C(255, 255, 255), material = Enum.Material.Snow, placeable = true },
    [ID.OakLog] = { name = "Oak Log", tex = cube(TEX.oakTop, TEX.oakSide, TEX.oakTop), color = C(255, 255, 255), material = W, placeable = true },
    [ID.OakLeaves] = { name = "Oak Leaves", tex = uniform(TEX.oakLeaf), color = C(255, 255, 255), material = Enum.Material.LeafyGrass, placeable = true, opaque = false, alpha = 1 },

    [ID.CoarseDirt] = { name = "Coarse Dirt", tex = uniform(TEX.coarseDirt), color = C(120, 90, 64), material = Enum.Material.Ground, placeable = true },
    [ID.Podzol] = { name = "Podzol", tex = cube(TEX.podzolTop, TEX.podzolSide, TEX.dirt), color = C(90, 64, 30), material = Enum.Material.Ground, placeable = true },
    [ID.Mud] = { name = "Mud", tex = uniform(TEX.mud), color = C(60, 52, 50), material = Enum.Material.Mud, placeable = true },
    [ID.MossBlock] = { name = "Moss Block", tex = uniform(TEX.mossBlock), color = C(90, 120, 60), material = Enum.Material.Grass, placeable = true },
    [ID.RedSand] = { name = "Red Sand", tex = uniform(TEX.redSand), color = C(190, 100, 50), material = Enum.Material.Sand, placeable = true },
    [ID.Sandstone] = { name = "Sandstone", tex = cube(TEX.sandstoneTop, TEX.sandstoneSide, TEX.sandstoneTop), color = C(220, 205, 160), material = Enum.Material.Sandstone, placeable = true },
    [ID.RedSandstone] = { name = "Red Sandstone", tex = cube(TEX.redSandstoneTop, TEX.redSandstoneSide, TEX.redSandstoneTop), color = C(190, 100, 50), material = Enum.Material.Sandstone, placeable = true },
    [ID.Terracotta] = { name = "Terracotta", tex = uniform(TEX.terracotta), color = C(150, 90, 65), material = Enum.Material.Brick, placeable = true },
    [ID.Cobblestone] = { name = "Cobblestone", tex = uniform(TEX.cobblestone), color = C(120, 120, 120), material = Enum.Material.Cobblestone, placeable = true },
    [ID.Granite] = { name = "Granite", tex = uniform(TEX.granite), color = C(160, 110, 90), material = Enum.Material.Granite, placeable = true },
    [ID.Diorite] = { name = "Diorite", tex = uniform(TEX.diorite), color = C(200, 200, 200), material = Enum.Material.Rock, placeable = true },
    [ID.Andesite] = { name = "Andesite", tex = uniform(TEX.andesite), color = C(140, 140, 140), material = Enum.Material.Rock, placeable = true },
    [ID.Gravel] = { name = "Gravel", tex = uniform(TEX.gravel), color = C(130, 125, 120), material = Enum.Material.Pebble, placeable = true },
    [ID.Clay] = { name = "Clay", tex = uniform(TEX.clay), color = C(160, 165, 170), material = Enum.Material.Sand, placeable = true },
    [ID.Ice] = { name = "Ice", tex = uniform(TEX.ice), color = C(200, 225, 255), material = Enum.Material.Glacier, placeable = true, opaque = false, alpha = 0.35 },
    [ID.PackedIce] = { name = "Packed Ice", tex = uniform(TEX.packedIce), color = C(180, 210, 245), material = Enum.Material.Glacier, placeable = true },

    [ID.BirchLog] = { name = "Birch Log", tex = cube(TEX.birchTop, TEX.birchSide, TEX.birchTop), color = C(255, 255, 255), material = W, placeable = true },
    [ID.BirchLeaves] = { name = "Birch Leaves", tex = uniform(TEX.birchLeaf), color = C(255, 255, 255), material = Enum.Material.LeafyGrass, placeable = true, opaque = false, alpha = 1 },
    [ID.SpruceLog] = { name = "Spruce Log", tex = cube(TEX.spruceTop, TEX.spruceSide, TEX.spruceTop), color = C(255, 255, 255), material = W, placeable = true },
    [ID.SpruceLeaves] = { name = "Spruce Leaves", tex = uniform(TEX.spruceLeaf), color = C(255, 255, 255), material = Enum.Material.LeafyGrass, placeable = true, opaque = false, alpha = 1 },
    [ID.JungleLog] = { name = "Jungle Log", tex = cube(TEX.jungleTop, TEX.jungleSide, TEX.jungleTop), color = C(255, 255, 255), material = W, placeable = true },
    [ID.JungleLeaves] = { name = "Jungle Leaves", tex = uniform(TEX.jungleLeaf), color = C(255, 255, 255), material = Enum.Material.LeafyGrass, placeable = true, opaque = false, alpha = 1 },
    [ID.AcaciaLog] = { name = "Acacia Log", tex = cube(TEX.acaciaTop, TEX.acaciaSide, TEX.acaciaTop), color = C(255, 255, 255), material = W, placeable = true },
    [ID.AcaciaLeaves] = { name = "Acacia Leaves", tex = uniform(TEX.acaciaLeaf), color = C(255, 255, 255), material = Enum.Material.LeafyGrass, placeable = true, opaque = false, alpha = 1 },

    [ID.CoalOre] = { name = "Coal Ore", tex = uniform(TEX.coalOre), color = C(60, 60, 60), material = Enum.Material.Slate, placeable = true },
    [ID.IronOre] = { name = "Iron Ore", tex = uniform(TEX.ironOre), color = C(180, 150, 130), material = Enum.Material.Slate, placeable = true },
    [ID.CopperOre] = { name = "Copper Ore", tex = uniform(TEX.copperOre), color = C(190, 120, 90), material = Enum.Material.Slate, placeable = true },
    [ID.GoldOre] = { name = "Gold Ore", tex = uniform(TEX.goldOre), color = C(220, 190, 90), material = Enum.Material.Slate, placeable = true },
    [ID.DiamondOre] = { name = "Diamond Ore", tex = uniform(TEX.diamondOre), color = C(120, 220, 220), material = Enum.Material.Slate, placeable = true },
    [ID.EmeraldOre] = { name = "Emerald Ore", tex = uniform(TEX.emeraldOre), color = C(80, 200, 120), material = Enum.Material.Slate, placeable = true },

    [ID.Glowstone] = { name = "Glowstone", tex = uniform(TEX.glowstone), color = C(255, 220, 140), material = Enum.Material.Neon, placeable = true, light = 15 },
}
Blocks.defs = defs

-- ===== queries used across the codebase =====
function Blocks.def(id: number): BlockDef?
    return defs[id]
end

-- Does this block hide the neighbour face touching it? (Air + transparent = no.)
function Blocks.isOpaque(id: number): boolean
    if id == ID.Air then
        return false
    end
    local d = defs[id]
    return d ~= nil and d.opaque ~= false
end

function Blocks.isPlaceable(id: number): boolean
    local d = defs[id]
    return d ~= nil and d.placeable == true
end

-- id -> {top, bottom, side} (mesher/hotbar previews).
local BlockTextures: { [number]: { top: string, bottom: string, side: string } } = {}
for id, d in defs do
    BlockTextures[id] = { top = d.tex.top, bottom = d.tex.bottom, side = d.tex.side }
end
Blocks.BlockTextures = BlockTextures

return Blocks
