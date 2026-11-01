--!strict
--[[
	ProfileStore2
	@author DistractedGames
	@version 1.3.0

	Copyright 2026 Distracted Games

	Licensed under the Apache License, Version 2.0 (the "License");
	you may not use this file except in compliance with the License.
	You may obtain a copy of the License at

		http://www.apache.org/licenses/LICENSE-2.0

	Unless required by applicable law or agreed to in writing, software
	distributed under the License is distributed on an "AS IS" BASIS,
	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
	See the License for the specific language governing permissions and
	limitations under the License.
]]

--[[
	The main entry point for the ProfileStore2 library.
	This module manages ProfileStore instances, session locking, periodic auto-saving,
	Studio offline fallback mocking, critical state monitoring, and server shutdown persistence.
]]

const DataStoreService = game:GetService("DataStoreService")
const HttpService = game:GetService("HttpService")
const MessagingService = game:GetService("MessagingService")
const RunService = game:GetService("RunService")

const Constants = require("@self/Constants")
const Messaging = require("@self/Addons/Messaging")
const Profile = require("@self/Profile")
const Promise = require("@self/LeanPromise")
const PromiseError = require("@self/LeanPromise/PromiseError")
const Signal = require("@self/Signal")
const Types = require("@self/Types")
const Util = require("@self/Util")
const Versioning = require("@self/Addons/Versioning")

const CONNECTIVITY_STORE_NAME = "____PS"
const DEBUG_MODE = false
const MAX_BACKOFF_NORMAL = 20
const MAX_BACKOFF_SHUTDOWN = 8
const MESSAGING_COOLDOWN = 6

const DataStoreState = table.freeze({
	NotReady = "NotReady" :: "NotReady",
	NoInternet = "NoInternet" :: "NoInternet",
	NoAccess = "NoAccess" :: "NoAccess",
	Access = "Access" :: "Access",
})

export type Profile<T> = Profile.Profile<T>
export type VersionQuery<T = any> = Versioning.VersionQuery<T>
export type Promise<T = any> = Promise.Promise<T>
export type PromiseError = PromiseError.PromiseError
export type ErrorKind = Types.ErrorKind
export type Signal<T... = ...any> = Signal.Signal<T...>
export type Connection<T... = ...any> = Signal.Connection<T...>
export type ConstantName = Constants.ConstantName
export type CreateStoreOptions = Types.CreateStoreOptions
export type LoadProfileParams = Types.LoadProfileParams
export type LastSaveReason = Types.LastSaveReason
export type DataStoreState = Types.DataStoreState

type MockEntry = {
	Data: any,
	CreatedTime: number,
	UpdatedTime: number,
	VersionId: number,
	UserIds: { number },
	MetaData: { [string]: any },
}

type TransformParams<T> = {
	ExistingProfileHandle: ((latestData: Types.ProfileData<T>) -> ())?,
	MissingProfileHandle: ((latestData: Types.ProfileData<T>) -> ())?,
	EditProfile: ((latestData: Types.ProfileData<T>) -> ())?,
}

type InFlightLoadJob = {
	Generation: number,
	Cancel: (() -> ())?,
}

export type MockProfileStore<T> = {
	read Name: string,
	read LoadProfileAsync: (
		self: MockProfileStore<T>,
		key: string,
		params: Types.LoadProfileParams?
	) -> Promise.Promise<Profile.Profile<T>>,
	read GetAsync: (self: MockProfileStore<T>, key: string, version: string?) -> Promise.Promise<Profile.Profile<T>?>,
	read RemoveAsync: (self: MockProfileStore<T>, key: string) -> Promise.Promise<boolean>,
	read MessageAsync: (self: MockProfileStore<T>, key: string, message: { [any]: any }) -> Promise.Promise<boolean>,
	read VersionQuery: (
		self: MockProfileStore<T>,
		key: string,
		sortDirection: Enum.SortDirection?,
		minDate: DateTime | number | nil,
		maxDate: DateTime | number | nil
	) -> Versioning.VersionQuery<T>,
}

local ProfileStore = {}
ProfileStore.__index = ProfileStore

type ProfileStoreMetatable = {}

type ProfileStoreClassData<T> = {
	-- Public Properties
	Name: string,
	Mock: MockProfileStore<T>,

	-- Public Methods
	read LoadProfileAsync: (
		self: ProfileStore<T>,
		key: string,
		params: Types.LoadProfileParams?
	) -> Promise.Promise<Profile.Profile<T>>,
	read GetAsync: (self: ProfileStore<T>, key: string, version: string?) -> Promise.Promise<Profile.Profile<T>?>,
	read RemoveAsync: (self: ProfileStore<T>, key: string) -> Promise.Promise<boolean>,
	read MessageAsync: (self: ProfileStore<T>, key: string, message: { [any]: any }) -> Promise.Promise<boolean>,
	read VersionQuery: (
		self: ProfileStore<T>,
		key: string,
		sortDirection: Enum.SortDirection?,
		minDate: DateTime | number | nil,
		maxDate: DateTime | number | nil
	) -> Versioning.VersionQuery<T>,

	-- Internal Properties
	_template: T,
	_scope: string?,
	_fullStoreKey: string,
	_useLegacySchema: boolean,
	_dataStore: DataStore?,
	_isReady: boolean,
	_loadJobs: { [string]: InFlightLoadJob },
	_mockLoadJobs: { [string]: InFlightLoadJob },

	-- Internal Methods
	read _waitForStoreReady: (self: ProfileStore<T>) -> (),
	read _performDataStoreOperation: (
		self: ProfileStore<T>,
		key: string,
		transformParams: TransformParams<T>,
		isUserMock: boolean,
		isGetCall: boolean?,
		version: string?
	) -> (Types.ProfileData<T>?, DataStoreKeyInfo?, string?),
	read _saveProfileInternal: (
		self: ProfileStore<T>,
		profile: Profile.Profile<T>,
		requeueAutoSave: boolean
	) -> Promise.Promise<T>,
	read _saveProfile: (self: ProfileStore<T>, profile: Profile.Profile<T>) -> Promise.Promise<T>,
	read _releaseProfile: (
		self: ProfileStore<T>,
		profile: Profile.Profile<T>,
		reason: Types.LastSaveReason
	) -> Promise.Promise<nil>,
	read _overwriteProfile: (self: ProfileStore<T>, profile: Profile.Profile<T>) -> Promise.Promise<nil>,
	read _loadProfileInternal: (
		self: ProfileStore<T>,
		key: string,
		params: Types.LoadProfileParams?,
		isUserMock: boolean
	) -> Promise.Promise<Profile.Profile<T>>,
	read _getAsyncInternal: (
		self: ProfileStore<T>,
		key: string,
		version: string?,
		isUserMock: boolean
	) -> Promise.Promise<Profile.Profile<T>?>,
	read _removeAsyncInternal: (self: ProfileStore<T>, key: string, isUserMock: boolean) -> Promise.Promise<boolean>,
}

export type ProfileStore<T> = setmetatable<ProfileStoreClassData<T>, ProfileStoreMetatable>

export type TestInspectionState = {
	ActiveSessionCheck: { [string]: Profile.Profile<any> },
	AutoSaveList: { Profile.Profile<any> },
	ActiveProfileLoadJobs: number,
	ActiveProfileSaveJobs: number,
	AutoMockStore: { [string]: { [string]: MockEntry } },
	UserMockStore: { [string]: { [string]: MockEntry } },
	UpdateQueue: { [string]: { thread } },
	IssueQueue: { number },
}

export type ProfileStoreModule = {
	ErrorKind: Types.ErrorKindTable,
	IsClosing: boolean,
	IsCriticalState: boolean,
	DataStoreState: Types.DataStoreState,
	OnError: Signal.Signal<string, string, string>,
	OnOverwrite: Signal.Signal<string, string>,
	OnCriticalToggle: Signal.Signal<boolean>,
	create: <T>(
		storeName: string,
		template: T?,
		options: Types.CreateStoreOptions?
	) -> Promise.Promise<ProfileStore<T>>,
	SetConstant: (name: Constants.ConstantName, value: number) -> (),
	Test: () -> TestInspectionState,
}

-- Global State
const isStudio = RunService:IsStudio()
const placeId = game.PlaceId
const jobId = game.JobId

local activeSessionCheck: { [string]: Profile.Profile<any> } = {}
local autoSaveList: { Profile.Profile<any> } = {}
local issueQueue: { number } = {}
local updateQueue: { [string]: { thread } } = {}
local userMockStore: { [string]: { [string]: MockEntry } } = {}
local autoMockStore: { [string]: { [string]: MockEntry } } = {}

