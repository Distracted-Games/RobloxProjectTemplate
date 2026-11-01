--!strict
--[[
	Messaging add-on submodule for ProfileStore2.
	Manages GlobalUpdates persistence, queuing, handler dispatch, and cross-server
	or offline profile messaging via ProfileStore:MessageAsync().
]]

const Constants = require("../Constants")
const Profile = require("../Profile")
const Promise = require("../LeanPromise")
const PromiseError = require("../LeanPromise/PromiseError")
const Types = require("../Types")
const Util = require("../Util")

const MAX_BACKOFF_NORMAL = 20

export type TransformParams<T> = {
	ExistingProfileHandle: ((latestData: Types.ProfileData<T>) -> ())?,
	MissingProfileHandle: ((latestData: Types.ProfileData<T>) -> ())?,
	EditProfile: ((latestData: Types.ProfileData<T>) -> ())?,
}

export type MessagingCallbacks<T> = {
	WaitForStoreReady: () -> (),
	IsServerClosing: () -> boolean,
	PerformDataStoreOperation: (
		key: string,
		transformParams: TransformParams<T>,
		isUserMock: boolean
	) -> (Types.ProfileData<T>?, DataStoreKeyInfo?, string?),
	NotifyMessageTarget: (key: string, loadedData: Types.ProfileData<T>, isUserMock: boolean) -> (),
}

const Messaging = {}

--[[
	Synchronizes GlobalUpdates state after a successful DataStore read/write and dispatches
	newly received messages to registered handlers if the session is active.
]]
function Messaging.SyncAndDispatchGlobalUpdates(
	profile: Profile.Profile<any>,
	loadedData: Types.ProfileData<any>,
	shouldDispatch: boolean
)
	const lockedUpdates = profile._lockedGlobalUpdates
	const receivedUpdates = profile._receivedGlobalUpdates
	const activeUpdates: { Types.GlobalUpdateEntry } = if typeof(loadedData.GlobalUpdates) == "table"
			and typeof(loadedData.GlobalUpdates[2]) == "table"
		then loadedData.GlobalUpdates[2]
		else {}

	const newUpdates: { Types.GlobalUpdateEntry } = {}
	const stillPending: { [number]: boolean } = {}

	for _, update in activeUpdates do
		if typeof(update) ~= "table" then
			continue
		end
		const updateId = update[1]
		if typeof(updateId) ~= "number" then
			continue
		end

		if lockedUpdates[updateId] then
			stillPending[updateId] = true
		elseif not receivedUpdates[updateId] then
			receivedUpdates[updateId] = true
			table.insert(newUpdates, update)
		end
	end

	for updateId in lockedUpdates do
		if not stillPending[updateId] then
			lockedUpdates[updateId] = nil
		end
	end

	profile._globalUpdates = activeUpdates

	if not shouldDispatch then
		return
	end

	for _, update in newUpdates do
		const updateId = update[1] :: number
		const updateData = update[#update]

		for _, handler in profile._messageHandlers do
			if lockedUpdates[updateId] then
				break
			end

			local isProcessed = false
			local function processedCallback()
				isProcessed = true
				lockedUpdates[updateId] = true
			end

			const payloadCopy = Util.DeepCopyTable(updateData)
			task.spawn(handler, payloadCopy, processedCallback)

			if isProcessed then
				break
			end
		end
	end
end

--[[
	Removes messages that have been marked as processed by a handler from the
	persisted GlobalUpdates payload during a profile save.
]]
function Messaging.PruneLockedUpdatesFromPayload(
	lockedUpdates: { [number]: boolean },
	globalUpdates: Types.GlobalUpdatesPayload?
)
	if next(lockedUpdates) == nil then
		return
	end
	if typeof(globalUpdates) ~= "table" or typeof(globalUpdates[2]) ~= "table" then
		return
	end

	const activeUpdates = globalUpdates[2] :: { Types.GlobalUpdateEntry }
	local index = 1
	while index <= #activeUpdates do
		const update = activeUpdates[index]
		if typeof(update) == "table" and typeof(update[1]) == "number" and lockedUpdates[update[1]] then
			table.remove(activeUpdates, index)
		else
			index += 1
		end
	end
end

--[[
	Appends a message table to a profile's GlobalUpdates queue and notifies any live session
	(either locally on this server or remotely via MessagingService).
]]
function Messaging.MessageAsyncInternal<T>(
	callbacks: MessagingCallbacks<T>,
	key: string,
	message: { [any]: any },
	isUserMock: boolean
): Promise.Promise<boolean>
	if typeof(key) ~= "string" or #key == 0 or #key > 50 then
		error("[ProfileStore]: Invalid 'key' provided to MessageAsync. Must be a string of 1-50 characters.", 3)
	end
	if typeof(message) ~= "table" then
		error(`[ProfileStore]: 'message' provided to MessageAsync must be a table, got {typeof(message)}.`, 3)
	end

	const messageSnapshot = Util.DeepCopyTable(message)

	return Promise.new(function(resolve: (boolean) -> (), reject, onCancel)
		local isCancelled = false
		onCancel(function()
			isCancelled = true
		end)

		if callbacks.IsServerClosing() then
			reject(PromiseError.new({
				error = "Cannot call MessageAsync while server is shutting down.",
				kind = Types.ErrorKind.Cancelled,
			}))
			return
		end

		callbacks.WaitForStoreReady()

		local backoff = 1
		local attempt = 0

		while true do
			if callbacks.IsServerClosing() or isCancelled then
				reject(PromiseError.new({
					error = "MessageAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end

			const loadedData, _, errorMessage = callbacks.PerformDataStoreOperation(key, {
				ExistingProfileHandle = nil,
				MissingProfileHandle = nil,
				EditProfile = function(latestData: Types.ProfileData<T>)
					local globalUpdates: Types.GlobalUpdatesPayload
					if
						typeof(latestData.GlobalUpdates) == "table"
						and typeof(latestData.GlobalUpdates[1]) == "number"
						and typeof(latestData.GlobalUpdates[2]) == "table"
					then
						globalUpdates = latestData.GlobalUpdates
					else
						globalUpdates = { 0, {} }
						latestData.GlobalUpdates = globalUpdates
					end

					const nextUpdateId = (globalUpdates[1] :: number) + 1
					const updateList = globalUpdates[2] :: { Types.GlobalUpdateEntry }

					globalUpdates[1] = nextUpdateId
					table.insert(updateList, { nextUpdateId, Util.DeepCopyTable(messageSnapshot) })

					while #updateList > Constants.MAX_MESSAGE_QUEUE do
						table.remove(updateList, 1)
					end
				end,
			}, isUserMock)

			if errorMessage == nil and loadedData ~= nil then
				callbacks.NotifyMessageTarget(key, loadedData, isUserMock)
				resolve(true)
				return
			end

			const errText = errorMessage or `Failed to send message to key '{key}'.`
			attempt += 1

			if attempt > Constants.MAX_TRANSIENT_RETRIES or not Util.IsTransientDataStoreError(errText) then
				reject(PromiseError.new({
					error = errText,
					kind = Types.ErrorKind.DataStoreError,
				}))
				return
			end

			local function shouldAbort(): boolean
				return callbacks.IsServerClosing() or isCancelled
			end

			if Util.WaitInterruptible(backoff, shouldAbort) then
				reject(PromiseError.new({
					error = "MessageAsync was cancelled or server is shutting down.",
					kind = Types.ErrorKind.Cancelled,
				}))
				return
			end
			backoff = math.min(MAX_BACKOFF_NORMAL, backoff * 2)
		end
	end)
end

return table.freeze(Messaging)
