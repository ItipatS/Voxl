--!strict
--==================================================================================--
--  Shoreline · Config  ·  StarterPlayerScripts.VisualEffect.Shoreline
--==================================================================================--
--  PIXEL-ART water: a flat, dense grid of tiles whose COLOUR is computed each frame from
--  a math field (cellular foam + shoreline wash, cel-shaded into a tiny palette). "Pixel
--  art with math" — reference: teal blobs with thick white foam borders + a white wash
--  band meeting the sand. NO particles, NO trails, NO 3D wave displacement (the tiles
--  never move; only their colour does).
--
--  Cosmetic, client-only, nothing replicates. Designers move/resize the Workspace.Beach
--  zone parts; the grid + depth gradient re-bake from them on run (no hard-coded coords).
--==================================================================================--

local Config = {
	--==============================================================================--
	--  ZONES — resolved by name via WaitForChild (parts stream in late; keep Beach a
	--  Persistent Model so they always replicate — see Bake / the streaming notes).
	--==============================================================================--
	zones = {
		beachFolder = "Beach", -- Workspace.Beach (a Persistent Model)
		shoreFolder = "ShoreLines",
		shorePart = "ShoreStrip", -- the breaking strip; its short axis (size.Z) is the depth01 gradient
		deepPart = "DeepZone", -- the open ocean behind each ShoreStrip → 3D voxel wave grid
		waitTimeout = 12, -- seconds to wait for each zone instance before warning + disabling
	},

	--==============================================================================--
	--  GRID — flat and DENSE (the pixels). Smaller spacing = finer pixels = crisper
	--  foam borders, but more tiles to recolour. Two resolutions: fine near shore where
	--  the eye is, coarse for the background deep band.
	--==============================================================================--
	-- ShoreStrip = the SHALLOW foam band ONLY (its depth = size.Z = the waterline falloff); the
	-- open ocean behind it is the separate DeepZone (3D voxel waves). Orient each ShoreStrip so
	-- its FRONT face (LookVector) points OUT TO SEA; RightVector = along the shore.
	useCanvasShore = true,

	-- FOAM / WHITE-LINE STYLE — flip between the two looks (both good):
	--   true  = CLASSIC: crisp BINARY foam (uniform white blobs across the whole band) + a symmetric
	--           swash driven by `wash.riseFrac` (no backwash fade). Punchy, graphic white line.
	--   false = SOFT:    foam fades in from the deep edge and INTENSIFIES toward the sand
	--           (`cell.shoreFoamBias`) + an asymmetric swash (fast uprush, slow FADING backwash via
	--           `wash.upFrac`/`wash.backFade`). Softer, more naturalistic.
	classicFoam = false,
	canvas = {
		-- The shore is split into TILES along its length: each tile is its own part + SurfaceGui +
		-- EditableImage. Keeping each part <= ~200 studs wide dodges the SurfaceGui LOD edge-fade,
		-- and lets a big beach paint only the tiles near the player (renderRadius). The field is
		-- world-space, so tiles stitch seamlessly.
		tileWidth = 200, -- studs of shore per tile-part (<= ~200 avoids the edge fade)
		pixelsPerStud = 1.0, -- image resolution (was `width`); higher = crisper + costlier
		-- PERF (the main dials): only repaint tiles within `renderRadius` of the player; far tiles
		-- paint ONCE then freeze (distant water barely moves). `paintBudget` caps how many SHORE
		-- tiles repaint per frame (round-robin) so there's never a spike, no matter the beach size.
		renderRadius = 280,
		paintBudget = 4,
		-- Foam is slow, so each tile repaints at most this many times/sec (the world still renders
		-- smooth; only the foam image updates at this rate).
		fps = 24,
		yOffset = 0.06, -- lift the canvas above the waterline so it doesn't z-fight ocean/terrain
		-- SurfaceGui rendering. maxDistance = 0 disables the distance LOD fade (otherwise the far
		-- left/right edges fade out when you zoom out — a PLAY-mode-only artifact). lightInfluence
		-- 0 = vivid/ignore lighting, 1 = fully lit by the environment (day/night, sun colour).
		maxDistance = 0,
		lightInfluence = 1,
		-- The foam line IS the waterline: the sea (water + foam web) renders only SEAWARD of it;
		-- everything shoreward is transparent wet sand. So the water/sand boundary moves with the
		-- wave — water rushes up, then drains to expose sand.
		water = {
			edgeSoft = 0.05, -- how sharply the sea meets the exposed sand at the waterline (depth01)
			maxAlpha = 1.0, -- opacity of the sea (lower = the sea itself is a bit see-through)
		},
		ripple = {
			speed = 16, -- studs/sec the foam ring expands from the player
			width = 2.5, -- ring thickness (studs)
			life = 1.1, -- seconds a ripple lives
			max = 14, -- max concurrent ripples
			travelStuds = 2.5, -- min player travel (studs) between auto-ripples
		},
	},

	grid = {
		-- Waterline Y for the SHORE foam canvas. nil = auto = the ShoreStrip's CENTRE (the marker
		-- straddles the waterline). Use the centre, not the top, or the sheet floats above the sand.
		baseY = nil :: number?,
	},

	--==============================================================================--
	--  OCEAN — 3D voxel parts (Pool builds them, OceanWaves moves them). The wave field is a
	--  SPECTRAL sum (FFT-style): many directional sine waves whose amplitudes follow the Phillips
	--  spectrum and cluster around the wind, with deep-water dispersion (w = sqrt(g*k)). Reads as
	--  a real swell, not a 3-wave wobble. VERTICAL only — colour is baked static (Pool), never
	--  updated per frame. LOD: only parts within `lodRadius` move (amplitude fades to 0 there).
	--==============================================================================--
	ocean = {
		-- voxel grid: chunky cubes that GROW with distance (big = the "voxel ocean" look, fewer
		-- parts). Spacing/thickness lerp from near (shore boundary) to far (horizon).
		spacingNear = 10, -- tile size (studs) at the shore boundary
		spacingFar = 40, -- tile size far out — big chunky cubes
		thickNear = 3, -- tile thickness (Y) near the boundary
		thickFar = 24, -- tile thickness far out (top sits at the wave surface)
		rampStuds = 40, -- studs over which the swell eases in from 0 at the shore boundary
		colorFadeDist = 320, -- studs over which the static colour lerps blueMid (near) -> blueDeep (far)
		colorFadePow = 1.5, -- >1 keeps the teal-blue longer, darkening toward blueDeep only further out

		-- SPECTRAL wave field (Phillips). Tune `amplitude` for calm-day height; storms scale it up.
		numWaves = 40, -- number of summed directional waves (more = richer, costlier per part)
		windDir = Vector2.new(0.6, 0.8), -- dominant swell direction in world XZ (unit-ish)
		windSpeed = 8, -- Phillips wind speed: bigger = longer dominant wavelength / bigger swell
		directionSpread = 0.6, -- radians of scatter around the wind (0 = all aligned, ~1 = choppy)
		minWavelength = 10, -- shortest wave (studs) — fine chop
		maxWavelength = 140, -- longest wave (studs) — the big rolling swell
		amplitude = 2.5, -- overall swell height (studs) on a calm day
		weatherGain = 1.5, -- extra swell at full storm: effAmp = amplitude * (1 + storm * weatherGain)
		gravity = 30, -- dispersion w = sqrt(g*k); bigger = faster waves
		speed = 1.0, -- overall time scale of the swell
		seed = 1337, -- deterministic wave set (same swell every run)

		-- LOD: only parts within `lodRadius` of the camera move (amplitude smoothstep-fades to 0
		-- at the edge so the moving/near and flat/far ocean meet seamlessly). Throttled to lod.fps.
		lodRadius = 320,
		lod = { fps = 30 },
	},

	--==============================================================================--
	--  CELLULAR FOAM (the blobs) — animated Voronoi. Teal cells, white borders where the
	--  two nearest cell centres are ~equidistant. The whole pattern drifts shoreward so it
	--  reads as waves rolling in.
	--==============================================================================--
	cell = {
		-- TWO foam octaves = a MIX of blob sizes (foam wherever EITHER layer has a border):
		--   primary = big blobs (also drives the teal colour patches),
		--   secondary = small blobs for fine foam detail. Set size2 = 0 for a single scale.
		size = 13, -- primary (big) blob diameter in studs — smaller = finer foam overall
		foamWidth = 1.8, -- primary border thickness
		size2 = 5.5, -- secondary (small) blob diameter; 0 disables the mix
		foamWidth2 = 1.0, -- secondary border thickness
		shoreGain = 1.0, -- borders thicken up to this factor as depth01 -> 0 (turbulent near sand)
		foamDepthMax = 0.72, -- depth01 above which the cellular foam STOPS (open sea has no foam web)
		-- Foam RAMP: the white foam + outlines fade in from nothing at foamDepthMax and INTENSIFY
		-- toward the sand (so foam doesn't pop in mid-water). Higher bias = foam hugs the sand more.
		shoreFoamBias = 1.6, -- exponent on the deep->sand foam ramp (1 = linear, >1 = concentrated at sand)
		jitter = 0.85, -- 0..1 how irregular/organic the blob shapes are
		driftStuds = 5, -- studs/sec the foam pattern drifts toward the beach
		wobble = 0.12, -- small per-cell breathing so borders aren't dead-static
		wobbleSpeed = 0.9, -- rad/sec of that breathing
	},

	--==============================================================================--
	--  SHORE WASH — the foam SURGES in and drains out each wave (not just a morphing
	--  pattern). A periodic cycle sweeps a solid foam sheet up the shallows fast, then lets
	--  it drain back slowly (real swash/backwash), exposing teal shallow water as it recedes.
	--==============================================================================--
	-- The wash is a moving foam LINE (the wave's leading edge), NOT a fill — it sweeps up the
	-- shore and back each cycle. Everything behind/around it is the normal water (which is
	-- transparent in the shallows, so you see wet sand where the wave isn't).
	wash = {
		period = 5.0, -- seconds per wave (one full in + out)
		reachOut = 0.0, -- depth01 the foam line pulls back to when fully receded (at the sand)
		reachIn = 0.34, -- depth01 the foam line washes up to at the peak of the surge
		-- CLASSIC swash (classicFoam = true): symmetric-ish, no backwash fade.
		riseFrac = 0.32, -- fraction of the cycle spent rushing IN (the rest drains out, slower)
		-- SOFT swash (classicFoam = false): the UPRUSH is fast + energetic (`upFrac` of the cycle),
		-- the BACKWASH is the slow remainder and FADES out as it drains. Small upFrac = snappier push.
		upFrac = 0.26, -- fraction of the cycle spent rushing UP the beach (rest = slow drain back)
		backFade = 0.85, -- how much the foam/line fades over the backwash (0 = no fade, 1 = fully absorbed)
		lineWidth = 0.05, -- HALF-thickness of the foam line in depth01 (~3 studs); bigger = fatter line
		foamBreath = 0.5, -- the cellular foam borders thicken a touch with the surge
		sandFade = 0.06, -- the foam line fades out over this depth01 as it reaches the sand edge
		-- BREAK THE PERIODICITY — without these the whole 503-stud shore washes as one straight sine
		-- line. Perlin noise staggers the wave CYCLE along the shore (sections arrive out of phase)
		-- and wiggles the waterline SHAPE so it's irregular, not a clean sin.
		alongShore = 0.004, -- base phase travel along the shore (per stud)
		phaseNoiseAmt = 0.35, -- how much the wave cycle is staggered along the shore (fraction of a cycle)
		phaseNoiseFreq = 0.012, -- spatial frequency of the stagger (per stud) — lower = longer staggered stretches
		phaseNoiseSpeed = 0.06, -- how fast the stagger pattern itself drifts over time
		edgeAmp = 0.05, -- amplitude of the wiggly-waterline noise (depth01)
		edgeFreq = 0.02, -- spatial frequency of the waterline wiggle (per stud)
	},

	--==============================================================================--
	--  BEACH SOUND — ReplicatedStorage.Assets.Beach, looped; volume fades with distance to
	--  the shore strip (full near, silent far) and lifts a little when the sea is rough.
	--==============================================================================--
	sound = {
		assetPath = { "Assets", "Beach" }, -- under ReplicatedStorage
		maxVolume = 0.6, -- volume when right at the shore in calm weather
		nearDist = 35, -- within this many studs of the strip = full volume
		farDist = 230, -- beyond this = silent
		stormBoost = 0.4, -- extra volume fraction at full storm (rougher sea = louder)
	},

	--==============================================================================--
	--  CEL-SHADING — 3 teal shades banded by depth01 (hard thresholds = pixel art), with
	--  occasional per-cell shade shifts for variation. Plus the foam white.
	--==============================================================================--
	-- Colour by depth01: bright teal in the shallows -> deep ocean blue out at sea (hard steps =
	-- pixel art). Per-cell hash nudges some tiles a shade lighter/darker for variety.
	-- The shore band is the SHALLOW turquoise water — keep it teal-dominant and let it end at
	-- `blueMid` at its seaward edge, which is exactly where the OCEAN parts START (Pool lerps
	-- blueMid -> blueDeep going out). So sand -> deep sea is ONE continuous teal->blue gradient
	-- with no dark seam. `deep >= 1` keeps blueDeep out of the shore band (only the deep ocean is blue).
	bands = {
		shallow = 0.40, -- depth01 < this -> tealLight (sunlit turquoise shallows)
		mid = 0.75, -- depth01 < this -> tealMid
		deep = 1.01, -- depth01 < this -> blueMid; the shore band never reaches blueDeep (the ocean does)
		lightenChance = 0.26, -- fraction of cells bumped one shade lighter
		darkenChance = 0.20, -- fraction of cells bumped one shade darker
	},
	palette = {
		foam = Color3.fromRGB(240, 250, 252), -- shore foam + ocean whitecaps
		tealLight = Color3.fromRGB(128, 216, 206), -- shallow shore
		tealMid = Color3.fromRGB(74, 184, 180),
		blueMid = Color3.fromRGB(46, 142, 164), -- shallow-sea teal-blue: shore edge + ocean NEAR colour
		blueDeep = Color3.fromRGB(24, 74, 122), -- deep open ocean (ocean FAR colour)
	},
	-- Big, soft patches of shade variation in the deep blue (so the open sea isn't one flat colour).
	oceanVarCell = 34, -- studs per deep-water shade patch
	oceanVarChance = 0.4, -- fraction of patches nudged to blueMid instead of blueDeep
}

return Config
