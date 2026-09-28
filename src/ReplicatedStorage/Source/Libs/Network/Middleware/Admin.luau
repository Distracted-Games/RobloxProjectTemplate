--!strict

export type Middleware = (...any) -> (boolean, string?)

--[[
    Creates a middleware function that only allows players with specific UserIds to pass.
    Only supports server-side use (the first argument must be a Player).
]]
local function Admin(adminUserIds: { number }): Middleware
    -- Convert the array to a dictionary for faster O(1) lookups
    local adminDict: { [number]: boolean } = {}
    for _, userId in adminUserIds do
        adminDict[userId] = true
    end

    -- selene: allow(unused_variable)
    return function(player: any, ...: any): (boolean, string?)
        -- In case this is improperly used on the client side, we check if player is an Instance.
        if not player:IsA("Player") or typeof(player) ~= "Instance" then
            return false, "Admin middleware requires a Player as the first argument"
        end

        if adminDict[player.UserId] then
            return true, nil
        end

        return false, "Player is not an admin"
    end
end

return Admin
