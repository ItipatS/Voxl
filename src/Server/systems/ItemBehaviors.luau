--!strict
-- Server-side handlers for INSTANT-use items (fired via Blink UseItem): PlayerStore
-- checks ownership + usableIn × placemode, calls run(key, player), and consumes one
-- unit on a truthy result. A handler does its own gameplay validation.
--
-- NOTE: placement items (the Star Seed → planting) do NOT go through here. They use
-- their own validated flow (PlantService / Blink PlantStar) so a raw UseItem can't
-- plant without the full cell + name checks. This registry is empty until an instant
-- item exists; it's the extension point for those.
--
-- See .claude/17-items-and-inventory + .claude/18-planting.

local M = {}

local BEHAVIORS: { [string]: (Player) -> (boolean, string?) } = {}

-- Run a behavior by key. Returns (ok, reason). Unknown key = not ok (safe no-op).
function M.run(key: string, player: Player): (boolean, string?)
	local fn = BEHAVIORS[key]
	if not fn then
		return false, "unknown behavior"
	end
	return fn(player)
end

return M
