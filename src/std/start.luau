local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std = ReplicatedStorage.std
local scheduler = require(std.scheduler)

local function start(modules)
	-- Time each module's require so a slow/blocking load shows up in the console
	-- (a yielding top-level require stalls the whole sequential boot).
	local total = os.clock()
	for _, module in modules do
		local t = os.clock()
		require(module)
		local ms = (os.clock() - t) * 1000
		if ms > 30 then
			warn(`[start] '{module.Name}' took {math.floor(ms)}ms to load`)
		end
	end
	local events = scheduler.COLLECT()
	scheduler.BEGIN(events)
	print(`[start] booted {#modules} systems in {math.floor((os.clock() - total) * 1000)}ms`)
end

return start
