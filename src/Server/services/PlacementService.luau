--[=[
    @System: PlacementService
    @description: Server-authoritative placement system for the Factory Build epic.
    Owns plot assignment (one workspace plot per player), grid cell occupancy, and
    place / remove flows. The `PlacementComponent` is a thin per-player session
    wrapper that exposes `RequestPlace` and `RequestRemove` to clients and delegates
    to this module.

    State (module-level):
        - `_plotsByInstance` — every BasePart in `workspace.Plots`, mapped to a
          per-plot record (cells, byId, ownerUserId).
        - `_playerToPlot` — UserId -> PlotRecord pointer for fast lookup.
        - `_nextItemId` — monotonic counter for placed-item IDs (used as the cell
          occupancy value AND the lookup key in `byId`).

    Grid geometry uses `TILE_SIZE` studs to match `StationRegistry`. Cell keys
    are `"gx,gy,gz"` strings (Luau tables don't natively hash on tuples), where
    gz is the floor index (0 = ground, +1 per `FLOOR_HEIGHT` studs up — v1
    vertical stacking). gz is carried in `PlaceStation`'s `options.gz` and
    defaults to 0, so every legacy single-floor path keys the ground floor.

    Per-plot ownership (CLO-179):
        Both `PlaceStation` and `RemoveStation` resolve the plot via
        `GetPlayerPlot(player)` — they only ever operate on the caller's own plot
        record. There is no API surface that accepts a foreign plot reference, so
        cross-plot griefing is structurally impossible:
            - PlaceStation with (gx, gy) targets only the caller's plot bounds.
              Coordinates valid for plot A but inside plot B are still rejected
              with `out_of_bounds` against A — they never touch B's cell map.
            - RemoveStation with a leaked item_id from plot A is rejected with
              `unknown_item` when called by plot B's owner (item_id isn't in B's
              byId map).
            - A player with no assigned plot fails both calls with `no_plot`.
        These properties are locked by the "per-plot ownership enforcement
        (CLO-179)" describe block in the spec.

    Public API:
        PlacementService.Initialize() -> ()
            Builds placeholder Models, walks `workspace.Plots` and registers every
            BasePart child. Idempotent — re-running re-uses existing PlotRecords.

        PlacementService.AssignPlot(player) -> PlotRecord?
            Claims the first free plot for the player. Returns nil if none free.

        PlacementService.ReleasePlot(player) -> ()
            Marks the player's plot as free, destroys placed Models, resets state.
            Called by `PlacementComponent` on player removal.

        PlacementService.GetPlayerPlot(player) -> PlotRecord?
        PlacementService.GetPlayerPlotPart(player) -> BasePart?

        PlacementService.PlaceStation(player, type_name, gx, gy, rotation, options?) -> (ok: boolean, item_id_or_error: number | string)
            `options.gz` (default 0) is the target floor index for vertical
            stacking; `options.from_restore` bypasses payment on rejoin.
            Full place flow:
                1. Payload validation (rotation enum, gx/gy integers, known type_name)
                2. Floor validation (gz integer in [0, MAX_FLOORS))
                3. Player's plot lookup
                4. Plot bounds check (XZ)
                5. Cell free check (at gz)
                6. Support check (gz > 0 needs an occupant directly below)
                7. Debit cost via player's EconomyComponent
                8. Clone Model, position via grid CFrame (lifted by gz), parent to itemHolder
                9. Record cell + byId entry (with gz + Floor/Gx/Gy attributes)
            Returns (true, item_id) on success.
            Returns (false, error_code) on failure. Error codes:
                "bad_payload", "bad_rotation", "bad_xy", "bad_floor",
                "unknown_type", "no_plot", "out_of_bounds", "tile_locked",
                "cell_occupied", "no_support", "no_session", "no_economy",
                "insufficient_coins", "no_prefab", "spawn_failed".

        PlacementService.RemoveStation(player, item_id) -> (ok: boolean, error?: string)
            Frees the cell, destroys the Model, removes the byId entry, and
            increments the player's Builder Inventory by 1 of that station's
            type (CLO-245). Replaces the pre-mini-epic 50% coin refund — the
            inventory round-trip is the canonical "you still own this station"
            ledger; PlaceStation (CLO-244) drains the inventory before falling
            through to coin debit, so removing then re-placing is fully free
            in coin terms. Returns `false, "supporting_above"` if another
            station sits directly on top — towers are removed top-down (the
            no-floating support rule).

    Test seams (prefixed `_`, intended only for spec.luau use):
        PlacementService._ResetForTesting() — clears all module state
        PlacementService._SeedPlotForTesting(plot_part, owner_user_id?) — inject a
            mock plot record without touching workspace.Plots
        PlacementService._GetState() — returns the live state tables for assertions
]=]

-- / Services:

local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Workspace = game:GetService('Workspace');

-- / Imports:

local StationRegistry = require(ReplicatedStorage.Shared.Modules.StationRegistry);
local CollisionGroups = require(ReplicatedStorage.Shared.Modules.CollisionGroups);
local Session = require(ReplicatedStorage.Shared.Framework.Session);
local Logger = require(ReplicatedStorage.Logger);

local PlotExpansionService = require(script.Parent.PlotExpansionService);
local InventoryService = require(script.Parent.InventoryService);

-- / Constants:

local IDENTIFIER = "PlacementService";

local ECONOMY_COMPONENT_KEY = "EconomyComponent";

local PLOTS_FOLDER_NAME = "Plots";
local MODELS_FOLDER_NAME = "Models";
local ITEM_HOLDER_NAME = "ItemHolder";

local TILE_SIZE = StationRegistry.TILE_SIZE;
local FLOOR_HEIGHT = StationRegistry.FLOOR_HEIGHT;
local MAX_FLOORS = StationRegistry.MAX_FLOORS;

-- A BasePart inside a station model only counts as functional hitbox if its
-- `Collision` attribute is set to true. Artists tag in Studio's properties
-- panel: decorative parts (no attribute / false) are visually rendered but
-- ignored by bounds + overlap checks. Multi-part stations (any future L-shape
-- or extended footprint) tag every functional arm so the full footprint is
-- enforced; current v1 prefabs are square single-Part stations, but the
-- attribute system stays in place for future shapes.
local HITBOX_ATTRIBUTE = "Collision";

local VALID_ROTATIONS = {
    R0 = 0,
    R90 = 90,
    R180 = 180,
    R270 = 270,
};

-- Pitch (vertical) rotation — tilts the station's forward (+X local) face up or down so
-- a port can point along Y. Degrees are about local Z: +90 sends +X -> +Y (Up), -90 sends
-- +X -> -Y (Down). Combined with the 4 yaws this yields the 6 forward directions. Default
-- "Flat" reproduces the legacy yaw-only CFrame exactly.
local VALID_PITCHES = {
    Flat = 0,
    Up = 90,
    Down = -90,
};

-- TODO: gate before launch. While DEV_MODE_STARTER_COINS > 0, every plot
-- assignment credits the player this much on top of GDD §4's "starting
-- amount: 0" — purely a testing convenience so we can place stations
-- without grinding mining first.
local DEV_MODE_STARTER_COINS = 10000;

-- / State:

local _plotsByInstance = {};
local _playerToPlot = {};
local _nextItemId = 1;

-- / Types:

export type PlotRecord = {
    plot: BasePart,
    itemHolder: Folder,
    ownerUserId: number,
    cells: { [string]: number },
    byId: { [number]: ItemRecord },
};

export type ItemRecord = {
    id: number,
    type_name: string,
    gx: number,
    gy: number,
    gz: number,
    rotation: string,
    model: Model,
};

-- / Module:

local PlacementService = {};

-- / Private — pure helpers (unit-testable):

-- Cell occupancy is keyed on (gx, gy, gz) where gz is the floor index
-- (0 = ground, +1 per FLOOR_HEIGHT studs up). `gz` is optional and defaults to
-- 0 so every legacy single-floor call site keys the ground floor unchanged.
function PlacementService._CellKey(gx, gy, gz)
    return (`{gx},{gy},{gz or 0}`);
