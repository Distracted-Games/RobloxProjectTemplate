--!strict
const MessagingService = game:GetService("MessagingService")
const Players = game:GetService("Players")
const RunService = game:GetService("RunService")

const DefaultPlayerData = require("@self/DefaultPlayerData")
const LeanPromise = require("../../ReplicatedStorage/Source/Libs/LeanPromise")
const Logger = require("../../ReplicatedStorage/Source/Utility/Logger")
const PlayerDataType = require("../../ReplicatedStorage/Source/Types/PlayerDataType")
const ProfileStore2 = require("../Libs/ProfileStore2")
const SafeTeleport = require("../Libs/SafeTeleport")
const Signal = require("../../ReplicatedStorage/Source/Libs/Signal")
const TableUtil = require("../../ReplicatedStorage/Source/Utility/TableUtil")
const TypeFunctions = require("../../ReplicatedStorage/Source/Utility/TypeFunctions")

const PLAYER_DATA_STORE = if RunService:IsStudio() then "TestData_v1" else "PlayerData_v1"
const PROFILE_KEY_PREFIX = "Player_"
const PLACE_ID = game.PlaceId -- Could set to a Main Menu place

export type PlayerData = TypeFunctions.AddKeyIndexer<PlayerDataType.PlayerData>
export type PlayerDataKey = PlayerDataType.PlayerDataKey
export type Deltas = { [PlayerDataKey]: any }
export type MessageHandler = (player: Player, payload: any) -> ()

type Promise<T> = LeanPromise.Promise<T>
type Profile = ProfileStore2.Profile<PlayerData>
type ProfileStore<T> = ProfileStore2.ProfileStore<T>
type SignalConnection = Signal.Connection
type UnhandledMessage = {
	key: string,
	data: any,
	processed: () -> (),
}
type DrainedBatch = {
	player: Player,
	entries: { UnhandledMessage },
}

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

-- A cache for active, loaded profiles for quick access.
const _profiles: { [Player]: Profile } = {}
const _loadingPlayers: { [Player]: boolean } = {}
const _frozenProfiles: { [Player]: PlayerData } = {}
const _activeWorkingCopies: { [Player]: PlayerData } = {}
const _messageHandlers: { [string]: MessageHandler } = {}
const _unhandledMessages: { [Player]: { UnhandledMessage } } = {}
const _sessionEndConnections: { [Player]: SignalConnection } = {}

-- The single ProfileStore2 instance for all player data.
local _playerStore: ProfileStore<PlayerData>? = nil

const PlayerDataService = {}

PlayerDataService.Signals = {
	OnDataUpdated = Signal.new() :: Signal.Signal<Player, PlayerData, Deltas, number?>,
	PlayerProfileLoaded = Signal.new() :: Signal.Signal<Player, PlayerData>,
}

local function clearPlayerCaches(player: Player)
	const sessionConnection = _sessionEndConnections[player]
	if sessionConnection and sessionConnection.Connected then
		sessionConnection:Disconnect()
	end
	_sessionEndConnections[player] = nil

	_profiles[player] = nil
	_loadingPlayers[player] = nil
	_frozenProfiles[player] = nil
	_activeWorkingCopies[player] = nil
	_unhandledMessages[player] = nil
end

local function handleLoadFailure(player: Player, kickMessage: string)
	if player.Parent ~= Players then
		return
	end

	if RunService:IsStudio() then
		player:Kick(kickMessage)
		return
	end

	SafeTeleport.Teleport(player, PLACE_ID) -- Retry loading to the main place
end

local function invokeMessageHandler(
	player: Player,
	key: string,
	handler: MessageHandler,
	data: any,
	processed: () -> ()
)
	const profile = _profiles[player]
	if not (profile and profile:IsActive()) then
		return
	end

	const ok, err = pcall(handler, player, data)
	if not ok then
		logger:warn(`Message handler '{key}' failed for {player.Name}: {tostring(err)}`)
		return
	end

	processed()
