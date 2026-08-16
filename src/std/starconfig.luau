--!strict
-- Which star the Star (ResourceStar) place should generate. The place hosts ONE star at a
-- time (single-live, keyed by starId — the server routing is MemoryStore, doc 06/15). The
-- server publishes the visited star's config via ReplicatedStorage attributes; both server
-- and client call `WorldGen.applyStarByBiomes(get())` so the client-generated terrain matches.
--
-- The config carries the star's rolled BIOME MIX (`{type,tier}` per featured resource, from
-- std/universe) — tier is what selects the ladder rung (doc 21), so it must survive the trip.
-- For now `get()` falls back to a fixed TEST star so the place is playable without the full
-- teleport flow. The biome list is serialised into one attribute as "type:tier,type:tier".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGen = require(ReplicatedStorage.Misc.WorldGen)
local PrebakedMap = require(ReplicatedStorage.Misc.PrebakedMap)

local M = {}

export type StarBiome = { type: string, tier: number }
-- `map` names a BAKED world under Misc.MapData (doc 23). When set it replaces
-- procedural generation entirely — seed/radius/biomes are then ignored, because
-- the terrain is imported rather than rolled.
export type StarCfg = { seed: number, radius: number, biomes: { StarBiome }, map: string? }

-- Fallback TEST star until a real one is set. radius in BLOCKS (footprint ≈ 2×). A mixed set
-- (T2 Flora rim, a T1 Stone patch, a rarer T3 Bog core) so the ladder + placement are visible. [TUNE]
M.TEST = {
	seed = 424242,
	radius = 96,
	biomes = { { type = "Flora", tier = 2 }, { type = "Stone", tier = 1 }, { type = "Bog", tier = 3 } },
} :: StarCfg

local function encode(biomes: { StarBiome }): string
	local parts: { string } = {}
	for _, b in biomes do
		parts[#parts + 1] = `{b.type}:{b.tier}`
	end
	return table.concat(parts, ",")
end

local function decode(s: string): { StarBiome }
	local out: { StarBiome } = {}
	for pair in string.gmatch(s, "[^,]+") do
		local ty, tier = string.match(pair, "([^:]+):(%d+)")
		if ty and tier then
			out[#out + 1] = { type = ty, tier = tonumber(tier) :: number }
		end
	end
	return out
end

-- Server: publish this star's config so every client builds the identical world.
-- `mapMeta` is the handful of numbers a client needs to interpret baked chunks
-- (grid origin/size, radius, y floor) — NOT the map itself, which never leaves
-- the server (doc 23).
function M.set(seed: number, radius: number, biomes: { StarBiome }, map: string?, mapMeta: string?)
	ReplicatedStorage:SetAttribute("StarSeed", seed)
	ReplicatedStorage:SetAttribute("StarRadius", radius)
	ReplicatedStorage:SetAttribute("StarBiomes", encode(biomes))
	ReplicatedStorage:SetAttribute("StarMap", map)
	ReplicatedStorage:SetAttribute("StarMapMeta", mapMeta)
end

-- Current config: the replicated attrs if published, else the TEST star.
function M.get(): StarCfg
	local seed = ReplicatedStorage:GetAttribute("StarSeed")
	if seed == nil then
		return M.TEST
	end
	local biomes = decode(ReplicatedStorage:GetAttribute("StarBiomes") or "")
	if #biomes == 0 then
		biomes = M.TEST.biomes
	end
	return {
		seed = seed,
		radius = ReplicatedStorage:GetAttribute("StarRadius") or 96,
		biomes = biomes,
		map = ReplicatedStorage:GetAttribute("StarMap"),
	}
end

-- SERVER: the baked-map module for a config, or nil. It lives in ServerStorage, so
-- this only ever resolves on the server — which is the point. An unknown name is a
-- loud warning and a fall back to procedural, rather than a star nobody can enter.
function M.mapSource(cfg: StarCfg): PrebakedMap.Source?
	if not cfg.map then
		return nil
	end
	local ServerStorage = game:GetService("ServerStorage")
	local folder = ServerStorage:FindFirstChild("MapData")
	local mod = folder and folder:FindFirstChild(cfg.map)
	if not mod then
		warn(`starconfig: baked map "{cfg.map}" not found under ServerStorage.MapData — falling back to procedural`)
		return nil
	end
	return require(mod) :: any
end

-- SERVER: build this star's world. Returns the loaded source (for its baked spawn
-- point) and the map itself, or nil for a generated star.
function M.applyServer(cfg: StarCfg): (PrebakedMap.Source?, PrebakedMap.Map?)
	local src = M.mapSource(cfg)
	if src then
		local map = PrebakedMap.open(src)
		WorldGen.applyPrebaked(map)
		return src, map
	end
	WorldGen.applyStarByBiomes(cfg.seed, cfg.radius, cfg.biomes)
	return nil, nil
end

-- CLIENT: build this star's world. A generated star is derived from the seed as
-- always; a baked one starts EMPTY and fills in as the server streams chunks, so
-- nothing large is downloaded and the lobby ships none of it.
function M.applyClient(cfg: StarCfg): PrebakedMap.Map?
	if cfg.map then
		local encoded = ReplicatedStorage:GetAttribute("StarMapMeta")
		local meta = if typeof(encoded) == "string" then PrebakedMap.decodeMeta(encoded) else nil
		if meta then
			local map = PrebakedMap.receiver(meta)
			WorldGen.applyPrebaked(map)
			return map
		end
		warn(`starconfig: star claims baked map "{cfg.map}" but published no usable meta — falling back to procedural`)
	end
	WorldGen.applyStarByBiomes(cfg.seed, cfg.radius, cfg.biomes)
	return nil
end

return M
