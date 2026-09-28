--!strict

local Players = game:GetService("Players")

export type Middleware = (...any) -> (boolean, string?)

--[[
    Creates a middleware function that rate limits incoming network events per player.
    Only supports server-side rate limiting (the first argument must be a Player).
]]
local function RateLimit(cooldown: number): Middleware
    local lastFiredTimes: { [Player]: number } = {}

    -- We use PlayerRemoving for explicit cleanup since Player instances 
    -- are sometimes held in memory by other game scripts accidentally.
    Players.PlayerRemoving:Connect(function(player: Player)
        lastFiredTimes[player] = nil
    end)

    -- selene: allow(unused_variable)
    return function(player: any, ...: any): (boolean, string?)
        -- In case this is improperly used on the client side, we check if player is an Instance.
        if not player:IsA("Player") or typeof(player) ~= "Instance" then
            return false, "RateLimit middleware requires a Player as the first argument"
        end

        local now = os.clock()
        local lastFired = lastFiredTimes[player] or 0

        if now - lastFired < cooldown then
            return false, "Rate limited"
        end

        lastFiredTimes[player] = now
        return true, nil
    end
end

return RateLimit
