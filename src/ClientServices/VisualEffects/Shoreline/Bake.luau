--!strict
--==================================================================================--
--  Shoreline · Bake  ·  shore segments (foam canvas) + ocean tile grid (voxel parts)
--==================================================================================--
--  Workspace.Beach has, per stretch of coast:
--    • ShoreStrip (under ShoreLines) — the SHALLOW foam band. Its FRONT face (LookVector)
--      points out to sea; Right axis = along the shore; local Z = the foam-band depth.
--      -> becomes a shore SEGMENT for the foam canvas (ShoreCanvas).
--    • DeepZone — the open ocean behind it. -> becomes a grid of chunky voxel tiles for the
--      3D wave ocean (Pool + OceanWaves), growing bigger with distance.
--  ShoreStrip is paired with its nearest DeepZone. Corner parts are ignored for now.
--==================================================================================--

local Workspace = game:GetService("Workspace")

local Bake = {}

export type Segment = {
	origin: Vector2,
	longDir: Vector2,
	depthDir: Vector2,
	falloff: number,
	longHalf: number,
	baseY: number,
}

export type Result = {
	depthAt: (number, number) -> number,
	segments: { Segment }, -- shore foam (ShoreCanvas)
	-- ocean voxel tiles (Pool + OceanWaves)
	count: number,
	restPos: { Vector3 },
	tileSize: { Vector3 },
	waveScale: { number }, -- 0 at the shore boundary, eases 0->1 into the ocean
	distOut: { number }, -- studs out from the shore (for static colour gradient)
}

local function collectParts(parent: Instance?, name: string, timeout: number): { BasePart }
	local list = {}
	if not parent then
		return list
	end
	parent:WaitForChild(name, timeout)
	for _, c in parent:GetChildren() do
		if c:IsA("BasePart") and c.Name == name then
			table.insert(list, c)
		end
	end
	return list
end

-- half-extent of a flat part along a world XZ direction
local function halfExtent(part: BasePart, dir: Vector2): number
	local cf, sz = part.CFrame, part.Size
	local lx = Vector2.new(cf.RightVector.X, cf.RightVector.Z)
	local lz = Vector2.new(-cf.LookVector.X, -cf.LookVector.Z)
	lx = lx.Magnitude > 1e-4 and lx.Unit or Vector2.new(1, 0)
	lz = lz.Magnitude > 1e-4 and lz.Unit or Vector2.new(0, 1)
	return math.abs(dir:Dot(lx)) * sz.X * 0.5 + math.abs(dir:Dot(lz)) * sz.Z * 0.5
end

