--[=[
    @Controller: BuildToolController (Forager Tycoon)
    @description: Client build mode + the build "context UI" transitions. Drives
    placement against the framework's server-authoritative PlacementComponent.

    Context UI (per the authored Interface layout):
      - `Interface.Building` (right-docked bar: Build / Move / Remove buttons) is
        the mode selector. It SLIDES IN once the player is in their plot, and
        slides out otherwise.
      - `Interface.HotBar` (bottom palette: Slot1..SlotN) selects which placeable
        is active. Clicking a slot only sets the selection — it does not change
        mode.
      - Entering any mode (Build/Edit/Remove) SLIDES THE HOTBAR DOWN and closes
        the other popup panels (Inventory, Equipments); exiting restores the
        HotBar. `UIStateController.SetState("Build"/"Vanilla")` is the single
        GUI-state authority so the rest of the UI can react.

    Modes:
      - Build  : ghost of the selected placeable follows the grid; click to place.
      - Edit   : click a placed model to pick it up (ghost), click a cell to move.
      - Remove : click a placed model to remove it.
    Controls: R rotates the ghost; Q or right-click exits the active mode.

    Placement is server-authoritative — the client only sends (type_name, gx, gy,
    rotation); the server validates and spawns/moves/removes the real model, which
    replicates back into the plot's ItemHolder.
]=]

-- / Services:

local Players = game:GetService('Players');
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local UserInputService = game:GetService('UserInputService');
local RunService = game:GetService('RunService');
local TweenService = game:GetService('TweenService');
local Workspace = game:GetService('Workspace');

-- / Imports:

local Controller = require(ReplicatedStorage.Shared.Framework.Main.Controller);
local Replication = require(ReplicatedStorage.Shared.Framework.Utils.Replication);
local StationRegistry = require(ReplicatedStorage.Shared.Modules.StationRegistry);
local StationPortIndicators = require(ReplicatedStorage.Shared.Modules.StationPortIndicators);
local UIStateController = require(ReplicatedStorage.Shared.Framework.UI.UIStateController);
-- The old game's UIManager is the single GUI-context authority for popup panels
-- (Inventory / Equipments / quickMenu / Shop / Chest). Build mode delegates
-- "close other UIs" to it instead of hiding panels itself.
local UIManager = require(ReplicatedStorage.ClientSystems.UI.UI);
local Logger = require(ReplicatedStorage.Logger);

-- / Constants:

local IDENTIFIER = "BuildToolController";

local TILE_SIZE = StationRegistry.TILE_SIZE;
local FLOOR_HEIGHT = TILE_SIZE; -- one floor = one tile in Y (matches StationRegistry)
local MODELS_FOLDER_NAME = "Models";
local INTERFACE_NAME = "Interface";
local HOTBAR_NAME = "HotBar";
local BUILDING_NAME = "Building";
local BUILD_SELECT_NAME = "BuildSelect";
local ITEM_HOLDER_NAME = "ItemHolder";
local ERROR_LABEL_NAME = "Error";

local ROTATIONS = { "R0", "R90", "R180", "R270" };
local ROTATION_DEGREES = { R0 = 0, R90 = 90, R180 = 180, R270 = 270 };

-- Vertical (pitch) rotation — T key cycles it. Mirrors PlacementService.VALID_PITCHES.
local PITCHES = { "Flat", "Up", "Down" };
local PITCH_DEGREES = { Flat = 0, Up = 90, Down = -90 };

local SLIDE_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out);
local HOTBAR_HIDE_DY = 0.3;   -- Y-scale pushed below screen
local BUILDING_HIDE_DX = 0.25; -- X-scale pushed off the right edge
local BUILD_SELECT_HIDE_DY = 0.4; -- Y-scale pushed below screen (the build picker bar)

local GHOST_TRANSPARENCY = 0.5;
local GHOST_OK_COLOR = Color3.fromRGB(80, 220, 120);

-- Hover highlight tint per mode (edit = blue, remove = red); active mode button stroke.
local HOVER_COLOR_EDIT = Color3.fromRGB(80, 150, 255);
local HOVER_COLOR_REMOVE = Color3.fromRGB(220, 80, 80);
local MODE_ACTIVE_STROKE = Color3.fromRGB(165, 170, 180); -- soft gray (toggled state)