end

-- Rotate a footprint cell offset (dx, dz, in grid units) by 0 / 90 / 180 / 270
-- degrees around the pivot. Returns a new (dx, dz) tuple. Matches the
-- placement-rotation convention: "R90" is +90° around Y so +X maps to +Z.
local ROTATION_TO_DEGREES = { R0 = 0, R90 = 90, R180 = 180, R270 = 270 };

function PlacementService._RotateFootprintCell(dx, dz, rotation)
    local degrees = ROTATION_TO_DEGREES[rotation] or 0;
    if degrees == 0 then return dx, dz end
    if degrees == 90 then return -dz, dx end
    if degrees == 180 then return -dx, -dz end
    if degrees == 270 then return dz, -dx end
    return dx, dz;
end

-- Returns the world-grid cells occupied by a station of `type_name` placed at
-- anchor `(gx, gy)` with `rotation`. Single-cell stations return one entry;
-- AlloySmelter (and any future multi-cell station) returns its full footprint
-- rotated. Each entry is `{ gx = number, gy = number }`.
function PlacementService._FootprintCells(type_name, gx, gy, gz, rotation)
    local footprint = StationRegistry.GetFootprint(type_name);
    local floorHeight = StationRegistry.GetFloorHeight(type_name);
    local baseGz = gz or 0;
    local cells = {};
    for _, cell in ipairs(footprint) do
        local rdx, rdz = PlacementService._RotateFootprintCell(cell.dx, cell.dz, rotation);
        -- Extrude the 2D footprint up `floorHeight` floors. A 1-floor station
        -- yields the single cell it always did; a Lift (2) also reserves the
        -- cell directly above so nothing can be built inside its top block.
        for f = 0, floorHeight - 1 do
            table.insert(cells, { gx = gx + rdx, gy = gy + rdz, gz = baseGz + f });
        end
    end
    return cells;
end

function PlacementService._IsValidRotation(rotation)
    return type(rotation) == "string" and VALID_ROTATIONS[rotation] ~= nil;
end

-- Pitch is optional; nil and "Flat" both mean no vertical tilt. A non-nil value must be
-- a known key.
function PlacementService._IsValidPitch(pitch)
    if pitch == nil then return true end
    return type(pitch) == "string" and VALID_PITCHES[pitch] ~= nil;
end

-- Support requirement DROPPED (2026-06-04, per user): pieces no longer need to
-- be anchored to the plot / a cell below / a same-floor neighbour — anything can
-- float on any floor. This keeps placement, edit, restore, and removal mutually
-- consistent: if nothing needs support, then removing a piece can never strand
-- the one above it (see RemoveStation / EditStation, where the load-bearing
-- guards were removed too). Kept as an always-true stub so every call site
-- (PlaceStation / EditStation) compiles unchanged and the rule is trivial to
-- reinstate later.
function PlacementService._IsPieceAnchored(record, footprint_cells, own_keys, exclude_id)
    return true;
end

function PlacementService._IsValidGridCoord(value)
    if type(value) ~= "number" then return false end
    if value ~= value then return false end
    if value == math.huge or value == -math.huge then return false end
    return math.floor(value) == value;
end

-- A valid floor index is an integer in [0, MAX_FLOORS). gz = 0 is the ground
-- floor; the cap bounds tower height for both the server bounds and the
-- client's MaxHeight ghost clamp.
function PlacementService._IsValidFloor(value)
    if not PlacementService._IsValidGridCoord(value) then return false end
    return value >= 0 and value < MAX_FLOORS;
end

--[=[
    Per-axis origin offset of cell (0, 0) from plot center, matching the
    vendored PlacementService snap convention. Keeps the tile grid symmetric
    around plot center for every plot size — not just sizes where
    plot.Size % (2*TILE_SIZE) == 0.

    Plot sizes where N % 8 == 0 (e.g. 40, 48, 56, 64) → origin = +2 (legacy).
    Plot sizes where N % 8 == 4 (e.g. 44, 52, 60, 68) → origin =  0 (CLO-198
        60x60 grid; previously off-by-half-tile vs the ghost preview).
]=]
function PlacementService._GridOriginOffset(plot_size)
    return TILE_SIZE * 0.5 - (plot_size % (2 * TILE_SIZE)) * 0.5;
end

function PlacementService._WithinPlotBounds(plot_size_x, plot_size_z, gx, gy, prefab_size_x, prefab_size_z)

    -- Footprint check: the station's PrimaryPart spans
    --   [cell_center - prefab/2, cell_center + prefab/2]
    -- in plot-local space. All four edges must fall inside the plot's
    -- ±plot_size/2 half-extents. Defaults to 1-tile (TILE_SIZE) for callers
    -- that haven't loaded a prefab yet — the strict check happens once we
    -- have the actual prefab.PrimaryPart.Size.

    prefab_size_x = prefab_size_x or TILE_SIZE;
    prefab_size_z = prefab_size_z or TILE_SIZE;

    local origin_x = PlacementService._GridOriginOffset(plot_size_x);
    local origin_z = PlacementService._GridOriginOffset(plot_size_z);

    local cell_center_x = gx * TILE_SIZE + origin_x;
    local cell_center_z = gy * TILE_SIZE + origin_z;

    local left = cell_center_x - prefab_size_x * 0.5;
    local right = cell_center_x + prefab_size_x * 0.5;
    local back = cell_center_z - prefab_size_z * 0.5;
    local front = cell_center_z + prefab_size_z * 0.5;

    local plot_half_x = plot_size_x * 0.5;
    local plot_half_z = plot_size_z * 0.5;

    return left >= -plot_half_x
       and right <= plot_half_x
       and back >= -plot_half_z
       and front <= plot_half_z;
end

function PlacementService._IsHitboxPart(part)
    if not part or not part:IsA("BasePart") then return false end
    return part:GetAttribute(HITBOX_ATTRIBUTE) == true;
end

