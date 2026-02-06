--!strict

local network = script.Parent.Parent
local RemoteEventName = require(network.RemoteName.RemoteEventName)
local RemoteFolderName = require(network.RemoteFolderName)
local RemoteFunctionName = require(network.RemoteName.RemoteFunctionName)

--[[
	Wait in parallel for all RemoteEvents and RemoteFunctions defined in
    RemoteNames to replicate into the remoteFolder.

	Used to ensure all remotes exist before the client Network module finishes
    initializing.
]]
local function waitForAllRemotesAsync(remoteFolder: Folder, timeoutSeconds: number)
	-- Using FindFirstChild to satisfy type checker.
	local remoteEventsFolder = remoteFolder:FindFirstChild(RemoteFolderName.RemoteEvents) :: Folder
	local remoteFunctionsFolder = remoteFolder:FindFirstChild(RemoteFolderName.RemoteFunctions) :: Folder

	-- Make each set of event and function names read-only.
	local remoteEvents = table.freeze(RemoteEventName) :: { string }
	local remoteFunctions = table.freeze(RemoteFunctionName) :: { string }

	-- Validate that the remotes defined under RemoteNames exist in remote folders.
	local success = true
	local function search(names: { string }, folder: Folder)
		for _, remoteName in ipairs(names) do
			local remote = folder:WaitForChild(remoteName, timeoutSeconds)
			if not remote then
				success = false
				break
			end
		end
	end

	search(remoteEvents, remoteEventsFolder)
	search(remoteFunctions, remoteFunctionsFolder)

	assert(
        success,
        "Network could not find all reemotes. Did the client Network module initialize before the server?"
    )
end

return waitForAllRemotesAsync