local ERROR_TEXT = {
    insufficient_coins = "Not enough coins!",
    cell_occupied = "Something's already there.",
    out_of_bounds = "Outside your plot.",
    tile_locked = "That tile is locked.",
    no_plot = "No plot assigned yet.",
    no_prefab = "That placeable has no model.",
    no_support = "Needs support below.",
    unknown_type = "Unknown placeable.",
    unknown_item = "That isn't yours to edit.",
};

-- / Controller:

local BuildToolController = Controller.Extend({
    identifier = IDENTIFIER;
    dependencies = {};
    replica_dependencies = {};
    state = {};
});

-- / Private — grid math (mirrors server PlacementService cell-center convention):

local function _gridOrigin(plot_size)
    return TILE_SIZE * 0.5 - (plot_size % (2 * TILE_SIZE)) * 0.5;
end

function BuildToolController:_WorldToGrid(worldPos)
    local plot = self._plot;
    local localP = plot.CFrame:PointToObjectSpace(worldPos);
    local gx = math.floor((localP.X - _gridOrigin(plot.Size.X)) / TILE_SIZE + 0.5);
    local gy = math.floor((localP.Z - _gridOrigin(plot.Size.Z)) / TILE_SIZE + 0.5);
    return gx, gy;
end

function BuildToolController:_GridToWorld(gx, gy, rotation, prefabHeight, pitch, gz)
    local plot = self._plot;
    local px = gx * TILE_SIZE + _gridOrigin(plot.Size.X);
    local pz = gy * TILE_SIZE + _gridOrigin(plot.Size.Z);
    local addY = (plot.Size.Y * 0.5) + ((gz or 0) * FLOOR_HEIGHT) + (prefabHeight * 0.5);
    local yawRad = math.rad(ROTATION_DEGREES[rotation]);
    local pitchRad = math.rad(PITCH_DEGREES[pitch or "Flat"] or 0);
    local localCFrame = CFrame.new(px, addY, pz) * CFrame.Angles(0, yawRad, 0) * CFrame.Angles(0, 0, pitchRad);
    return plot.CFrame * localCFrame;
end

-- / Private — plot resolution (lazy; AssignPlot runs server-side at register):

function BuildToolController:_ResolvePlot()
    if self._plot and self._plot.Parent then return true end

    local resp = Replication.InvokeServer("Session", {
        Identifier = "PlacementComponent";
        Call = "GetPlotName";
        Args = {};
    });

    if type(resp) ~= "table" or not resp.ok or not resp.plot_name then
        return false;
    end

    local plotsFolder = Workspace:FindFirstChild("Plots");
    local plot = plotsFolder and plotsFolder:FindFirstChild(resp.plot_name, true);
    if not plot or not plot:IsA("BasePart") then return false end

    self._plot = plot;
    self._itemHolder = plot:FindFirstChild(ITEM_HOLDER_NAME);
    return true;
end

-- / Private — ghost:

function BuildToolController:_DestroyGhost()
    if self._ghost then
        self._ghost:Destroy();
        self._ghost = nil;
    end
end

function BuildToolController:_BuildGhost(type_name)

    self:_DestroyGhost();

    local modelsFolder = ReplicatedStorage:FindFirstChild(MODELS_FOLDER_NAME);
    local prefab = modelsFolder and modelsFolder:FindFirstChild(type_name);
    if not prefab or not prefab:IsA("Model") or not prefab.PrimaryPart then
        Logger.warn(`[{IDENTIFIER}:BuildGhost] No usable prefab for '{type_name}'`);
        return false;
    end

    local ghost = prefab:Clone();
    -- Keep the model's real look; just make it non-interactive. Validity reads from a
    -- Highlight overlay (green), not by recoloring the whole model.
    for _, d in ipairs(ghost:GetDescendants()) do
        if d:IsA("BasePart") then
            d.CanCollide = false;
            d.CanQuery = false;
            d.Anchored = true;
        elseif d:IsA("Script") or d:IsA("LocalScript") then
            d:Destroy();
        end
    end

    local highlight = Instance.new("Highlight");
    highlight.Name = "GhostHighlight";
    highlight.FillColor = GHOST_OK_COLOR;
    highlight.FillTransparency = 0.7;
    highlight.OutlineColor = GHOST_OK_COLOR;
    highlight.OutlineTransparency = 0;
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop;
    highlight.Adornee = ghost;
    highlight.Parent = ghost;

    ghost.Parent = Workspace;

    self._ghost = ghost;
    self._ghostHeight = prefab.PrimaryPart.Size.Y;

    -- IN (blue) / OUT (green) port arrows, parented into the ghost so they follow it
    -- rigidly via the per-frame PivotTo (position + rotation). Cleared on _DestroyGhost.
    StationPortIndicators.Attach(ghost, type_name);

    return true;
