--!strict

const Players = game:GetService("Players")

const Network = require("../../../ReplicatedStorage/Source/Libs/Network")
const PlayerDataService = require("./.")

type PlayerData = PlayerDataService.PlayerData
type PlayerDataKey = PlayerDataService.PlayerDataKey
type Deltas = PlayerDataService.Deltas

local function replicateDataDeltas(player: Player, _data: PlayerData, deltas: Deltas, triggeredByTxId: number?)
	Network.fireClient(Network.RemoteEvents.PlayerDataUpdated, player, deltas, triggeredByTxId)
end

const DataReplicationService = {}

function DataReplicationService.Start()
	PlayerDataService.Signals.OnDataUpdated:Connect(replicateDataDeltas)

	PlayerDataService.Signals.PlayerProfileLoaded:Connect(function(player: Player, data: PlayerData)
		Network.fireClient(Network.RemoteEvents.InitialDataLoaded, player, data)
	end)

	Network.connectEvent(Network.RemoteEvents.RequestInitialData, function(player: Player)
		const data = PlayerDataService.GetProfile(player)
		if data then
			Network.fireClient(Network.RemoteEvents.InitialDataLoaded, player, data)
		end
	end)

	for _, player in Players:GetPlayers() do
		const data = PlayerDataService.GetProfile(player)
		if data then
			Network.fireClient(Network.RemoteEvents.InitialDataLoaded, player, data)
		end
	end
end

return DataReplicationService
