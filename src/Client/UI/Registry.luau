-- StarterPlayerScripts/UIRegistry.luau
-- THE one place the game's UI is declared, so everything behaves uniformly and
-- there's a single spot to maintain. It:
--   1. registers every toggle panel with UIController (frames/group/modal/key),
--   2. wires the buttons that open/close them (by path), and
--   3. gives EVERY button under Interface uniform hover+click feedback — including
--      buttons that don't exist yet (item slots, future panels) via DescendantAdded.
--      Add a button in Studio → it gets feedback for free. Add a panel frame + one
--      line here → it's fully wired.
--
-- Modal feature-prompts (CreatePlanet) self-register in their own controller because
-- they need custom onClose logic; everything else lives here. See .claude/19.

local Players = game:GetService("Players")

local UIData = require(script.Parent.UIData)
local UIController = require(script.Parent.Controller)
local UISound = require(script.Parent.Sound)
local UITween = require(script.Parent.Tween)

local interface = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Interface")

-- ---- panel declarations -----------------------------------------------------
-- Panels whose primary frame is missing are skipped (declare future ones freely).
local PANELS: { { name: string, primary: string, cfg: any } } = {
	{
		name = "Inventory",
		primary = "Inventory",
		cfg = { frames = { "Inventory", "Equipments" }, group = "main", key = Enum.KeyCode.E },
	},
	-- The quick menu itself is a panel: it ships Visible = false and the Menu
	-- button is what raises it (Quest / Map / Bag / Back live inside it).
	{ name = "QuickMenu", primary = "QuickMenu", cfg = { group = "main" } },
	-- Future panels — add the frame in Studio + a button below and they light up:
	{ name = "Map", primary = "Map", cfg = { group = "main" } },
	{ name = "Quest", primary = "Quest", cfg = { group = "main" } },
	{ name = "Settings", primary = "Settings", cfg = { group = "main" } },
}

-- button path (under Interface) → panel + action. Skipped if either is absent.
local BUTTONS: { { path: string, panel: string, action: string } } = {
	-- NOTE the capital Q. These read "quickMenu" for a long time, and
	-- FindFirstChild is case-SENSITIVE — every path resolved to nil, and byPath
	-- returning nil is a silent skip, so Bag/Map/Quest simply did nothing.
	{ path = "QuickMenu.Bag", panel = "Inventory", action = "toggle" },
	{ path = "Inventory.Exit", panel = "Inventory", action = "close" },
	{ path = "QuickMenu.Map", panel = "Map", action = "toggle" },
	{ path = "QuickMenu.Quest", panel = "Quest", action = "toggle" },
	-- Menu (a direct child of Interface) raises the quick menu. There is no
	-- QuickMenu.Menu — its children are Quest / Map / Bag / Back.
	{ path = "Menu", panel = "QuickMenu", action = "toggle" },
}

local function byPath(path: string): Instance?
	local node: Instance = interface
	for _, part in string.split(path, ".") do
		node = node:FindFirstChild(part) :: Instance
		if not node then
			return nil
		end
	end
	return node
end

-- ---- register panels + hide them (they start closed) ------------------------
local registered: { [string]: boolean } = {}
for _, p in PANELS do
	if interface:FindFirstChild(p.primary) and UIController.register(p.name, p.cfg) then
		registered[p.name] = true
		for _, fname in (p.cfg.frames or { p.name }) do
			local f = interface:FindFirstChild(fname)
			if f then
				(f :: GuiObject).Visible = false
			end
		end
	end
end

-- ---- wire open/close buttons ------------------------------------------------
for _, b in BUTTONS do
	if registered[b.panel] then
		local btn = byPath(b.path)
		if btn and btn:IsA("GuiButton") then
			btn:SetAttribute("UISoundOwned", true) -- the panel open/close sound is the feedback
			btn.MouseButton1Click:Connect(function()
				if b.action == "close" then
					UIController.close(b.panel)
				else
					UIController.toggle(b.panel)
				end
			end)
		end
	end
end

-- ---- universal button feedback (current + future buttons) -------------------
-- Hover for all (throttled so sweeping a grid doesn't machine-gun). Click plays
-- "select" UNLESS a button is UISoundOwned (a panel button / controller-owned one),
-- checked at click time so registration order never matters.
local HOVER_CD = 0.06
local lastHover = 0

local function bindFeedback(btn: GuiButton)
	if btn:GetAttribute("UIFeedback") then
		return
	end
	btn:SetAttribute("UIFeedback", true)
	UITween.buttonFX(btn) -- uniform hover=brighter+bigger, press=dimmer+smaller
	btn.MouseEnter:Connect(function()
		local t = os.clock()
		if t - lastHover >= HOVER_CD then
			lastHover = t
			UISound.play("hover") -- uniform hover sound
		end
	end)
	btn.MouseButton1Click:Connect(function()
		if not btn:GetAttribute("UISoundOwned") then
			UISound.play("select")
		end
	end)
end

-- Uniform font: stamp Silkscreen (Regular, never bold) on every text element.
local function applyFont(d: Instance)
	if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
		(d :: any).FontFace = UIData.Font
	end
end

for _, d in interface:GetDescendants() do
	if d:IsA("GuiButton") then
		bindFeedback(d)
	end
	applyFont(d)
end
interface.DescendantAdded:Connect(function(d)
	if d:IsA("GuiButton") then
		bindFeedback(d)
	end
	applyFont(d)
end)

return {}