end

function BuildToolController:_UpdateGhost()

    if not self._ghost or not self._plot then return end

    local camera = Workspace.CurrentCamera;
    if not camera then return end

    local mouseLoc = UserInputService:GetMouseLocation();
    local ray = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y);

    local params = RaycastParams.new();
    params.FilterType = Enum.RaycastFilterType.Include;
    params.FilterDescendantsInstances = { self._plot };

    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params);
    if not hit then return end

    -- Face-based placement: if the cursor is over a placed station, target the cell
    -- adjacent to it ON THE FACE the player is pointing at (from the hit normal) — top
    -- face stacks a floor up, a SIDE face builds beside it (off a ledge/pillar), the
    -- bottom face goes a floor down. Over the bare plot, snap to the hovered ground cell.
    -- (Hitbox is CanQuery=false, so we hit the visible geometry → the normal is real.)
    local gx, gy, gz;
    local model;
    local itemHolder = self._itemHolder or (self._plot and self._plot:FindFirstChild(ITEM_HOLDER_NAME));
    if itemHolder and hit.Instance then
        model = hit.Instance:FindFirstAncestorOfClass("Model");
        while model and model.Parent ~= itemHolder do
            model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model");
        end
        if model and model:GetAttribute("Id") == nil then model = nil end
    end

    if model then
        local mgx = model:GetAttribute("Gx") or 0;
        local mgy = model:GetAttribute("Gy") or 0;
        local mFloor = model:GetAttribute("Floor") or 0;
        local mTop = model:GetAttribute("TopFloor") or mFloor;
        -- Hit normal in plot-local space: X→gx axis, Z→gy axis, Y→floor.
        local n = self._plot.CFrame:VectorToObjectSpace(hit.Normal);
        local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z);
        if ay >= ax and ay >= az then
            gx, gy = mgx, mgy;
            gz = (n.Y >= 0) and (mTop + 1) or (mFloor - 1);  -- top stacks up, bottom goes down
        elseif ax >= az then
            gx, gy, gz = mgx + (n.X >= 0 and 1 or -1), mgy, mFloor;  -- E/W ledge
        else
            gx, gy, gz = mgx, mgy + (n.Z >= 0 and 1 or -1), mFloor;  -- N/S ledge
        end
        if gz < 0 then gz = 0 end
    else
        gx, gy = self:_WorldToGrid(hit.Position);
        gz = 0;
    end

    self._gx, self._gy, self._gz = gx, gy, gz;

    local cf = self:_GridToWorld(gx, gy, ROTATIONS[self._rotationIndex], self._ghostHeight or 1, PITCHES[self._pitchIndex or 1], gz);
    self._ghost:PivotTo(cf);
end

-- / Private — pick a placed model under the cursor (has a server "Id" attribute):

function BuildToolController:_PickPlacedModel()

    if not self._itemHolder then
        self._itemHolder = self._plot and self._plot:FindFirstChild(ITEM_HOLDER_NAME);
    end
    if not self._itemHolder then return nil end

    local camera = Workspace.CurrentCamera;
    if not camera then return nil end

    local mouseLoc = UserInputService:GetMouseLocation();
    local ray = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y);

    local params = RaycastParams.new();
    params.FilterType = Enum.RaycastFilterType.Include;
    params.FilterDescendantsInstances = { self._itemHolder };

    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params);
    if not hit then return nil end

    local model = hit.Instance:FindFirstAncestorOfClass("Model");
    while model and model.Parent ~= self._itemHolder do
        model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model");
    end
    if not model or model:GetAttribute("Id") == nil then return nil end

    return model;
