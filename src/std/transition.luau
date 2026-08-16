--!strict
-- Cartoon iris transition + planet loading card. SHARED so the black circle that closes over
-- the Lobby continues seamlessly into the Star place's loading screen and irises open on
-- arrival. Deliberately self-contained (no UI-framework / no LocalPlayer at module scope) so
-- ReplicatedFirst can require it before StarterPlayerScripts exist.
--
-- Used by:
--   * Lobby `UniverseField` — `close()` the iris on Enter, `buildTeleportGui()` for SetTeleportGui,
--     `open()` again if the server denies the trip (or it fails, e.g. Studio can't cross places).
--   * `ReplicatedFirst/LoadingScreen` — `cover()` instantly on the destination, then `open()`
--     once the world is ready.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local M = {}

export type Info = {
	name: string?, -- planet name (headline)
	types: { string }?, -- featured resource types (coloured chips)
	players: number?, -- destination player count (nil = hide the line)
	subtitle: string?, -- e.g. "Traveling…" / "Arriving…"
	primary: string?, -- primary resource type (headline tint); defaults to types[1]
}

local SILK = Font.new("rbxassetid://12187371840", Enum.FontWeight.Regular, Enum.FontStyle.Normal)

-- Resource-type colours (match Client/UniverseField's TYPE_COLOR) as hex, for RichText chips.
local TYPE_HEX: { [string]: string } = {
	Flora = "78C85A",
	Stone = "A0A0AA",
	Sand = "DCBE78",
	Frost = "AADCFF",
	Bog = "788C5A",
}
local function typeColor3(t: string?): Color3
	local hex = t and TYPE_HEX[t]
	return if hex then Color3.fromHex(hex) else Color3.fromRGB(230, 235, 245)
end

-- The circle must reach the screen's diagonal to cover every corner (the screen rectangle is
-- then inscribed in the disc). Fall back to 1080p if the camera isn't up yet (early load).
local function coverDiameter(): number
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	return math.sqrt(vp.X * vp.X + vp.Y * vp.Y) * 1.15
end

type Tree = {
	gui: ScreenGui,
	circle: Frame,
	card: CanvasGroup, -- CanvasGroup so the whole card fades as one unit (GroupTransparency)
	title: TextLabel,
	types: TextLabel,
	count: TextLabel,
	sub: TextLabel,
}

-- Build the full transition tree (black iris disc + planet card). Not parented — the caller
-- parents it (live overlay → PlayerGui; teleport GUI → handed to SetTeleportGui).
local function buildTree(): Tree
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlanetTransition"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local circle = Instance.new("Frame")
	circle.Name = "Iris"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromOffset(0, 0)
	circle.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
	circle.BorderSizePixel = 0
	circle.ZIndex = 1
	circle.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0) -- square frame → perfect circle
	corner.Parent = circle

	local card = Instance.new("CanvasGroup")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.82, 0.5)
	card.BackgroundTransparency = 1
	card.GroupTransparency = 0
	card.Visible = false
	card.ZIndex = 2
	card.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.Parent = card

	local function lbl(order: number, height: number, color: Color3, stroke: number): TextLabel
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, height)
		t.LayoutOrder = order
		t.FontFace = SILK
		t.RichText = true
		t.TextScaled = true
		t.TextColor3 = color
		t.TextStrokeTransparency = stroke
		t.TextTransparency = 0
		t.ZIndex = 2
		t.Parent = card
		return t
	end

	local title = lbl(1, 0.34, Color3.fromRGB(255, 255, 255), 0.4)
	local types = lbl(2, 0.14, Color3.fromRGB(220, 228, 240), 0.6)
	local count = lbl(3, 0.10, Color3.fromRGB(170, 180, 195), 0.7)
	local sub = lbl(4, 0.12, Color3.fromRGB(150, 160, 178), 0.7)

	return { gui = gui, circle = circle, card = card, title = title, types = types, count = count, sub = sub }
end