end

local function dispatchProfileMessage(player: Player, message: any, processed: () -> ())
	if type(message) ~= "table" then
		return
	end

	const envelope = message :: { key: unknown, data: any }
	if type(envelope.key) ~= "string" then
		return
	end

	const handler = _messageHandlers[envelope.key]
	if not handler then
		const profile = _profiles[player]
		if not (profile and profile:IsActive()) then
			return
		end

		local queue = _unhandledMessages[player]
		if not queue then
			queue = {}
			_unhandledMessages[player] = queue
		end
		table.insert(queue, {
			key = envelope.key,
			data = envelope.data,
			processed = processed,
		})
		return
	end

	invokeMessageHandler(player, envelope.key, handler, envelope.data, processed)
end

local function commitWorkingCopy(
	player: Player,
	profile: Profile,
	workingCopy: PlayerData,
	triggeredByTxId: number?
): Deltas
	const indexedData = profile.Data
	const deltas: Deltas? = TableUtil.Diff(indexedData, workingCopy)
	if not deltas then
		return {}
	end

	for key, newValue in workingCopy do
		indexedData[key] = newValue
	end

	for key in indexedData do
		if workingCopy[key] == nil then
			indexedData[key] = nil
		end
	end

	const frozenData = TableUtil.DeepFreezeClone(profile.Data) :: PlayerData
	_frozenProfiles[player] = frozenData

	PlayerDataService.Signals.OnDataUpdated:Fire(player, frozenData, deltas, triggeredByTxId)
	return deltas
end

--[[
	Initializes the loaded profile, runs one-shot legacy hydration, caches the
	O(1) frozen snapshot, and emits `PlayerProfileLoaded`.
]]
local function onProfileLoaded(player: Player, profile: Profile)
	if player.Parent ~= Players or not profile:IsActive() then
		-- Player left while their data was loading or profile is inactive. Safely release the session.
		_loadingPlayers[player] = nil
		profile:EndSession()
		return
	end

	profile:AddUserId(player.UserId) -- Required for GDPR compliance
	profile:Reconcile() -- Fills in any new fields from the default data template

	_loadingPlayers[player] = nil
	_profiles[player] = profile

	-- Connecting a listener for when the session is forcibly ended (e.g., another server logs in).
	_sessionEndConnections[player] = profile.OnSessionEnd:Connect(function()
		_sessionEndConnections[player] = nil
		clearPlayerCaches(player)
		if player.Parent == Players then
			player:Kick("Your data profile has been loaded in another server.")
		end
	end)

	profile:MessageHandler(function(message: any, processed: () -> ())
		dispatchProfileMessage(player, message, processed)
	end)

	const frozenData = TableUtil.DeepFreezeClone(profile.Data) :: PlayerData
	_frozenProfiles[player] = frozenData
	PlayerDataService.Signals.PlayerProfileLoaded:Fire(player, frozenData)
	logger:logTable(profile.Data, `Profile loaded for {player.Name}:`)
end

local function onPlayerAdded(player: Player)
	if not _playerStore then
		logger:warn(`Player '{player.Name}' (ID: {player.UserId}) joined before PlayerStore initialized.`)
		handleLoadFailure(player, "Player data store is not available. Please rejoin.")
		return
	end

	if _profiles[player] or _loadingPlayers[player] then
		return
	end
	_loadingPlayers[player] = true

	logger:debug(`Attempting to load Profile for {player.Name}...`)

	_playerStore
		:LoadProfileAsync(`{PROFILE_KEY_PREFIX}{player.UserId}`)
		:andThen(function(profile: Profile)
			logger:debug(`Successfully loaded profile for {player.Name}.`)
			onProfileLoaded(player, profile)
		end)
		:catch(function(err: any)
			logger:warn(`CRITICAL: Failed to load profile for {player.Name} (ID: {player.UserId}): {tostring(err)}`)
			_loadingPlayers[player] = nil
			handleLoadFailure(player, "Failed to load your player data. Please rejoin.")
		end)