end

-- / Private — UI feedback + context transitions:

function BuildToolController:_FlashError(code)
    local label = self._errorLabel;
    if not label then return end
    label.Text = ERROR_TEXT[code] or ("Can't: " .. tostring(code));
    label.Visible = true;
    self._errorToken = (self._errorToken or 0) + 1;
    local token = self._errorToken;
    task.delay(2, function()
        if self._errorToken == token and label then label.Visible = false end
    end);
end

function BuildToolController:_SlideBuilding(visibleIn)
    local f = self._buildingFrame;
    if not f or not self._buildingShownPos then return end
    local target = visibleIn and self._buildingShownPos
        or (self._buildingShownPos + UDim2.fromScale(BUILDING_HIDE_DX, 0));
    TweenService:Create(f, SLIDE_INFO, { Position = target }):Play();
end

function BuildToolController:_SlideHotbar(visibleIn)
    local f = self._hotbarFrame;
    if not f or not self._hotbarShownPos then return end
    local target = visibleIn and self._hotbarShownPos
        or (self._hotbarShownPos + UDim2.fromScale(0, HOTBAR_HIDE_DY));
    TweenService:Create(f, SLIDE_INFO, { Position = target }):Play();
end

-- The horizontal build-select bar: slides UP into where the HotBar was when a build
-- mode is active, slides back DOWN on exit.
function BuildToolController:_SlideBuildSelect(visibleIn)
    local f = self._buildSelectFrame;
    if not f or not self._buildSelectShownPos then return end
    local target = visibleIn and self._buildSelectShownPos
        or (self._buildSelectShownPos + UDim2.fromScale(0, BUILD_SELECT_HIDE_DY));
    TweenService:Create(f, SLIDE_INFO, { Position = target }):Play();
end

-- True when the local character is standing on its OWN assigned plot.
function BuildToolController:_IsOnPlot()
    if not self._plot or not self._plot.Parent then return false end
    local character = Players.LocalPlayer and Players.LocalPlayer.Character;
    local root = character and character:FindFirstChild("HumanoidRootPart");
    if not root then return false end
    local lp = self._plot.CFrame:PointToObjectSpace(root.Position);
    local size = self._plot.Size;
    return math.abs(lp.X) <= size.X * 0.5 + 2
        and math.abs(lp.Z) <= size.Z * 0.5 + 2
        and lp.Y >= -size.Y and lp.Y <= 80;
end

-- The Building bar (mode selector) is shown ONLY while the player is on their plot;
-- walking off slides it out and exits any active mode.
function BuildToolController:_StartPlotPresenceWatch()
    if self._presenceConn then return end
    local accum = 0;
    self._presenceConn = RunService.Heartbeat:Connect(function(dt)
        accum += dt;
        if accum < 0.2 then return end
        accum = 0;
        if not self:_ResolvePlot() then return end
        local on = self:_IsOnPlot();
        if on and not self._buildingShown then
            self._buildingShown = true;
            self:_SlideBuilding(true);
        elseif not on and self._buildingShown then
            self._buildingShown = false;
            self:_SlideBuilding(false);
            if self._mode then self:ExitMode() end
        end
    end);
end

-- / Private — hover highlight + active-mode button:

function BuildToolController:_EnsureHoverHighlight()
    if self._hoverHighlight then return end
    local h = Instance.new("Highlight");
    h.Name = "BuildHoverHighlight";
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop;
    h.FillTransparency = 0.55;
    h.OutlineTransparency = 0;
    h.OutlineColor = Color3.fromRGB(255, 255, 255);
    h.Adornee = nil;
    h.Enabled = false;
    h.Parent = Workspace;
    self._hoverHighlight = h;
end

function BuildToolController:_SetHoverColor(color)
    self:_EnsureHoverHighlight();
    if self._hoverHighlight then self._hoverHighlight.FillColor = color end
end

function BuildToolController:_ClearHover()
    if self._hoverHighlight then
        self._hoverHighlight.Adornee = nil;
        self._hoverHighlight.Enabled = false;
    end
