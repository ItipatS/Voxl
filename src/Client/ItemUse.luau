-- StarterPlayerScripts/ItemUse.luau
-- Client-side item interactions keyed by ItemDef.behavior. Placement-style items
-- (e.g. the Star Seed → planting mode) register a handler here; ItemInventory runs
-- it on click. Instant items (no handler) fall through to the generic Blink UseItem.
--
-- Decouples the UI from feature controllers: PlantingController registers itself,
-- so ItemInventory never needs to know planting exists — and nothing planting-
-- related loads in places where it isn't registered.

local M = {}

local handlers: { [string]: (any) -> () } = {}

function M.register(behaviorKey: string, fn: (any) -> ())
	handlers[behaviorKey] = fn
end

function M.has(behaviorKey: string?): boolean
	return behaviorKey ~= nil and handlers[behaviorKey] ~= nil
end

function M.run(behaviorKey: string, def: any)
	local fn = handlers[behaviorKey]
	if fn then
		fn(def)
	end
end

return M
