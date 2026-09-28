--!strict
--[[
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
    Represents a single player's data profile.
    This class is the component that holds the player's data, amages its state,
    and provides methods for interaction.
]]

local Promise = require(script.Parent.LeanPromise)
local Signal = require(script.Parent.Signal)
local Util = require(script.Parent.Util)

-- Declaring ProfileStore types to avoid circular dependencies.
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
type ProfileStore<T> = {
	-- Public Properties
	Name: string,
	Mock: any, -- Typed as any to avoid recursive dependency loop

	-- Internal Properties
	_template: T,

	-- Public Methods
	create: (storeName: string, template: T?) -> Promise.Promise<any>, -- Returns ProfileStore<T>
	LoadProfileAsync: (
		self: ProfileStore<T>,
		key: string,
		paramas: { Steal: boolean?, Cancel: () -> boolean? }?
	) -> Promise.Promise<any>, -- Returns Profile<T>
	GetAsync: (self: ProfileStore<T>, key: string, version: string?) -> Promise.Promise<any>, -- Returns Profile<T>?
	RemoveAsync: (self: ProfileStore<T>, key: string) -> Promise.Promise<boolean>,

	-- Private Methods
	_releaseProfile: (self: ProfileStore<T>, profile: any, reason: string) -> (),
	_saveProfile: (self: ProfileStore<T>, profile: any) -> (),

	[any]: any,
}

-- The generic <T> represents the developer's custom data structure (e.g., PlayerProfile)
type ClassType<T> = {
	-- Public, Read-Only Data
	Data: T,
	LastSavedData: T,
	FirstSessionTime: number,
	SessionLoadCount: number,
	Session: { PlaceId: number, JobId: string }?,
	UserIds: { number },
	KeyInfo: DataStoreKeyInfo,
	Key: string,
	ProfileStore: ProfileStore<T>,

	-- Writable Data
	RobloxMetaData: { [string]: any },

	-- Public Signals
	OnSave: Signal.Signal<>,
	OnLastSave: Signal.Signal<>, -- "Manual" | "External" | "Shutdown"
	OnSessionEnd: Signal.Signal<>,
	OnAfterSave: Signal.Signal<>,

	-- Internal State (for class methods)
	_loadTimestamp: number,
	_isMock: boolean,
	_sessionToken: string,
	_loadIndex: number,
	_lockedGlobalUpdates: { [string]: boolean },
	_receivedGlobalUpdates: { [string]: boolean },
	_messageHandlers: { (message: any, processed: () -> ()) -> () },
	_globalUpdates: { { any } },
	_robloxMessageSubscription: { Disconnect: () -> () }?,
	_viewMode: boolean,
	_isActive: boolean,

	-- Public Methods
	IsActive: (self: Profile<T>) -> boolean,
	Reconcile: (self: Profile<T>) -> (),
	EndSession: (self: Profile<T>) -> (),
	AddUserId: (self: Profile<T>, userId: number) -> (),
	RemoveUserId: (self: Profile<T>, userId: number) -> (),
	MessageHandler: (self: Profile<T>, fn: (message: any, processed: () -> ()) -> ()) -> (),
	Save: (self: Profile<T>) -> (),
	SetAsync: (self: Profile<T>) -> (),
	new: (
		rawDataTable: ProfileData<T>,
		keyInfo: DataStoreKeyInfo,
		profileStore: ProfileStore<T>,
		key: string,
		isMock: boolean,
		sessionToken: string
	) -> Profile<T>,
}

local Profile = {}
Profile.__index = Profile

-- The generic <T> represents the developer's custom data structure (e.g., PlayerProfile)
export type Profile<T> = setmetatable<ClassType<T>, typeof(Profile)>

function Profile.new<T>(
	rawDataTable: ProfileData<T>,
	keyInfo: DataStoreKeyInfo,
	profileStore: ProfileStore<T>,
	key: string,
	isMock: boolean,
	sessionToken: string
): Profile<T>
	-- Ensure rawDataTable and its MetaData are tables to prevent errors.
	local rawData = rawDataTable
		or {} :: { Data: T?, MetaData: any?, GlobalUpdates: any?, RobloxMetaData: any?, UserIds: any? }
	local metaData = (typeof(rawData.MetaData) == "table" and rawData.MetaData) or {}

	-- Extract session information.
	local session = metaData.ActiveSession
	local sessionInfo = if typeof(session) == "table"
		then { PlaceId = session.PlaceId :: number, JobId = session.JobId :: string }
		else nil

	-- Process global updates (messages) to track what has been received.
	local globalUpdates: { any } = if typeof(rawData.GlobalUpdates) == "table" then rawData.GlobalUpdates[2] else {}
	local receivedGlobalUpdates = {}
	for _, update in ipairs(globalUpdates) do
		receivedGlobalUpdates[update[1]] = true
	end

	local self = setmetatable({}, Profile) :: Profile<T>

	-- Public Data
	self.Data = rawData.Data or {} :: any
	self.LastSavedData = Util.DeepCopyTable(self.Data)
	self.FirstSessionTime = metaData.ProfileCreateTime or 0
	self.SessionLoadCount = metaData.SessionLoadCount or 0
	self.Session = sessionInfo
	self.RobloxMetaData = rawData.RobloxMetaData or {}
	self.UserIds = rawData.UserIds or {}
	self.KeyInfo = keyInfo
	self.Key = key
	self.ProfileStore = profileStore

	-- Public Signals
	self.OnSave = Signal.new()
	self.OnLastSave = Signal.new()
	self.OnSessionEnd = Signal.new()
	self.OnAfterSave = Signal.new()

	-- Internal State
	self._loadTimestamp = os.clock()
	self._isMock = isMock
	self._sessionToken = sessionToken
	self._loadIndex = metaData.SessionLoadCount or 0
	self._lockedGlobalUpdates = {}
	self._receivedGlobalUpdates = receivedGlobalUpdates
	self._messageHandlers = {}
	self._globalUpdates = globalUpdates
	self._viewMode = false
	self._isActive = true

	return self
