--!native
--!optimize 2
--==================================================================================--
--  Shoreline · ShoreCanvas  ·  shore foam painted into EditableImage TILES (multi-segment)
--==================================================================================--
--  Each straight shore SEGMENT (from Bake) is described by direction vectors (origin =
--  sand-edge centre, longDir along the shore, depthDir toward deep). Each segment is split
--  into TILE panels along its length (`canvas.tileWidth`, <= ~200 studs each to dodge the
--  SurfaceGui distance-LOD edge fade). A panel's part is ORIENTED to its segment via
--  CFrame.fromMatrix, so a yaw-rotated beach renders the same as an axis-aligned one.
--
--  The foam field (Voronoi + surge wash + cel bands) is sampled in WORLD space, so separate
--  segments stitch seamlessly. Per pixel: image-col -> depth (sand->deep), image-row -> long.
--  world = origin + longDir*longParam + depthDir*depthParam, depth01 = depthParam / falloff.
--
--  Interaction: addRipple(worldX, worldZ, t) injects an expanding foam ring (world space).
--==================================================================================--

local AssetService = game:GetService("AssetService")
local Workspace = game:GetService("Workspace")

local ShoreCanvas = {}

local TWO_PI = 6.2831853071796

local function fract(x: number): number
	return x - math.floor(x)
end
local function hashX(i: number, j: number): number
	return fract(math.sin(i * 127.1 + j * 311.7) * 43758.5453)
end
local function hashZ(i: number, j: number): number
	return fract(math.sin(i * 269.5 + j * 183.3) * 24634.6345)
end
local function hashId(i: number, j: number): number
	return fract(math.sin(i * 419.2 + j * 371.9) * 51329.5453)
end

type SegData = {
	originX: number,
	originZ: number,
	longX: number,
	longZ: number, -- longDir (possibly flipped for a right-handed part frame)
	depthX: number,
	depthZ: number, -- depthDir (toward deep)
	falloff: number,
	driftX: number,
	driftZ: number, -- shoreward drift (= -depthDir * driftStuds)
}
type Tile = {
	image: EditableImage,
	buf: buffer,
	ny: number,
	longAt: { number }, -- per row: long parameter
	centerX: number,
	centerZ: number, -- world centre (for culling)
	seg: SegData,
	nextT: number, -- next time this tile is due to repaint
	painted: boolean, -- has it been painted at least once (far tiles paint once then freeze)
}

-- module state
local cfg
local nx = 0 -- DEPTH resolution (shared)
local d01At: { number } = {} -- per depth-col: depth01 (0..1)
local colBand: { number } = {}
local colMul: { number } = {}
local shoreFoamAt: { number } = {} -- per depth-col: foam ramp (0 at deep edge -> 1 at sand)
local foamR, foamG, foamB = 0, 0, 0
local bandR: { number } = {}
local bandG: { number } = {}
local bandB: { number } = {}
local paintInterval = 0
local driftStuds = 0
local tiles: { Tile } = {}
local cursor = 0 -- round-robin start for the per-frame paint budget
-- per-frame scratch
local rowFront: { number } = {}
local rowBreath: { number } = {}
local rowWashA: { number } = {} -- per row: wash-line alpha (1 on uprush, fades over backwash)
local cc1x, cc1z, c1id = {}, {}, {}
local cc2x, cc2z, c2id = {}, {}, {}
-- ripples
local ripX: { number } = {}
local ripZ: { number } = {}
local ripStart: { number } = {}
local ripCount = 0
local lastRippleX, lastRippleZ = math.huge, math.huge
local rLo: { number } = {}
local rHi: { number } = {}
local rcx: { number } = {}
local rcz: { number } = {}
local rAlpha: { number } = {}
local liveRip = 0

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