end

-- A Highlight renders reliably on a Model once it contains a Humanoid; placed stations
-- are plain part models, so tag the hovered one with a bare (client-only) Humanoid the
-- first time it's hovered. Every part is Anchored, so the Humanoid never moves it.
function BuildToolController:_EnsureHighlightable(model)
    if model:FindFirstChildOfClass("Humanoid") then return end
    local h = Instance.new("Humanoid");
    h.Name = "UXHighlightHumanoid";
    h.Parent = model;
end

-- Edit/Remove: highlight the placed station under the cursor each frame.
function BuildToolController:_UpdateHover()
    if not self._hoverHighlight then return end
    local model = self:_PickPlacedModel();
    if model then
        self:_EnsureHighlightable(model);
        self._hoverHighlight.Adornee = model;
        self._hoverHighlight.Enabled = true;
    else
        self._hoverHighlight.Adornee = nil;
        self._hoverHighlight.Enabled = false;
    end
end

-- Active-mode visual on the Building bar (Build / Move / Remove buttons).
function BuildToolController:_HighlightModeButton(activeMode)
    if not self._modeButtons then return end
    for mode, btn in pairs(self._modeButtons) do
        local stroke = btn:FindFirstChild("ModeActiveStroke");
        if not stroke then
            stroke = Instance.new("UIStroke");
            stroke.Name = "ModeActiveStroke";
            stroke.Color = MODE_ACTIVE_STROKE;
            stroke.Thickness = 2;
            stroke.Transparency = 0.15;
            stroke.Parent = btn;
        end
        stroke.Enabled = (mode == activeMode);
    end
end

-- / Public — mode control:

function BuildToolController:_EnterMode(mode)

    if not self:_ResolvePlot() then
        self:_FlashError("no_plot");
        return;
    end

    -- Re-clicking the active mode button toggles it off.
    if self._mode == mode then
        self:ExitMode();
        return;
    end

    self:ExitMode(true); -- clear any prior mode without restoring the hotbar yet

    self._mode = mode;
    self._editStage = (mode == "Edit") and "pick" or nil;
    self._rotationIndex = self._rotationIndex or 1;

    if mode == "Build" then
        local type_name = self._selectedType or StationRegistry.GetTypeNames()[1];
        if not type_name or not self:_BuildGhost(type_name) then
            self:_FlashError("no_prefab");
            self._mode = nil;
            return;
        end
        self._selectedType = type_name;
    end

    UIStateController.SetState("Build");
    self:_SlideHotbar(false);
    -- Only Build mode needs the placeable picker; Move/Remove act on existing stations.
    self:_SlideBuildSelect(mode == "Build");
    UIManager:CloseAll();

    -- Active-mode button highlight + per-mode hover tint (Build uses the ghost,
    -- so its hover is cleared; Edit/Remove highlight the station under the cursor).
    self:_HighlightModeButton(mode);
    if mode == "Edit" then
        self:_SetHoverColor(HOVER_COLOR_EDIT);
    elseif mode == "Remove" then
        self:_SetHoverColor(HOVER_COLOR_REMOVE);
    else
        self:_ClearHover();
    end

    if not self._renderConn then
        self._renderConn = RunService.RenderStepped:Connect(function()
            if self._ghost then
                self:_UpdateGhost();
            elseif self._mode == "Edit" or self._mode == "Remove" then
                self:_UpdateHover();
            end
        end);
    end

    Logger.info(`[{IDENTIFIER}:EnterMode] {mode}`);
end

function BuildToolController:ExitMode(silent)
    self._mode = nil;
    self._editStage = nil;
    self._editId = nil;
    self:_DestroyGhost();
    self:_ClearHover();
    if self._renderConn then
        self._renderConn:Disconnect();
        self._renderConn = nil;
    end
    if not silent then
        UIStateController.SetState("Vanilla");
        self:_SlideBuildSelect(false);
        self:_SlideHotbar(true);
        self:_HighlightModeButton(nil);
    end
end

