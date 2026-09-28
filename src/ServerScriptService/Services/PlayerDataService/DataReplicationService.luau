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

return {
	Start = function()
		PlayerDataService.Signals.OnDataUpdated:Connect(replicateDataDeltas)

		PlayerDataService.Signals.PlayerProfileLoaded:Connect(function(player: Player, data: PlayerData)
			Network.fireClient(Network.RemoteEvents.InitialDataLoaded, player, data)
		end)

		for _, player in Players:GetPlayers() do
			local data = PlayerDataService.GetProfile(player)
			if data then
				Network.fireClient(Network.RemoteEvents.InitialDataLoaded, player, data)
			end
		end
	end,
}