local autoSaveIndex = 1
local lastAutoSave = os.clock()
local isClosing = false
local isCriticalState = false
local criticalStateStart = 0
local activeProfileLoadJobs = 0
local activeProfileSaveJobs = 0
local loadGenerationCounter = 0

local currentDataStoreState: Types.DataStoreState = if isStudio then DataStoreState.NotReady else DataStoreState.Access

-- Global Signals
const onError: Signal.Signal<string, string, string> = Signal.new()
const onOverwrite: Signal.Signal<string, string> = Signal.new()
const onCriticalToggle: Signal.Signal<boolean> = Signal.new()
const stateChanged: Signal.Signal<> = Signal.new()

--------------------------------------------------------------------------------
-- Private Helper Functions
--------------------------------------------------------------------------------

local function validateKey(key: string, methodName: string)
	if typeof(key) ~= "string" or #key == 0 or #key > 50 then
		error(`[ProfileStore]: Invalid 'key' provided to {methodName}. Must be 1-50 characters.`, 3)
	end
end

local function isThisSession(sessionTag: any): boolean
	if typeof(sessionTag) ~= "table" then
		return false
	end
	if sessionTag.PlaceId ~= nil then
		return sessionTag.PlaceId == placeId and sessionTag.JobId == jobId
	end
	return sessionTag[1] == placeId and sessionTag[2] == jobId
end

local function getSessionUniqueId(sessionTag: any): string?
	if typeof(sessionTag) ~= "table" then
		return nil
	end
	if typeof(sessionTag.UniqueId) == "string" then
		return sessionTag.UniqueId
	end
	if typeof(sessionTag[3]) == "string" then
		return sessionTag[3]
	end
	return nil
end

local function buildActiveSession(uniqueId: string, useLegacySchema: boolean): Types.SessionLock
	if useLegacySchema then
		return { placeId, jobId, uniqueId }
	end
	return {
		PlaceId = placeId,
		JobId = jobId,
		UniqueId = uniqueId,
	}
end

local function buildForceLoadSession(useLegacySchema: boolean): Types.ForceLoadLock
	if useLegacySchema then
		return { placeId, jobId }
	end
	return {
		PlaceId = placeId,
		JobId = jobId,
	}
end

local function generateSessionToken(fullStoreKey: string, profileKey: string, isUserMock: boolean): string
	local prefix: string
	if isUserMock then
		prefix = "U_"
	elseif currentDataStoreState ~= DataStoreState.Access then
		prefix = "M_"
	else
		prefix = "L_"
	end
	return `{prefix}{fullStoreKey}\0{profileKey}`
end

--[[
	Ensures that only one DataStore operation runs at a time per session token on this server.
	Returns a release callback that MUST be called once the operation completes.
]]
local function waitForUpdateQueue(sessionToken: string): () -> ()
	local queue = updateQueue[sessionToken]
	if not queue then
		local newQueue: { thread } = {}
		updateQueue[sessionToken] = newQueue

		return function()
			const nextThread = table.remove(newQueue, 1)
			if nextThread then
				task.spawn(nextThread)
			else
				updateQueue[sessionToken] = nil
			end
		end
	end

	table.insert(queue, coroutine.running())
	coroutine.yield()

	return function()
		const nextThread = table.remove(queue, 1)
		if nextThread then
			task.spawn(nextThread)
		else
			updateQueue[sessionToken] = nil
		end
	end
end

local function registerError(errorMessage: string, storeName: string, profileKey: string)
	warn(`[ProfileStore]: DataStore API error (STORE: {storeName}; KEY: {profileKey}) - {errorMessage}`)
	table.insert(issueQueue, os.clock())
	onError:Fire(errorMessage, storeName, profileKey)
end

local function registerOverwrite(storeName: string, profileKey: string)
	warn(`[ProfileStore]: Invalid profile was overwritten (STORE: {storeName}; KEY: {profileKey})`)
	onOverwrite:Fire(storeName, profileKey)
end

local function publishSessionMessageSafe(uniqueSessionId: string, payload: { [string]: any })
	task.spawn(function()
		pcall(function()
			MessagingService:PublishAsync(`PS_{uniqueSessionId}`, payload)
		end)
	end)
end