function PlacementService._ComputeLocalHitboxBounds(prefab)

    -- Walks the prefab's descendants for parts with the Collision attribute
    -- set to true. Computes the union AABB of those parts in PrimaryPart-local
    -- space (i.e., relative to the prefab's pivot). Returns 4 numbers:
    -- (min_x, min_z, max_x, max_z). Falls back to the PrimaryPart's own AABB
    -- when no parts are tagged (handles ConveyorLine-style single-part
    -- stations that haven't been tagged + safety default).

    if not prefab or not prefab.PrimaryPart then return -2, -2, 2, 2 end

    local pivot_inv = prefab.PrimaryPart.CFrame:Inverse();

    local min_x, min_z = math.huge, math.huge;
    local max_x, max_z = -math.huge, -math.huge;
    local found = false;

    for _, part in ipairs(prefab:GetDescendants()) do
        if PlacementService._IsHitboxPart(part) then
            local local_cframe = pivot_inv * part.CFrame;
            local p = local_cframe.Position;
            local hx, hz = part.Size.X * 0.5, part.Size.Z * 0.5;
            min_x = math.min(min_x, p.X - hx);
            max_x = math.max(max_x, p.X + hx);
            min_z = math.min(min_z, p.Z - hz);
            max_z = math.max(max_z, p.Z + hz);
            found = true;
        end
    end

    if not found then
        local size = prefab.PrimaryPart.Size;
        local hx, hz = size.X * 0.5, size.Z * 0.5;
        return -hx, -hz, hx, hz;
    end

    return min_x, min_z, max_x, max_z;
end

function PlacementService._FullFootprintFitsInPlot(plot_size_x, plot_size_z, gx, gy, min_x, min_z, max_x, max_z, rotation)

    -- Rotates the 4 local-AABB corners around the pivot, then translates by
    -- the cell center, then checks the resulting axis-aligned plot-local AABB
    -- fits within +-plot_size/2.
    --
    -- BOUNDARY EPSILON: Roblox CFrame uses 32-bit floats internally, so
    -- CFrame.Angles(0, math.rad(180), 0) * Vector3 introduces ~2.4e-7 stud
    -- drift in the rotated coordinates (sin(pi) isn't exactly zero at FP32).
    -- That tiny drift was flipping edge-aligned placements at R180 from
    -- "fits exactly" to "out_of_bounds" by 0.00000024 studs. R0/R90/R270
    -- happen to land on exact values; only R180 hits the FP wall. We add
    -- 0.001 stud (1 mm — orders of magnitude bigger than the drift, orders
    -- smaller than any visible game-scale offset) of slack to the boundary
    -- comparison so true edge placements pass at every rotation.

    local angle_deg = VALID_ROTATIONS[rotation] or 0;
    local rot_cframe = CFrame.Angles(0, math.rad(angle_deg), 0);

    local corners = {
        rot_cframe * Vector3.new(min_x, 0, min_z),
        rot_cframe * Vector3.new(min_x, 0, max_z),
        rot_cframe * Vector3.new(max_x, 0, min_z),
        rot_cframe * Vector3.new(max_x, 0, max_z),
    };

    local r_min_x, r_min_z = math.huge, math.huge;
    local r_max_x, r_max_z = -math.huge, -math.huge;

    for _, c in ipairs(corners) do
        r_min_x = math.min(r_min_x, c.X);
        r_max_x = math.max(r_max_x, c.X);
        r_min_z = math.min(r_min_z, c.Z);
        r_max_z = math.max(r_max_z, c.Z);
    end

    local cell_cx = gx * TILE_SIZE + PlacementService._GridOriginOffset(plot_size_x);
    local cell_cz = gy * TILE_SIZE + PlacementService._GridOriginOffset(plot_size_z);

    local plot_half_x = plot_size_x * 0.5;
    local plot_half_z = plot_size_z * 0.5;

    local EPSILON = 0.001;

    return cell_cx + r_min_x >= -plot_half_x - EPSILON
       and cell_cx + r_max_x <= plot_half_x + EPSILON
       and cell_cz + r_min_z >= -plot_half_z - EPSILON
       and cell_cz + r_max_z <= plot_half_z + EPSILON;
end

function PlacementService._HasHitboxOverlap(itemHolder, cframe, size_x, size_y, size_z, exclude_item_id)

    -- Belt-and-suspenders for cell-key occupancy: catches actual world-space
    -- overlap with placed stations inside the player's ItemHolder.
    --
    -- A hit counts if its ancestor Model has an `Id` attribute (set by
    -- PlaceStation on every placed station). ALL parts of a placed station
    -- count, not just the PrimaryPart — any multi-part station (future
    -- L-shapes, extended-footprint conveyors, etc.) needs its non-primary
    -- parts to block adjacent placements.
    --
    -- Free-floating parts directly under ItemHolder (no Model ancestor with
    -- an Id) are debris / SFX / decor — they don't count.
    --
    -- Shrinks the check size by 0.1 stud on each axis to avoid false
    -- positives from edge-touching neighbours.
    --
    -- `exclude_item_id` (CLO-242): the Edit flow validates against the
    -- destination cell while the model being moved still lives at its
    -- current cell. Passing the item_id excludes its own parts from the
    -- overlap count so the station doesn't "collide with itself" when the
    -- player edits in place (same cell + rotation flip) or to an adjacent
    -- cell whose AABB still grazes the original footprint. nil keeps
    -- legacy PlaceStation behavior.

    if not itemHolder then return false end
    if type(size_x) ~= "number" or type(size_y) ~= "number" or type(size_z) ~= "number" then
        return false;
    end
    if size_x <= 0 or size_y <= 0 or size_z <= 0 then return false end

    local params = OverlapParams.new();
    params.FilterDescendantsInstances = { itemHolder };
    params.FilterType = Enum.RaycastFilterType.Include;

    local check_size = Vector3.new(
        math.max(0.1, size_x - 0.1),
        math.max(0.1, size_y - 0.1),
        math.max(0.1, size_z - 0.1)
    );

    local hits = workspace:GetPartBoundsInBox(cframe, check_size, params);

    -- A hit counts only when BOTH conditions hold:
    --   1. The part lives inside a placed-station Model (Model has `Id` attr)
    --   2. The part itself has `Collision = true` (functional, not decorative)
    -- Untagged decorative geometry on a placed station is ignored — see
    -- HITBOX_ATTRIBUTE doc at the top of the file.

    for _, part in ipairs(hits) do
        if PlacementService._IsHitboxPart(part) then
            local model = part:FindFirstAncestorOfClass("Model");
            if model then
                local model_id = model:GetAttribute("Id");
                if model_id ~= nil and model_id ~= exclude_item_id then
                    return true;
                end
            end
        end
    end

    return false;
end

-- Per-Collision-part overlap test for concave footprints. The single-box
-- `_HasHitboxOverlap` above tests one OBB — fine for a solid rectangle, but a
-- T / L station's union AABB also covers its EMPTY notch cells, so a single-box
-- test would falsely block a neighbour sitting in the notch. This walks every
-- Collision-tagged part of the placing `prefab`, transforms it to the world OBB
-- it WOULD occupy once placed (PrimaryPart pivot lands on `placement_cframe`),
-- and overlap-tests each one independently. A placement is blocked only when one
-- of its SOLID cells actually intersects another station's solid cell. Single-
-- cell + solid-rectangle prefabs behave exactly as the old union-box check did
-- (one part, or a tiling of parts whose union is the same rectangle).
function PlacementService._HasFootprintOverlap(itemHolder, prefab, placement_cframe, exclude_item_id)

    if not itemHolder or not prefab or not prefab.PrimaryPart then return false end

    local pivot_inv = prefab.PrimaryPart.CFrame:Inverse();

    for _, part in ipairs(prefab:GetDescendants()) do
        if PlacementService._IsHitboxPart(part) then
            local world_cframe = placement_cframe * (pivot_inv * part.CFrame);
            if PlacementService._HasHitboxOverlap(
                itemHolder, world_cframe, part.Size.X, part.Size.Y, part.Size.Z, exclude_item_id
            ) then
                return true;
            end
        end
    end

    return false;
end

function PlacementService._ValidatePayload(type_name, gx, gy, rotation)

    if type(type_name) ~= "string" then
        return false, "bad_payload";
    end

    if not StationRegistry.Get(type_name) then
        return false, "unknown_type";
    end

    if not PlacementService._IsValidGridCoord(gx) or not PlacementService._IsValidGridCoord(gy) then
        return false, "bad_xy";
    end

    if not PlacementService._IsValidRotation(rotation) then
        return false, "bad_rotation";
    end

    return true, nil;
end

function PlacementService._GridToWorldCFrame(plot_cframe, plot_size_x, plot_size_z, plot_size_y, prefab_height_y, gx, gy, gz, rotation, pitch)

    -- gx / gy are tile indices; the model's CENTER lands at the CENTER of that
    -- tile. Tile (gx=0, gy=0) center is at `_GridOriginOffset(plot_size)` in
    -- plot-local space — symmetric around plot center for every plot size, to
    -- match the vendored PlacementService snap convention. See
    -- `_GridOriginOffset` for the offset table.
    --
    -- gz is the floor index: floor N's base sits `gz * FLOOR_HEIGHT` studs above
    -- the plot top, so a station's center is lifted by that plus half its own
    -- height. gz defaults to 0 (ground) for legacy single-floor callers.

    local px = gx * TILE_SIZE + PlacementService._GridOriginOffset(plot_size_x);
    local pz = gy * TILE_SIZE + PlacementService._GridOriginOffset(plot_size_z);
    local addY = (plot_size_y * 0.5) + ((gz or 0) * FLOOR_HEIGHT) + (prefab_height_y * 0.5);

    -- Yaw about Y (the 4 cardinal facings) composed with pitch about local Z (tilts the
    -- forward face up/down). Pitch defaults to Flat, so this is byte-identical to the old
    -- yaw-only CFrame for every legacy caller.
    local yawRad = math.rad(VALID_ROTATIONS[rotation]);
    local pitchRad = math.rad(VALID_PITCHES[pitch or "Flat"] or 0);
    local localCFrame = CFrame.new(px, addY, pz) * CFrame.Angles(0, yawRad, 0) * CFrame.Angles(0, 0, pitchRad);

    return plot_cframe * localCFrame;
end

-- / Private — runtime helpers (need workspace / Session):

function PlacementService._EnsureItemHolder(plot)

    local existing = plot:FindFirstChild(ITEM_HOLDER_NAME);

    if existing and existing:IsA("Folder") then
        return existing;
    end

    if existing then
        existing:Destroy();
    end

    local folder = Instance.new("Folder");
    folder.Name = ITEM_HOLDER_NAME;
    folder.Parent = plot;

    return folder;
end

function PlacementService._RegisterPlotPart(plot)

    if _plotsByInstance[plot] then
        return _plotsByInstance[plot];
    end

    local record = {
        plot = plot,
        itemHolder = PlacementService._EnsureItemHolder(plot),
        ownerUserId = 0,
        cells = {},
        byId = {},
    };

    _plotsByInstance[plot] = record;

    return record;
end

function PlacementService._ResolveEconomyComponent(player)

    if not player or not player:IsA("Player") then
        return nil, "no_session";
    end

    local registry = Session._getRegistry();

    if not registry then
        return nil, "no_session";
    end

    local playerSession = registry[player.UserId];

    if not playerSession or type(playerSession) ~= "table" then
        return nil, "no_session";
    end

    if not playerSession.components then
        return nil, "no_session";
    end

    local economy = playerSession.components[ECONOMY_COMPONENT_KEY];

    if not economy then
        return nil, "no_economy";
    end

    return economy, nil;
end

function PlacementService._GetPrefabFor(type_name)

    local modelsFolder = ReplicatedStorage:FindFirstChild(MODELS_FOLDER_NAME);

    if not modelsFolder then return nil end

    local prefab = modelsFolder:FindFirstChild(type_name);

    if not prefab or not prefab:IsA("Model") then return nil end

    if not prefab.PrimaryPart then return nil end

    return prefab;
end

-- / Public:

function PlacementService.Initialize()

    if not ReplicatedStorage:FindFirstChild(MODELS_FOLDER_NAME) then
        Logger.warn(`[{IDENTIFIER}:Initialize] ReplicatedStorage.{MODELS_FOLDER_NAME} not found — RequestPlace will return 'no_prefab' until real station Models are present (see AssetReview migration)`);
    end

    local container = Workspace:FindFirstChild(PLOTS_FOLDER_NAME);

    if not container then
        Logger.warn(`[{IDENTIFIER}:Initialize] workspace.{PLOTS_FOLDER_NAME} not found — no plots registered (stub for CLO-179 plot system)`);
        return;
    end

    local registered = 0;

    for _, child in ipairs(container:GetChildren()) do
        if not child:IsA("BasePart") then continue end
        PlacementService._RegisterPlotPart(child);
        registered = registered + 1;
    end

    Logger.info(`[{IDENTIFIER}:Initialize] Registered {registered} plot(s) under workspace.{PLOTS_FOLDER_NAME}`);
end

--[=[
    Claims the first free plot for the player and registers it with the
    FactoryTickRuntime. The dev-coin grant used to live here but was moved out
    (CLO-215) so PlacementComponent can restore a persisted layout or leave a
    first-time player's plot empty; callers needing it invoke SeedDevStartingCoins
    explicitly. (FTUE v2 no longer seeds a preplaced chain — FTUEComponent
    free-grants the starter pieces instead.)
]=]
function PlacementService.AssignPlot(player)

    if not player or not player:IsA("Player") then
        Logger.warn(`[{IDENTIFIER}:AssignPlot] invalid player argument`);
        return nil;
    end

    if _playerToPlot[player.UserId] then
        return _playerToPlot[player.UserId];
    end

    local function claim(record)
        record.ownerUserId = player.UserId;
        _playerToPlot[player.UserId] = record;

        if record.plot then
            record.plot:SetAttribute("OwnerUserId", player.UserId);
            record.plot:SetAttribute("OwnerName", player.Name);
        end

        Logger.info(`[{IDENTIFIER}:AssignPlot] Assigned plot '{record.plot.Name}' to {player.Name} (UserId {player.UserId})`);

        local FactoryTickRuntime = script.Parent:FindFirstChild("FactoryTickRuntime");
        if FactoryTickRuntime then
            local ok, mod = pcall(require, FactoryTickRuntime);
            if ok and mod then
                mod.RegisterPlot(record);
                mod.RebuildGraph(record);
            end
        end

        return record;
    end

    -- Honor an explicit plot choice from the main-menu deploy flow (MenuService sets
    -- the `ChosenPlot` attribute before LoadCharacter). Falls back to first-free if the
    -- chosen plot is gone/taken by the time registration runs.
    local chosen = player:GetAttribute("ChosenPlot");
    if type(chosen) == "string" and #chosen > 0 then
        for _, record in pairs(_plotsByInstance) do
            if record.plot and record.plot.Name == chosen and record.ownerUserId == 0 then
                return claim(record);
            end
        end
        Logger.warn(`[{IDENTIFIER}:AssignPlot] chosen plot '{chosen}' unavailable for {player.Name} — using first free`);
    end

    for _, record in pairs(_plotsByInstance) do
        if record.ownerUserId == 0 then
            return claim(record);
        end
    end

    Logger.warn(`[{IDENTIFIER}:AssignPlot] No free plots available for {player.Name}`);
    return nil;
end

function PlacementService.SeedDevStartingCoins(player)

    -- Dev-only convenience. Credits `DEV_MODE_STARTER_COINS` so the tester
    -- doesn't have to mine + sell to get past the FTUE coin gate. Skip
    -- silently if the flag is 0 (production mode) or the economy isn't
    -- ready yet (same recoverable mid-session pattern as RemoveStation's
    -- refund).

    if DEV_MODE_STARTER_COINS <= 0 then return end
    if not player or not player:IsA("Player") then return end

    local economy = PlacementService._ResolveEconomyComponent(player);
    if not economy then
        Logger.warn(`[{IDENTIFIER}:SeedDevStartingCoins] Economy not ready for {player.Name} — starter coins skipped`);
        return;
    end

    economy:Credit(DEV_MODE_STARTER_COINS);
    Logger.info(`[{IDENTIFIER}:SeedDevStartingCoins] Granted {DEV_MODE_STARTER_COINS}c starter pack to {player.Name} (TODO: gate before launch)`);
end

function PlacementService.ReleasePlot(player)

    if not player or not player:IsA("Player") then return end

    local record = _playerToPlot[player.UserId];

    if not record then return end

    for _, itemRecord in pairs(record.byId) do
        if itemRecord.model and itemRecord.model.Parent then
            itemRecord.model:Destroy();
        end
    end

    record.cells = {};
    record.byId = {};
    record.ownerUserId = 0;
    record.flow = nil;
    _playerToPlot[player.UserId] = nil;

    if record.plot then
        record.plot:SetAttribute("OwnerUserId", 0);
        record.plot:SetAttribute("OwnerName", "");
    end

    local FactoryTickRuntime = script.Parent:FindFirstChild("FactoryTickRuntime");
    if FactoryTickRuntime then
        local ok, mod = pcall(require, FactoryTickRuntime);
        if ok and mod then
            mod.UnregisterPlot(record);
        end
    end
end

function PlacementService.GetPlayerPlot(player)
    if not player or not player:IsA("Player") then return nil end
    return _playerToPlot[player.UserId];
end

function PlacementService.GetPlayerPlotPart(player)
    local record = PlacementService.GetPlayerPlot(player);
    if not record then return nil end
    return record.plot;
end

--[=[
    CLO-207 — returns the type_name of the station occupying cell (gx, gy) on
    the caller's plot, or nil if the cell is empty. Used by the FTUE driver to
    detect a station placed in a tutorial gap without reaching into byId.
]=]
function PlacementService.GetStationTypeAt(player, gx, gy, gz)

    local record = PlacementService.GetPlayerPlot(player);
    if not record then return nil end

    local itemId = record.cells[PlacementService._CellKey(gx, gy, gz or 0)];
    if not itemId then return nil end

    local item = record.byId[itemId];
    return item and item.type_name or nil;
end

--[=[
    CLO-208 — the EXACT CFrame a real PlaceStation of `type_name` would land at
    cell (gx, gy). Resolves the prefab's PrimaryPart height so a client ghost
    preview cloned from `ReplicatedStorage.Models.<type_name>` and PivotTo'd to
    this CFrame sits flush on the target tile, identical to the placed station.
]=]
function PlacementService.GetCellPlacementCFrame(player, type_name, gx, gy, rotation, gz)

    local record = PlacementService.GetPlayerPlot(player);
    if not record then return nil end

    local prefab = PlacementService._GetPrefabFor(type_name);
    if not prefab or not prefab.PrimaryPart then return nil end

    return PlacementService._GridToWorldCFrame(
        record.plot.CFrame, record.plot.Size.X, record.plot.Size.Z, record.plot.Size.Y,
        prefab.PrimaryPart.Size.Y, gx, gy, gz or 0, rotation or "R0"
    );
end

--[=[
    Places a station on the caller's plot.

    `options` (optional) accepts:
        from_restore : boolean — when true, bypass both Inventory consumption
                       AND economy debit. Used by `RestorePlacedStations` on
                       rejoin since the player paid for these stations in a
                       prior session — they're not on the inventory ledger
                       (those are independent unplaced stock) and they're not
                       coin-eligible. Default false.

    Payment-source decision tree (CLO-244):
        1. from_restore=true                    → no payment, no inventory
        2. InventoryService.GetCount > 0         → consume one from inventory
        3. otherwise                            → debit cost from economy
                                                    (insufficient_coins if low)
]=]
function PlacementService.PlaceStation(player, type_name, gx, gy, rotation, options)

    options = options or {};
    local from_restore = options.from_restore == true;

    -- Floor index (v1 vertical stacking). Carried in `options.gz` rather than a
    -- positional arg so legacy callers (AdminCommands, FTUE) stay untouched and
    -- default to the ground floor.
    local gz = options.gz or 0;
    -- Vertical tilt (default Flat = legacy behaviour). Lets a port face up/down.
    local pitch = options.pitch or "Flat";

    local payloadOk, payloadErr = PlacementService._ValidatePayload(type_name, gx, gy, rotation);

    if not payloadOk then
        return false, payloadErr;
    end

    if not PlacementService._IsValidFloor(gz) then
        return false, "bad_floor";
    end

    if not PlacementService._IsValidPitch(pitch) then
        return false, "bad_payload";
    end

    local record = PlacementService.GetPlayerPlot(player);

    if not record then
        return false, "no_plot";
    end

    local prefab = PlacementService._GetPrefabFor(type_name);

    if not prefab then
        Logger.warn(`[{IDENTIFIER}:PlaceStation] No prefab for '{type_name}' — placeholder Models folder may be missing`);
        return false, "no_prefab";
    end

    -- Bounds check uses the FULL hitbox-attributed footprint, not just the
    -- PrimaryPart. Any multi-part station that tags its functional parts is
    -- counted in full — so trying to place an extended-footprint station at
    -- the plot edge is rejected if any tagged part would overhang.

    local local_min_x, local_min_z, local_max_x, local_max_z =
        PlacementService._ComputeLocalHitboxBounds(prefab);

    if not PlacementService._FullFootprintFitsInPlot(
        record.plot.Size.X, record.plot.Size.Z, gx, gy,
        local_min_x, local_min_z, local_max_x, local_max_z, rotation
    ) then
        return false, "out_of_bounds";
    end

    -- Compute the full footprint (single cell for most types, multi-cell for
    -- AlloySmelter and similar). Every cell must pass the unlock + occupancy
    -- check; the anchor cell IS the first footprint entry so the legacy
    -- single-cell flow is preserved exactly when `footprint = {{0,0}}`.
    local footprint_cells = PlacementService._FootprintCells(type_name, gx, gy, gz, rotation);

    -- Reject a station whose top floor would exceed the build ceiling (only
    -- matters for multi-floor pieces like the Lift sitting near MAX_FLOORS).
    for _, cell in ipairs(footprint_cells) do
        if cell.gz >= MAX_FLOORS then
            return false, "bad_floor";
        end
    end

    -- Set of this station's own footprint cells, for internal-support lookups
    -- below (a multi-floor piece holds its own upper cells up).
    local footprint_keys = {};
    for _, cell in ipairs(footprint_cells) do
        footprint_keys[PlacementService._CellKey(cell.gx, cell.gy, cell.gz)] = true;
    end

    for _, cell in ipairs(footprint_cells) do
        -- Tile unlock is per XZ column (floor-independent): a locked tile is
        -- locked on every floor, so the gz isn't passed to IsTileUnlocked.
        if not PlotExpansionService.IsTileUnlocked(record, cell.gx, cell.gy) then
            return false, "tile_locked";
        end
        if record.cells[PlacementService._CellKey(cell.gx, cell.gy, cell.gz)] ~= nil then
            return false, "cell_occupied";
        end
    end

    -- Anchor rule (no floating): a piece above the ground must attach to the
    -- plot, a cell below, or an occupied same-floor neighbour (build off the
    -- network / a Lift top). Server validates independently so a crafted
    -- request can't float a disconnected station.
    if not PlacementService._IsPieceAnchored(record, footprint_cells, footprint_keys, nil) then
        return false, "no_support";
    end

    -- Anchor cell key — used later by save snapshot lookups. Other footprint
    -- cells will all map to the same itemId in `record.cells`.
    local cellKey = PlacementService._CellKey(gx, gy, gz);

    -- The PrimaryPart's height drives the y-positioning math; PivotTo lands the
    -- pivot on placementCFrame, so each Collision part's destination world OBB is
    -- placementCFrame * (its local offset from pivot) — see _HasFootprintOverlap.
    local prefab_size_y = prefab.PrimaryPart.Size.Y;
    local placementCFrame = PlacementService._GridToWorldCFrame(
        record.plot.CFrame, record.plot.Size.X, record.plot.Size.Z, record.plot.Size.Y, prefab_size_y, gx, gy, gz, rotation, pitch
    );

    if PlacementService._HasFootprintOverlap(
        record.itemHolder, prefab, placementCFrame
    ) then
        return false, "cell_occupied";
    end

    -- / Payment decision (CLO-244).
    --
    -- Three branches, mutually exclusive. Track `payment_source` so the
    -- spawn-failed rollback below refunds via the matching channel.

    local payment_source = "none";  -- "inventory" | "coins" | "none" (restore)
    local cost = 0;
    local economy = nil;

    if not from_restore then
        if InventoryService.GetCount(player, type_name) > 0 then
            InventoryService.IncrementCount(player, type_name, -1);
            payment_source = "inventory";
        else
            cost = StationRegistry.GetCost(type_name) or 0;

            local economyErr;
            economy, economyErr = PlacementService._ResolveEconomyComponent(player);

            if not economy then
                return false, economyErr or "no_economy";
            end

            if cost > 0 then
                local debitOk = economy:Debit(cost);
                if not debitOk then
                    return false, "insufficient_coins";
                end
            end

            payment_source = "coins";
        end
    end

    local cloneOk, cloneResult = pcall(function()
        local model = prefab:Clone();
        model:PivotTo(placementCFrame);
        -- Solid, static station: anchor every part, collide all EXCEPT the
        -- Hitbox (which drives placement preview + overlap collision, not world
        -- collision). Players bump into stations; the model is put in the
        -- Obstacle collision group so clones (Clone group) pass through and
        -- still reach the Stockpile via the proximity deposit.
        for _, descendant in ipairs(model:GetDescendants()) do
            if descendant:IsA("BasePart") then
                descendant.Anchored = true;
                descendant.CanCollide = (descendant.Name ~= "Hitbox");
                -- The Hitbox drives placement/overlap, not UX. Take it out of cursor
                -- raycasts (build/edit/remove hover + auto-stack) so those hit the VISIBLE
                -- geometry the player actually sees, not the invisible placement box.
                descendant.CanQuery = (descendant.Name ~= "Hitbox");
            end
        end
        CollisionGroups.Assign(model, CollisionGroups.OBSTACLE);
        model.Parent = record.itemHolder;
        return model;
    end);

    if not cloneOk or not cloneResult then
        -- Atomic refund: roll back whichever channel paid.
        if payment_source == "inventory" then
            InventoryService.IncrementCount(player, type_name, 1);
        elseif payment_source == "coins" and economy and cost > 0 then
            economy:Credit(cost);
        end
        Logger.warn(`[{IDENTIFIER}:PlaceStation] Spawn failed for '{type_name}' on {record.plot.Name}: {tostring(cloneResult)}`);
        return false, "spawn_failed";
    end

    local model = cloneResult;
    local itemId = _nextItemId;
    _nextItemId = _nextItemId + 1;

    model:SetAttribute("Id", itemId);
    model:SetAttribute("TypeName", type_name);
    model:SetAttribute("Rotation", rotation);
    model:SetAttribute("Pitch", pitch);
    -- Floor + anchor cell published as attributes so the client's auto-stack
    -- can read a column's height (max TopFloor at a given Gx/Gy) straight off
    -- the placed models without a server round-trip. TopFloor is the highest
    -- floor the piece occupies (anchor + floor_height - 1), so stacking onto a
    -- 2-tall Lift correctly targets two floors up.
    model:SetAttribute("Floor", gz);
    model:SetAttribute("TopFloor", gz + StationRegistry.GetFloorHeight(type_name) - 1);
    model:SetAttribute("Gx", gx);
    model:SetAttribute("Gy", gy);

    -- Reserve every footprint cell (anchor + any extras for multi-cell
    -- stations). Each cell points to the same itemId so the cells->id lookup
    -- works uniformly regardless of which cell a query hit.
    for _, cell in ipairs(footprint_cells) do
        record.cells[PlacementService._CellKey(cell.gx, cell.gy, cell.gz)] = itemId;
    end
    record.byId[itemId] = {
        id = itemId,
        type_name = type_name,
        gx = gx,
        gy = gy,
        gz = gz,
        rotation = rotation,
        pitch = pitch,
        model = model,
    };

    PlacementService._NotifyRuntimeMutation(record);

    Logger.info(`[{IDENTIFIER}:PlaceStation] Placed '{type_name}' id={itemId} at ({gx},{gy},f{gz}) {rotation} for {player.Name} via {payment_source}`);

    return true, itemId;
end

function PlacementService._NotifyRuntimeMutation(record)
    local FactoryTickRuntime = script.Parent:FindFirstChild("FactoryTickRuntime");
    if not FactoryTickRuntime then return end
    local ok, mod = pcall(require, FactoryTickRuntime);
    if ok and mod then
        mod.RebuildGraph(record);
    end
end

-- Dev/test: inject one item onto the player's first station of `type_name` (default
-- Stockpile) so the factory runtime has something to flow. Returns (ok, message).
-- Temporary — real input is forager harvest (a later GDD layer).
function PlacementService.DevDepositItem(player, ore, refinement, type_name, count)
    local record = _playerToPlot[player.UserId];
    if not record then return false, "no_plot" end

    local FactoryTickRuntime = script.Parent:FindFirstChild("FactoryTickRuntime");
    if not FactoryTickRuntime then return false, "no_runtime" end
    local ok, mod = pcall(require, FactoryTickRuntime);
    if not ok or not mod then return false, "runtime_require_failed" end

    type_name = type_name or "Stockpile";
    ore = ore or "Stone";
    refinement = refinement or "Raw";
    local stationId = mod.GetFirstStationByType(record, type_name);
    if not stationId then return false, `no_station:{type_name}` end

    -- Batch deposits (dev dump panel) go through DepositItemsBulk so N items cost one
    -- bulk_spawn packet instead of N reliable spawns; a single deposit keeps the 1-item path.
    count = (type(count) == "number" and count > 1) and math.floor(count) or 1;
    if count > 1 then
        local n = mod.DepositItemsBulk(record, stationId, ore, refinement, count);
        if n <= 0 then return false, "deposit_rejected" end
        Logger.info(`[{IDENTIFIER}:DevDepositItem] {player.Name} -> {type_name} #{stationId}: {n}x {ore}/{refinement}`);
        return true, "ok";
    end

    local deposited = mod.DepositItem(record, stationId, { ore = ore, refinement = refinement });
    if not deposited then return false, "deposit_rejected" end

    Logger.info(`[{IDENTIFIER}:DevDepositItem] {player.Name} -> {type_name} #{stationId}: {ore}/{refinement}`);
    return true, "ok";
end

-- / Persistence (CLO-215):

--[=[
    Returns a save-blob array of currently-placed stations on the player's
    plot. Each entry is { type_name, gx, gy, gz, rotation } — the minimum
    needed to round-trip RestorePlacedStations(player, snapshot) back into the
    same layout. `gz` is the floor index (omitted on legacy saves → restored as
    ground floor). FTUE-seeded stations are part of the snapshot; by the time we
    persist there's no meaningful split between "seeded" and "player-placed"
    — they're all part of the player's layout.
]=]
function PlacementService.SnapshotPlacedStations(player)

    if not player or not player:IsA("Player") then
        return {};
    end

    local record = _playerToPlot[player.UserId];

    if not record then
        return {};
    end

    local snapshot = {};

    for _, item in pairs(record.byId) do
        if type(item) ~= "table" then continue end
        if type(item.type_name) ~= "string" then continue end
        if not PlacementService._IsValidGridCoord(item.gx) then continue end
        if not PlacementService._IsValidGridCoord(item.gy) then continue end
        if not PlacementService._IsValidRotation(item.rotation) then continue end

        local entry = {
            type_name = item.type_name,
            gx = item.gx,
            gy = item.gy,
            gz = item.gz or 0,
            rotation = item.rotation,
            pitch = item.pitch or "Flat",
        };

        -- Persist per-instance config the runtime reads off the model. A Filter
        -- stores its (ore, type) match (FilterOre / FilterType); without this it
        -- would restore to the prefab default and silently route wrong after a
        -- rejoin.
        if item.model and item.model.Parent then
            local filterOre = item.model:GetAttribute("FilterOre");
            if filterOre ~= nil then
                entry.filter_ore = filterOre;
            end
            local filterType = item.model:GetAttribute("FilterType");
            if filterType ~= nil then
                entry.filter_type = filterType;
            end
        end

        table.insert(snapshot, entry);
    end

    return snapshot;
end

--[=[
    Re-issues PlaceStation calls for every entry in the snapshot, passing
    `{ from_restore = true }` so the underlying PlaceStation bypasses BOTH
    inventory consumption AND coin debit. These stations were paid for in
    a prior session — they're not on the inventory ledger (that table
    tracks independent unplaced stock) and they're not coin-eligible.

    Pre-CLO-244 this path mirrored the cost via Credit-before / Debit-on-
    failure to net to zero. With the from_restore flag PlaceStation
    skips the economy path entirely, so the mirror is dead weight and
    gets dropped.

    CALLED AFTER AssignPlot has run. Caller (PlacementComponent registration
    hook) must ensure that ordering — restoring before a plot exists is a
    no-op `no_plot` for every entry.
]=]
function PlacementService.RestorePlacedStations(player, snapshot)

    if not player or not player:IsA("Player") then
        return 0;
    end

    if type(snapshot) ~= "table" then
        return 0;
    end

    local restored = 0;

    -- Restore lowest floors first. The support rule rejects a station whose
    -- cell-below is empty, so a floor-1 station must be placed AFTER the
    -- floor-0 station under it. Sort a shallow copy by gz ascending (entries
    -- without gz are legacy ground-floor → 0) so save order never matters.
    local ordered = {};
    for _, entry in ipairs(snapshot) do
        if type(entry) == "table" then
            table.insert(ordered, entry);
        end
    end
    table.sort(ordered, function(a, b)
        return (a.gz or 0) < (b.gz or 0);
    end);

    for _, entry in ipairs(ordered) do

        -- Map pre-rename type names to current ones (turn-conveyor
        -- rename 2026-05-22 — ConveyorTurnLeft → ConveyorCounterClockwise
        -- etc.). Unknown names pass through unchanged.
        local resolved_type = StationRegistry.ResolveLegacyTypeName(entry.type_name);

        local ok, result = PlacementService.PlaceStation(
            player, resolved_type, entry.gx, entry.gy, entry.rotation,
            { from_restore = true, gz = entry.gz or 0, pitch = entry.pitch }
        );

        if not ok then
            Logger.warn(`[{IDENTIFIER}:RestorePlacedStations] Failed to restore {resolved_type} at ({entry.gx},{entry.gy},f{entry.gz or 0}) for {player.Name}: {result}`);
        else
            restored = restored + 1;

            -- Re-apply persisted per-instance config. `result` is the new
            -- item_id; set the Filter's saved (ore, type) on its fresh model +
            -- refresh the on-model label / prompt so it reads + routes correctly.
            if entry.filter_ore ~= nil or entry.filter_type ~= nil then
                local rec = PlacementService.GetPlayerPlot(player);
                local item = rec and rec.byId[result];
                local model = item and item.model;
                if model then
                    if entry.filter_ore ~= nil then model:SetAttribute("FilterOre", entry.filter_ore) end
                    if entry.filter_type ~= nil then model:SetAttribute("FilterType", entry.filter_type) end
                    PlacementService._RefreshFilterLabel(model, model:GetAttribute("FilterOre"), model:GetAttribute("FilterType"));
                end
            end
        end
    end

    Logger.info(`[{IDENTIFIER}:RestorePlacedStations] Restored {restored}/{#snapshot} stations for {player.Name}`);

    return restored;
end

function PlacementService.RemoveStation(player, item_id)

    if type(item_id) ~= "number" then
        return false, "bad_payload";
    end

    local record = PlacementService.GetPlayerPlot(player);

    if not record then
        return false, "no_plot";
    end

    local item = record.byId[item_id];

    if not item then
        return false, "unknown_item";
    end

    local item_gz = item.gz or 0;

    -- Footprint cells this station reserved (anchor + extras for multi-cell
    -- stations), rederived from the type for the cell-clear below.
    local remove_cells = PlacementService._FootprintCells(item.type_name, item.gx, item.gy, item_gz, item.rotation);

    -- (Load-bearing guard removed 2026-06-04: support is no longer required, so a
    -- piece can always be removed even with something directly above it — the
    -- piece above simply stays where it is. See _IsPieceAnchored.)

    -- Clear every footprint cell this station reserved. The footprint is
    -- rederived from the type so we
    -- don't need to persist the cell list per-station.
    for _, cell in ipairs(remove_cells) do
        record.cells[PlacementService._CellKey(cell.gx, cell.gy, cell.gz)] = nil;
    end
    record.byId[item_id] = nil;

    -- Soft-call FactoryTickRuntime.CleanupStation first so it can destroy
    -- any in-flight item visuals before we nil out the pending list.
    local FactoryTickRuntime = script.Parent:FindFirstChild("FactoryTickRuntime");
    if FactoryTickRuntime then
        local okReq, mod = pcall(require, FactoryTickRuntime);
        if okReq and mod and type(mod.CleanupStation) == "function" then
            mod.CleanupStation(record, item_id);
        end
    end

    if record.flow then
        if record.flow.pending then record.flow.pending[item_id] = nil end
        if record.flow.morph then record.flow.morph[item_id] = nil end
        if record.flow.splitter then record.flow.splitter[item_id] = nil end
    end

    if item.model and item.model.Parent then
        item.model:Destroy();
    end

    PlacementService._NotifyRuntimeMutation(record);

    -- CLO-245: return the destroyed station to the Builder Inventory
    -- instead of crediting a 50% coin refund. Sparse-storage in
    -- InventoryService means the new_count is always >= 1 here.
    local new_count = InventoryService.IncrementCount(player, item.type_name, 1);

    Logger.info(`[{IDENTIFIER}:RemoveStation] Removed id={item_id} ({item.type_name}) for {player.Name} — returned to inventory (count={new_count})`);

    return true, nil;
end

-- Human-readable text for a Filter's current (ore, type) match, used on the
-- on-model FilterLabel + the prompt. "Any"/nil collapse to a wildcard.
function PlacementService._FilterMatchText(ore, refinement)
    local o = ore;
    if o == nil or o == "Any" then o = nil end
    local r = refinement;
    if r == nil or r == "Any" then r = nil end
    if not o and not r then return "Keep: Any" end
    if o and r then return `Keep: {o} {r}` end
    if o then return `Keep: {o}` end
    return `Keep: Any {r}`;
end

-- Refresh a Filter model's on-model label + prompt text to its current match.
function PlacementService._RefreshFilterLabel(model, ore, refinement)
    if not model then return end
    local text = PlacementService._FilterMatchText(ore, refinement);
    local gui = model:FindFirstChild("FilterLabel", true);
    if gui and gui:IsA("TextLabel") then
        gui.Text = text;
    end
    local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true);
    if prompt then
        prompt.ObjectText = text;
    end
