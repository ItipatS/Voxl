-- StarterPlayerScripts/LockController.luau
-- Press L to drop a claim lock at your feet. The server validates, claims the
-- cylinder, and spawns the crown + force-field radius (which replicate back).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local blink = require(ReplicatedStorage.std.ClientNet)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    if input.KeyCode == Enum.KeyCode.L then
        blink.PlaceLock.Fire()
    end
end)

return {}