local function buildCells(C, offX, offZ, wxLo, wxHi, wzLo, wzHi, wobPhase, jitter, wobble, ccx, ccz, cid)
	local invC = 1 / C
	local gx0 = math.floor((wxLo - offX) * invC) - 1
	local gx1 = math.floor((wxHi - offX) * invC) + 1
	local gz0 = math.floor((wzLo - offZ) * invC) - 1
	local gz1 = math.floor((wzHi - offZ) * invC) + 1
	local cellsW = gx1 - gx0 + 1
	for cz = gz0, gz1 do
		local rowBase = (cz - gz0) * cellsW
		for cx = gx0, gx1 do
			local jx, jz = hashX(cx, cz), hashZ(cx, cz)
			local wob = wobble * math.sin(wobPhase + (jx + jz) * TWO_PI)
			local k = rowBase + (cx - gx0) + 1
			ccx[k] = (cx + 0.5 + (jx - 0.5) * jitter + wob) * C
			ccz[k] = (cz + 0.5 + (jz - 0.5) * jitter + wob) * C
			cid[k] = hashId(cx, cz)
		end
	end
	return gx0, gz0, cellsW, invC
end

function ShoreCanvas.init(Config, bake)
	cfg = Config
	driftStuds = Config.cell.driftStuds
	paintInterval = (Config.canvas.fps and Config.canvas.fps > 0) and (1 / Config.canvas.fps) or 0
	cursor = 0

	local function rgb(c: Color3): (number, number, number)
		return math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)
	end
	foamR, foamG, foamB = rgb(Config.palette.foam)
	bandR[1], bandG[1], bandB[1] = rgb(Config.palette.tealLight)
	bandR[2], bandG[2], bandB[2] = rgb(Config.palette.tealMid)
	bandR[3], bandG[3], bandB[3] = rgb(Config.palette.blueMid)
	bandR[4], bandG[4], bandB[4] = rgb(Config.palette.blueDeep)

	-- shared DEPTH columns (depth01 0..1) + static band / foam-width
	local pxPerStud = Config.canvas.pixelsPerStud
	local maxFalloff = 1
	for _, seg in bake.segments do
		maxFalloff = math.max(maxFalloff, seg.falloff)
	end
	nx = math.clamp(math.floor(maxFalloff * pxPerStud + 0.5), 8, 1024)
	local shoreGain = Config.cell.shoreGain
	local bShallow, bMid, bDeep = Config.bands.shallow, Config.bands.mid, Config.bands.deep
	local foamDepthMax0 = Config.cell.foamDepthMax
	local invFDM = 1 / math.max(foamDepthMax0, 1e-3)
	local foamBias = Config.cell.shoreFoamBias
	for i = 0, nx - 1 do
		local d01 = i / (nx - 1)
		d01At[i] = d01
		colMul[i] = 1 + shoreGain * (1 - d01)
		-- foam ramp: 0 at the deep edge (foamDepthMax) -> 1 at the sand (d01=0), biased so the
		-- white foam concentrates near shore instead of popping in fully-formed mid-water.
		shoreFoamAt[i] = math.clamp((foamDepthMax0 - d01) * invFDM, 0, 1) ^ foamBias
		if d01 < bShallow then
			colBand[i] = 0
		elseif d01 < bMid then
			colBand[i] = 1
		elseif d01 < bDeep then
			colBand[i] = 2
		else
			colBand[i] = 3
		end
	end

	-- build tile panels per segment
	local folder = makeFolder("ShorelineCanvas")
	table.clear(tiles)
	local up = Vector3.yAxis
	for _, seg in bake.segments do
		-- The panel's local +Z faces the SAND (shoreward = -depthDir): the SurfaceGui maps image
		-- column 0 to the local +Z+ edge, and we want column 0 = sand (depth 0). Flip longDir as
		-- needed so the frame stays right-handed (longDir x up = shoreward).
		local longD3 = Vector3.new(seg.longDir.X, 0, seg.longDir.Y)
		local depthD3 = Vector3.new(seg.depthDir.X, 0, seg.depthDir.Y)
		local shoreD3 = -depthD3
		if longD3:Cross(up):Dot(shoreD3) < 0 then
			longD3 = -longD3
		end
		local seg2: SegData = {
			originX = seg.origin.X,
			originZ = seg.origin.Y,
			longX = longD3.X,
			longZ = longD3.Z,
			depthX = seg.depthDir.X,
			depthZ = seg.depthDir.Y,
			falloff = seg.falloff,
			driftX = -seg.depthDir.X * driftStuds,
			driftZ = -seg.depthDir.Y * driftStuds,
		}

		local longSpan = 2 * seg.longHalf
		local nTiles = math.max(1, math.ceil(longSpan / math.max(Config.canvas.tileWidth, 1)))
		local tileLongSpan = longSpan / nTiles
		for k = 0, nTiles - 1 do
			local tLo = -seg.longHalf + k * tileLongSpan
			local tHi = tLo + tileLongSpan
			local centerLong = (tLo + tHi) * 0.5
			local ny = math.clamp(math.floor(tileLongSpan * pxPerStud + 0.5), 8, 1024)
			-- world centre (depth centred at falloff/2)
			local cx = seg2.originX + seg2.longX * centerLong + seg2.depthX * (seg.falloff * 0.5)
			local cz = seg2.originZ + seg2.longZ * centerLong + seg2.depthZ * (seg.falloff * 0.5)

			local part = Instance.new("Part")
			part.Name = "CanvasTile"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Transparency = 1
			part.Size = Vector3.new(tileLongSpan, 0.2, seg.falloff) -- local X = long, Z = depth
			part.CFrame = CFrame.fromMatrix(Vector3.new(cx, seg.baseY + Config.canvas.yOffset, cz), longD3, up, shoreD3)
			part.Parent = folder

			local image = AssetService:CreateEditableImage({ Size = Vector2.new(nx, ny) })
			local sg = Instance.new("SurfaceGui")
			sg.Name = "Canvas"
			sg.Face = Enum.NormalId.Top
			sg.LightInfluence = Config.canvas.lightInfluence
			sg.MaxDistance = Config.canvas.maxDistance
			sg.PixelsPerStud = 8
			sg.Parent = part
			local il = Instance.new("ImageLabel")
			il.Size = UDim2.fromScale(1, 1)
			il.BackgroundTransparency = 1
			il.ResampleMode = Enum.ResamplerMode.Pixelated
			il.ImageContent = Content.fromObject(image)
			il.Parent = sg

			local longAt = {}
			for j = 0, ny - 1 do
				longAt[j] = tLo + (j / (ny - 1)) * (tHi - tLo)
			end
			tiles[#tiles + 1] = {
				image = image,
				buf = buffer.create(nx * ny * 4),
				ny = ny,
				longAt = longAt,
				centerX = cx,
				centerZ = cz,
				seg = seg2,
				nextT = -1e9,
				painted = false,
			}
		end
	end

	print(`[Shoreline] Canvas: {#bake.segments} segment(s), {#tiles} tiles, {nx}px deep`)
