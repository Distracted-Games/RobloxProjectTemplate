--!strict

--[[
	Specifies the names of all RemoteEvents. One RemoteEvent object gets
	generated for each name in this list, and these names are used as enums when
	interacting with the Network module to tell it which remote event to fire
	without typing out typo-prone string literals.
]]

local StrictEnum = require("../Utility/StrictEnum")

export type EnumType = "TeleportFailed"
	| "Teleporting"
	| "InitialDataLoaded"
	| "PlayerDataUpdated"
	| "SendNotification"
	| "RequestInitialData"

const RemoteEventName: StrictEnum.FromEnum<EnumType> = {
	TeleportFailed = "TeleportFailed",
	Teleporting = "Teleporting",
	InitialDataLoaded = "InitialDataLoaded",
	PlayerDataUpdated = "PlayerDataUpdated",
	SendNotification = "SendNotification",
	RequestInitialData = "RequestInitialData",
}

return RemoteEventName
