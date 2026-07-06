--!strict
--==================================================================================--
--  Shoreline · Pool  ·  the ocean voxel parts
--==================================================================================--
--  Preallocated chunky cube parts over the DeepZones. Their COLOUR is set ONCE here (a static
--  near->far blue gradient, no per-frame recolour); at runtime OceanWaves only MOVES them
--  (vertical wave displacement, LOD-culled). Anchored, non-interactive.
--==================================================================================--

local Workspace = game:GetService("Workspace")

local Pool = {}

local function makeFolder(name: string): Folder
	local existing = Workspace:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

function Pool.createOcean(bake, Config): { BasePart }
	local folder = makeFolder("ShorelineOcean")
	local near = Config.palette.blueMid
	local far = Config.palette.blueDeep
	local fade = math.max(Config.ocean.colorFadeDist, 1)
	local fadePow = Config.ocean.colorFadePow or 1
	local parts = table.create(bake.count)
	for i = 1, bake.count do
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Material = Enum.Material.SmoothPlastic
		p.Transparency = 0.3
		local size = bake.tileSize[i]
		p.Size = size
		p.Color = near:Lerp(far, math.clamp(bake.distOut[i] / fade, 0, 1) ^ fadePow) -- static gradient, never updated
		-- top-align the cube to the waterline (restPos.Y): centre sits half a thickness below, so
		-- the TOP face = restPos.Y. Far parts that LOD never moves stay correctly at the surface.
		local rp = bake.restPos[i]
		p.CFrame = CFrame.new(rp.X, rp.Y - size.Y * 0.5, rp.Z)
		p.Parent = folder
		parts[i] = p
	end
	return parts
end

-- Moves a slice of ocean parts (OceanWaves passes only the near, LOD-active ones).
function Pool.bulkMove(parts: { BasePart }, cframes: { CFrame })
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

return Pool
