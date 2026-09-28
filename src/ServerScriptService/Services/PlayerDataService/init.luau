--!strict
const MessagingService = game:GetService("MessagingService")
const Players = game:GetService("Players")
const RunService = game:GetService("RunService")

const DefaultPlayerData = require("@self/DefaultPlayerData")
const Logger = require("../../ReplicatedStorage/Source/Utility/Logger")
const PlayerDataType = require("../../ReplicatedStorage/Source/Types/PlayerDataType")
const Profile = require("../Libs/ProfileStore2/Profile")
const ProfileStore2 = require("../Libs/ProfileStore2")
const SafeTeleport = require("../Libs/SafeTeleport")
const Signal = require("../../ReplicatedStorage/Source/Libs/Signal")
const TableUtil = require("../../ReplicatedStorage/Source/Utility/TableUtil")
const TypeFunctions = require("../../ReplicatedStorage/Source/Utility/TypeFunctions")

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

const PLAYER_DATA_STORE = if RunService:IsStudio() then "TestData_v1" else "PlayerData_v1"
const PLACE_ID = game.PlaceId -- Could set to a Main Menu place

export type PlayerData = TypeFunctions.AddKeyIndexer<PlayerDataType.PlayerData>
export type PlayerDataKey = PlayerDataType.PlayerDataKey
export type Deltas = { [PlayerDataKey]: any }

type Profile = Profile.Profile<PlayerData>
type ProfileStore<T> = ProfileStore2.ProfileStore<T>

const PlayerDataService = {}

PlayerDataService.Signals = {
	OnDataUpdated = Signal.new() :: Signal.Signal<Player, PlayerData, Deltas, number?>,
	PlayerProfileLoaded = Signal.new() :: Signal.Signal<Player, PlayerData>,
}

-- A cache for active, loaded profiles for quick access.
local _profiles: { [Player]: Profile } = {}
-- The single ProfileStore2 instance for all player data.
local _playerStore: ProfileStore<PlayerData>? = nil

--[[
    The main handler for when a player's profile has been successfully loaded.
    This function is responsible for intializing the player's state in the game.
]]
local function onProfileLoaded(player: Player, profile: Profile)
	if player.Parent ~= Players then
		-- Player left while their data was loading. Safely release the session.
		profile:EndSession()
		return
	end

	profile:AddUserId(player.UserId) -- Required for GDPR compliance
	profile:Reconcile() -- Fills in any new fields from the default data template

	_profiles[player] = profile
	logger:logTable(profile.Data, `Profile loaded for {player.Name}:`)

	-- Connecting a listener for when the session is forcibly ended (e.g., another server logs in).
	profile.OnSessionEnd:Connect(function()
		_profiles[player] = nil
		player:Kick("Your data profile has been loaded in another server.")
	end)

	local frozenData = TableUtil.DeepFreezeClone(profile.Data) :: PlayerData
	PlayerDataService.Signals.PlayerProfileLoaded:Fire(player, frozenData)
end

local function onPlayerAdded(player: Player)
	if not _playerStore then
		logger:warn(
			`Player '{player.Name}' (ID: {player.UserId}) joined but PlayerStore is not ready. They will be reloaded.`
		)
		SafeTeleport.Teleport(player, PLACE_ID) -- Retry loading to the main place
		return
	end

	logger:debug(`Attempting to load Profile for {player.Name}...`)

	_playerStore
		:LoadProfileAsync(`Player_{player.UserId}`)
		:andThen(function(profile: Profile)
			logger:debug(`Successfully loaded profile for {player.Name}.`)
			return onProfileLoaded(player, profile)
		end)
		:catch(function(err)
			logger:warn(`CRITICAL: Failed to laod profile for {player.Name} (ID: {player.UserId}): {err}`)
			SafeTeleport.Teleport(player, PLACE_ID) -- Retry loading to the main place
		end)
end

local function onPlayerRemoving(player: Player)
	local profile = _profiles[player]
	if profile then
		profile:EndSession()
	end
end

--[[
    Returns a read-only snapshot of the player's current data.
    Prevents external systems from mutating state without using `PlayerDataService.UpdateData`.
]]
function PlayerDataService.GetProfile(player: Player): PlayerData?
	local profile = _profiles[player]
	if not profile then
		return nil
	end

	local data = TableUtil.DeepFreezeClone(profile.Data)
	return data
end

--[[
    Safely mutates player data and triggers a change Signal.
]]
function PlayerDataService.UpdateData(
	player: Player,
	updateFunc: (data: PlayerData) -> (),
	triggeredByTxId: number?
): (boolean, Deltas?)
	local profile = _profiles[player]
	if not profile then
		logger:warn(`Failed to find cached profile for {player.Name} (ID: {player.UserId})`)
		return false, nil
	end

	local workingCopy = TableUtil.DeepClone(profile.Data)

	local success, err = pcall(updateFunc, workingCopy)

	if not success then
		logger:debug(`Failed to update player data for {player.Name} (ID: {player.UserId}): {err}`)
		return false, nil
	end

	local deltas: Deltas = TableUtil.Diff(profile.Data, workingCopy)
	if not deltas then
		return true, {}
	end

	for key, newValue in workingCopy do
		profile.Data[key] = newValue
	end

	for key in profile.Data do
		if workingCopy[key] == nil then
			profile.Data[key] = nil
		end
	end

	local fullData = TableUtil.DeepFreezeClone(profile.Data)

	PlayerDataService.Signals.OnDataUpdated:Fire(player, fullData, deltas, triggeredByTxId)

	return true, deltas
end

function PlayerDataService.Setup()
	return ProfileStore2.create(PLAYER_DATA_STORE, DefaultPlayerData)
		:andThen(function(playerStore)
			_playerStore = playerStore
			logger:debug(`ProfileStore '{PLAYER_DATA_STORE}' is ready. Connecting player listeners.`)

			Players.PlayerAdded:Connect(function(player: Player)
				onPlayerAdded(player)
				logger:debug(`{player.Name} added.`)
			end)

			Players.PlayerRemoving:Connect(onPlayerRemoving)

			-- Handle players already in the game before listeners connect.
			for _, player in Players:GetPlayers() do
				task.spawn(onPlayerAdded, player)
			end
		end)
		:catch(function(err)
			logger:warn(
				`CRITICAL: ProfileStore '{PLAYER_DATA_STORE}' could not be created. Data will not save or load. Error: {err}`
			)

			-- Prevent new players from joining this broken server.
			Players.PlayerAdded:Connect(function(player: Player)
				player:Kick(
					"This server is experiencing critical data issues and is shutting down. Please try rejoining in a couple of minutes."
				)
			end)

			-- Gently remove any players who are already connected.
			for _, player in Players:GetPlayers() do
				-- Giving a more informative message to players who are already here.
				player:Kick(
					"A Critical data error occurred. The server is restarting to protect your data. Please rejoin in a couple of minutes."
				)
			end

			-- Using Messaging service to signal an issue. Could hook into this using an external service.
			MessagingService:PublishAsync("ServerHealthAlerts", "A server failed to initialize its ProfileStore.")
		end)
end

return table.freeze(PlayerDataService)