end

function ShoreCanvas.addRipple(wx: number, wz: number, t: number)
	if ripCount >= cfg.canvas.ripple.max then
		for i = 1, ripCount - 1 do
			ripX[i], ripZ[i], ripStart[i] = ripX[i + 1], ripZ[i + 1], ripStart[i + 1]
		end
		ripCount -= 1
	end
	ripCount += 1
	ripX[ripCount], ripZ[ripCount], ripStart[ripCount] = wx, wz, t
end

function ShoreCanvas.tryPlayerRipple(wx: number, wz: number, t: number)
	local dx, dz = wx - lastRippleX, wz - lastRippleZ
	if dx * dx + dz * dz >= cfg.canvas.ripple.travelStuds ^ 2 then
		lastRippleX, lastRippleZ = wx, wz
		ShoreCanvas.addRipple(wx, wz, t)
	end
end

local function paintTile(tile: Tile, t: number)
	local seg = tile.seg
	local oX, oZ = seg.originX, seg.originZ
	local lX, lZ = seg.longX, seg.longZ
	local dX, dZ = seg.depthX, seg.depthZ
	local falloff = seg.falloff
	local offX, offZ = seg.driftX * t, seg.driftZ * t
	local nyT = tile.ny
	local longAt = tile.longAt
	local buf = tile.buf

	local C1 = cfg.cell.size
	local w1 = cfg.cell.foamWidth
	local C2 = cfg.cell.size2
	local w2 = cfg.cell.foamWidth2
	local hasOct2 = C2 and C2 > 0
	local jitter = cfg.cell.jitter
	local wobble = cfg.cell.wobble
	local foamDepthMax = cfg.cell.foamDepthMax
	local wobblePhase = t * cfg.cell.wobbleSpeed

	local classic = cfg.classicFoam
	local wash = cfg.wash
	local invPeriod = 1 / wash.period
	local reachOut, reachSpan = wash.reachOut, wash.reachIn - wash.reachOut
	local riseFrac = wash.riseFrac -- classic swash
	local invRise, invFall = 1 / riseFrac, 1 / (1 - riseFrac)
	local upFrac = wash.upFrac -- soft swash
	local invUp, invBack = 1 / upFrac, 1 / (1 - upFrac)
	local backFade = wash.backFade
	local washAlong, edgeAmp, edgeFreq = wash.alongShore, wash.edgeAmp, wash.edgeFreq
	local foamBreath = wash.foamBreath
	local lineWidth = wash.lineWidth
	local invSandFade = 1 / math.max(wash.sandFade, 1e-3)
	local phNoiseAmt, phNoiseFreq, phNoiseSpeed = wash.phaseNoiseAmt, wash.phaseNoiseFreq, wash.phaseNoiseSpeed

	local lightenChance = cfg.bands.lightenChance
	local darkenChance = 1 - cfg.bands.darkenChance
	local waterMaxAlpha = cfg.canvas.water.maxAlpha
	local invEdgeSoft = 1 / math.max(cfg.canvas.water.edgeSoft, 1e-3)

	-- per-row surge (Perlin-staggered along the shore param). `frontN`: 0 = washed all the way UP
	-- (at the sand), 1 = fully RECEDED. The UPRUSH (u < upFrac) is fast + crisp; the BACKWASH is the
	-- slow remainder and its foam fades out (`backFade`) as the water soaks into the sand.
	for j = 0, nyT - 1 do
		local lng = longAt[j]
		local phaseNoise = math.noise(lng * phNoiseFreq, t * phNoiseSpeed) * phNoiseAmt
		local u = fract(t * invPeriod - lng * washAlong + phaseNoise)
		local edge = (math.noise(lng * edgeFreq, t * 0.13) + 0.5 * math.noise(lng * edgeFreq * 2.7, t * 0.21 + 50))
			* edgeAmp
		if classic then
			-- CLASSIC: symmetric-ish surge `s` (0 = receded, 1 = washed up), no backwash fade.
			local s: number
			if u < riseFrac then
				local a = u * invRise
				s = a * a * (3 - 2 * a)
			else
				local a = 1 - (u - riseFrac) * invFall
				s = a * a * (3 - 2 * a)
			end
			rowFront[j] = reachOut + reachSpan * s + edge
			rowBreath[j] = 1 + foamBreath * (s * 2 - 1)
			rowWashA[j] = 1
		else
			-- SOFT: `frontN` 0 = washed up, 1 = receded. Fast uprush, slow FADING backwash.
			local frontN: number
			local washA: number
			if u < upFrac then
				local a = u * invUp -- 0..1, FAST
				local sm = a * a * (3 - 2 * a)
				frontN = 1 - sm -- receded -> up
				washA = 1
			else
				local b = (u - upFrac) * invBack -- 0..1, slow
				local sm = b * b * (3 - 2 * b)
				frontN = sm -- up -> receded
				washA = 1 - backFade * sm -- foam absorbs as it drains back
			end
			rowFront[j] = reachOut + reachSpan * frontN + edge
			rowBreath[j] = 1 + foamBreath * (1 - frontN * 2) -- more foam when washed up
			rowWashA[j] = washA
		end
	end

	-- visible cell range = world bbox of this tile's strip (4 corners: long lo/hi x depth 0/falloff)
	local lLo, lHi = longAt[0], longAt[nyT - 1]
	local x1, z1 = oX + lX * lLo, oZ + lZ * lLo
	local x2, z2 = oX + lX * lHi, oZ + lZ * lHi
	local fx, fz = dX * falloff, dZ * falloff
	local xs = { x1, x2, x1 + fx, x2 + fx }
	local zs = { z1, z2, z1 + fz, z2 + fz }
	local wxLo, wxHi, wzLo, wzHi = xs[1], xs[1], zs[1], zs[1]
	for q = 2, 4 do
		wxLo, wxHi = math.min(wxLo, xs[q]), math.max(wxHi, xs[q])
		wzLo, wzHi = math.min(wzLo, zs[q]), math.max(wzHi, zs[q])
	end
	local gx0a, gz0a, cwa, invC1 =
		buildCells(C1, offX, offZ, wxLo, wxHi, wzLo, wzHi, wobblePhase, jitter, wobble, cc1x, cc1z, c1id)
	local gx0b, gz0b, cwb, invC2 = 0, 0, 0, 0
	if hasOct2 then
		gx0b, gz0b, cwb, invC2 =
			buildCells(C2, offX, offZ, wxLo, wxHi, wzLo, wzHi, wobblePhase, jitter, wobble, cc2x, cc2z, c2id)
	end

	for j = 0, nyT - 1 do
		local lng = longAt[j]
		local front = rowFront[j]
		local breath = rowBreath[j]
		local washA = rowWashA[j]
		local baseX, baseZ = oX + lX * lng, oZ + lZ * lng -- world at depth 0 for this row
		local rowPix = j * nx
		for i = 0, nx - 1 do
			local d01 = d01At[i]
			local depthC = d01 * falloff
			local worldX = baseX + dX * depthC
			local worldZ = baseZ + dZ * depthC

			local sx, sz = worldX - offX, worldZ - offZ
			local mul = colMul[i] * breath
			local inFoamZone = d01 < foamDepthMax
			local gx, gz = math.floor(sx * invC1), math.floor(sz * invC1)
			local f1, f2, id1 = 1e9, 1e9, 0.0
			for ox = -1, 1 do
				local cxk = gx + ox - gx0a
				for oz = -1, 1 do
					local k = (gz + oz - gz0a) * cwa + cxk + 1
					local dx = sx - cc1x[k]
					local dz = sz - cc1z[k]
					local d2 = dx * dx + dz * dz
					if d2 < f1 then
						f2 = f1
						f1 = d2
						id1 = c1id[k]
					elseif d2 < f2 then
						f2 = d2
					end
				end
			end

			-- octave-2 foam edge (F2-F1 of the small blobs), computed once when in the foam zone
			local e2 = 1e9
			if hasOct2 and inFoamZone then
				local gx2, gz2 = math.floor(sx * invC2), math.floor(sz * invC2)
				local g1, g2 = 1e9, 1e9
				for ox = -1, 1 do
					local cxk = gx2 + ox - gx0b
					for oz = -1, 1 do
						local k = (gz2 + oz - gz0b) * cwb + cxk + 1
						local dx = sx - cc2x[k]
						local dz = sz - cc2z[k]
						local d2 = dx * dx + dz * dz
						if d2 < g1 then
							g2 = g1
							g1 = d2
						elseif d2 < g2 then
							g2 = d2
						end
					end
				end
				e2 = math.sqrt(g2) - math.sqrt(g1)
			end

			-- foam amount: CLASSIC = crisp BINARY (uniform white blobs across the band); SOFT = an
			-- anti-aliased coverage RAMPED by `shoreFoamAt` so it fades in toward the sand (no pop-in).
			local e1 = math.sqrt(f2) - math.sqrt(f1)
			local foamAmt = 0.0
			if inFoamZone then
				if classic then
					if e1 < w1 * mul or (hasOct2 and e2 < w2 * mul) then
						foamAmt = 1.0
					end
				else
					local sf = shoreFoamAt[i]
					if sf > 0 then
						local cov = 1 - e1 / (w1 * mul)
						if hasOct2 then
							local cov2 = 1 - e2 / (w2 * mul)
							if cov2 > cov then
								cov = cov2
							end
						end
						if cov > 0 then
							foamAmt = (cov > 1 and 1 or cov) * sf
						end
					end
				end
			end

			local overlay = 0.0
			if d01 > front - lineWidth and d01 < front + lineWidth then
				overlay = math.clamp(d01 * invSandFade, 0, 1) * washA -- the receding line fades out
			end
			if liveRip > 0 and overlay < 1 then
				for r = 1, liveRip do
					local dx = worldX - rcx[r]
					local dz = worldZ - rcz[r]
					local d2 = dx * dx + dz * dz
					if d2 > rLo[r] and d2 < rHi[r] then
						if rAlpha[r] > overlay then
							overlay = rAlpha[r]
						end
					end
				end
			end

			local band = colBand[i]
			if id1 < lightenChance then
				band -= 1
			elseif id1 > darkenChance then
				band += 1
			end
			if band < 0 then
				band = 0
			elseif band > 3 then
				band = 3
			end
			local bidx = band + 1
			-- water colour -> blend toward foam by the soft cellular coverage, then by the wash line
			local sr = bandR[bidx] + (foamR - bandR[bidx]) * foamAmt
			local sg = bandG[bidx] + (foamG - bandG[bidx]) * foamAmt
			local sb = bandB[bidx] + (foamB - bandB[bidx]) * foamAmt

			local surfA = math.clamp((d01 - front) * invEdgeSoft, 0, 1) * waterMaxAlpha
			local r = (sr + (foamR - sr) * overlay) // 1
			local g = (sg + (foamG - sg) * overlay) // 1
			local b = (sb + (foamB - sb) * overlay) // 1
			local ai = ((surfA + overlay * (1 - surfA)) * 255) // 1
			buffer.writeu32(buf, (rowPix + i) * 4, r + g * 256 + b * 65536 + ai * 16777216)
		end
	end

	tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(nx, nyT), buf)
