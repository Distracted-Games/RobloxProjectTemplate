--!strict
--[[
	Versioning add-on submodule for ProfileStore2.
	Provides historical version querying and iteration via ProfileStore:VersionQuery()
	and VersionQuery:NextAsync().
]]

const Constants = require("../Constants")
const Profile = require("../Profile")
const Promise = require("../LeanPromise")
const PromiseError = require("../LeanPromise/PromiseError")
const Types = require("../Types")
const Util = require("../Util")

const MAX_BACKOFF_NORMAL = 20

export type VersioningCallbacks<T> = {
	StoreName: string,
	GetDataStore: () -> DataStore?,
	WaitForStoreReady: () -> (),
	IsServerClosing: () -> boolean,
	HasDataStoreAccess: () -> boolean,
	IsStudio: () -> boolean,
	RegisterError: (errorMessage: string, storeName: string, profileKey: string) -> (),
	GetAsyncInternal: (
		key: string,
		version: string?,
		isUserMock: boolean
	) -> Promise.Promise<Profile.Profile<T>?>,
}

export type VersionQuery<T = any> = {
	read NextAsync: (self: VersionQuery<T>) -> Promise.Promise<Profile.Profile<T>?>,
}

local warnedAboutVersionQueryOnce = false

const ProfileVersionQuery = {}
ProfileVersionQuery.__index = ProfileVersionQuery

type VersionQueryClassData<T> = {
	_callbacks: VersioningCallbacks<T>,
	_key: string,
	_sortDirection: Enum.SortDirection?,
	_minDate: number?,
	_maxDate: number?,
	_isUserMock: boolean,
	_queryPages: DataStoreVersionPages?,
	_queryIndex: number,
	_queryFailure: boolean,
	_isQueueBusy: boolean,
	_pendingQueue: { thread },
}

type InternalVersionQuery<T = any> = setmetatable<VersionQueryClassData<T>, typeof(ProfileVersionQuery)>

local function acquireQueryTurn(self: InternalVersionQuery<any>): () -> ()
	if not self._isQueueBusy then
		self._isQueueBusy = true
	else
		table.insert(self._pendingQueue, coroutine.running())
		coroutine.yield()
	end

	local released = false
	return function()
		if released then
			return
		end
		released = true

		const nextThread = table.remove(self._pendingQueue, 1)
		if nextThread then
			task.spawn(nextThread)
		else
			self._isQueueBusy = false
		end
	end
end

local function executePageOperationWithRetry<T>(
	self: InternalVersionQuery<T>,
	isCancelled: () -> boolean,
	operation: () -> ()
): (boolean, string?)
	local backoff = 1
	local attempt = 0

	while true do
		if self._callbacks.IsServerClosing() or isCancelled() then
			return false, "Cancelled"
		end

		const ok, err = pcall(operation)
		if ok then
			return true, nil
		end

		const errText = tostring(err)
		self._callbacks.RegisterError(errText, self._callbacks.StoreName, self._key)
		attempt += 1

		if attempt > Constants.MAX_TRANSIENT_RETRIES or not Util.IsTransientDataStoreError(errText) then
			return false, errText
		end

		local function shouldAbort(): boolean
			return self._callbacks.IsServerClosing() or isCancelled()
		end

		if Util.WaitInterruptible(backoff, shouldAbort) then
			return false, "Cancelled"
		end
		backoff = math.min(MAX_BACKOFF_NORMAL, backoff * 2)
	end
end