local function applyInfo(tree: Tree, info: Info?)
	info = info or {}
	local nfo = info :: Info
	tree.title.Text = nfo.name or "Deep Space"
	tree.title.TextColor3 = typeColor3(nfo.primary or (nfo.types and nfo.types[1]))

	if nfo.types and #nfo.types > 0 then
		local parts: { string } = {}
		for _, t in nfo.types do
			parts[#parts + 1] = `<font color="#{TYPE_HEX[t] or "E6EBF5"}">{t}</font>`
		end
		tree.types.Text = table.concat(parts, "   ·   ")
		tree.types.Visible = true
	else
		tree.types.Visible = false
	end

	if nfo.players then
		tree.count.Text = if nfo.players == 1 then "1 explorer here" else `{nfo.players} explorers here`
		tree.count.Visible = true
	else
		tree.count.Visible = false
	end

	tree.sub.Text = nfo.subtitle or "Traveling…"
end

-- ---- the live overlay (one per client) --------------------------------------
local live: Tree? = nil
local liveInfo: Info = {}
local pulse: Tween? = nil

local function ensureLive(): Tree
	if live and live.gui.Parent then
		return live :: Tree
	end
	local tree = buildTree()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	tree.gui.Parent = pg
	live = tree
	return tree
end

local function startPulse(tree: Tree)
	if pulse then
		pulse:Cancel()
	end
	tree.sub.TextTransparency = 0.7
	pulse = TweenService:Create(
		tree.sub,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ TextTransparency = 0.15 }
	)
	;(pulse :: Tween):Play()
end

local function stopPulse()
	if pulse then
		pulse:Cancel()
		pulse = nil
	end
end

-- Iris CLOSE: the black disc grows from a dot to swallow the screen, then the planet card
-- fades up. `done` fires once fully covered. Cartoon feel = a snappy Quad ease.
function M.close(info: Info?, dur: number?, done: (() -> ())?)
	local tree = ensureLive()
	liveInfo = info or {}
	applyInfo(tree, info)
	tree.card.Visible = false
	tree.card.GroupTransparency = 0
	local d = coverDiameter()
	local t = TweenService:Create(
		tree.circle,
		TweenInfo.new(dur or 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(d, d) }
	)
	t.Completed:Connect(function()
		tree.card.Visible = true
		startPulse(tree)
		if done then
			done()
		end
	end)
	t:Play()
end

-- Instantly fully covered + card up (destination's initial state, before the world reveals).
function M.cover(info: Info?)
	local tree = ensureLive()
	liveInfo = info or {}
	applyInfo(tree, info)
	-- Fixed large disc: the camera may not exist yet (early ReplicatedFirst load), so don't rely
	-- on the viewport diagonal here — just guarantee full coverage. open() snaps to the true
	-- diagonal before revealing.
	tree.circle.Size = UDim2.fromOffset(8000, 8000)
	tree.card.Visible = true
	startPulse(tree)
end

-- Merge-update the live card (e.g. fill in the player count once players have replicated).
function M.setLive(partial: Info)
	if not live then
		return
	end
	for k, v in partial :: any do
		(liveInfo :: any)[k] = v
	end
	applyInfo(live :: Tree, liveInfo)
end

-- Iris OPEN: fade the card, then shrink the disc away to reveal the world; tidy up after.
function M.open(dur: number?)
	local tree = live
	if not tree then
		return
	end
	local t = tree :: Tree
	stopPulse()
	-- Snap to the exact screen diagonal first (camera is up by now), so the whole shrink is an
	-- on-screen reveal rather than starting off-screen from the fixed cover disc. Any covered
	-- state is ≥ the diagonal, so this stays fully covered.
	local d = coverDiameter()
	t.circle.Size = UDim2.fromOffset(d, d)
	TweenService:Create(t.card, TweenInfo.new(0.2), { GroupTransparency = 1 }):Play()
	local shrink = TweenService:Create(
		t.circle,
		TweenInfo.new(dur or 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = UDim2.fromOffset(0, 0) }
	)
	shrink.Completed:Connect(function()
		t.gui:Destroy()
		if live == t then
			live = nil
		end
	end)
	shrink:Play()
end

-- Standalone, fully-covered transition GUI for TeleportService:SetTeleportGui (shown by the
-- engine during the trip). Static — no tween runs while the engine displays it, so we build it
-- already covered. Not parented; the caller hands it to SetTeleportGui.
function M.buildTeleportGui(info: Info?): ScreenGui
	local tree = buildTree()
	applyInfo(tree, info)
	tree.circle.Size = UDim2.fromOffset(6000, 6000) -- comfortably covers any handshake viewport
	tree.card.Visible = true
	return tree.gui
end

return M
