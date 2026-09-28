--!strict

local DEFAULT_ALLOWED_DISTANCE = 15

export type Middleware = (...any) -> (boolean, string?)

--[[
    Creates a middleware function that ensures the player's character exists,
	is alive, and is within a valid interaction radius of the given position.
    Only supports server-side use (the first argument must be a Player).

	@param targetPos The Vector3 position of the interaction object.
	@param maxAllowedDistance The maximum distance allowed between the character and the interaction object.
]]
local function Proximity(targetPos: Vector3, maxAllowedDistance: number?): Middleware
    local allowedDistance = maxAllowedDistance or DEFAULT_ALLOWED_DISTANCE

    -- selene: allow(unused_variable)
    return function(player: any, ...: any): (boolean, string?)
        -- In case this is improperly used on the client side, we check if player is an Instance.
        if not player:IsA("Player") or typeof(player) ~= "Instance" then
            return false, "Proximity middleware requires a Player as the first argument"
        end

		local character = (player :: Player).Character
		if not (character and character:IsDescendantOf(workspace)) then
			return false, "Character is missing or not a descendent of Workspace"
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return false, "Character is not alive"
		end

		local distance = (character:GetPivot().Position - targetPos).Magnitude

        if distance > allowedDistance then
			return false, "Player is not within interaction proximity"
        end

        return true, nil
    end
end

return Proximity