end

-- Repaints at most `canvas.paintBudget` tiles per frame (round-robin), only those near the
-- player (`canvas.renderRadius`) and due (their own `fps` interval). Far tiles paint ONCE then
-- freeze. playerPos = nil disables culling.
function ShoreCanvas.step(t: number, playerPos: Vector3?)
	-- ripples: compact + ring radii every frame (cheap; keeps ages current for whatever paints)
	local rip = cfg.canvas.ripple
	local rSpeed, rWidth, rLife = rip.speed, rip.width, rip.life
	liveRip = 0
	local w = 0
	for i = 1, ripCount do
		local age = t - ripStart[i]
		if age <= rLife then
			w += 1
			ripX[w], ripZ[w], ripStart[w] = ripX[i], ripZ[i], ripStart[i]
			liveRip += 1
			local rr = age * rSpeed
			local lo = math.max(rr - rWidth, 0)
			rLo[liveRip] = lo * lo
			rHi[liveRip] = (rr + rWidth) * (rr + rWidth)
			rcx[liveRip] = ripX[i]
			rcz[liveRip] = ripZ[i]
			rAlpha[liveRip] = 1 - age / rLife
		end
	end
	ripCount = w

	local n = #tiles
	if n == 0 then
		return
	end
	local budget = cfg.canvas.paintBudget
	local cullR = cfg.canvas.renderRadius
	local px = playerPos and playerPos.X or nil
	local pz = playerPos and playerPos.Z or nil
	local painted = 0
	local broke = false
	for off = 0, n - 1 do
		local i0 = (cursor + off) % n
		local tile = tiles[i0 + 1]
		-- far & already painted -> freeze (don't repaint)
		if cullR > 0 and px and tile.painted then
			local dx, dz = px - tile.centerX, pz - tile.centerZ
			if dx * dx + dz * dz > cullR * cullR then
				continue
			end
		end
		if t < tile.nextT then
			continue -- not due yet
		end
		paintTile(tile, t)
		tile.painted = true
		tile.nextT = t + paintInterval
		painted += 1
		if painted >= budget then
			cursor = (i0 + 1) % n
			broke = true
			break
		end
	end
	if not broke then
		cursor = (cursor + 1) % n
	end
end

return ShoreCanvas