local function createMockKeyInfo(entry: MockEntry): DataStoreKeyInfo
	const versionString = tostring(entry.VersionId)
	const paddedVersion = string.rep("0", math.max(0, 10 - #versionString)) .. versionString
	const metaCopy = entry.MetaData
	const userIdsCopy = entry.UserIds

	return (
		{
			CreatedTime = entry.CreatedTime,
			UpdatedTime = entry.UpdatedTime,
			Version = `{string.rep("0", 16)}.{paddedVersion}.{string.rep("0", 16)}.01`,
			GetMetadata = function()
				return Util.DeepCopyTable(metaCopy)
			end,
			GetUserIds = function()
				return Util.DeepCopyTable(userIdsCopy)
			end,
		} :: any
	) :: DataStoreKeyInfo
end

--[[
	Simulates a DataStore UpdateAsync or GetAsync call against an in-memory mock table.
]]
local function mockUpdateAsync<T>(
	mockDataStore: { [string]: { [string]: MockEntry } },
	fullStoreKey: string,
	key: string,
	transform: (latestData: any) -> (Types.ProfileData<T>?, { number }?, { [string]: any }?),
	isGetCall: boolean
): (Types.ProfileData<T>?, DataStoreKeyInfo?)
	local storeTable = mockDataStore[fullStoreKey]
	if not storeTable then
		if isGetCall then
			task.wait()
			return nil, nil
		end
		storeTable = {}
		mockDataStore[fullStoreKey] = storeTable
	end

	const epochMillis = math.floor(os.time() * 1000)
	local existingEntry = storeTable[key]

	if isGetCall then
		if not existingEntry then
			task.wait()
			return nil, nil
		end
		const snapshotInput = Util.DeepCopyTable(existingEntry.Data)
		const transformedData = transform(snapshotInput)
		task.wait()
		if not transformedData then
			return nil, nil
		end
		return Util.DeepCopyTable(transformedData), createMockKeyInfo(existingEntry)
	end

	const inputCopy = if existingEntry then Util.DeepCopyTable(existingEntry.Data) else nil
	const transformedData, userIds, robloxMetaData = transform(inputCopy)

	if not transformedData then
		task.wait()
		return nil, nil
	end

	if not existingEntry then
		existingEntry = {
			Data = nil,
			CreatedTime = epochMillis,
			UpdatedTime = epochMillis,
			VersionId = 0,
			UserIds = {},
			MetaData = {},
		}
		storeTable[key] = existingEntry
	end

	existingEntry.Data = Util.DeepCopyTable(transformedData)
	existingEntry.UserIds = Util.DeepCopyTable(userIds or {})
	existingEntry.MetaData = Util.DeepCopyTable(robloxMetaData or {})
	existingEntry.VersionId += 1
	existingEntry.UpdatedTime = epochMillis

	task.wait()
	return Util.DeepCopyTable(transformedData), createMockKeyInfo(existingEntry)
end

--[[
	Adds a profile to the circular auto-save schedule.
]]
local function addProfileToAutoSave(profile: Profile.Profile<any>)
	activeSessionCheck[profile._sessionToken] = profile

	table.insert(autoSaveList, autoSaveIndex, profile)

	if #autoSaveList > 1 then
		autoSaveIndex += 1
	elseif #autoSaveList == 1 then
		lastAutoSave = os.clock()
	end
end

--[[
	Removes a profile from the circular auto-save schedule and adjusts the rotation index.
]]
local function removeProfileFromAutoSave(profile: Profile.Profile<any>)
	if activeSessionCheck[profile._sessionToken] == profile then
		activeSessionCheck[profile._sessionToken] = nil
	end

	const indexInList = table.find(autoSaveList, profile)
	if not indexInList then
		return
	end

	table.remove(autoSaveList, indexInList)
	if indexInList < autoSaveIndex then
		autoSaveIndex -= 1
	end
	if autoSaveList[autoSaveIndex] == nil then
		autoSaveIndex = 1
	end
end

local function disconnectProfileSubscription(profile: Profile.Profile<any>)
	const subscription = profile._robloxMessageSubscription
	if subscription then
		profile._robloxMessageSubscription = nil
		pcall(function()
			subscription:Disconnect()
		end)
	end
end

const syncAndDispatchGlobalUpdates = Messaging.SyncAndDispatchGlobalUpdates
const pruneLockedUpdatesFromPayload = Messaging.PruneLockedUpdatesFromPayload

--[[
	Subscribes a live profile to MessagingService pokes for fast cross-server session release
	and live GlobalUpdates delivery.
]]
local function startRobloxMessageSubscription(profile: Profile.Profile<any>, uniqueSessionId: string)
	local lastMessageClock = 0

	const ok, subscription = pcall(function()
		return MessagingService:SubscribeAsync(`PS_{uniqueSessionId}`, function(message: any)
			if typeof(message) ~= "table" or typeof(message.Data) ~= "table" then
				return
			end
			if message.Data.LoadCount ~= profile.SessionLoadCount then
				return
			end

			const now = os.clock()
			if now - lastMessageClock <= MESSAGING_COOLDOWN and message.Data.EndSession ~= true then
				return
			end
			lastMessageClock = now

			if not profile:IsActive() then
				return
			end

			if message.Data.EndSession == true then
				profile.ProfileStore:_releaseProfile(profile, "External")
			else
				profile:Save()
			end
		end)
	end)

	if not ok or not subscription then
		return
	end

	if profile:IsActive() then
		profile._robloxMessageSubscription = subscription
	else
		pcall(function()
			subscription:Disconnect()
		end)
	end
end

--------------------------------------------------------------------------------
-- Private ProfileStore Methods
--------------------------------------------------------------------------------

function ProfileStore._waitForStoreReady(self: ProfileStore<any>)
	while not self._isReady do
		task.wait()
	end
end

local function notifyMessageTarget<T>(
	store: ProfileStore<T>,
	key: string,
	loadedData: Types.ProfileData<T>,
	isUserMock: boolean
)
	const sessionToken = generateSessionToken(store._fullStoreKey, key, isUserMock)
	const localActiveProfile = activeSessionCheck[sessionToken]

	if localActiveProfile and localActiveProfile:IsActive() then
		store:_saveProfileInternal(localActiveProfile, false)
	elseif not isUserMock and currentDataStoreState == DataStoreState.Access then
		const metaData: Types.ProfileMetaData? = loadedData.MetaData
		if metaData then
			const uniqueSessionId = getSessionUniqueId(metaData.ActiveSession)
			if uniqueSessionId ~= nil then
				publishSessionMessageSafe(uniqueSessionId, {
					LoadCount = metaData.SessionLoadCount or 0,
				})
			end
		end
	end
end

--[[
	Core serialized DataStore access wrapper with schema validation, corruption recovery,
	and mock routing. Returns `(loadedData, keyInfo, errorMessage)`.
]]
function ProfileStore._performDataStoreOperation<T>(
	self: ProfileStore<T>,
	key: string,
	transformParams: TransformParams<T>,
	isUserMock: boolean,
	isGetCall: boolean?,
	version: string?
): (Types.ProfileData<T>?, DataStoreKeyInfo?, string?)
	self:_waitForStoreReady()

	const sessionToken = generateSessionToken(self._fullStoreKey, key, isUserMock)
	const releaseQueue = waitForUpdateQueue(sessionToken)

	local loadedData: Types.ProfileData<T>?
	local keyInfo: DataStoreKeyInfo?

	const success, callError = pcall(function()
		local function transformFunction(rawLatestData: any): (Types.ProfileData<T>?, { number }?, { [string]: any }?)
			local missingProfile = false
			local overwritten = false
			local globalUpdates: Types.GlobalUpdatesPayload = { 0, {} }
			local latestData: any = rawLatestData

			if latestData == nil then
				missingProfile = true
			elseif
				typeof(latestData) == "table"
				and typeof(latestData.Data) == "table"
				and typeof(latestData.MetaData) == "table"
			then
				latestData.WasOverwritten = false
				if
					typeof(latestData.GlobalUpdates) == "table"
					and typeof(latestData.GlobalUpdates[1]) == "number"
					and typeof(latestData.GlobalUpdates[2]) == "table"
				then
					globalUpdates = latestData.GlobalUpdates
				else
					latestData.GlobalUpdates = globalUpdates
				end

				if transformParams.ExistingProfileHandle then
					transformParams.ExistingProfileHandle(latestData)
				end
			elseif
				typeof(latestData) == "table"
				and latestData.Data == nil
				and latestData.MetaData == nil
				and typeof(latestData.GlobalUpdates) == "table"
			then
				latestData.WasOverwritten = false
				if
					typeof(latestData.GlobalUpdates[1]) == "number"
					and typeof(latestData.GlobalUpdates[2]) == "table"
				then
					globalUpdates = latestData.GlobalUpdates
				end
				missingProfile = true
			else
				missingProfile = true
				overwritten = true
			end

			if missingProfile then
				latestData = {
					GlobalUpdates = globalUpdates,
					UserIds = {},
					RobloxMetaData = {},
				}
				if transformParams.MissingProfileHandle then
					transformParams.MissingProfileHandle(latestData)
				end
			end

			if transformParams.EditProfile then
				transformParams.EditProfile(latestData)
			end

			-- If key was missing and neither MissingProfileHandle nor EditProfile populated profile or update data,
			-- cancel the write so externally deleted keys (RemoveAsync) are not resurrected as empty tombstones.
			if
				missingProfile
				and transformParams.MissingProfileHandle == nil
				and latestData.Data == nil
				and latestData.MetaData == nil
				and (typeof(globalUpdates[2]) ~= "table" or #globalUpdates[2] == 0)
			then
				return nil, nil, nil
			end

			if overwritten then
				latestData.WasOverwritten = true
			end

			return latestData, latestData.UserIds, latestData.RobloxMetaData
		end

		if isUserMock then
			loadedData, keyInfo =
				mockUpdateAsync(userMockStore, self._fullStoreKey, key, transformFunction, isGetCall == true)
		elseif currentDataStoreState ~= DataStoreState.Access then
			loadedData, keyInfo =
				mockUpdateAsync(autoMockStore, self._fullStoreKey, key, transformFunction, isGetCall == true)
		else
			const dataStore = self._dataStore
			assert(dataStore ~= nil, "DataStore instance missing in Access state")

			if isGetCall == true then
				if version ~= nil then
					const targetVersion = version
					const getVersionOk, getVersionErr = pcall(function()
						const packed = { dataStore:GetVersionAsync(key, targetVersion) }
						loadedData = packed[1]
						keyInfo = packed[2]
					end)
					if not getVersionOk then
						if typeof(getVersionErr) == "string" and string.find(getVersionErr, "not valid") then
							warn(`[ProfileStore]: Passed version argument '{targetVersion}' is not valid.`)
						end
						error(getVersionErr)
					end
				else
					const packed = { dataStore:GetAsync(key) }
					loadedData = packed[1]
					keyInfo = packed[2]
				end

				if loadedData ~= nil and keyInfo ~= nil then
					loadedData = transformFunction(loadedData)
				end
			else
				const packed = { dataStore:UpdateAsync(key, transformFunction) }
				loadedData = packed[1]
				keyInfo = packed[2]
			end
		end
	end)

	releaseQueue()

	if not success then
		const errorMessage = tostring(callError)
		registerError(errorMessage, self.Name, key)
		return nil, nil, errorMessage
	end

	if typeof(loadedData) == "table" and loadedData.WasOverwritten == true and isGetCall ~= true then
		registerOverwrite(self.Name, key)
	end

	return loadedData, keyInfo, nil
end

--[[
	Internal live save implementation without releasing the session lock.
	If `requeueAutoSave` is true (manual Profile:Save()), delays the next auto-save for this profile.
]]
function ProfileStore._saveProfileInternal<T>(
	self: ProfileStore<T>,
	profile: Profile.Profile<T>,
	requeueAutoSave: boolean
): Promise.Promise<T>
	const currentData: unknown = profile.Data
	if typeof(currentData) ~= "table" then
		const errText = `Developer code set Profile.Data to a non-table value (STORE: {self.Name}; KEY: {profile.Key}).`
		error(`[ProfileStore]: {errText}`, 2)
	end

	if requeueAutoSave then
		removeProfileFromAutoSave(profile)
		addProfileToAutoSave(profile)
	end

	profile.OnSave:Fire()

	return Promise.new(function(resolve, reject)
		activeProfileSaveJobs += 1

		const loadedData, keyInfo, errorMessage = self:_performDataStoreOperation(profile.Key, {
			ExistingProfileHandle = nil,
			MissingProfileHandle = nil,
			EditProfile = function(latestData: Types.ProfileData<T>)
				const metaData: Types.ProfileMetaData? = latestData.MetaData
				if not metaData then
					return
				end
				const activeSession = metaData.ActiveSession
				const sessionLoadCount = metaData.SessionLoadCount
				const sessionOwnsProfile = isThisSession(activeSession) and sessionLoadCount == profile._loadIndex

				if not sessionOwnsProfile then
					return
				end

				pruneLockedUpdatesFromPayload(profile._lockedGlobalUpdates, latestData.GlobalUpdates)
				latestData.Data = profile.Data
				latestData.RobloxMetaData = profile.RobloxMetaData
				latestData.UserIds = profile.UserIds
				metaData.LastUpdate = os.time()
			end,
		}, profile._isMock)

		activeProfileSaveJobs -= 1

		if errorMessage ~= nil then
			reject(PromiseError.new({
				error = errorMessage,
				kind = Types.ErrorKind.DataStoreError,
			}))
			return
		end

		const metaData: Types.ProfileMetaData? = if loadedData then loadedData.MetaData else nil
		if loadedData == nil or keyInfo == nil or metaData == nil then
			disconnectProfileSubscription(profile)
			if profile._isActive then
				profile._isActive = false
				removeProfileFromAutoSave(profile)
				profile.OnSessionEnd:Fire()
			end
			resolve(profile.LastSavedData)
			return
		end

		const activeSession = metaData.ActiveSession
		const sessionLoadCount = metaData.SessionLoadCount
		const sessionOwnsProfile = isThisSession(activeSession) and sessionLoadCount == profile._loadIndex

		const forceLoadSession = metaData.ForceLoadSession
		const forceLoadPending = typeof(forceLoadSession) == "table" and not isThisSession(forceLoadSession)

		if forceLoadPending and sessionOwnsProfile then
			profile.KeyInfo = keyInfo
			profile.LastSavedData = Util.DeepCopyTable(loadedData.Data)
			if profile:IsActive() then
				self:_releaseProfile(profile, "External")
			end
			resolve(profile.LastSavedData)
			return
		end

		const shouldDispatchMessages = sessionOwnsProfile and profile:IsActive()
		syncAndDispatchGlobalUpdates(profile, loadedData, shouldDispatchMessages)

		profile.KeyInfo = keyInfo
		profile.LastSavedData = Util.DeepCopyTable(loadedData.Data)

		if not sessionOwnsProfile then
			disconnectProfileSubscription(profile)
			if profile._isActive then
				profile._isActive = false
				removeProfileFromAutoSave(profile)
				profile.OnSessionEnd:Fire()
			end
		end

		profile.OnAfterSave:Fire(profile.LastSavedData)
		resolve(profile.LastSavedData)
	end) :: Promise.Promise<T>
end

function ProfileStore._saveProfile<T>(self: ProfileStore<T>, profile: Profile.Profile<T>): Promise.Promise<T>
	if not profile:IsActive() then
		const message = `Attempted to save an inactive profile (STORE: {self.Name}; KEY: {profile.Key}).`
		warn(`[ProfileStore]: {message}`)
		return Promise.reject(PromiseError.new({
			error = message,
			kind = Types.ErrorKind.SessionConflict,
		}))
	end

	return self:_saveProfileInternal(profile, true)
end

--[[
	Performs the final save for a profile and releases its session lock, retrying transient
	DataStore failures with exponential backoff while aborting on non-retryable data errors.
]]
function ProfileStore._releaseProfile<T>(
	self: ProfileStore<T>,
	profile: Profile.Profile<T>,
	reason: Types.LastSaveReason
): Promise.Promise<nil>
	if profile._releasePromise then
		return profile._releasePromise
	end

	const currentData: unknown = profile.Data
	if typeof(currentData) ~= "table" then
		const errText = `Developer code set Profile.Data to a non-table value (STORE: {self.Name}; KEY: {profile.Key}).`
		error(`[ProfileStore]: {errText}`, 2)
	end

	profile._isActive = false
	disconnectProfileSubscription(profile)
	removeProfileFromAutoSave(profile)

	profile.OnSave:Fire()
	profile.OnLastSave:Fire(reason)

	const releasePromise = Promise.new(function(resolve, reject)
		activeProfileSaveJobs += 1
		local backoff = 1

		while true do
			const loadedData, keyInfo, errorMessage = self:_performDataStoreOperation(profile.Key, {
				ExistingProfileHandle = nil,
				MissingProfileHandle = nil,
				EditProfile = function(latestData: Types.ProfileData<T>)
					const metaData: Types.ProfileMetaData? = latestData.MetaData
					if not metaData then
						return
					end
					const activeSession = metaData.ActiveSession
					const sessionLoadCount = metaData.SessionLoadCount
					const sessionOwnsProfile = isThisSession(activeSession) and sessionLoadCount == profile._loadIndex

					if not sessionOwnsProfile then
						return
					end

					pruneLockedUpdatesFromPayload(profile._lockedGlobalUpdates, latestData.GlobalUpdates)
					latestData.Data = profile.Data
					latestData.RobloxMetaData = profile.RobloxMetaData
					latestData.UserIds = profile.UserIds
					metaData.LastUpdate = os.time()
					metaData.ActiveSession = nil
				end,
			}, profile._isMock)

			if errorMessage == nil then
				const metaData: Types.ProfileMetaData? = if loadedData then loadedData.MetaData else nil
				if loadedData ~= nil and keyInfo ~= nil and metaData ~= nil then
					syncAndDispatchGlobalUpdates(profile, loadedData, false)
					profile.KeyInfo = keyInfo
					profile.LastSavedData = Util.DeepCopyTable(loadedData.Data)
					profile.OnAfterSave:Fire(profile.LastSavedData)
				end
				profile.OnSessionEnd:Fire()
				activeProfileSaveJobs -= 1
				resolve(nil)
				return
			end

			const errText = errorMessage
			if not Util.IsTransientDataStoreError(errText) then
				profile.OnSessionEnd:Fire()
				activeProfileSaveJobs -= 1
				reject(PromiseError.new({
					error = errText,
					kind = Types.ErrorKind.DataStoreError,
				}))
				return
			end

			const maxBackoff = if reason == "Shutdown" or isClosing then MAX_BACKOFF_SHUTDOWN else MAX_BACKOFF_NORMAL
			task.wait(backoff)
			backoff = math.min(maxBackoff, backoff * 2)
		end
	end) :: Promise.Promise<nil>

	profile._releasePromise = releasePromise
	return releasePromise
end

--[[
	Forcefully overwrites a profile from a view-mode snapshot (Profile:SetAsync()),
	clearing any active session lock and notifying any active owner.
]]
function ProfileStore._overwriteProfile<T>(self: ProfileStore<T>, profile: Profile.Profile<T>): Promise.Promise<nil>
	const currentData: unknown = profile.Data
	if typeof(currentData) ~= "table" then
		const errText = `Developer code set Profile.Data to a non-table value (STORE: {self.Name}; KEY: {profile.Key}).`
		error(`[ProfileStore]: {errText}`, 2)
	end

	profile.OnSave:Fire()

	return Promise.new(function(resolve, reject, onCancel)
		local isCancelled = false
		onCancel(function()
			isCancelled = true
		end)

		local function shouldAbort(): boolean
			return isClosing or isCancelled
		end

		activeProfileSaveJobs += 1
		local backoff = 1
		local attempt = 0

		while true do
			if isClosing or isCancelled then
				activeProfileSaveJobs -= 1
				reject(PromiseError.new({
					error = "SetAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end

			local previousSessionUniqueId: string? = nil
			local previousSessionLoadCount = 0

			const loadedData, keyInfo, errorMessage = self:_performDataStoreOperation(profile.Key, {
				ExistingProfileHandle = nil,
				MissingProfileHandle = function(latestData: Types.ProfileData<T>)
					const metaTags: { [string]: any }? = if self._useLegacySchema then {} else nil
					latestData.Data = Util.DeepCopyTable(self._template)
					latestData.MetaData = {
						ProfileCreateTime = os.time(),
						SessionLoadCount = 0,
						ActiveSession = nil,
						ForceLoadSession = nil,
						MetaTags = metaTags,
					}
				end,
				EditProfile = function(latestData: Types.ProfileData<T>)
					const metaData: Types.ProfileMetaData? = latestData.MetaData
					if metaData then
						previousSessionUniqueId = getSessionUniqueId(metaData.ActiveSession)
						previousSessionLoadCount = metaData.SessionLoadCount or 0
						metaData.ActiveSession = nil
						metaData.ForceLoadSession = nil
						metaData.LastUpdate = os.time()
					end

					pruneLockedUpdatesFromPayload(profile._lockedGlobalUpdates, latestData.GlobalUpdates)
					latestData.Data = profile.Data
					latestData.RobloxMetaData = profile.RobloxMetaData
					latestData.UserIds = profile.UserIds
				end,
			}, profile._isMock)

			if errorMessage == nil and loadedData ~= nil and keyInfo ~= nil then
				syncAndDispatchGlobalUpdates(profile, loadedData, false)
				profile.KeyInfo = keyInfo
				profile.LastSavedData = Util.DeepCopyTable(loadedData.Data)
				profile.OnAfterSave:Fire(profile.LastSavedData)

				-- Immediately notify any live session on this server or a remote server.
				const sessionToken = generateSessionToken(self._fullStoreKey, profile.Key, profile._isMock)
				const localActiveProfile = activeSessionCheck[sessionToken]
				if localActiveProfile and localActiveProfile:IsActive() then
					self:_saveProfileInternal(localActiveProfile, false)
				elseif
					previousSessionUniqueId ~= nil
					and not profile._isMock
					and currentDataStoreState == DataStoreState.Access
				then
					publishSessionMessageSafe(previousSessionUniqueId, {
						LoadCount = previousSessionLoadCount,
					})
				end

				activeProfileSaveJobs -= 1
				resolve(nil)
				return
			end

			const errText = errorMessage or `Failed to SetAsync profile for key '{profile.Key}'.`
			attempt += 1
			if attempt > Constants.MAX_TRANSIENT_RETRIES or not Util.IsTransientDataStoreError(errText) then
				activeProfileSaveJobs -= 1
				reject(PromiseError.new({
					error = errText,
					kind = Types.ErrorKind.DataStoreError,
				}))
				return
			end

			if Util.WaitInterruptible(backoff, shouldAbort) then
				activeProfileSaveJobs -= 1
				reject(PromiseError.new({
					error = "SetAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end
			backoff = math.min(MAX_BACKOFF_NORMAL, backoff * 2)
		end
	end) :: Promise.Promise<nil>
end

function ProfileStore._loadProfileInternal<T>(
	self: ProfileStore<T>,
	key: string,
	params: Types.LoadProfileParams?,
	isUserMock: boolean
): Promise.Promise<Profile.Profile<T>>
	validateKey(key, "LoadProfileAsync")
	if params ~= nil and typeof(params) ~= "table" then
		error("[ProfileStore]: Invalid 'params' table provided to LoadProfileAsync.", 3)
	end

	const options: Types.LoadProfileParams = params or {}

	return Promise.new(function(resolve, reject, onCancel)
		local isPromiseCancelled = false
		onCancel(function()
			isPromiseCancelled = true
		end)

		if isClosing then
			reject(PromiseError.new({
				error = "Cannot load profile while server is shutting down.",
				kind = Types.ErrorKind.Cancelled,
			}))
			return
		end

		self:_waitForStoreReady()

		if isClosing or isPromiseCancelled then
			reject(PromiseError.new({
				error = "Profile load cancelled before starting.",
				kind = Types.ErrorKind.Cancelled,
			}))
			return
		end

		const sessionToken = generateSessionToken(self._fullStoreKey, key, isUserMock)
		if activeSessionCheck[sessionToken] ~= nil then
			reject(PromiseError.new({
				error = `Profile (STORE: {self.Name}; KEY: {key}) already has an active session on this server.`,
				kind = Types.ErrorKind.SessionConflict,
			}))
			return
		end

		-- Supersede any earlier still-loading request for the same key on this server.
		loadGenerationCounter += 1
		const myGeneration = loadGenerationCounter
		local loadJobsMap = if isUserMock then self._mockLoadJobs else self._loadJobs
		const existingLoadJob = loadJobsMap[key]
		if existingLoadJob and existingLoadJob.Cancel then
			existingLoadJob.Cancel()
		end

		local isSuperseded = false
		const myLoadJob: InFlightLoadJob = {
			Generation = myGeneration,
			Cancel = function()
				isSuperseded = true
			end,
		}
		loadJobsMap[key] = myLoadJob

		local function cleanupLoadJob()
			if loadJobsMap[key] == myLoadJob then
				loadJobsMap[key] = nil
			end
		end

		local isUserCancelled = false
		local function isCancelled(): boolean
			if isPromiseCancelled or isSuperseded then
				return true
			end
			if not isUserCancelled and options.Cancel ~= nil then
				isUserCancelled = options.Cancel() == true
			end
			return isUserCancelled
		end

		local function shouldAbort(): boolean
			return isClosing or isCancelled()
		end

		activeProfileLoadJobs += 1

		const userSteal = options.Steal == true
		local forceLoadSteps = 0
		local requestForceLoad = true
		local stealSession = false
		const startClock = os.clock()
		local errorBackoff = 1

		while not isClosing and not isCancelled() do
			-- Check session start timeout when no custom Cancel predicate is managing lifetime.
			if options.Cancel == nil and os.clock() - startClock >= Constants.START_SESSION_TIMEOUT then
				cleanupLoadJob()
				activeProfileLoadJobs -= 1
				reject(PromiseError.new({
					error = `Timed out waiting to start session for key '{key}'.`,
					kind = Types.ErrorKind.TimedOut,
				}))
				return
			end

			const uniqueSessionId = HttpService:GenerateGUID(false)

			const loadedData, keyInfo, errorMessage = self:_performDataStoreOperation(key, {
				ExistingProfileHandle = function(latestData: Types.ProfileData<T>)
					if isClosing or isCancelled() then
						return
					end

					const activeSession = latestData.MetaData.ActiveSession
					const forceLoadSession = latestData.MetaData.ForceLoadSession

					if activeSession == nil then
						latestData.MetaData.ActiveSession = buildActiveSession(uniqueSessionId, self._useLegacySchema)
						latestData.MetaData.ForceLoadSession = nil
					elseif typeof(activeSession) == "table" then
						if not isThisSession(activeSession) then
							const lastUpdate = latestData.MetaData.LastUpdate
							if lastUpdate ~= nil and os.time() - lastUpdate > Constants.ASSUME_DEAD then
								latestData.MetaData.ActiveSession =
									buildActiveSession(uniqueSessionId, self._useLegacySchema)
								latestData.MetaData.ForceLoadSession = nil
								return
							end

							if stealSession or userSteal then
								const forceLoadInterrupted = if forceLoadSession ~= nil
									then not isThisSession(forceLoadSession)
									else true
								if not forceLoadInterrupted or userSteal then
									latestData.MetaData.ActiveSession =
										buildActiveSession(uniqueSessionId, self._useLegacySchema)
									latestData.MetaData.ForceLoadSession = nil
								end
							elseif requestForceLoad then
								latestData.MetaData.ForceLoadSession = buildForceLoadSession(self._useLegacySchema)
							end
						else
							latestData.MetaData.ActiveSession =
								buildActiveSession(uniqueSessionId, self._useLegacySchema)
							latestData.MetaData.ForceLoadSession = nil
						end
					end
				end,
				MissingProfileHandle = function(latestData: Types.ProfileData<T>)
					const shouldCancel = isClosing or isCancelled()
					const metaTags: { [string]: any }? = if self._useLegacySchema then {} else nil
					latestData.Data = Util.DeepCopyTable(self._template)
					latestData.MetaData = {
						ProfileCreateTime = os.time(),
						SessionLoadCount = 0,
						ActiveSession = if not shouldCancel
							then buildActiveSession(uniqueSessionId, self._useLegacySchema)
							else nil,
						ForceLoadSession = nil,
						MetaTags = metaTags,
					}
				end,
				EditProfile = function(latestData: Types.ProfileData<T>)
					if isClosing or isCancelled() then
						return
					end

					const activeSession = latestData.MetaData.ActiveSession
					if activeSession ~= nil and isThisSession(activeSession) then
						latestData.MetaData.SessionLoadCount += 1
						latestData.MetaData.LastUpdate = os.time()
					end
				end,
			}, isUserMock)

			if isSuperseded then
				cleanupLoadJob()
				activeProfileLoadJobs -= 1
				reject(PromiseError.new({
					error = `LoadProfileAsync for key '{key}' was superseded by a newer load request.`,
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end

			if errorMessage == nil and loadedData ~= nil and keyInfo ~= nil then
				errorBackoff = 1
				const activeSession = loadedData.MetaData.ActiveSession

				if typeof(activeSession) == "table" then
					if isThisSession(activeSession) then
						const isAutoMock = not isUserMock and currentDataStoreState ~= DataStoreState.Access
						local profile = Profile.new(
							loadedData,
							keyInfo,
							self :: any,
							key,
							isUserMock,
							isAutoMock,
							sessionToken,
							false
						)
						addProfileToAutoSave(profile)

						if not isUserMock and currentDataStoreState == DataStoreState.Access then
							task.spawn(startRobloxMessageSubscription, profile, uniqueSessionId)
						end

						-- If shutdown or cancellation occurred mid-flight while acquiring the lock, release immediately.
						if isClosing or isCancelled() then
							cleanupLoadJob()
							const releaseReason: Types.LastSaveReason = if isClosing then "Shutdown" else "Manual"
							self:_releaseProfile(profile, releaseReason):finally(function()
								activeProfileLoadJobs -= 1
							end)
							reject(PromiseError.new({
								error = "Profile load was cancelled or server started shutting down.",
								kind = Types.ErrorKind.Cancelled,
							}))
							return
						end

						cleanupLoadJob()
						activeProfileLoadJobs -= 1
						resolve(profile)
						return
					else
						-- Owned by another server; negotiate handoff or escalate toward SESSION_STEAL.
						if isClosing or isCancelled() then
							cleanupLoadJob()
							activeProfileLoadJobs -= 1
							reject(PromiseError.new({
								error = "Profile load was cancelled during session handoff.",
								kind = Types.ErrorKind.Cancelled,
							}))
							return
						end

						const forceLoadSession = loadedData.MetaData.ForceLoadSession
						const forceLoadInterrupted = if forceLoadSession ~= nil
							then not isThisSession(forceLoadSession)
							else true

						if forceLoadInterrupted then
							cleanupLoadJob()
							activeProfileLoadJobs -= 1
							reject(PromiseError.new({
								error = `Another remote server interrupted session handoff for key '{key}'.`,
								kind = Types.ErrorKind.SessionConflict,
							}))
							return
						end

						if not requestForceLoad then
							forceLoadSteps += 1
							const stepsToSteal = math.ceil(Constants.SESSION_STEAL / Constants.LOAD_REPEAT_PERIOD)
							if forceLoadSteps >= stepsToSteal then
								stealSession = true
							end
						end

						const remoteUniqueId = getSessionUniqueId(activeSession)
						if
							remoteUniqueId ~= nil
							and not isUserMock
							and currentDataStoreState == DataStoreState.Access
						then
							publishSessionMessageSafe(remoteUniqueId, {
								LoadCount = loadedData.MetaData.SessionLoadCount or 0,
								EndSession = true,
							})
						end

						const repeatDelay = if requestForceLoad
							then Constants.FIRST_LOAD_REPEAT
							else Constants.LOAD_REPEAT_PERIOD
						requestForceLoad = false

						if options.Cancel == nil then
							const remainingBeforeTimeout = Constants.START_SESSION_TIMEOUT - (os.clock() - startClock)
							if remainingBeforeTimeout <= 0 then
								cleanupLoadJob()
								activeProfileLoadJobs -= 1
								reject(PromiseError.new({
									error = `Timed out waiting to start session for key '{key}'.`,
									kind = Types.ErrorKind.TimedOut,
								}))
								return
							end
						end

						Util.WaitInterruptible(repeatDelay, shouldAbort)
					end
				else
					-- ActiveSession was nil because isClosing / isCancelled fired inside MissingProfileHandle.
					cleanupLoadJob()
					activeProfileLoadJobs -= 1
					reject(PromiseError.new({
						error = "Profile load was cancelled or server is shutting down.",
						kind = Types.ErrorKind.Cancelled,
					}))
					return
				end
			else
				-- DataStore API error occurred.
				const errText = errorMessage or `DataStore UpdateAsync failed for key '{key}'.`
				if not Util.IsTransientDataStoreError(errText) then
					cleanupLoadJob()
					activeProfileLoadJobs -= 1
					reject(PromiseError.new({
						error = errText,
						kind = Types.ErrorKind.DataStoreError,
					}))
					return
				end

				if options.Cancel == nil and os.clock() - startClock >= Constants.START_SESSION_TIMEOUT then
					cleanupLoadJob()
					activeProfileLoadJobs -= 1
					reject(PromiseError.new({
						error = `Timed out starting session for key '{key}': {errText}`,
						kind = Types.ErrorKind.TimedOut,
					}))
					return
				end

				Util.WaitInterruptible(errorBackoff, shouldAbort)
				errorBackoff = math.min(MAX_BACKOFF_NORMAL, errorBackoff * 2)
			end
		end

		cleanupLoadJob()
		activeProfileLoadJobs -= 1
		reject(PromiseError.new({
			error = "Profile load was cancelled or server is shutting down.",
			kind = Types.ErrorKind.Cancelled,
		}))
	end) :: Promise.Promise<Profile.Profile<T>>
end

function ProfileStore._getAsyncInternal<T>(
	self: ProfileStore<T>,
	key: string,
	version: string?,
	isUserMock: boolean
): Promise.Promise<Profile.Profile<T>?>
	validateKey(key, "GetAsync")

	return Promise.new(function(resolve: (Profile.Profile<T>?) -> (), reject, onCancel)
		local isCancelled = false
		onCancel(function()
			isCancelled = true
		end)

		local function shouldAbort(): boolean
			return isClosing or isCancelled
		end

		if isClosing then
			reject(PromiseError.new({
				error = "Cannot call GetAsync while server is shutting down.",
				kind = Types.ErrorKind.Cancelled,
			}))
			return
		end

		self:_waitForStoreReady()

		if version ~= nil and (isUserMock or currentDataStoreState ~= DataStoreState.Access) then
			resolve(nil)
			return
		end

		local backoff = 1
		local attempt = 0

		while true do
			if isClosing or isCancelled then
				reject(PromiseError.new({
					error = "GetAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end

			const loadedData, keyInfo, errorMessage = self:_performDataStoreOperation(key, {
				ExistingProfileHandle = nil,
				MissingProfileHandle = function(latestData: Types.ProfileData<T>)
					const metaTags: { [string]: any }? = if self._useLegacySchema then {} else nil
					latestData.Data = Util.DeepCopyTable(self._template)
					latestData.MetaData = {
						ProfileCreateTime = os.time(),
						SessionLoadCount = 0,
						ActiveSession = nil,
						ForceLoadSession = nil,
						MetaTags = metaTags,
					}
				end,
				EditProfile = nil,
			}, isUserMock, true, version)

			if errorMessage == nil then
				if loadedData == nil or keyInfo == nil then
					resolve(nil)
					return
				end

				const sessionToken = generateSessionToken(self._fullStoreKey, key, isUserMock)
				const isAutoMock = not isUserMock and currentDataStoreState ~= DataStoreState.Access
				local profile =
					Profile.new(loadedData, keyInfo, self :: any, key, isUserMock, isAutoMock, sessionToken, true)
				resolve(profile)
				return
			end

			attempt += 1
			if attempt > Constants.MAX_TRANSIENT_RETRIES or not Util.IsTransientDataStoreError(errorMessage) then
				reject(PromiseError.new({
					error = errorMessage,
					kind = Types.ErrorKind.DataStoreError,
				}))
				return
			end

			if Util.WaitInterruptible(backoff, shouldAbort) then
				reject(PromiseError.new({
					error = "GetAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end
			backoff = math.min(MAX_BACKOFF_NORMAL, backoff * 2)
		end
	end)
end

function ProfileStore._removeAsyncInternal<T>(
	self: ProfileStore<T>,
	key: string,
	isUserMock: boolean
): Promise.Promise<boolean>
	validateKey(key, "RemoveAsync")

	return Promise.new(function(resolve, reject, onCancel)
		local isCancelled = false
		onCancel(function()
			isCancelled = true
		end)

		local function shouldAbort(): boolean
			return isClosing or isCancelled
		end

		if isClosing then
			reject(PromiseError.new({
				error = "Cannot call RemoveAsync while server is shutting down.",
				kind = Types.ErrorKind.Cancelled,
			}))
			return
		end

		self:_waitForStoreReady()

		const sessionToken = generateSessionToken(self._fullStoreKey, key, isUserMock)
		local backoff = 1
		local attempt = 0

		while true do
			if isClosing or isCancelled then
				reject(PromiseError.new({
					error = "RemoveAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end

			const releaseQueue = waitForUpdateQueue(sessionToken)
			local removeError: string? = nil

			if isUserMock then
				local mockStore = userMockStore[self._fullStoreKey]
				if mockStore then
					mockStore[key] = nil
					if next(mockStore) == nil then
						userMockStore[self._fullStoreKey] = nil
					end
				end
				task.wait()
			elseif currentDataStoreState ~= DataStoreState.Access then
				local mockStore = autoMockStore[self._fullStoreKey]
				if mockStore then
					mockStore[key] = nil
					if next(mockStore) == nil then
						autoMockStore[self._fullStoreKey] = nil
					end
				end
				task.wait()
			else
				const dataStore = self._dataStore
				assert(dataStore ~= nil, "DataStore instance missing in Access state")
				const ok, err = pcall(function()
					dataStore:RemoveAsync(key)
				end)
				if not ok then
					removeError = tostring(err)
				end
			end

			releaseQueue()

			if removeError == nil then
				if DEBUG_MODE then
					print(`[ProfileStore]: Successfully removed profile for key '{key}'.`)
				end
				resolve(true)
				return
			end

			registerError(removeError, self.Name, key)
			attempt += 1

			if attempt > Constants.MAX_TRANSIENT_RETRIES or not Util.IsTransientDataStoreError(removeError) then
				reject(PromiseError.new({
					error = removeError,
					kind = Types.ErrorKind.DataStoreError,
				}))
				return
			end

			if Util.WaitInterruptible(backoff, shouldAbort) then
				reject(PromiseError.new({
					error = "RemoveAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end
			backoff = math.min(MAX_BACKOFF_NORMAL, backoff * 2)
		end
	end) :: Promise.Promise<boolean>
end

--------------------------------------------------------------------------------
-- Store Construction & Public Methods
--------------------------------------------------------------------------------

local function messageAsyncInternal<T>(
	store: ProfileStore<T>,
	key: string,
	message: { [any]: any },
	isUserMock: boolean
): Promise.Promise<boolean>
	return Messaging.MessageAsyncInternal({
		WaitForStoreReady = function()
			store:_waitForStoreReady()
		end,
		IsServerClosing = function()
			return isClosing
		end,
		PerformDataStoreOperation = function(
			targetKey: string,
			transformParams: Messaging.TransformParams<T>,
			targetIsMock: boolean
		)
			return store:_performDataStoreOperation(targetKey, transformParams, targetIsMock)
		end,
		NotifyMessageTarget = function(targetKey: string, loadedData: Types.ProfileData<T>, targetIsMock: boolean)
			notifyMessageTarget(store, targetKey, loadedData, targetIsMock)
		end,
	}, key, message, isUserMock)
end

local function versionQueryInternal<T>(
	store: ProfileStore<T>,
	key: string,
	sortDirection: Enum.SortDirection?,
	minDate: DateTime | number | nil,
	maxDate: DateTime | number | nil,
	isUserMock: boolean
): Versioning.VersionQuery<T>
	return Versioning.CreateVersionQuery({
		StoreName = store.Name,
		GetDataStore = function()
			return store._dataStore
		end,
		WaitForStoreReady = function()
			store:_waitForStoreReady()
		end,
		IsServerClosing = function()
			return isClosing
		end,
		HasDataStoreAccess = function()
			return currentDataStoreState == DataStoreState.Access
		end,
		IsStudio = function()
			return isStudio
		end,
		RegisterError = registerError,
		GetAsyncInternal = function(targetKey: string, version: string?, targetIsMock: boolean)
			return store:_getAsyncInternal(targetKey, version, targetIsMock)
		end,
	}, key, sortDirection, minDate, maxDate, isUserMock)
end

local function createStoreInstance<T>(storeName: string, template: T?, options: Types.CreateStoreOptions?): ProfileStore<T>
	if typeof(storeName) ~= "string" or #storeName == 0 or #storeName > 50 then
		error("[ProfileStore]: Invalid 'storeName' provided. Must be a string of 1-50 characters.", 3)
	end

	const profileTemplate: any = if template ~= nil then template else {}
	if typeof(profileTemplate) ~= "table" then
		error("[ProfileStore]: Invalid 'template' provided. Must be a table.", 3)
	end

	if options ~= nil and typeof(options) ~= "table" then
		error("[ProfileStore]: Invalid 'options' provided. Must be a table.", 3)
	end

	const scope = if options and options.Scope ~= nil then options.Scope else nil
	if scope ~= nil and (typeof(scope) ~= "string" or #scope == 0 or #scope > 50) then
		error("[ProfileStore]: Invalid 'options.Scope' provided. Must be a string of 1-50 characters.", 3)
	end

	const useLegacySchema = if options and options.UseLegacySchema == true then true else false
	const fullStoreKey = if scope then `{storeName}\0{scope}` else storeName

	local self = (setmetatable({}, ProfileStore) :: any) :: ProfileStore<T>
	self.Name = storeName
	self._template = Util.DeepCopyTable(profileTemplate)
	self._scope = scope
	self._fullStoreKey = fullStoreKey
	self._useLegacySchema = useLegacySchema
	self._dataStore = nil
	self._isReady = false
	self._loadJobs = {}
	self._mockLoadJobs = {}

	local mock: MockProfileStore<T> = {
		Name = storeName,
		LoadProfileAsync = function(_, key: string, params: Types.LoadProfileParams?)
			return self:_loadProfileInternal(key, params, true)
		end,
		GetAsync = function(_, key: string, version: string?)
			return self:_getAsyncInternal(key, version, true)
		end,
		RemoveAsync = function(_, key: string)
			return self:_removeAsyncInternal(key, true)
		end,
		MessageAsync = function(_, key: string, message: { [any]: any })
			return messageAsyncInternal(self, key, message, true)
		end,
		VersionQuery = function(
			_,
			key: string,
			sortDirection: Enum.SortDirection?,
			minDate: DateTime | number | nil,
			maxDate: DateTime | number | nil
		)
			return versionQueryInternal(self, key, sortDirection, minDate, maxDate, true)
		end,
	}
	self.Mock = table.freeze(mock)

	local function finalizeStoreReadiness()
		if currentDataStoreState == DataStoreState.Access then
			local dataStoreOptions = Instance.new("DataStoreOptions")
			dataStoreOptions:SetExperimentalFeatures({ v2 = true })
			self._dataStore = DataStoreService:GetDataStore(storeName, scope, dataStoreOptions)
		end
		self._isReady = true
	end

	if currentDataStoreState ~= DataStoreState.NotReady then
		finalizeStoreReadiness()
	else
		stateChanged:Once(finalizeStoreReadiness)
	end

	return self
end

--[[
	Asynchronously creates and initializes a ProfileStore.
	In Studio with API Services disabled, automatically falls back to an isolated in-memory mock store.
]]
function ProfileStore.create<T>(
	storeName: string,
	template: T?,
	options: Types.CreateStoreOptions?
): Promise.Promise<ProfileStore<T>>
	const store = createStoreInstance(storeName, template, options)
	const untypedStore: any = store

	if currentDataStoreState ~= DataStoreState.NotReady then
		return (Promise.resolve(untypedStore) :: any) :: Promise.Promise<ProfileStore<T>>
	end

	return (
		Promise.new(function(resolve)
			if currentDataStoreState ~= DataStoreState.NotReady then
				resolve(untypedStore)
				return
			end

			stateChanged:Once(function()
				resolve(untypedStore)
			end)
		end) :: any
	) :: Promise.Promise<ProfileStore<T>>
end

--[[
	Updates a configurable ProfileStore timing or threshold constant at runtime.
]]
function ProfileStore.SetConstant(name: Constants.ConstantName, value: number)
	if typeof(name) ~= "string" or (Constants :: { [string]: any })[name] == nil then
		error(`[ProfileStore]: Invalid constant name '{tostring(name)}' provided to SetConstant.`, 2)
	end
	if typeof(value) ~= "number" or value < 0 or value ~= value then
		error(`[ProfileStore]: Invalid numeric value '{tostring(value)}' provided to SetConstant.`, 2)
	end

	(Constants :: { [string]: any })[name] = value
end

--[[
	Exposes live internal queues and mock stores for automated unit testing and diagnostics.
]]
function ProfileStore.Test(): TestInspectionState
	return {
		ActiveSessionCheck = activeSessionCheck,
		AutoSaveList = autoSaveList,
		ActiveProfileLoadJobs = activeProfileLoadJobs,
		ActiveProfileSaveJobs = activeProfileSaveJobs,
		AutoMockStore = autoMockStore,
		UserMockStore = userMockStore,
		UpdateQueue = updateQueue,
		IssueQueue = issueQueue,
	}
end

--[[
	Loads a profile with cross-server session locking to guarantee single-server ownership.
]]
function ProfileStore.LoadProfileAsync<T>(
	self: ProfileStore<T>,
	key: string,
	params: Types.LoadProfileParams?
): Promise.Promise<Profile.Profile<T>>
	return self:_loadProfileInternal(key, params, false)
end

--[[
	Reads a view-mode snapshot of a profile (or historical version) without starting a session.
	Resolves with `nil` if no data is saved under the key, or rejects on DataStore failure.
]]
function ProfileStore.GetAsync<T>(
	self: ProfileStore<T>,
	key: string,
	version: string?
): Promise.Promise<Profile.Profile<T>?>
	return self:_getAsyncInternal(key, version, false)
end

--[[
	Permanently deletes a profile from the DataStore (or mock DataStore).
]]
function ProfileStore.RemoveAsync<T>(self: ProfileStore<T>, key: string): Promise.Promise<boolean>
	return self:_removeAsyncInternal(key, false)
end

--[[
	Sends a message table to a profile's GlobalUpdates queue for cross-server or offline delivery.
]]
function ProfileStore.MessageAsync<T>(
	self: ProfileStore<T>,
	key: string,
	message: { [any]: any }
): Promise.Promise<boolean>
	return messageAsyncInternal(self, key, message, false)
end

--[[
	Creates an iterator for querying historical DataStore versions of a profile key.
]]
function ProfileStore.VersionQuery<T>(
	self: ProfileStore<T>,
	key: string,
	sortDirection: Enum.SortDirection?,
	minDate: DateTime | number | nil,
	maxDate: DateTime | number | nil
): Versioning.VersionQuery<T>
	return versionQueryInternal(self, key, sortDirection, minDate, maxDate, false)
end

--------------------------------------------------------------------------------
-- Global Lifecycle Management
--------------------------------------------------------------------------------

local function onHeartbeat()
	-- 1. Circular auto-save rotation
	const autoSaveCount = #autoSaveList
	if autoSaveCount > 0 then
		const autoSaveInterval = Constants.AUTO_SAVE_PERIOD / autoSaveCount
		const clock = os.clock()

		while clock - lastAutoSave > autoSaveInterval do
			lastAutoSave += autoSaveInterval
			local profileToSave: Profile.Profile<any>? = autoSaveList[autoSaveIndex]

			if profileToSave and clock - profileToSave._loadTimestamp < Constants.AUTO_SAVE_PERIOD / 2 then
				profileToSave = nil
				for _ = 1, autoSaveCount - 1 do
					autoSaveIndex += 1
					if autoSaveIndex > autoSaveCount then
						autoSaveIndex = 1
					end
					const candidate = autoSaveList[autoSaveIndex]
					if candidate and clock - candidate._loadTimestamp >= Constants.AUTO_SAVE_PERIOD / 2 then
						profileToSave = candidate
						break
					end
				end
			end

			autoSaveIndex += 1
			if autoSaveIndex > autoSaveCount then
				autoSaveIndex = 1
			end

			if profileToSave and profileToSave:IsActive() then
				if DEBUG_MODE then
					print(`[ProfileStore]: Auto-saving profile for key '{profileToSave.Key}'.`)
				end
				profileToSave.ProfileStore:_saveProfileInternal(profileToSave, false)
			end
		end
	end

	-- 2. Issue expiration cleanup (prune expired issues before evaluating critical state)
	const now = os.clock()
	while true do
		const oldestIssueTime = issueQueue[1]
		if oldestIssueTime == nil then
			break
		end
		if now - oldestIssueTime > Constants.CRITICAL_STATE_ERROR_EXPIRE then
			table.remove(issueQueue, 1)
		else
			break
		end
	end

	-- 3. Critical state monitoring
	if not isCriticalState then
		if #issueQueue >= Constants.CRITICAL_STATE_ERROR_COUNT then
			isCriticalState = true
			criticalStateStart = now
			onCriticalToggle:Fire(true)
			warn("[ProfileStore]: Entered critical DataStore error state.")
		end
	else
		if #issueQueue >= Constants.CRITICAL_STATE_ERROR_COUNT then
			criticalStateStart = now
		elseif now - criticalStateStart > Constants.CRITICAL_STATE_EXPIRE then
			isCriticalState = false
			onCriticalToggle:Fire(false)
			warn("[ProfileStore]: Critical DataStore error state ended.")
		end
	end
end

local function onShutDown()
	if isClosing then
		return
	end
	isClosing = true

	if currentDataStoreState ~= DataStoreState.Access then
		-- Snapshot and release mock profiles quickly so Studio Play Solo stops promptly.
		const snapshot = table.clone(autoSaveList)
		for _, profile in snapshot do
			if profile:IsActive() then
				profile.ProfileStore:_releaseProfile(profile, "Shutdown")
			end
		end
		task.wait()
		return
	end

	if DEBUG_MODE then
		print("[ProfileStore]: Server is shutting down. Releasing all active profiles...")
	end

	-- Clone autoSaveList prior to iteration because _releaseProfile removes entries synchronously.
	const activeProfilesSnapshot = table.clone(autoSaveList)
	local releasePromises: { Promise.Promise<nil> } = {}

	for _, profile in activeProfilesSnapshot do
		if profile:IsActive() then
			table.insert(releasePromises, profile.ProfileStore:_releaseProfile(profile, "Shutdown"))
		end
	end

	if #releasePromises > 0 then
		local allSettled = false
		Promise.all(releasePromises):finally(function()
			allSettled = true
		end)
		while not allSettled do
			task.wait()
		end
	end

	-- Also wait for any already-in-flight load or save jobs to settle cleanly.
	while activeProfileLoadJobs > 0 or activeProfileSaveJobs > 0 do
		task.wait()
	end

	if DEBUG_MODE then
		print("[ProfileStore]: All profiles saved and released. Server can now close.")
	end
end

--------------------------------------------------------------------------------
-- One-Time Module Initialization
--------------------------------------------------------------------------------

if isStudio then
	task.spawn(function()
		local resolvedState: Types.DataStoreState = DataStoreState.NoAccess

		const status, message = pcall(function()
			DataStoreService:GetDataStore(CONNECTIVITY_STORE_NAME):SetAsync(CONNECTIVITY_STORE_NAME, os.time())
		end)

		const messageText = if typeof(message) == "string" then message else tostring(message)
		const noInternet = not status and string.find(messageText, "ConnectFail", 1, true) ~= nil

		if noInternet then
			warn("[ProfileStore]: No internet access - check your network connection.")
		end

		if
			not status
			and (
				string.find(messageText, "403", 1, true) ~= nil
				or string.find(messageText, "must publish", 1, true) ~= nil
				or noInternet
			)
		then
			resolvedState = if noInternet then DataStoreState.NoInternet else DataStoreState.NoAccess
			print("[ProfileStore]: Roblox API services unavailable - data will use an in-memory mock store.")
		else
			resolvedState = DataStoreState.Access
			if DEBUG_MODE then
				print("[ProfileStore]: Roblox API services available - data will be saved.")
			end
		end

		currentDataStoreState = resolvedState
		stateChanged:Fire()
	end)
end

RunService.Heartbeat:Connect(onHeartbeat)
game:BindToClose(onShutDown)

local PublicModule = {
	ErrorKind = Types.ErrorKind,
	create = ProfileStore.create,
	SetConstant = ProfileStore.SetConstant,
	Test = ProfileStore.Test,
}

return (
	setmetatable(PublicModule, {
		__index = function(_, key: string): any
			if key == "IsClosing" then
				return isClosing
			end
			if key == "IsCriticalState" then
				return isCriticalState
			end
			if key == "DataStoreState" then
				return currentDataStoreState
			end
			if key == "OnError" then
				return onError
			end
			if key == "OnOverwrite" then
				return onOverwrite
			end
			if key == "OnCriticalToggle" then
				return onCriticalToggle
			end

			return (ProfileStore :: { [string]: any })[key]
		end,
		__newindex = function(_, key: string)
			error(`[ProfileStore]: Attempt to modify read-only property '{tostring(key)}'.`, 2)
		end,
	}) :: any
) :: ProfileStoreModule