function BuildToolController:_Rotate()
    if not self._ghost then return end
    self._rotationIndex = (self._rotationIndex % #ROTATIONS) + 1;
end

function BuildToolController:_Pitch()
    if not self._ghost then return end
    self._pitchIndex = ((self._pitchIndex or 1) % #PITCHES) + 1;
end

-- / Private — click handlers per mode:

function BuildToolController:_OnClick()

    if self._mode == "Build" then
        self:_TryPlace();

    elseif self._mode == "Remove" then
        local model = self:_PickPlacedModel();
        if not model then return end
        self:_Invoke("RequestRemove", { model:GetAttribute("Id") });

    elseif self._mode == "Edit" then
        if self._editStage == "pick" then
            local model = self:_PickPlacedModel();
            if not model then return end
            self._editId = model:GetAttribute("Id");
            local type_name = model:GetAttribute("Type") or self._selectedType;
            if type_name and self:_BuildGhost(type_name) then
                self._editStage = "move";
            end
        elseif self._editStage == "move" and self._editId and self._gx then
            local resp = self:_Invoke("RequestEdit",
                { self._editId, self._gx, self._gy, ROTATIONS[self._rotationIndex], self._gz or 0, PITCHES[self._pitchIndex or 1] });
            if type(resp) == "table" and resp.ok then
                self:_DestroyGhost();
                self._editId = nil;
                self._editStage = "pick";
            end
        end
    end
end

function BuildToolController:_Invoke(call, args)
    local resp = Replication.InvokeServer("Session", {
        Identifier = "PlacementComponent";
        Call = call;
        Args = args;
    });
    if type(resp) ~= "table" or not resp.ok then
        local code = (type(resp) == "table" and resp.error_code) or "unknown";
        self:_FlashError(code);
    end
    return resp;
end

function BuildToolController:_TryPlace()
    if not self._selectedType or not self._gx then return end
    local resp = self:_Invoke("RequestPlace",
        { self._selectedType, self._gx, self._gy, ROTATIONS[self._rotationIndex], self._gz or 0, PITCHES[self._pitchIndex or 1] });
    if type(resp) == "table" and resp.ok then
        Logger.info(`[{IDENTIFIER}:Place] '{self._selectedType}' (item {tostring(resp.item_id)}) at {self._gx},{self._gy}`);
    end
end

-- / Private — wiring:

function BuildToolController:_WireHotbar(interface)
    local hotbar = interface:FindFirstChild(HOTBAR_NAME);
    if not hotbar then return end

    self._hotbarFrame = hotbar;
    self._hotbarShownPos = hotbar.Position;

    local typeNames = StationRegistry.GetTypeNames();
    for index, type_name in ipairs(typeNames) do
        local slot = hotbar:FindFirstChild("Slot" .. index);
        if slot and slot:IsA("GuiButton") then
            slot:SetAttribute("PlaceableType", type_name);
            slot.Activated:Connect(function()
                self._selectedType = type_name; -- selection only; mode unchanged
                if self._mode == "Build" then self:_BuildGhost(type_name) end
            end);
        end
    end

    -- Default selection so Build works before any slot is clicked.
    self._selectedType = typeNames[1];
end

function BuildToolController:_WireBuilding(interface)
    local building = interface:FindFirstChild(BUILDING_NAME);
    if not building then
        Logger.warn(`[{IDENTIFIER}:WireBuilding] {BUILDING_NAME} frame not found — mode buttons disabled`);
        return;
    end

    self._buildingFrame = building;
    self._buildingShownPos = building.Position;
    -- Start slid out; slides in once the plot resolves.
    building.Position = self._buildingShownPos + UDim2.fromScale(BUILDING_HIDE_DX, 0);

    self._modeButtons = {};
    local map = { Build = "Build", Move = "Edit", Remove = "Remove" };
    for buttonName, mode in pairs(map) do
        local btn = building:FindFirstChild(buttonName);
        if btn and btn:IsA("GuiButton") then
            self._modeButtons[mode] = btn;
            btn.Activated:Connect(function()
                self:_EnterMode(mode);
            end);
        end
    end
end

-- Live 3D icon of a placeable in a ViewportFrame (prefab cloned, centered, 3/4 cam).
-- Populate an existing Icon ViewportFrame (from the editable tile template) with a
-- live 3D model of the placeable. Only the 3D content is generated; the frame is authored.
function BuildToolController:_FillIcon(vf, type_name)
    if not vf or not vf:IsA("ViewportFrame") then return end
    for _, ch in ipairs(vf:GetChildren()) do
        if ch:IsA("Model") or ch:IsA("BasePart") or ch:IsA("Camera") then ch:Destroy() end
    end
    vf.Ambient = Color3.fromRGB(190, 190, 200);
    vf.LightColor = Color3.fromRGB(255, 255, 255);
    vf.LightDirection = Vector3.new(-1, -1.2, -0.6);

    local models = ReplicatedStorage:FindFirstChild(MODELS_FOLDER_NAME);
    local prefab = models and models:FindFirstChild(type_name);
    if not prefab or not prefab:IsA("Model") then return end

    local clone = prefab:Clone();
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") then
            if d.Transparency >= 0.9 then
                d:Destroy();
            else
                d.Anchored = true; d.CanCollide = false;
                if d.Transparency > 0.05 then d.Transparency = 0 end
            end
        elseif d:IsA("BillboardGui") or d:IsA("ProximityPrompt") or d:IsA("Script") or d:IsA("LocalScript") then
            d:Destroy();
        end
    end

    local bbCF, sz = clone:GetBoundingBox();
    local shift = -bbCF.Position;
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") then d.CFrame = d.CFrame + shift end
    end
    clone.Parent = vf;

    local cam = Instance.new("Camera");
    cam.FieldOfView = 30;
    vf.CurrentCamera = cam;
    cam.Parent = vf;
    local maxExtent = math.max(sz.X, sz.Y, sz.Z, 1);
    local dist = maxExtent * 2.4;
    cam.CFrame = CFrame.lookAt(Vector3.new(dist * 0.7, dist * 0.6, dist * 0.7), Vector3.zero);
end

function BuildToolController:_UpdateBuildInfo(type_name)
    local info = self._buildSelectFrame and self._buildSelectFrame:FindFirstChild("Info");
    if not info then return end
    local nameLabel = info:FindFirstChild("Name");
    local descLabel = info:FindFirstChild("Desc");
    if type_name then
        if nameLabel then nameLabel.Text = type_name end
        if descLabel then
            local cost = StationRegistry.GetCost(type_name) or 0;
            local mi = StationRegistry.GetMachineInfo(type_name);
            descLabel.Text = `Cost: {cost}c` .. (mi and mi.desc and ("\n" .. mi.desc) or "");
        end
    else
        if nameLabel then nameLabel.Text = "" end
        if descLabel then descLabel.Text = "" end
    end
end

function BuildToolController:_HighlightEntry(type_name)
    if not self._entryTiles then return end
    for name, tile in pairs(self._entryTiles) do
        local stroke = tile:FindFirstChildOfClass("UIStroke");
        if stroke then stroke.Transparency = (name == type_name) and 0 or 1 end
    end
end

-- An entry tile cloned from the editable BuildSelect.TileTemplate: fill icon + name,
-- wire selection. Styling lives on the template in Studio.
function BuildToolController:_BuildEntryTile(type_name, parent, order)
    if not self._tileTemplate then return end
    local tile = self._tileTemplate:Clone();
    tile.Name = "Tile_" .. type_name;
    tile.LayoutOrder = order;
    tile.Visible = true;
    tile.Parent = parent;

    local label = tile:FindFirstChild("Label");
    if label then label.Text = type_name end
    local icon = tile:FindFirstChild("Icon");
    if icon then self:_FillIcon(icon, type_name) end

    tile.Activated:Connect(function()
        self._selectedType = type_name;
        if self._mode == "Build" then self:_BuildGhost(type_name) end
        self:_HighlightEntry(type_name);
        self:_UpdateBuildInfo(type_name);
    end);

    self._entryTiles[type_name] = tile;
    return tile;
end

-- (Re)generate the entry tiles for a category into the Items scroller.
function BuildToolController:_PopulateItems(category)
    local items = self._buildSelectFrame and self._buildSelectFrame:FindFirstChild("Items");
    if not items then return end
    for _, ch in ipairs(items:GetChildren()) do
        if ch:IsA("GuiButton") then ch:Destroy() end
    end
    self._entryTiles = {};
    local order = 0;
    for _, type_name in ipairs(StationRegistry.GetTypeNamesInCategory(category)) do
        order += 1;
        self:_BuildEntryTile(type_name, items, order);
    end
    self._activeCategory = category;
    self:_HighlightEntry(self._selectedType);
end

function BuildToolController:_SelectCategory(category)
    if self._tabButtons then
        for cat, btn in pairs(self._tabButtons) do
            btn.BackgroundTransparency = (cat == category) and 0.05 or 0.55;
        end
    end
    self:_PopulateItems(category);
end

function BuildToolController:_BuildTabs()
    local tabs = self._buildSelectFrame and self._buildSelectFrame:FindFirstChild("Tabs");
    if not tabs or not self._tabTemplate then return end
    self._tabButtons = {};
    local order = 0;
    for _, category in ipairs(StationRegistry.GetCategories()) do
        order += 1;
        local btn = self._tabTemplate:Clone();
        btn.Name = "Tab_" .. category;
        btn.Text = category;
        btn.LayoutOrder = order;
        btn.Visible = true;
        btn.Parent = tabs;
        btn.Activated:Connect(function() self:_SelectCategory(category) end);
        self._tabButtons[category] = btn;
    end
end

function BuildToolController:_WireBuildSelect(interface)
    local panel = interface:FindFirstChild(BUILD_SELECT_NAME);
    if not panel then
        Logger.warn(`[{IDENTIFIER}:WireBuildSelect] {BUILD_SELECT_NAME} panel not found — build picker disabled`);
        return;
    end

    self._buildSelectFrame = panel;
    self._tileTemplate = panel:FindFirstChild("TileTemplate");
    self._tabTemplate = panel:FindFirstChild("TabTemplate");
    if not self._tileTemplate or not self._tabTemplate then
        Logger.warn(`[{IDENTIFIER}:WireBuildSelect] TileTemplate/TabTemplate missing under {BUILD_SELECT_NAME} — picker won't populate`);
    end
    self._buildSelectShownPos = panel.Position;
    -- Start slid down (hidden); slides up when a build mode is entered.
    panel.Position = self._buildSelectShownPos + UDim2.fromScale(0, BUILD_SELECT_HIDE_DY);

    -- Build the category tabs + the first category's entries (cloned from the templates).
    self:_BuildTabs();
    local categories = StationRegistry.GetCategories();
    if categories[1] then self:_SelectCategory(categories[1]) end
end

function BuildToolController:_WireInput()
    self._inputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if not self._mode then return end

        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self:_OnClick();
        elseif input.KeyCode == Enum.KeyCode.R then
            self:_Rotate();
        elseif input.KeyCode == Enum.KeyCode.T then
            self:_Pitch();
        end
        -- Exit a mode by re-clicking its Building-bar button (no keyboard cancel).
    end);
end

-- / Lifecycle:

function BuildToolController:RunOnCompilationCompleted()
    if not self.config then return end
    self._rotationIndex = 1;
    self._mode = nil;
end

function BuildToolController:RunOnRegistrationCompleted()

    if not self.config then return end

    local localPlayer = Players.LocalPlayer;
    local playerGui = localPlayer and localPlayer:WaitForChild("PlayerGui", 10);
    local interface = playerGui and playerGui:WaitForChild(INTERFACE_NAME, 10);

    if not interface then
        Logger.warn(`[{IDENTIFIER}:Register] {INTERFACE_NAME} ScreenGui missing — build tool disabled`);
        return;
    end

    self._interface = interface;
    self._errorLabel = interface:FindFirstChild(ERROR_LABEL_NAME, true);

    self:_WireHotbar(interface);
    self:_WireBuilding(interface);
    self:_WireBuildSelect(interface);
    self:_WireInput();

    -- The Building bar appears only while the player stands on their own plot.
    self:_StartPlotPresenceWatch();

    Logger.info(`[{IDENTIFIER}:Register] Build tool ready ({#StationRegistry.GetTypeNames()} placeables)`);
end

return BuildToolController;