end

local function onPlayerRemoving(player: Player)
	const profile = _profiles[player]
	clearPlayerCaches(player)

	if profile then
		profile:EndSession()
	end
end

function PlayerDataService.IsLoaded(player: Player): boolean
	return _profiles[player] ~= nil
end

--[[
    Returns an O(1) cached deep-frozen read-only snapshot of the player's current data.
	Prevents external systems from mutating state without using `PlayerDataService.UpdateData`.
]]
function PlayerDataService.GetProfile(player: Player): PlayerData?
	const activeWorkingCopy = _activeWorkingCopies[player]
	if activeWorkingCopy then
		return TableUtil.DeepFreezeClone(activeWorkingCopy)
	end

	return _frozenProfiles[player]
end

--[[
	Returns a Promise resolving with the player's frozen `PlayerData` once loaded,
	or rejecting if the player leaves before loading completes.
]]
function PlayerDataService.WaitForDataAsync(player: Player): Promise<PlayerData>
	const existing = _frozenProfiles[player]
	if existing then
		return LeanPromise.resolve(existing)
	end

	if player.Parent ~= Players then
		return LeanPromise.reject("Player is no longer in the game.")
	end

	return LeanPromise.new(function(resolve, reject, onCancel)
		local loadedConnection: Signal.Connection? = nil
		local removingConnection: RBXScriptConnection? = nil

		local function disconnectAll()
			if loadedConnection and loadedConnection.Connected then
				loadedConnection:Disconnect()
				loadedConnection = nil
			end
			if removingConnection and removingConnection.Connected then
				removingConnection:Disconnect()
				removingConnection = nil
			end
		end

		loadedConnection = PlayerDataService.Signals.PlayerProfileLoaded:Connect(
			function(loadedPlayer: Player, data: PlayerData)
				if loadedPlayer ~= player then
					return
				end
				disconnectAll()
				resolve(data)
			end
		)

		removingConnection = Players.PlayerRemoving:Connect(function(removingPlayer: Player)
			if removingPlayer ~= player then
				return
			end
			disconnectAll()
			reject("Player left while waiting for profile data.")
		end)

		onCancel(disconnectAll)
	end) :: Promise<PlayerData>
end

--[[
	Yields until the player's profile is loaded, the player leaves, or `timeoutSeconds`
	elapses. Returns the frozen `PlayerData` snapshot, or `nil` if unavailable.
]]
function PlayerDataService.WaitForData(player: Player, timeoutSeconds: number?): PlayerData?
	const existing = _frozenProfiles[player]
	if existing then
		return existing
	end

	if player.Parent ~= Players then
		return nil
	end

	const waitPromise = PlayerDataService.WaitForDataAsync(player)
	local timeoutThread: thread? = nil

	if timeoutSeconds and timeoutSeconds > 0 then
		timeoutThread = task.delay(timeoutSeconds, function()
			waitPromise:cancel()
		end)
	end

	const ok, data = pcall(function()
		return waitPromise:await()
	end)

	if timeoutThread and coroutine.status(timeoutThread) == "suspended" then
		task.cancel(timeoutThread)
	end

	return if ok then data else _frozenProfiles[player]
end