end

-- Set a Filter's (ore, type) match. Validates ownership + that the station is a
-- Filter, coerces both values against the producible matrix (unknown → "Any" so
-- a forged value just becomes a harmless wildcard), writes the FilterOre /
-- FilterType attributes the runtime reads, and refreshes the on-model label. The
-- config UI (FilterConfigController) drives this via the SetFilter RPC.
function PlacementService.SetStationFilter(player, item_id, ore, refinement)

    if type(item_id) ~= "number" then
        return false, "bad_payload";
    end

    local record = PlacementService.GetPlayerPlot(player);
    if not record then
        return false, "no_plot";
    end

    local item = record.byId[item_id];
    if not item then
        return false, "unknown_item";
    end

    if item.type_name ~= "Filter" then
        return false, "bad_payload";
    end

    local options = StationRegistry.GetFilterOptions();
    local oreSet, typeSet = {}, {};
    for _, o in ipairs(options.ores) do oreSet[o] = true end
    for _, t in ipairs(options.types) do typeSet[t] = true end

    local norm_ore = (type(ore) == "string" and oreSet[ore]) and ore or "Any";
    local norm_type = (type(refinement) == "string" and typeSet[refinement]) and refinement or "Any";

    local model = item.model;
    if model and model.Parent then
        model:SetAttribute("FilterOre", norm_ore);
        model:SetAttribute("FilterType", norm_type);
        PlacementService._RefreshFilterLabel(model, norm_ore, norm_type);
    end

    return true, nil;
