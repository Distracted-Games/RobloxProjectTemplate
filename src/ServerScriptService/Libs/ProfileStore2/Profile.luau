--!strict
--[[
	Represents a single player's data profile.
	This class holds the player's session-cached data, manages its lifecycle state,
	and provides methods for reconciliation, messaging, user association, and saving.
]]

const Promise = require("./LeanPromise")
const PromiseError = require("./LeanPromise/PromiseError")
const Signal = require("./Signal")
const Types = require("./Types")
const Util = require("./Util")

export type ProfileStoreOwner<T> = {
	Name: string,
	Mock: any,
	_template: T,
	_saveProfile: (self: any, profile: Profile<T>) -> Promise.Promise<T>,
	_releaseProfile: (self: any, profile: Profile<T>, reason: Types.LastSaveReason) -> Promise.Promise<nil>,
	_overwriteProfile: (self: any, profile: Profile<T>) -> Promise.Promise<nil>,
	[any]: any,
}

local function extractSessionInfo(session: any): Types.SessionInfo?
	if typeof(session) ~= "table" then
		return nil
	end

	if typeof(session.PlaceId) == "number" and typeof(session.JobId) == "string" then
		return {
			PlaceId = session.PlaceId,
			JobId = session.JobId,
		}
	end

	if typeof(session[1]) == "number" and typeof(session[2]) == "string" then
		return {
			PlaceId = session[1],
			JobId = session[2],
		}
	end

	return nil
end

local Profile = {}
Profile.__index = Profile

type ProfileClassData<T> = {
	-- Public Data
	Data: T,
	LastSavedData: T,
	FirstSessionTime: number,
	SessionLoadCount: number,
	Session: Types.SessionInfo?,
	RobloxMetaData: { [string]: any },
	UserIds: { number },
	KeyInfo: DataStoreKeyInfo,
	Key: string,
	ProfileStore: ProfileStoreOwner<T>,

	-- Public Signals
	OnSave: Signal.Signal<>,
	OnLastSave: Signal.Signal<Types.LastSaveReason>,
	OnSessionEnd: Signal.Signal<>,
	OnAfterSave: Signal.Signal<T>,

	-- Internal State
	_loadTimestamp: number,
	_isMock: boolean,
	_isAutoMock: boolean,
	_sessionToken: string,
	_loadIndex: number,
	_lockedGlobalUpdates: { [number]: boolean },
	_receivedGlobalUpdates: { [number]: boolean },
	_messageHandlers: { (message: any, processed: () -> ()) -> () },
	_globalUpdates: { Types.GlobalUpdateEntry },
	_robloxMessageSubscription: RBXScriptConnection?,
	_viewMode: boolean,
	_isActive: boolean,
	_releasePromise: Promise.Promise<nil>?,
}

export type Profile<T> = setmetatable<ProfileClassData<T>, typeof(Profile)>

function Profile.new<T>(
	rawDataTable: Types.ProfileData<T>,
	keyInfo: DataStoreKeyInfo,
	profileStore: ProfileStoreOwner<T>,
	key: string,
	isMock: boolean,
	isAutoMock: boolean,
	sessionToken: string,
	isViewMode: boolean?
): Profile<T>
	const rawData = if typeof(rawDataTable) == "table" then rawDataTable else ({} :: any) :: Types.ProfileData<T>
	const metaData = if typeof(rawData.MetaData) == "table"
		then rawData.MetaData
		else ({} :: any) :: Types.ProfileMetaData

	const sessionInfo = extractSessionInfo(metaData.ActiveSession)

	const globalUpdates: { Types.GlobalUpdateEntry } = if typeof(rawData.GlobalUpdates) == "table"
			and typeof(rawData.GlobalUpdates[2]) == "table"
		then rawData.GlobalUpdates[2]
		else {}

	local receivedGlobalUpdates: { [number]: boolean } = {}
	for _, update in globalUpdates do
		if typeof(update) == "table" and typeof(update[1]) == "number" then
			receivedGlobalUpdates[update[1]] = true
		end
	end

	const viewMode = isViewMode == true
	const initialData: T = if rawData.Data ~= nil then rawData.Data else {} :: any

	local self = setmetatable({}, Profile) :: Profile<T>

	-- Public Data
	self.Data = initialData
	self.LastSavedData = Util.DeepCopyTable(initialData)
	self.FirstSessionTime = metaData.ProfileCreateTime or 0
	self.SessionLoadCount = metaData.SessionLoadCount or 0
	self.Session = sessionInfo
	self.RobloxMetaData = if typeof(rawData.RobloxMetaData) == "table" then rawData.RobloxMetaData else {}
	self.UserIds = if typeof(rawData.UserIds) == "table" then rawData.UserIds else {}
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
	self._isAutoMock = isAutoMock
	self._sessionToken = sessionToken
	self._loadIndex = metaData.SessionLoadCount or 0
	self._lockedGlobalUpdates = {}
	self._receivedGlobalUpdates = receivedGlobalUpdates
	self._messageHandlers = {}
	self._globalUpdates = globalUpdates
	self._robloxMessageSubscription = nil
	self._viewMode = viewMode
	self._isActive = not viewMode
	self._releasePromise = nil

	return self
