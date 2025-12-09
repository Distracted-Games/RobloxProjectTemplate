--!strict
--[[
    A network abstraction layer that manages RemoteEvent and RemoteFunction
	instances automatically. It provides a clean, type-safe API for remote
	communication without needing to manually instance or find remotes. It also
    enforces argument type checking on all remote signal receivers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RemoteEventName = require(script.RemoteName.RemoteEventName)
local RemoteFunctionName = require(script.RemoteName.RemoteFunctionName)

local utility = script.Utility
local createRemotesFolders = require(utility.createRemotesFolders)
local waitForAllRemotesAsync = require(utility.waitForAllRemotesAsync)
local getInstance = require(utility.getInstance)

-- How long the client will wait for remotes to replicate before erroring.
local REMOTE_REPLICATION_TIMEOUT_SECONDS = 2
local REMOTE_FOLDER_PARENT = ReplicatedStorage
local REMOTE_FOLDER_NAME = "Remotes"

local Network = {}
-- Expose enums for external use in other scripts.
Network.RemoteEvents = RemoteEventName
Network.RemoteFunctions = RemoteFunctionName
Network._started = false
Network._remoteFolder = nil :: Folder?

local function getPlayerPosition(player: Player): Vector3?
    local character = player.Character
    return if character then character:GetPivot().Position else nil
end

--[[
	Initializes the network stack on the server. This **must be called before any
	other network functions** are used on the server.
]]
function Network.startServer()
	assert(RunService:IsServer(), "Network.startServer can only be called on the server")
	assert(not Network._started, "Network.startServer has already been called")
	Network._started = true

	local remoteFolder = createRemotesFolders(REMOTE_FOLDER_NAME)
	remoteFolder.Parent = REMOTE_FOLDER_PARENT
	Network._remoteFolder = remoteFolder
end

--[[
	Initializes the network stack on the client, waiting for remotes to be
	replicated from the server. This **must be called before any other network
	functions** are used on the client.
]]
function Network.startClientAsync()
	assert(RunService:IsClient(), "Network.startClientAsync can only be called on the client")
	assert(not Network._started, "Network.startClientAsync has already been called")
	Network._started = true

	local remoteFolder =
		REMOTE_FOLDER_PARENT:WaitForChild(REMOTE_FOLDER_NAME, REMOTE_REPLICATION_TIMEOUT_SECONDS)

    -- This can occur if the client script running this initializes faster than the server script.
	assert(
		remoteFolder and remoteFolder:IsA("Folder"),
		`Missing remoteFolder folder {REMOTE_FOLDER_NAME}. Did the client Network initialize before the server?`
	)

	waitForAllRemotesAsync(remoteFolder, REMOTE_REPLICATION_TIMEOUT_SECONDS)

	Network._remoteFolder = remoteFolder
end

function Network._getRemoteEvent(eventName: RemoteEventName.EnumType): RemoteEvent
	assert(Network._remoteFolder, "Network setup not complete")

	local remoteEvent = getInstance(Network._remoteFolder, "RemoteEvents", eventName) :: RemoteEvent

	return remoteEvent
end

function Network._getRemoteFunction(functionName: RemoteFunctionName.EnumType): RemoteFunction
	assert(Network._remoteFolder, "Network setup not complete")

	local remoteFunction = getInstance(Network._remoteFolder, "RemoteFunctions", functionName) :: RemoteFunction

	return remoteFunction
end

--[[
    Connects a callback to a RemoteEvent, automatically handling the distinction
	between OnServerEvent and OnClientEvent.
]]
function Network.connectEvent(eventName: RemoteEventName.EnumType, callback: (...any) -> ()): RBXScriptConnection
	local remoteEvent = Network._getRemoteEvent(eventName)

	if RunService:IsServer() then
		return remoteEvent.OnServerEvent:Connect(callback)
	else
		return remoteEvent.OnClientEvent:Connect(callback)
	end
end

--[[
	Binds a callback to a RemoteFunction, automatically handling the distinction
	between OnServerInvoke and OnClientInvoke.
]]
function Network.bindFunction(functionName: RemoteFunctionName.EnumType, callback: (...any) -> ...any): ...any
	local remoteFunction = Network._getRemoteFunction(functionName)

	if RunService:IsServer() then
		remoteFunction.OnServerInvoke = callback
	else
		remoteFunction.OnClientInvoke = callback
	end
end

--[[
    Fires a RemoteEvent from the client to the server.
]]
function Network.fireServer(eventName: RemoteEventName.EnumType, ...: any)
	assert(RunService:IsClient(), "Network.fireServer can only be called on the client")

	local remoteEvent = Network._getRemoteEvent(eventName)
	remoteEvent:FireServer(...)
end

--[[
    Fires a RemoteEvent from the server to a specific client.
]]
function Network.fireClient(eventName: RemoteEventName.EnumType, player: Player, ...: any)
	assert(RunService:IsServer(), "Network.fireClient can only be called on the server")

	local remoteEvent = Network._getRemoteEvent(eventName)
	remoteEvent:FireClient(player, ...)
end

--[[
    Fires a RemoteEvent from the server to all connected clients.
]]
function Network.fireAllClients(eventName: RemoteEventName.EnumType, ...: any)
	assert(RunService:IsServer(), "Network.fireAllClients can only be called on the server")

	local remoteEvent = Network._getRemoteEvent(eventName)
	remoteEvent:FireAllClients(...)
end

--[[
    Fires a RemoteEvent from the server to all connected clients in the provided
    table.
]]
function Network.fireSpecificClients(eventName: RemoteEventName.EnumType, players: { Player }, ...: any)
	assert(RunService:IsServer(), "Network.fireSpecificClients can only be called on the server")

	local remoteEvent = Network._getRemoteEvent(eventName)
	
    for _, player in ipairs(Players:GetPlayers()) do
        if table.find(players, player) then
            remoteEvent:FireClient(player, ...)
        end
    end
end

--[[
    Fires a RemoteEvent from the server to all clients except those in the
    provided table.
]]
function Network.fireAllClientsExcept(eventName: RemoteEventName.EnumType, excludePlayers: { Player }, ...: any)
	assert(RunService:IsServer(), "Network.fireAllClientsExcept can only be called on the server")

	local remoteEvent = Network._getRemoteEvent(eventName)

	for _, player in ipairs(Players:GetPlayers()) do
		if table.find(excludePlayers, player) then
			continue
		end

		remoteEvent:FireClient(player, ...)
	end
end

--[[
    Fires a RemoteEvent from the server to all clients within a given distance
    from a provided position.
]]
function Network.fireClientsInRange(eventName: RemoteEventName.EnumType, sourcePosition: Vector3, maxDistance: number, ...: any)
    assert(RunService:IsServer(), "Network.fireAllClientsInRange can only be called on the server")

    local remoteEvent = Network._getRemoteEvent(eventName)

    for _, player in ipairs(Players:GetPlayers()) do
        local position = getPlayerPosition(player)
        if not position then
            continue
        end

        local distance = (sourcePosition - position).Magnitude
        if distance <= maxDistance then
            remoteEvent:FireClient(player, ...)
        end
    end
end

--[[
    Fires a RemoteEvent from the server to all clients within a given distance
    from a provided position except those provided in the exclusion table.
]]
function Network.fireClientsInRangeExcept(eventName: RemoteEventName.EnumType, sourcePosition: Vector3, maxDistance: number, excludePlayers: { Player }, ...: any)
    assert(RunService:IsServer(), "Network.fireAllClientsInRangeExcept can only be called on the server")

    local remoteEvent = Network._getRemoteEvent(eventName)

    for _, player in ipairs(Players:GetPlayers()) do
        if table.find(excludePlayers, player) then
            continue
        end

        local position = getPlayerPosition(player)
        if not position then
            continue
        end

        local distance = (sourcePosition - position).Magnitude
        if distance <= maxDistance then
            remoteEvent:FireClient(player, ...)
        end
    end
end

--[[
	Invokes a RemoteFunction on the server from the client.
    
    Wraps the call in a pcall to safely handle errors and network issues.
]]
function Network.invokeServerAsync(functionName: RemoteFunctionName.EnumType, ...: any): (boolean, ...any)
	assert(RunService:IsClient(), "Network.invokeServerAsync can only be called on the client")

	local remoteFunction = Network._getRemoteFunction(functionName)

	return pcall(remoteFunction.InvokeServer, remoteFunction, ...)
end

--[[
	Invokes a RemoteFunction on a client from the server.

    Wraps the call in pcall to safely handle errors and network issues.
]]
function Network.invokeClientAsync(
	functionName: RemoteFunctionName.EnumType,
	player: Player,
	...: any
): (boolean, ...any)
	assert(RunService:IsServer(), "Network.invokeClientAsync can only be called on the server")

	local remoteFunction = Network._getRemoteFunction(functionName)

	return pcall(remoteFunction.InvokeClient, remoteFunction, player, ...)
end

return Network