end

--[=[
    CLO-242 — Edit a placed station in place: rotate, move to a different
    cell, or both. Preserves the existing `item_id` — no destroy + recreate,
    no coin movement, no FactoryTickRuntime CleanupStation cycle. Atomic:
    all validation runs before any state mutates, so a rejected edit leaves
    the station at its current cell + rotation.

    Returns (true, item_id) on success, (false, error_code) on failure.
    Error codes mirror PlaceStation where they overlap:
        "bad_payload"   — invalid item_id / gx / gy / rotation
        "no_plot"       — caller has no assigned plot
        "unknown_item"  — item_id not in caller's byId map
        "out_of_bounds" — destination cell footprint exceeds plot half-extents
        "tile_locked"   — destination cell is in the locked half AND not unlocked
        "cell_occupied" — destination cell is occupied by another item, OR a
                          world-AABB overlap with another placed station
        "no_support"    — destination is above ground (gz > 0) with no occupant
                          directly below (the moved station can't support itself)
        "supporting_above" — the move would vacate a cell that is holding a
                          station above it (no-floating support rule)
        "bad_floor"     — target floor (gz) outside [0, MAX_FLOORS)

    `gz` (optional, default = the station's current floor) is the DESTINATION
    floor — edits can now relocate a station up/down as well as across the XZ
    grid. The origin floor comes from the stored item.
]=]
function PlacementService.EditStation(player, item_id, gx, gy, rotation, gz, pitch)

    if type(item_id) ~= "number" then
        return false, "bad_payload";
    end

    if not PlacementService._IsValidGridCoord(gx) or not PlacementService._IsValidGridCoord(gy) then
        return false, "bad_payload";
    end

    if not PlacementService._IsValidRotation(rotation) then
        return false, "bad_payload";
    end

    local record = PlacementService.GetPlayerPlot(player);

    if not record then
        return false, "no_plot";
    end

    local item = record.byId[item_id];

    if not item then
        return false, "unknown_item";
    end

    local item_gz = item.gz or 0;

    -- Destination floor. Defaults to the station's current floor so legacy
    -- 4-arg callers (and pure XZ/rotation edits) behave exactly as before.
    local dest_gz = gz ~= nil and gz or item_gz;
    if not PlacementService._IsValidFloor(dest_gz) then
        return false, "bad_floor";
    end

    -- Destination pitch. Defaults to the station's current pitch so legacy callers that
    -- don't pass it leave the vertical tilt untouched.
    local dest_pitch = pitch ~= nil and pitch or (item.pitch or "Flat");
    if not PlacementService._IsValidPitch(dest_pitch) then
        return false, "bad_payload";
    end

    -- No-op short circuit. If the player commits the ghost at the same cell +
    -- floor + rotation + pitch, return success without touching anything.
    if item.gx == gx and item.gy == gy and item.rotation == rotation and item_gz == dest_gz and (item.pitch or "Flat") == dest_pitch then
        return true, item_id;
    end

    -- Re-resolve the prefab for footprint geometry. We don't clone or spawn
    -- anything — just need the same _ComputeLocalHitboxBounds the original
    -- placement used so bounds + collision checks stay symmetric with
    -- PlaceStation.
    local prefab = PlacementService._GetPrefabFor(item.type_name);
    if not prefab then
        Logger.warn(`[{IDENTIFIER}:EditStation] No prefab for '{item.type_name}' — cannot validate bounds`);
        return false, "no_prefab";
    end

    local local_min_x, local_min_z, local_max_x, local_max_z =
        PlacementService._ComputeLocalHitboxBounds(prefab);

    if not PlacementService._FullFootprintFitsInPlot(
        record.plot.Size.X, record.plot.Size.Z, gx, gy,
        local_min_x, local_min_z, local_max_x, local_max_z, rotation
    ) then
        return false, "out_of_bounds";
    end

    -- Multi-cell-aware unlock + occupancy check. For single-cell stations
    -- the footprint is `{{0,0}}` so this collapses to the legacy check.
    -- For AlloySmelter (and any future multi-cell type) every cell in the
    -- destination footprint must be unlocked AND free of any OTHER station.
    local origin_cells = PlacementService._FootprintCells(item.type_name, item.gx, item.gy, item_gz, item.rotation);
    local origin_keys = {};
    for _, cell in ipairs(origin_cells) do
        origin_keys[PlacementService._CellKey(cell.gx, cell.gy, cell.gz)] = true;
    end

    local dest_cells = PlacementService._FootprintCells(item.type_name, gx, gy, dest_gz, rotation);
    local dest_keys = {};
    for _, cell in ipairs(dest_cells) do
        if not PlotExpansionService.IsTileUnlocked(record, cell.gx, cell.gy) then
            return false, "tile_locked";
        end
        local key = PlacementService._CellKey(cell.gx, cell.gy, cell.gz);
        dest_keys[key] = true;
        -- A footprint cell that the SAME station already occupies isn't an
        -- obstacle (pure rotation in place / cell-overlapping move).
        if not origin_keys[key] and record.cells[key] ~= nil then
            return false, "cell_occupied";
        end
    end

    -- Anchor rule on the destination (no floating): attach to the plot, a cell
    -- below, or an occupied same-floor neighbour. The piece can't anchor to its
    -- own cells (dest_keys) or to the origin cells it's vacating (item_id).
    if not PlacementService._IsPieceAnchored(record, dest_cells, dest_keys, item_id) then
        return false, "no_support";
    end

    -- (Load-bearing vacate guard removed 2026-06-04: support is no longer
    -- required, so moving a piece out from under another is allowed — the piece
    -- above just stays put. See _IsPieceAnchored.)

    local prefab_size_y = prefab.PrimaryPart.Size.Y;
    local destCFrame = PlacementService._GridToWorldCFrame(
        record.plot.CFrame, record.plot.Size.X, record.plot.Size.Z, record.plot.Size.Y,
        prefab_size_y, gx, gy, dest_gz, rotation, dest_pitch
    );

    -- Hitbox overlap excludes the station being edited so the model doesn't
    -- collide with itself (especially on rotate-in-place + adjacent moves
    -- where the AABBs touch by 1mm of float drift).
    if PlacementService._HasFootprintOverlap(
        record.itemHolder, prefab, destCFrame, item_id
    ) then
        return false, "cell_occupied";
    end

    -- / Atomic mutation block — all validation done; from here, every write
    -- must succeed.

    -- Rewrite the cell map for every footprint cell. Clearing the origin set
    -- and writing the destination set handles single-cell + multi-cell +
    -- rotation-in-place uniformly. The two sets may overlap (rotation at
    -- same anchor) so clearing first, writing second is safe.
    for key in pairs(origin_keys) do
        record.cells[key] = nil;
    end
    for _, cell in ipairs(dest_cells) do
        record.cells[PlacementService._CellKey(cell.gx, cell.gy, cell.gz)] = item_id;
    end

    item.gx = gx;
    item.gy = gy;
    item.gz = dest_gz;
    item.rotation = rotation;
    item.pitch = dest_pitch;

    if item.model and item.model.Parent then
        item.model:PivotTo(destCFrame);
        item.model:SetAttribute("Rotation", rotation);
        item.model:SetAttribute("Pitch", dest_pitch);
        item.model:SetAttribute("Gx", gx);
        item.model:SetAttribute("Gy", gy);
        item.model:SetAttribute("Floor", dest_gz);
        item.model:SetAttribute("TopFloor", dest_gz + StationRegistry.GetFloorHeight(item.type_name) - 1);
    end

    PlacementService._NotifyRuntimeMutation(record);

    Logger.info(`[{IDENTIFIER}:EditStation] Edited id={item_id} ({item.type_name}) -> ({gx},{gy},f{dest_gz}) {rotation} for {player.Name}`);

    return true, item_id;
end

-- / Test seams (spec.luau only):

function PlacementService._ResetForTesting()
    _plotsByInstance = {};
    _playerToPlot = {};
    _nextItemId = 1;
end

function PlacementService._SeedPlotForTesting(plot, owner_user_id)
    local record = {
        plot = plot,
        itemHolder = plot:FindFirstChild(ITEM_HOLDER_NAME) or plot,
        ownerUserId = owner_user_id or 0,
        cells = {},
        byId = {},
    };
    _plotsByInstance[plot] = record;
    if owner_user_id and owner_user_id > 0 then
        _playerToPlot[owner_user_id] = record;
    end
    return record;
end

function PlacementService._GetState()
    return {
        plotsByInstance = _plotsByInstance,
        playerToPlot = _playerToPlot,
        nextItemId = _nextItemId,
    };
end

return PlacementService;