function Bake.build(Config): Result?
	local timeout = Config.zones.waitTimeout or 12
	local beach = Workspace:WaitForChild(Config.zones.beachFolder, timeout)
	if not beach then
		warn(`[Shoreline] Workspace.{Config.zones.beachFolder} never replicated within {timeout}s — disabled.`)
		return nil
	end
	local shoreParent = beach:WaitForChild(Config.zones.shoreFolder, timeout)
	local shoreParts = collectParts(shoreParent, Config.zones.shorePart, timeout)
	local deepParts = collectParts(beach, Config.zones.deepPart, timeout)
	if #shoreParts == 0 then
		warn(`[Shoreline] No {Config.zones.shorePart} parts — disabled.`)
		return nil
	end

	local oc = Config.ocean
	local deepNearSp, deepFarSp = oc.spacingNear, oc.spacingFar
	local thickNear, thickFar = oc.thickNear, oc.thickFar
	local rampStuds = math.max(oc.rampStuds, 0.001)
	local function lerp(a: number, b: number, x: number): number
		return a + (b - a) * x
	end

	local segments: { Segment } = {}
	local restPos: { Vector3 } = {}
	local tileSize: { Vector3 } = {}
	local waveScale: { number } = {}
	local distOut: { number } = {}
	local n = 0

	for _, sp in shoreParts do
		local cf, sz = sp.CFrame, sp.Size
		local depthDir = Vector2.new(cf.LookVector.X, cf.LookVector.Z) -- Front = toward sea
		local longDir = Vector2.new(cf.RightVector.X, cf.RightVector.Z)
		if depthDir.Magnitude < 1e-4 or longDir.Magnitude < 1e-4 then
			continue
		end
		depthDir, longDir = depthDir.Unit, longDir.Unit
		local center = Vector2.new(sp.Position.X, sp.Position.Z)
		local foamDepth = sz.Z -- the ShoreStrip's depth = the foam band
		local longHalf = sz.X * 0.5
		local origin = center - depthDir * (foamDepth * 0.5) -- sand edge (back face)
		local baseY = Config.grid.baseY or sp.Position.Y

		segments[#segments + 1] = {
			origin = origin,
			longDir = longDir,
			depthDir = depthDir,
			falloff = math.max(foamDepth, 1),
			longHalf = longHalf,
			baseY = baseY,
		}

		-- pair with the nearest DeepZone for the ocean grid
		local deepPart: BasePart? = nil
		local bestD = math.huge
		for _, dp in deepParts do
			local d = (sp.Position - dp.Position).Magnitude
			if d < bestD then
				bestD, deepPart = d, dp
			end
		end
		if not deepPart then
			continue
		end

		-- DeepZone footprint in this segment's (long, depth) frame
		local dC = Vector2.new(deepPart.Position.X, deepPart.Position.Z)
		local deepCentreDepth = (dC - origin):Dot(depthDir)
		local deepHalfDepth = halfExtent(deepPart, depthDir)
		local deepCentreLong = (dC - origin):Dot(longDir)
		local deepHalfLong = halfExtent(deepPart, longDir)
		local depthNear = deepCentreDepth - deepHalfDepth
		local depthFar = deepCentreDepth + deepHalfDepth
		local boundary = math.max(depthNear, foamDepth) -- swell eases in from here
		local deepRange = math.max(depthFar - boundary, 0.001)
		local longLo, longHi = deepCentreLong - deepHalfLong, deepCentreLong + deepHalfLong

		-- chunky tiles growing with distance
		local depthC = depthNear
		while depthC <= depthFar + 0.0001 do
			local distBeyond = depthC - boundary
			local r = math.clamp(distBeyond / rampStuds, 0, 1)
			local rowScale = r * r * (3 - 2 * r)
			local farT = math.clamp(distBeyond / deepRange, 0, 1)
			local sp2 = lerp(deepNearSp, deepFarSp, farT)
			local tv = Vector3.new(sp2, lerp(thickNear, thickFar, farT), sp2)
			local longC = longLo
			while longC <= longHi + 0.0001 do
				n += 1
				restPos[n] = Vector3.new(
					origin.X + longDir.X * longC + depthDir.X * depthC,
					baseY,
					origin.Y + longDir.Y * longC + depthDir.Y * depthC
				)
				tileSize[n] = tv
				waveScale[n] = rowScale
				distOut[n] = math.max(distBeyond, 0)
				longC += sp2
			end
			depthC += sp2
		end
	end

	if #segments == 0 then
		warn("[Shoreline] No usable ShoreStrip segments — disabled.")
		return nil
	end

	local function depthAt(x: number, z: number): number
		local p = Vector2.new(x, z)
		local best = 1.0
		for _, seg in segments do
			local d = p - seg.origin
			if math.abs(d:Dot(seg.longDir)) <= seg.longHalf then
				local d01 = math.clamp(d:Dot(seg.depthDir) / seg.falloff, 0, 1)
				if d01 < best then
					best = d01
				end
			end
		end
		return best
	end

	print(`[Shoreline] Baked {#segments} segment(s) + {n} ocean voxel tiles`)

	return {
		depthAt = depthAt,
		segments = segments,
		count = n,
		restPos = restPos,
		tileSize = tileSize,
		waveScale = waveScale,
		distOut = distOut,
	}
end

return Bake
