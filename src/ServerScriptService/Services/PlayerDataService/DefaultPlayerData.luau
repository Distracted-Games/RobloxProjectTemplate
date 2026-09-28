--!strict

const PlayerDataType = require("../../../ReplicatedStorage/Source/Types/PlayerDataType")
const TypeFunctions = require("../../../ReplicatedStorage/Source/Utility/TypeFunctions")

type PlayerData = PlayerDataType.PlayerData

const DefaultPlayerData: TypeFunctions.AddKeyIndexer<PlayerData> = {
	Placeholder = "This is a placehold data item to satisfy type solver. Replace with your actual data."
}

return table.freeze(DefaultPlayerData)
