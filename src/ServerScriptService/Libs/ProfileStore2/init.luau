--!strict
--[[
    ProfileStore2
    @author DistractedGames
    @version 1.1.0

    Copyright 2025 Distracted Games

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
    This module acts as the "framework" or "manager" for creating and handling
    individual Profile objects.
    
    This is a lean, professional, and robust refactoring of ProfileStore.
    It focuses on the core functionality of providing safe, session-locked data persistence.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

local Constants = require(script.Constants)
local Profile = require(script.Profile)
local Promise = require(script.LeanPromise)
local PromiseError = require(script.LeanPromise.PromiseError)
local Signal = require(script.Signal)
local Util = require(script.Util)

-- The raw data structure stored in the DataStore.
type ProfileData<T> = {
	Data: T,
	MetaData: {
		ProfileCreateTime: number,
		SessionLoadCount: number,
		ActiveSession: { PlaceId: number, JobId: string, UniqueId: string }?,
		ForceLoadSession: { PlaceId: number, JobId: string }?,
		LastUpdate: number?,
	},
	GlobalUpdates: any?,
	UserIds: { number },
	RobloxMetaData: { [string]: any },
	WasOverwritten: boolean?,
}

-- The generic <T> represents the developer's custom data template.
type ClassType<T> = {
	-- Public Properties
	Name: string,
	Mock: ProfileStore<T>,

	-- Internal Properties
	_template: T,
	_dataStore: DataStore,
	_isReady: boolean,

	-- Public Methods
	create: (storeName: string, template: T?) -> Promise.Promise<ProfileStore<T>>,
	LoadProfileAsync: (
		self: ProfileStore<T>,
		key: string,
		paramas: { Steal: boolean?, Cancel: () -> boolean? }?
	) -> Promise.Promise<Profile.Profile<T>>,
	GetAsync: (self: ProfileStore<T>, key: string, version: string?) -> Promise.Promise<Profile.Profile<T>?>,
	RemoveAsync: (self: ProfileStore<T>, key: string) -> Promise.Promise<boolean>,

	-- Private Methods
	_updateAsync: (
		self: ProfileStore<T>,
		key: string,
		transform: (latestData: ProfileData<T>?) -> (ProfileData<T>?, { number }?, { [string]: any }?),
		isMock: boolean
	) -> (ProfileData<T>?, DataStoreKeyInfo?),
	_releaseProfile: (self: ProfileStore<T>, profile: Profile.Profile<T>, reason: string) -> (),
	_saveProfile: (self: ProfileStore<T>, profile: Profile.Profile<T>) -> (),
	_waitForStoreReady: (self: ProfileStore<T>) -> (),
}

local ProfileStore = {}
ProfileStore.__index = ProfileStore

-- The generic <T> represents the developer's custom data template.
export type ProfileStore<T> = setmetatable<ClassType<T>, typeof(ProfileStore)>

local DEBUG_MODE = false -- If true, debug print statements run

-- Global State
local ActiveSessionCheck: { [string]: Profile.Profile<any> } = {}
local AutoSaveList: { Profile.Profile<any> } = {}
local ReleasingProfiles: { [string]: Profile.Profile<any> } = {}
local AutoSaveIndex = 1
local IsClosing = false
local IsCriticalState = false
local JobId = game.JobId
local LastAutoSave = 0
local MockFlag = false
local PlaceId = game.PlaceId
local UpdateQueue: { [string]: { thread } } = {}
local UserMockStore = {}

-- Global Signals
local OnError = Signal.new()
local OnOverwrite = Signal.new()
local OnCriticalToggle = Signal.new()
local StateChanged = Signal.new()

-- DataStore Connectivity State
local DataStoreState = {
	NotReady = "NotReady",
	NoInternet = "NoInternet",
	NoAccess = "NoAccess", -- API Access Disabled in Studio
	Access = "Access",
}
local currentDataStoreState = DataStoreState.NotReady

--------------------------------------------------------------------------------
-- Private Helper Functions
--------------------------------------------------------------------------------

--[[
    Ensures that only one operation (Update, Remove, etc.) runs at a time for any given profile key.
    This prevents race conditions. It returns a function that MUST be called to release the lock.
]]
local function waitForUpdateQueue(sessionToken: string): () -> ()
	local queue = UpdateQueue[sessionToken]
	if not queue then
		queue = {}
		UpdateQueue[sessionToken] = queue

		return function()
			local nextThread = table.remove(queue :: any, 1)
			if nextThread then
				task.spawn(coroutine.resume, nextThread)
			else
				UpdateQueue[sessionToken] = nil
			end
		end
	end

	table.insert(queue, coroutine.running())
	coroutine.yield()

	return function()
		local nextThread = table.remove(queue, 1)
		if nextThread then
			task.spawn(coroutine.resume, nextThread)
		else
			UpdateQueue[sessionToken] = nil
		end
	end
end

--[[
    Reads the global MockFlag and immediately resets it. This ensures that only
    the very next operation is mocked.
]]
local function readMockFlag(): boolean
	local isMock = MockFlag
	MockFlag = false
	return isMock
end

--[[
    Generates a unique string identifier for a profile's session on the current server.
]]
local function generateSessionToken(storeName: string, profileKey: string, isUserMock: boolean): string
	-- Differentiate between a user-intitiated mock and an automatic mock due to no API access.
	local prefix: string
	if isUserMock then
		prefix = "U_" -- User Mock
	elseif currentDataStoreState ~= DataStoreState.Access then
		prefix = "M_" -- Automatic Mock
	else
		prefix = "L_" -- Live
	end
	return `{prefix}{storeName}_{profileKey}`
end

--[[
    Simulates a DataStore UpdateAsync call using an in-memory table.
]]
local function mockUpdateAsync<T>(
	mockDataStore: { [string]: { [string]: any } },
	storeName: string,
	key: string,
	transform: (
		latestData: ProfileData<T>?
	) -> (ProfileData<T>?, { number }?, { [string]: any }?)
): (ProfileData<T>?, DataStoreKeyInfo?)
	local profileStore = mockDataStore[storeName]
	if not profileStore then
		profileStore = {}
		mockDataStore[storeName] = profileStore
	end

	local mockEntry = profileStore[key]
	local transformedData = transform(mockEntry)

	if transformedData then
		profileStore[key] = Util.DeepCopyTable(transformedData)

		-- Create a mock DataStoreKeyInfo object.
		local keyInfo = {
			CreatedTime = os.time(),
			UpdatedTime = os.time(),
			Version = "MOCK_VERSION",
			GetMetaData = function()
				return {}
			end,
			GetUserIds = function()
				return {}
			end,
		} :: any
		return transformedData, keyInfo
	end

	return nil, nil
end

--[[
    The unified internal saving logic for a profile.
    Handles session lock verification and updating the DataStore.
]]
local function _internalSaveAsync(
	self: ProfileStore<any>,
	profile: Profile.Profile<any>,
	isRelease: boolean,
	reason: string?
)
	profile.OnSave:Fire()
	if isRelease then
		profile.OnLastSave:Fire(reason or "Manual")
	end

	local function transformFunction(latestData: ProfileData<any>?): any
		if not latestData then
			return nil
		end

		local activeSession = latestData.MetaData.ActiveSession
		local sessionLoadCount = latestData.MetaData.SessionLoadCount

		-- SECURITY: Only write data if this server's session lock is still valid.
		if
			activeSession
			and activeSession.PlaceId == PlaceId
			and activeSession.JobId == JobId
			and sessionLoadCount == profile._loadIndex
		then
			latestData.Data = profile.Data
			latestData.RobloxMetaData = profile.RobloxMetaData
			latestData.UserIds = profile.UserIds
			latestData.MetaData.LastUpdate = os.time()

			if isRelease then
				latestData.MetaData.ActiveSession = nil
			end
		end

		return latestData, latestData.UserIds, latestData.RobloxMetaData
	end

	ReleasingProfiles[profile._sessionToken] = profile

	task.spawn(function()
		local loadedData, keyInfo = self:_updateAsync(profile.Key, transformFunction, profile._isMock)

		if loadedData and keyInfo then
			profile.LastSavedData = Util.DeepCopyTable(loadedData.Data)
			profile.KeyInfo = keyInfo
			profile.OnAfterSave:Fire(profile.LastSavedData)

			-- TODO: Handle GlobalUpdates (mesaging) logiv from original SaveProfileAsync
		end

		if isRelease then
			ReleasingProfiles[profile._sessionToken] = nil
			profile.OnSessionEnd:Fire()
		end
	end)
end

--[[
    Adds a profile to the auto-save list and updates the global index.
    This is called when a profile session successfully starts.
]]
local function addProfileToAutoSave(profile: Profile.Profile<any>)
	ActiveSessionCheck[profile._sessionToken] = profile

	-- Insert at the current index to ensure fair rotation.
	table.insert(AutoSaveList, AutoSaveIndex, profile)

	if #AutoSaveList > 1 then
		AutoSaveIndex += 1
	elseif #AutoSaveList == 1 then
		-- If this is the first profile, reset the timer to prevent an immediate save.
		LastAutoSave = os.clock()
	end
end

--[[
    Removes a profile from the auto-save list and correctly adjusts the index.
    This is called when a profile session ends.
]]
local function removeProfileFromAutoSave(profile: Profile.Profile<any>)
	if ActiveSessionCheck[profile._sessionToken] == profile then
		ActiveSessionCheck[profile._sessionToken] = nil
	end

	local indexInList = table.find(AutoSaveList, profile)
	if indexInList then
		table.remove(AutoSaveList, indexInList)
		-- If we removed an item that was before the current index, we must
		-- shift the index back to avoid skipping the next profile in the list.
		if indexInList < AutoSaveIndex then
			AutoSaveIndex -= 1
		end
		-- If the index is now out of bounds, wrap is around.
		if AutoSaveIndex > #AutoSaveList then
			AutoSaveIndex = 1
		end
	end
end

--[[
    Contains the transformation logic used for the transform callback function
    that gets passed to UpdateAsync.
]]
local function transformProfileDataForLoad<T>(
	self: ProfileStore<T>,
	latestData: ProfileData<T>?,
	uniqueSessionId: string,
	options: { Steal: boolean?, Cancel: () -> boolean? }?
): (ProfileData<T>, { number }?, { [string]: any }?)
	-- Case 1: Handle a completely new profile.
	if not latestData then
		local newData: ProfileData<any> = {
			Data = Util.DeepCopyTable(self._template),
			MetaData = {
				ProfileCreateTime = os.time(),
				SessionLoadCount = 1,
				LastUpdate = os.time(),
				ActiveSession = { PlaceId = PlaceId, JobId = JobId, UniqueId = uniqueSessionId },
			},
			UserIds = {},
			RobloxMetaData = {},
		}
		return newData, newData.UserIds, newData.RobloxMetaData
	end

	-- Case 2: Handle an existing profile that is not session-locked.
	local activeSession = latestData.MetaData.ActiveSession
	if not activeSession then
		-- No active session, we're free to claim it.
		latestData.MetaData.ActiveSession = { PlaceId = PlaceId, JobId = JobId, UniqueId = uniqueSessionId }
		latestData.MetaData.SessionLoadCount += 1
		latestData.MetaData.LastUpdate = os.time()
		latestData.MetaData.ForceLoadSession = nil -- Clear any old requests
		return latestData, latestData.UserIds, latestData.RobloxMetaData
	end

	-- Case 3:  Handle a session conflict.
	local isOurSession = activeSession.PlaceId == PlaceId and activeSession.JobId == JobId
	if isOurSession then
		-- This is an unexpected state, but we can assume we have control.
		latestData.MetaData.ForceLoadSession = nil
		return latestData, latestData.UserIds, latestData.RobloxMetaData
	end

	-- Case 4: Handle a stale or developer-forced session steal.
	local isStale = (os.time() - latestData.MetaData.LastUpdate :: number) > Constants.ASSUME_DEAD
	if (options and options.Steal) or isStale then
		-- Forcefully take the session.
		latestData.MetaData.ActiveSession = { PlaceId = PlaceId, JobId = JobId, UniqueId = uniqueSessionId }
		latestData.MetaData.SessionLoadCount += 1
		latestData.MetaData.LastUpdate = os.time()
		latestData.MetaData.ForceLoadSession = nil
		return latestData, latestData.UserIds, latestData.RobloxMetaData
	end

	-- Case 5: Session is active and not stale. We must wait and ask the other server to release.
	latestData.MetaData.ForceLoadSession = { PlaceId = PlaceId, JobId = JobId }
	return latestData, latestData.UserIds, latestData.RobloxMetaData
end

--[[
    The private class constructor. It synchronously creates a ProfileStore instance.
    Initialization of the DataStore connection happens asynchronously.
]]
local function new<T>(storeName: string, template: T?): ProfileStore<T>
	if typeof(storeName) ~= "string" or #storeName == 0 or #storeName > 50 then
		error(`[ProfileStore]: Invalid 'storeName' provided. It must be a string between 1 and 50 characters.`, 2)
	end
	local profileTemplate = template or {}
	if typeof(profileTemplate) ~= "table" then
		error(`[ProfileStore]: invalid 'template' provided. It must be a table.`, 2)
	end

	local self = setmetatable({}, ProfileStore) :: ProfileStore<T>
	self.Name = storeName
	self._template = Util.DeepCopyTable(profileTemplate :: any)
	self._isReady = false -- A store is NEVER ready immediately after creation.

	local mock: any = {}
	mock.Name = storeName
	mock.LoadProfileAsync = function(_, key, params)
		MockFlag = true
		return self:LoadProfileAsync(key, params)
	end
	mock.GetAsync = function(_, key, version)
		MockFlag = true
		return self:GetAsync(key, version)
	end
	mock.RemoveAsync = function(_, key)
		MockFlag = true
		return self:RemoveAsync(key)
	end
	self.Mock = mock

	-- This function is only called when the DataStore connection is confirmed.
	local function initializeStore()
		if currentDataStoreState == DataStoreState.Access then
			self._dataStore = DataStoreService:GetDataStore(storeName)
			self._isReady = true
		end
	end

	-- If the connection is already confirmed, initialize immediately.
	if currentDataStoreState == DataStoreState.Access then
		initializeStore()
	else
		-- Otherwise, this store will initialize itself once the global state
		-- changes to "Access".
		StateChanged:Connect(initializeStore)
	end

	return self
end

--------------------------------------------------------------------------------
-- Private Methods
--------------------------------------------------------------------------------

--[[
    A private yielding method that waits until the store instance has a live
    connection to the DataStore service.
]]
function ProfileStore._waitForStoreReady(self: ProfileStore<any>)
	while not self._isReady do
		task.wait()
	end
end

--[[
    The private, core wrapper around DataStore:UpdateAsync. It handles request queuing,
    readiness checks, mocking, pcalling the API, and firing global error/overwrite signals.
]]
function ProfileStore._updateAsync<T>(
	self: ProfileStore<T>,
	key: string,
	transform: (
		latestData: ProfileData<T>?
	) -> (ProfileData<T>?, { number }?, { [string]: any }?),
	isMock: boolean
): (ProfileData<T>?, DataStoreKeyInfo?)
	self:_waitForStoreReady()

	local sessionToken = generateSessionToken(self.Name, key, isMock)
	local releaseQueue = waitForUpdateQueue(sessionToken)

	local success, result = pcall(function(): any
		if isMock then
			return { mockUpdateAsync(UserMockStore, self.Name, key, transform) }
		else
			return { self._dataStore:UpdateAsync(key, transform) }
		end
	end)

	releaseQueue()

	if not success then
		warn(`[ProfileStore]: UpdateAsync failed for key '{key}': {tostring(result)}`)
		OnError:Fire(tostring(result), self.Name, key)
		return nil, nil
	end

	local loadedData, keyInfo = table.unpack(result)

	if typeof(loadedData) == "table" and loadedData.WasOverwritten then
		OnOverwrite:Fire(self.Name, key)
	end

	return loadedData, keyInfo
end

--[[
    Called by Profile:Save().
    Performs a "live" save of the profile data without ending the session.
    This is typically used for auto-saving or manual checkpoints.
]]
function ProfileStore._saveProfile(self: ProfileStore<any>, profile: Profile.Profile<any>)
	if not profile:IsActive() then
		warn(`[ProfileStore]: Attempted to save an inactive profile (KEY: {profile.Key}).`)
		return
	end

	-- A manual save makes an immediate auto-save redundant. To delay the next
	-- auto-save for this profile, we effectively move it to the back of the queue.
	removeProfileFromAutoSave(profile)
	addProfileToAutoSave(profile)

	_internalSaveAsync(self, profile, false)
end

--[[
    Called by Profile:EndSession().
    Performs a final, definitive save of the profile data and releases the session
    lock, allowing another server to claim it.
]]
function ProfileStore._releaseProfile(self: ProfileStore<any>, profile: Profile.Profile<any>, _reason: string)
	local sessionToken = profile._sessionToken
	if ActiveSessionCheck[sessionToken] == profile then
		ActiveSessionCheck[sessionToken] = nil
	end

	removeProfileFromAutoSave(profile)

	_internalSaveAsync(self, profile, true)
end

--------------------------------------------------------------------------------
-- Public Methods
--------------------------------------------------------------------------------

--[[
    Creates and initializes a ProfileStore.
    @param storeName The name of the DataStore to connect to.
    @param template An optional template table for new profiles.
    @return A Promise that resolves with the ready-to-use ProfileStore, or rejects on failure.
]]
function ProfileStore.create<T>(storeName: string, template: T?): Promise.Promise<ProfileStore<T>>
	return Promise.new(function(resolve: (ProfileStore<T>) -> (), reject)
		local store = new(storeName, template)

		if currentDataStoreState == DataStoreState.Access then
			resolve(store)
			return
		end

		if currentDataStoreState == DataStoreState.NoAccess or currentDataStoreState == DataStoreState.NoInternet then
			reject(PromiseError.new({
				error = `Could not connect to DataStore service. State: {currentDataStoreState}`,
				kind = "ConnectivityError",
			}))
			return
		end

		local connection
		connection = StateChanged:Connect(function()
			-- Important: only listen once (`Once` not built into this version of Signal)
			if connection then
				connection:Disconnect()
			end
			if currentDataStoreState == DataStoreState.Access then
				resolve(store)
			else
				reject(PromiseError.new({
					error = `Could not connect to DataStore service. Final state: {currentDataStoreState}`,
					kind = "ConnectivityError",
				}))
			end
		end)
	end) :: Promise.Promise<ProfileStore<T>>
end

--[[
    Loads a player's profile, handling session locking to ensure data safety.
    @return A Promise that resolves with the Profile object or rejects if it fails or times out.
]]
function ProfileStore.LoadProfileAsync<T>(
	self: ProfileStore<T>,
	key: string,
	params: { Steal: boolean?, Cancel: () -> boolean? }?
): Promise.Promise<Profile.Profile<T>>
	self:_waitForStoreReady()

	if typeof(key) ~= "string" or #key == 0 or #key > 50 then
		error(`[ProfileStore]: Invalid 'key' provided to LoadProfileAsync.`, 2)
	end

	local options = params or {} :: any

	return Promise.new(
			function(resolve: (Profile.Profile<T>) -> (), reject, _onCancel)
				local startTime = os.clock()
				local uniqueSessionId = HttpService:GenerateGUID(false)
				local isMock = readMockFlag()
				local isSettled = false

				task.spawn(function()
					while not isSettled do
						-- Failsafe 1: Timeout
						if os.clock() - startTime > Constants.START_SESSION_TIMEOUT then
							isSettled = true
							reject(PromiseError.new({ error = "Timed out", kind = "TimedOut" }))
							break
						end

						-- Failsafe 2: User-provided cancellation
						if options.Cancel and options.Cancel() then
							isSettled = true
							reject(PromiseError.new({ error = "Cancelled by user", kind = "Cancelled" }))
							break
						end

						-- Execute the UpdateAsync call.
						local loadedData, keyInfo = self:_updateAsync(key, function(latestData)
							return transformProfileDataForLoad(self, latestData, uniqueSessionId, options)
						end, isMock)

						if loadedData == nil or keyInfo == nil then
							-- The UpdateAsync call failed. Wait and let the loop retry.
							task.wait(Constants.LOAD_REPEAT_PERIOD)
							continue
						end

						local activeSession = loadedData.MetaData.ActiveSession
						if activeSession and activeSession.PlaceId == PlaceId and activeSession.JobId == JobId then
							-- SUCCESS! We have secured the session lock.
							isSettled = true
							local sessionToken = generateSessionToken(self.Name, key, isMock)

							-- Explicit cast and check for the solver
							assert(loadedData, "loadedData cannot be nil here")
							local profile = Profile.new(loadedData, keyInfo, self :: any, key, isMock, sessionToken)
							addProfileToAutoSave(profile)
							profile:Reconcile() -- Fill in any new template data
							resolve(profile)
						else
							-- We did not get the session lock.
							if activeSession and typeof(activeSession.UniqueId) == "string" then
								task.spawn(
									MessagingService.PublishAsync,
									MessagingService,
									`PS_{activeSession.UniqueId}`,
									{
										LoadCount = loadedData.MetaData.SessionLoadCount,
										EndSession = true,
									}
								)
							end

							-- Wait and let the loop retry.
							task.wait(Constants.LOAD_REPEAT_PERIOD)
							continue
						end
					end
				end)
        end) :: Promise.Promise<Profile.Profile<T>>
end

--[[
    Gets a read-only snapshopt of a profile without starting a session.
    @param key The DataStore key of the profile to retrieve.
    @param version An optional version ID to retrieve a historical snapshot.
    @return A Promise that resolves with the view-mode Profile, or nil if not found.
]]
function ProfileStore.GetAsync<T>(
	self: ProfileStore<T>,
	key: string,
	version: string?
): Promise.Promise<Profile.Profile<T>?>
	self:_waitForStoreReady()

	if typeof(key) ~= "string" or #key == 0 or #key > 50 then
		error(`[ProfileStore]: Invalid 'key' provided to GetAsync.`, 2)
	end

	return Promise.new(function(resolve: (Profile.Profile<T>?) -> (), _reject)
		local isMock = readMockFlag()

		task.spawn(function()
			local rawData, keyInfo

			if isMock then
				-- For a simple get, the transform just returns the existing data.
				rawData, keyInfo = mockUpdateAsync(UserMockStore, self.Name, key, function(latestData)
					return latestData, nil, nil
				end)
			else
				local success, result = pcall(function()
					if version then
						return self._dataStore:GetVersionAsync(key, version)
					else
						return self._dataStore:GetAsync(key)
					end
				end)

				if not success then
					warn(`[ProfileStore]: GetAsync failed for key '{key}': {tostring(result)}`)
					OnError:Fire(tostring(result), self.Name, key)
					resolve(nil)
					return
				end
				rawData, keyInfo = table.unpack(result)
			end

			-- If the key was empty, there's no data or key info.
			if not rawData or not keyInfo then
				resolve(nil)
				return
			end

			-- Reconcile against the template to fill in any new default fields.
			Util.ReconcileTable((rawData :: any).Data, self._template :: any)

			local sessionToken = generateSessionToken(self.Name, key, isMock)
			local profile = Profile.new(rawData, keyInfo, self :: any, key, isMock, sessionToken)
			profile._viewMode = true -- CRITICAL: Flag this profile as read-only.
			resolve(profile)
		end)
	end) :: Promise.Promise<Profile.Profile<T>?>
end

--[[
    Completely remove a profile from the DataStore. This is irreversible.
    Used both for administrative data management and GDPR compliance.
]]
function ProfileStore.RemoveAsync<T>(self: ProfileStore<T>, key: string): Promise.Promise<boolean>
	self:_waitForStoreReady()

	if typeof(key) ~= "string" or #key == 0 then
		error(`[ProfileStore]: Invalid 'key' provided to RemoveAsync.`, 2)
	end

	return Promise.new(function(resolve: (boolean) -> (), _reject)
		local isMock = readMockFlag()
		local sessionToken = generateSessionToken(self.Name, key, isMock)

		task.spawn(function()
			-- Wait for our turn to access this profile key to prevent race conditions.
			local releaseQueue = waitForUpdateQueue(sessionToken)

			local success, removeSucceeded = pcall(function()
				if isMock then
					local mockStore = UserMockStore[self.Name]
					if mockStore then
						mockStore[key] = nil
					end
					return true
				else
					local ok, err = pcall(function()
						self._dataStore:RemoveAsync(key)
						return true
					end)
					if not ok then
						error(err) -- Re-throw the error to be cuaght by the other pcall
					end
					return ok
				end
			end)

			releaseQueue()

			if not success then
				warn(`[ProfileStore]: RemoveAsync failed for key '{key}': {tostring(removeSucceeded)}`)
				OnError:Fire(tostring(removeSucceeded), self.Name, key)
				resolve(false)
			else
				if DEBUG_MODE then
					print(`[ProfileStore]: Successfully removed profile for key '{key}'`)
				end
				resolve(true)
			end
		end)
	end) :: Promise.Promise<boolean>
end

--------------------------------------------------------------------------------
-- Global Lifecycle Management
--------------------------------------------------------------------------------

--[[
    This is the main update loop, dirven by Heartbeat. It handles auto-saving
    and checking for critical state issues.
]]
local function onHeartbeat()
	-- Auto-saving
	local autoSaveCount = #AutoSaveList
	if autoSaveCount > 0 then
		local interval = Constants.AUTO_SAVE_PERIOD / autoSaveCount
		local clock = os.clock()

		if clock - LastAutoSave > interval then
			LastAutoSave = clock
			local profileToSave = AutoSaveList[AutoSaveIndex]

			if clock - profileToSave._loadTimestamp < Constants.AUTO_SAVE_PERIOD / 2 then
				local initialIndex = AutoSaveIndex
				repeat
					AutoSaveIndex = (AutoSaveIndex % autoSaveCount) + 1
					profileToSave = AutoSaveList[AutoSaveIndex]
				until clock - profileToSave._loadTimestamp >= Constants.AUTO_SAVE_PERIOD / 2
					or AutoSaveIndex == initialIndex
			end

			if profileToSave and clock - profileToSave._loadTimestamp >= Constants.AUTO_SAVE_PERIOD / 2 then
				if DEBUG_MODE then
					print(`[ProfileStore]: Auto-saving profile for key '{profileToSave.Key}'`)
				end
				task.spawn(profileToSave.Save, profileToSave)
			end

			AutoSaveIndex = (AutoSaveIndex % autoSaveCount) + 1
		end
	end

	-- Critical state handling
	-- TODO: A full refactor should likely include the critical state logic here.
	-- For this lean version, we are omitting this advanced feature for now.
end

--[[
    This function handles the final, guaranteed save for all active profiles during server shutdown.
]]
local function onShutDown()
	if IsClosing then
		return
	end
	IsClosing = true

	if #AutoSaveList == 0 and next(ReleasingProfiles) == nil then
		return -- No profiles to save.
	end

	if DEBUG_MODE then
		print("[ProfileStore]: Server is shutting down. Saving all active profiles...")
	end

	-- Using Signal to block the BindToClose thread until all asyn saves are complete.
	local shutdownSignal = Signal.new()

	-- Create a promise that resolves only when all profiles are saved.
	local allSavedPromise = Promise.new(function(resolve)
		local profilesRemaining = #AutoSaveList
		for _ in pairs(ReleasingProfiles) do
			profilesRemaining += 1
		end

		if profilesRemaining == 0 then
			resolve()
			return
		end

		for _, profile in ipairs(AutoSaveList) do
			if profile:IsActive() then
				-- We hook into the profile's own signal to know when its final save is complete.
				profile.OnSessionEnd:Connect(function()
					profilesRemaining -= 1
					if profilesRemaining == 0 then
						resolve()
					end
				end)
				-- EndSession triggers the final save and cleanup.
				profile:EndSession()
			else
				profilesRemaining -= 1
			end
		end

		-- Also wait for profiles that are ALREADY in the process of being released.
		for _, profile in pairs(ReleasingProfiles) do
			profile.OnSessionEnd:Connect(function()
				profilesRemaining -= 1
				if profilesRemaining == 0 then
					resolve()
				end
			end)
		end

		if profilesRemaining == 0 then
			resolve()
		end
	end)

	-- When the promise chain is fully settled (success or failure), fire the signal.
	allSavedPromise:finally(function()
		shutdownSignal:Fire()
	end)

	-- Yield the BindToClose thread until the signal is fired.
	shutdownSignal:Wait()

	if DEBUG_MODE then
		print("[ProfileStore]: All profiles saved. Server can now close.")
	end
end

--------------------------------------------------------------------------------
-- One-Time Module Initialization
--------------------------------------------------------------------------------
task.spawn(function()
	if currentDataStoreState ~= DataStoreState.NotReady then
		return -- The check has already been performed.
	end

	local success, message = pcall(function()
		return DataStoreService:GetDataStore("____ProfileStoreConnectivityTest"):GetAsync("Connectivity")
	end)

	if success then
		currentDataStoreState = DataStoreState.Access
		if DEBUG_MODE then
			print("[ProfileStore]: Roblox API services are available.")
		end
	else
		if typeof(message) == "string" and (string.find(message, "403") or string.find(message, "must publish")) then
			currentDataStoreState = DataStoreState.NoAccess
			warn("[ProfileStore]: Roblox API services are unavailable. Is 'Enable Studio Access to API Services' enabled?")
		else
			currentDataStoreState = DataStoreState.NoInternet
			warn("[ProfileStore]: Could not connect to Roblox API services. Check your internet connection.")
		end
	end

	StateChanged:Fire()

	RunService.Heartbeat:Connect(onHeartbeat)
	game:BindToClose(onShutDown)
end)

local PublicModule = {}

PublicModule.create = ProfileStore.create

-- We use a metatable to provide live, read-only access to the global state
-- and to grant access to the ProfileStore's instance methods.
return setmetatable(PublicModule, {
	__index = function(_, key): any
		-- Allow reading global state properties
		if key == "IsClosing" then return IsClosing end
		if key == "IsCriticalState" then return IsCriticalState end
		if key == "DataStoreState" then return currentDataStoreState end
		if key == "OnError" then return OnError end
		if key == "OnOverwrite" then return OnOverwrite end
		if key == "OnCriticalToggle" then return OnCriticalToggle end

		-- Allow access to the methods on the ProfileStore class table
		return ProfileStore[key]
	end,
	__newindex = function(_, key, _value)
		error(`[ProfileStore]: Attempt to modify a read-only property '{key}'.`, 2)
	end,
})
