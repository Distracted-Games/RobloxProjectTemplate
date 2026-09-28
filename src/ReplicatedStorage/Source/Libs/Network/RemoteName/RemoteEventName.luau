--!strict

--[[
	Specifies the names of all RemoteEvents. One RemoteEvent object gets
    generated for each name	in this list, and these names are used as enums when
    interacting with the Network module to tell it which remote event to fire
    without typing out typo-prone string literals.
]]

local StrictEnum = require("../Utility/StrictEnum")

export type EnumType = "TeleportFailed"
    | "Teleporting"
    | "InitiateTeleport"
    | "InitialDataLoaded"
    | "PlayerDataUpdated"
    | "SendNotification"

local RemoteEventName: StrictEnum.FromEnum<EnumType> = {
	TeleportFailed = "TeleportFailed",
	Teleporting = "Teleporting",
    InitiateTeleport = "InitiateTeleport",
    InitialDataLoaded = "InitialDataLoaded",
    PlayerDataUpdated = "PlayerDataUpdated",
    SendNotification = "SendNotification",
}

return RemoteEventName