--[[
    Safely mutates player data, updates the cached O(1) frozen snapshot, and emits
	`OnDataUpdated` with minimal deltas.
]]
function PlayerDataService.UpdateData(
	player: Player,
	updateFunc: (data: PlayerData) -> (),
	triggeredByTxId: number?
): (boolean, Deltas?)
	const profile = _profiles[player]
	if not (profile and profile:IsActive()) then
		logger:warn(`Failed to find active cached profile for {player.Name} (ID: {player.UserId})`)
		return false, nil
	end

	const existingWorkingCopy = _activeWorkingCopies[player]
	if existingWorkingCopy then
		updateFunc(existingWorkingCopy)
		return true, {}
	end

	const workingCopy = TableUtil.DeepClone(profile.Data) :: PlayerData
	_activeWorkingCopies[player] = workingCopy

	const updateThread = coroutine.create(updateFunc)
	const success, err = coroutine.resume(updateThread, workingCopy)
	_activeWorkingCopies[player] = nil

	if not success then
		logger:warn(`Failed to update player data for {player.Name} (ID: {player.UserId}): {tostring(err)}`)
		return false, nil
	end

	if coroutine.status(updateThread) ~= "dead" then
		logger:warn(`UpdateData callback yielded for {player.Name} (ID: {player.UserId}); update discarded.`)
		return false, nil
	end

	if _profiles[player] ~= profile or not profile:IsActive() then
		logger:warn(`Player {player.Name} profile became inactive before update could be committed.`)
		return false, nil
	end

	const deltas: Deltas = commitWorkingCopy(player, profile, workingCopy, triggeredByTxId)

	return true, deltas
end

--[[
	Registers a handler for cross-server / offline profile messages matching `key`
	(wire format `{ key = key, data = payload }`).
]]
function PlayerDataService.RegisterMessageHandler(key: string, handler: MessageHandler): () -> ()
	assert(_messageHandlers[key] == nil, `Message handler for key '{key}' is already registered.`)
	_messageHandlers[key] = handler

	const batchesToDispatch: { DrainedBatch } = {}
	const emptyPlayers: { Player } = {}

	for player, queue in _unhandledMessages do
		local pendingForKey: { UnhandledMessage } = {}
		local index = 1

		while index <= #queue do
			const entry = queue[index]
			if entry.key == key then
				table.remove(queue, index)
				table.insert(pendingForKey, entry)
			else
				index += 1
			end
		end

		if #queue == 0 then
			table.insert(emptyPlayers, player)
		end

		if #pendingForKey > 0 then
			table.insert(batchesToDispatch, {
				player = player,
				entries = pendingForKey,
			})
		end
	end

	for _, player in emptyPlayers do
		_unhandledMessages[player] = nil
	end

	for _, batch in batchesToDispatch do
		for _, entry in batch.entries do
			task.spawn(invokeMessageHandler, batch.player, key, handler, entry.data, entry.processed)
		end
	end

	return function()
		if _messageHandlers[key] == handler then
			_messageHandlers[key] = nil
		end
	end
end

--[[
	Queues a persistent GlobalUpdates message (`{key = key, data = payload }`) on
	`player_<userId>` in `PLAYER_DATA_STORE` for online or offline delivery.
]]
function PlayerDataService.SendProfileMessageAsync(userId: number, key: string, payload: any): Promise<boolean>
	if not _playerStore then
		return LeanPromise.reject("PlayerStore is not initialized.")
	end

	return _playerStore:MessageAsync(`{PROFILE_KEY_PREFIX}{userId}`, { key = key, data = payload })
end

function PlayerDataService.Setup()
	const ok, storeOrErr = pcall(function()
		return ProfileStore2.create(PLAYER_DATA_STORE, DefaultPlayerData):await()
	end)

	if ok and storeOrErr then
		_playerStore = storeOrErr
		logger:debug(`ProfileStore '{PLAYER_DATA_STORE}' initialized.`)
		return
	end

	logger:warn(
		`CRITICAL: ProfileStore '{PLAYER_DATA_STORE}' could not be created. Data will not save or load. Error: {storeOrErr}`
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
end

function PlayerDataService.Start()
	if not _playerStore then
		return
	end

	Players.PlayerAdded:Connect(function(player: Player)
		onPlayerAdded(player)
		logger:debug(`{player.Name} added.`)
	end)

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return table.freeze(PlayerDataService)