--[[
	Advances the version query iterator and returns a Promise that resolves with the
	next historical view-mode Profile<T>, or `nil` when no further versions remain.
]]
function ProfileVersionQuery.NextAsync<T>(self: InternalVersionQuery<T>): Promise.Promise<Profile.Profile<T>?>
	return Promise.new(function(resolve: (Profile.Profile<T>?) -> (), reject, onCancel)
		local isCancelled = false
		onCancel(function()
			isCancelled = true
		end)

		self._callbacks.WaitForStoreReady()

		if self._callbacks.IsServerClosing() or isCancelled then
			resolve(nil)
			return
		end

		if self._isUserMock or not self._callbacks.HasDataStoreAccess() then
			if self._callbacks.IsStudio() and not warnedAboutVersionQueryOnce then
				warnedAboutVersionQueryOnce = true
				warn("[ProfileStore]: :VersionQuery() is not supported in mock mode!")
			end
			resolve(nil)
			return
		end

		const releaseTurn = acquireQueryTurn(self)

		if self._callbacks.IsServerClosing() or isCancelled or self._queryFailure then
			releaseTurn()
			resolve(nil)
			return
		end

		const dataStore = self._callbacks.GetDataStore()
		if not dataStore then
			releaseTurn()
			resolve(nil)
			return
		end

		-- First NextAsync call loads the initial DataStoreVersionPages object.
		if self._queryPages == nil then
			const listOk, listErr = executePageOperationWithRetry(self, function()
				return isCancelled
			end, function()
				self._queryPages =
					dataStore:ListVersionsAsync(self._key, self._sortDirection, self._minDate, self._maxDate)
				self._queryIndex = 0
			end)

			if not listOk or self._queryPages == nil then
				self._queryFailure = true
				releaseTurn()

				if listErr == "Cancelled" then
					reject(PromiseError.new({
						error = "VersionQuery:NextAsync() was cancelled or server is shutting down.",
						kind = Types.ErrorKind.Cancelled,
					}))
				else
					const errText = listErr or "ListVersionsAsync returned nil pages."
					warn(`[ProfileStore]: Version query fail - {errText}`)
					reject(PromiseError.new({
						error = errText,
						kind = Types.ErrorKind.DataStoreError,
					}))
				end
				return
			end
		end

		local pages = self._queryPages :: DataStoreVersionPages
		local currentPage = pages:GetCurrentPage() :: { DataStoreObjectVersionInfo }
		local nextItem = currentPage[self._queryIndex + 1]

		-- Advance across page boundaries until we find a version entry or reach the end.
		while nextItem == nil and not pages.IsFinished do
			const advanceOk, advanceErr = executePageOperationWithRetry(self, function()
				return isCancelled
			end, function()
				pages:AdvanceToNextPageAsync()
				self._queryIndex = 0
			end)

			if not advanceOk then
				self._queryFailure = true
				releaseTurn()

				if advanceErr == "Cancelled" then
					reject(PromiseError.new({
						error = "VersionQuery:NextAsync() was cancelled or server is shutting down.",
						kind = Types.ErrorKind.Cancelled,
					}))
				else
					const errText = advanceErr or "Failed to advance VersionQuery page."
					warn(`[ProfileStore]: Version query fail - {errText}`)
					reject(PromiseError.new({
						error = errText,
						kind = Types.ErrorKind.DataStoreError,
					}))
				end
				return
			end

			currentPage = pages:GetCurrentPage() :: { DataStoreObjectVersionInfo }
			if #currentPage == 0 then
				self._queryFailure = true
				break
			end
			nextItem = currentPage[1]
		end

		if nextItem == nil then
			releaseTurn()
			resolve(nil)
			return
		end

		self._queryIndex += 1
		const targetVersion = nextItem.Version

		-- Release the page-cursor lock before fetching the snapshot so concurrent
		-- NextAsync() callers can advance the cursor and fetch snapshots in parallel.
		releaseTurn()

		const getPromise = self._callbacks.GetAsyncInternal(self._key, targetVersion, self._isUserMock)
		onCancel(function()
			getPromise:cancel()
		end)

		getPromise:andThen(resolve, reject)
	end)
end

const Versioning = {}

--[[
	Validates VersionQuery parameters and constructs a new VersionQuery iterator.
]]
function Versioning.CreateVersionQuery<T>(
	callbacks: VersioningCallbacks<T>,
	key: string,
	sortDirection: Enum.SortDirection?,
	minDate: DateTime | number | nil,
	maxDate: DateTime | number | nil,
	isUserMock: boolean
): VersionQuery<T>
	if typeof(key) ~= "string" or #key == 0 or #key > 50 then
		error("[ProfileStore]: Invalid 'key' provided to VersionQuery. Must be a string of 1-50 characters.", 3)
	end

	if
		sortDirection ~= nil and (typeof(sortDirection) ~= "EnumItem" or sortDirection.EnumType ~= Enum.SortDirection)
	then
		error(`[ProfileStore]: Invalid 'sortDirection' ({tostring(sortDirection)}) provided to VersionQuery.`, 3)
	end

	if minDate ~= nil and typeof(minDate) ~= "DateTime" and typeof(minDate) ~= "number" then
		error(`[ProfileStore]: Invalid 'minDate' ({tostring(minDate)}) provided to VersionQuery.`, 3)
	end

	if maxDate ~= nil and typeof(maxDate) ~= "DateTime" and typeof(maxDate) ~= "number" then
		error(`[ProfileStore]: Invalid 'maxDate' ({tostring(maxDate)}) provided to VersionQuery.`, 3)
	end

	const resolvedMinDate: number? = if typeof(minDate) == "DateTime" then minDate.UnixTimestampMillis else minDate
	const resolvedMaxDate: number? = if typeof(maxDate) == "DateTime" then maxDate.UnixTimestampMillis else maxDate

	const self = setmetatable({}, ProfileVersionQuery) :: InternalVersionQuery<T>
	self._callbacks = callbacks
	self._key = key
	self._sortDirection = sortDirection
	self._minDate = resolvedMinDate
	self._maxDate = resolvedMaxDate
	self._isUserMock = isUserMock
	self._queryPages = nil
	self._queryIndex = 0
	self._queryFailure = false
	self._isQueueBusy = false
	self._pendingQueue = {}

	return (self :: any) :: VersionQuery<T>
end

return table.freeze(Versioning)
