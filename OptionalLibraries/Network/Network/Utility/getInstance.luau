--!strict
--[[
	Returns the instance corresponding with the given path of object names.
    Errors if this instance does not exist.

	Useful for accessing Instance trees generated at runtime For example:
    ```lua
    local remoteEventsFolder: Folder = getInstance(remoteFolder, "RemoteEvents")
    ```
]]
local function getInstance<T>(instance: Instance, ...: string): T
	for _, childName in { ... } do
		local child = assert(
			instance:FindFirstChild(childName),
			`{childName} is not a child of {instance:GetFullName()}`
		)
		instance = child
	end

	-- We want this function to be callable with generic types
	return (instance :: any) :: T
end

return getInstance
