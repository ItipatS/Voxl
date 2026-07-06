-- ServerScriptService/systems/constellation.luau
-- Resource-star entry is now proximity-driven on the client (a countdown HUD in
-- Client/ResourceStarEntry), not a press-E prompt. When the resource gathering
-- worlds exist, the SERVER-AUTHORITATIVE warp handler goes here: receive the
-- client's "request enter <star>", validate it's actually within WARP_RADIUS of
-- that star's real position (std.constellation.LANDMARKS), then teleport.
--
-- Private stars will use a press-E ProximityPrompt ("request enter") instead,
-- wired when the planting system lands.

return {}