end

--[[
    Returns true if the profile session is currently active on this server.
    This guarantee is only valid until code yields.
]]
function Profile.IsActive(self: Profile<any>): boolean
	-- The ProfileStore manager is responsible for updating this flag.
	-- This is much cleaner than checking a global table.
	return self._isActive
end

--[[
    Fills in missing (nil) fields in Profile.Data from the template table that
    was provided to the parent ProfileStore.
]]
function Profile.Reconcile(self: Profile<any>)
	-- We delegate the actual reconciliation logic to the Util module.
	-- The profile correctly gets the template from its parent store.
	local profileStore = self.ProfileStore
	if profileStore and profileStore._template :: any then
		Util.ReconcileTable(self.Data, profileStore._template)
	end
end

--[[
    Ends the session for this profile, triggering the final save.
    The Profile object will become inactive after this is called.
]]
function Profile.EndSession(self: Profile<any>)
	if not self._isActive then
		return
	end

	self._isActive = false

	-- This call tells the store to perform the final save and cleanup.
	local profileStore = self.ProfileStore
	if profileStore and profileStore._releaseProfile :: any then
		-- The "Manual" reason is passed for when the developer explicitely ends the session.
		profileStore:_releaseProfile(self, "Manual")
	end
end

--[[
    Associates a UserId with the profile for GDPR compliance.
]]
function Profile.AddUserId(self: Profile<any>, userId: number)
	-- Input Validation: Ensure the userId is a valid integer.
	if typeof(userId) ~= "number" or userId % 1 ~= 0 then
		warn(`[ProfileStore]: Invalid UserId provided to :AddUserId() ({tostring(userId)})`)
		return
	end

	-- Avoid sending negative UserIds to live APIs.
	-- This check is sufficient as `_isMock` covers all non-live scenarios.
	if userId < 0 and not self._isMock then
		return
	end

	if not table.find(self.UserIds, userId) then
		table.insert(self.UserIds, userId)
	end
end

--[[
    Removes a UserId association from the profile.
]]
function Profile.RemoveUserId(self: Profile<any>, userId: number)
	-- Input Validation: Ensure the userId is a valid integer.
	if typeof(userId) ~= "number" or userId % 1 ~= 0 then
		warn(`[ProfileStore]: Invalid UserId provided to :AddUserId() ({tostring(userId)})`)
		return
	end

	local index = table.find(self.UserIds, userId)
	if index then
		table.remove(self.UserIds, index)
	end
end

--[[
    Sets a handler function for processing incoming messages (GlobalUpdates).
    The handler is immediately called for any existing, unprocessed messages.
]]
function Profile.MessageHandler(self: Profile<any>, handler: (message: any, processed: () -> ()) -> ())
	if typeof(handler) ~= "function" then
		error(`[ProfileStore]: Argument to :MessageHandler() must be a function. Got {typeof(handler)}`, 2)
	end

	-- Don't process messages if the profile session is inactive or in view mode.
	if self._viewMode or not self:IsActive() then
		return
	end

	table.insert(self._messageHandlers, handler)

	-- Immediately process any existing messages with the new handler.
	for _, update in ipairs(self._globalUpdates) do
		local updateId = update[1]
		local messageData = update[#update] -- Backwards compatibility with original ProfileService

		-- Check if this message has already been locked by a previous handler.
		if not self._lockedGlobalUpdates[updateId] then
			-- The 'processed' callback is a closure that allows the handler to
			-- signal when it's done, locking the message from being processed again.
			local function processedCallback()
				self._lockedGlobalUpdates[updateId] = true
			end

			-- We provide a deep copy of the message data to prevent one handler
			-- from modifying the table that another handler will receive (data isolation).
			local messageCopy = Util.DeepCopyTable(messageData)

			-- Run the handler in a new thread to prevent one failing handler
			-- from stopping all other.
			task.spawn(handler, messageCopy, processedCallback)
		end
	end
end

--[[
    Immediately saves the profile's current Data to the DataStore if the session is active.
    This is an expensive call; use it sparingly.
]]
function Profile.Save(self: Profile<any>)
	-- A "view mode" profile is read-only and cannot be saved with this model.
	if self._viewMode then
		error("[ProfileStore]: :Save() cannot be used in view mode. Use :SetAsync() intead.", 2)
	end

	-- Prevent saving if the session has already been ended elsewhere.
	if not self:IsActive() then
		warn(`[ProfileStore]: Attempted to save an inactive profile (KEY: {self.Key}).`, 2)
		return
	end

	-- Delegate the actual saving logic to the ProfileStore manager.
	self.ProfileStore:_saveProfile(self)
end

--[[
    Forcefully saves the profile's current Data to the DataStore.
    This method is ONLY for profiles loaded in "view mode" via GetAsync or VersionQuery.
]]
function Profile.SetAsync(self: Profile<any>)
	if not self._viewMode then
		error("[ProfileStore]: :SetAsync() can only be used in view mode.", 2)
	end

	-- TODO: This method also delegates to the ProfileStore manager, but it will
	-- use a different internal function that bypasses session lock checks.
	-- For now, we can have it point to the same internal method, and we will
	-- build the specific logic for it when we refactor the ProfileStore class.
	self.ProfileStore:_saveProfile(self)
end

return Profile