end

--[[
	Returns true if the profile session is currently active on this server.
	This guarantee is only valid until code yields.
]]
function Profile.IsActive(self: Profile<any>): boolean
	return self._isActive and not self._viewMode
end

--[[
	Fills in missing (nil) string-keyed fields in Profile.Data from the template table
	that was provided to the parent ProfileStore.
]]
function Profile.Reconcile(self: Profile<any>)
	if typeof(self.Data) ~= "table" then
		error(`[ProfileStore]: Profile.Data must be a table to reconcile (KEY: {self.Key}).`, 2)
	end

	const profileStore = self.ProfileStore
	if profileStore and typeof(profileStore._template) == "table" then
		Util.ReconcileTable(self.Data :: { [string]: any }, profileStore._template :: { [string]: any })
	end
end

--[[
	Ends the session for this profile, triggering the final guaranteed save.
	Returns a Promise that resolves once the final save and release complete.
]]
function Profile.EndSession(self: Profile<any>): Promise.Promise<nil>
	if self._viewMode then
		return Promise.resolve(nil)
	end

	if self._releasePromise then
		return self._releasePromise
	end

	if not self._isActive then
		return Promise.resolve(nil)
	end

	return self.ProfileStore:_releaseProfile(self, "Manual")
end

--[[
	Associates a UserId with the profile for GDPR compliance.
]]
function Profile.AddUserId(self: Profile<any>, userId: number)
	if typeof(userId) ~= "number" or userId % 1 ~= 0 then
		warn(`[ProfileStore]: Invalid UserId provided to :AddUserId() ({tostring(userId)})`)
		return
	end

	-- Avoid sending negative test UserIds to live Roblox APIs.
	if userId < 0 and not self._isMock and not self._isAutoMock then
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
	if typeof(userId) ~= "number" or userId % 1 ~= 0 then
		warn(`[ProfileStore]: Invalid UserId provided to :RemoveUserId() ({tostring(userId)})`)
		return
	end

	const index = table.find(self.UserIds, userId)
	if index then
		table.remove(self.UserIds, index)
	end
end

--[[
	Registers a handler function for processing incoming messages (GlobalUpdates).
	The handler is immediately invoked for any existing, unprocessed messages.
]]
function Profile.MessageHandler(self: Profile<any>, handler: (message: any, processed: () -> ()) -> ())
	if typeof(handler) ~= "function" then
		error(`[ProfileStore]: Argument to :MessageHandler() must be a function. Got {typeof(handler)}.`, 2)
	end

	if not self._viewMode and not self:IsActive() then
		return
	end

	table.insert(self._messageHandlers, handler)

	for _, update in self._globalUpdates do
		if typeof(update) ~= "table" then
			continue
		end

		const updateId = update[1]
		if typeof(updateId) ~= "number" then
			continue
		end

		if self._lockedGlobalUpdates[updateId] then
			continue
		end

		const messageData = update[#update]
		local function processedCallback()
			self._lockedGlobalUpdates[updateId] = true
		end

		const messageCopy = Util.DeepCopyTable(messageData)
		task.spawn(handler, messageCopy, processedCallback)
	end
end

--[[
	Immediately saves the profile's current Data to the DataStore if the session is active.
	Returns a Promise that resolves with Profile.LastSavedData on success, or rejects on failure.
]]
function Profile.Save<T>(self: Profile<T>): Promise.Promise<T>
	if self._viewMode then
		error("[ProfileStore]: :Save() cannot be used in view mode. Use :SetAsync() instead.", 2)
	end

	if not self:IsActive() then
		const message = `Attempted to save an inactive profile (STORE: {self.ProfileStore.Name}; KEY: {self.Key}).`
		warn(`[ProfileStore]: {message}`)
		return Promise.reject(PromiseError.new({
			error = message,
			kind = Types.ErrorKind.SessionConflict,
		}))
	end

	return self.ProfileStore:_saveProfile(self)
end

--[[
	Forcefully saves the profile's current Data to the DataStore and clears any active session lock.
	This method is ONLY for profiles loaded in view mode via GetAsync or VersionQuery.
	Returns a Promise that resolves when the overwrite completes, or rejects on failure.
]]
function Profile.SetAsync(self: Profile<any>): Promise.Promise<nil>
	if not self._viewMode then
		error("[ProfileStore]: :SetAsync() can only be used in view mode.", 2)
	end

	return self.ProfileStore:_overwriteProfile(self)
end

return Profile
