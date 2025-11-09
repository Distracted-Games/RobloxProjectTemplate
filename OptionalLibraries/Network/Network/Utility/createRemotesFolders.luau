--!strict
--[[
	Creates folders for RemoteFunctions and RemoteEvents used by Network. These
    folders are then populated with new RemoteEvents and RemoteFunctions for
    each name specified in the RemoteNames constants module.
]]

local utility = script.Parent
local Network = utility.Parent
local remoteName = Network.RemoteName
local RemoteEventName = require(remoteName.RemoteEventName)
local RemoteFunctionName = require(remoteName.RemoteFunctionName)
local RemoteFolderName = require(Network.RemoteFolderName)
local getInstance = require(utility.getInstance)

type PropertiesTable = { [string]: any } -- Used for createInstanceTree

--[[
    Loops through each remote event from Network/RemoteName/RemoteEventName and
    each remote function from Network/RemoteName/RemoteFunctionName, creating the
    corresponding remotes within.
]]
local function createRemotes(remoteFolder: Folder)
    local remoteEventsFolder: Folder = getInstance(remoteFolder, RemoteFolderName.RemoteEvents)

    for eventName in pairs(RemoteEventName) do
		local remoteEvent = Instance.new("RemoteEvent")
		remoteEvent.Name = eventName
        remoteEvent.Parent = remoteEventsFolder
    end

    local remoteFunctionsFolder: Folder = getInstance(remoteFolder, RemoteFolderName.RemoteFunctions)

    for functionName in pairs(RemoteFunctionName) do
        local remoteFunction = Instance.new("RemoteFunction")
        remoteFunction.Name = functionName
        remoteFunction.Parent = remoteFunctionsFolder
    end
end

--[[
    Creates the remote event and remote function folders and populates them with
    each event and function from Network/RemoteName/RemoteEventName and
    Network/RemoteName/RemoteFunctionName.
]]
local function createRemotesFolders(rootFolderName: string): Folder
    local folder = Instance.new("Folder")
    folder.Name = rootFolderName

    local remoteEventsFolder = Instance.new("Folder")
    remoteEventsFolder.Name = RemoteFolderName.RemoteEvents
    remoteEventsFolder.Parent = folder

    local remoteFunctionsFolder = Instance.new("Folder")
    remoteFunctionsFolder.Name = RemoteFolderName.RemoteFunctions
    remoteFunctionsFolder.Parent = folder

    createRemotes(folder)

    return folder
end

return createRemotesFolders
