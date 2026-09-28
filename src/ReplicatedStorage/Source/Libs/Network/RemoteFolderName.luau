--[[
	Specifies the names of the RemoteEvent and RemoteFunction folders used by
    `createRemotesFolders` and `waitForAllRemotesAsync`.
]]

local StrictEnum = require("./Utility/StrictEnum")

export type EnumType =
	"RemoteEvents"
	| "RemoteFunctions"

local RemoteFolderName: StrictEnum.FromEnum<EnumType> = {
	RemoteEvents = "RemoteEvents" :: "RemoteEvents",
	RemoteFunctions = "RemoteFunctions" :: "RemoteFunctions",
}

return RemoteFolderName
