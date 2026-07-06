--!native
--!optimize 2
--==================================================================================--
--  Shoreline · OceanWaves  ·  spectral 3D ocean on the voxel parts (FFT-style, no colour)
--==================================================================================--
--  The ocean parts move with a realistic wave field: a sum of MANY directional waves whose
--  amplitudes come from the Phillips spectrum (the same spectrum an FFT ocean uses — here we
--  evaluate it directly because we sample sparse part positions, not a dense grid). Waves
--  cluster around the wind direction and follow deep-water dispersion (w = sqrt(g*k)), so it
--  reads as a real swell, not the old 3-wave wobble.
--
--  Only VERTICAL displacement; parts never recolour (Pool baked a static gradient). LOD: only
--  parts within `ocean.lodRadius` of the player move, and the amplitude FADES to 0 at that
--  radius so the moving/near and flat/far ocean meet with no seam. Throttled to `ocean.lod.fps`.
--==================================================================================--

local OceanWaves = {}

type Wave = { dx: number, dz: number, k: number, w: number, amp: number, phase: number }
local waves: { Wave } = {}
local ampScale, weatherGain, speed = 1, 0, 1

-- per-part static data + the reusable move buffers
local parts: { BasePart } = {}
local restX: { number } = {}
local restZ: { number } = {}
local baseY: { number } = {}
local halfThick: { number } = {}
local waveScale: { number } = {}
local count = 0
local moveParts: { BasePart } = {}
local moveCF: { CFrame } = {}

local paintInterval, lastT = 0, -1e9
local cfg
local bulkMove

function OceanWaves.init(Config, bake, oceanParts: { BasePart }, bulkMoveFn)
	parts = oceanParts
	count = bake.count
	cfg = Config
	bulkMove = bulkMoveFn
	local oc = Config.ocean
	ampScale = oc.amplitude
	weatherGain = oc.weatherGain
	speed = oc.speed
	paintInterval = (oc.lod.fps and oc.lod.fps > 0) and (1 / oc.lod.fps) or 0
	lastT = -1e9

	-- per-part static
	for i = 1, count do
		local p = bake.restPos[i]
		restX[i] = p.X
		restZ[i] = p.Z
		baseY[i] = p.Y
		halfThick[i] = bake.tileSize[i].Y * 0.5
		waveScale[i] = bake.waveScale[i]
	end

	-- generate the Phillips-weighted directional wave set
	table.clear(waves)
	local g = oc.gravity
	local wd = oc.windDir
	local wlen = math.max(math.sqrt(wd.X * wd.X + wd.Y * wd.Y), 1e-6)
	local wx, wz = wd.X / wlen, wd.Y / wlen
	local windAngle = math.atan2(wz, wx)
	local L = (oc.windSpeed * oc.windSpeed) / g -- Phillips length scale
	local rng = Random.new(oc.seed or 1337)
	local K = oc.numWaves
	local sumSq = 0
	for i = 1, K do
		local frac = (i - 0.5) / K
		local wavelength = oc.minWavelength * (oc.maxWavelength / oc.minWavelength) ^ frac -- log-spaced
		local k = (2 * math.pi) / wavelength
		local theta = windAngle + (rng:NextNumber() * 2 - 1) * oc.directionSpread
		local dx, dz = math.cos(theta), math.sin(theta)
		local align = dx * wx + dz * wz
		local phillips = math.exp(-1 / ((k * L) * (k * L))) / (k * k * k * k) * (align * align)
		local amp = math.sqrt(math.max(phillips, 0))
		waves[i] = { dx = dx, dz = dz, k = k, w = math.sqrt(g * k), amp = amp, phase = rng:NextNumber() * 2 * math.pi }
		sumSq += amp * amp
	end
	-- normalise so the summed RMS height ~ 1 (then scaled by ocean.amplitude at runtime)
	local norm = sumSq > 0 and (1 / math.sqrt(sumSq)) or 1
	for _, sw in waves do
		sw.amp *= norm
	end
end

OceanWaves.hasWork = function(): boolean
	return count > 0
end

function OceanWaves.step(t: number, storm: number, playerPos: Vector3?)
	if t - lastT < paintInterval then
		return
	end
	lastT = t
	if count == 0 or not playerPos then
		return
	end

	local st = t * speed
	local effAmp = ampScale * (1 + storm * weatherGain)
	local radius = cfg.ocean.lodRadius
	local invRadius = 1 / math.max(radius, 1)
	local r2 = radius * radius
	local px, pz = playerPos.X, playerPos.Z

	local m = 0
	for i = 1, count do
		local dx = restX[i] - px
		local dz = restZ[i] - pz
		local d2 = dx * dx + dz * dz
		if d2 <= r2 then
			-- amplitude fades to 0 at the LOD boundary (so near-wavy meets far-flat seamlessly)
			local a = math.sqrt(d2) * invRadius -- 0..1
			local fade = 1 - a * a * (3 - 2 * a)
			local scale = effAmp * waveScale[i] * fade
			local x0, z0 = restX[i], restZ[i]
			local h = 0.0
			for _, sw in waves do
				h += sw.amp * math.sin(sw.k * (sw.dx * x0 + sw.dz * z0) - sw.w * st + sw.phase)
			end
			m += 1
			moveParts[m] = parts[i]
			moveCF[m] = CFrame.new(x0, baseY[i] - halfThick[i] + scale * h, z0)
		end
	end
	-- trim the reusable arrays to the live count for BulkMoveTo
	for j = m + 1, #moveParts do
		moveParts[j] = nil
		moveCF[j] = nil
	end
	if m > 0 then
		bulkMove(moveParts, moveCF)
	end
end

return OceanWaves
