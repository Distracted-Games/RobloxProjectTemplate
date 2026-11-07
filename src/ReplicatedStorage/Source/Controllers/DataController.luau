--!strict

const LeanPromise = require("../Libs/LeanPromise")
const Logger = require("../Utility/Logger")
const Network = require("../Libs/Network")
const PlayerDataType = require("../Types/PlayerDataType")
const Signal = require("../Libs/Signal")
const TableUtil = require("../Utility/TableUtil")
const TypeFunctions = require("../Utility/TypeFunctions")

const DEFAULT_TRANSACTION_TIMEOUT = 5

export type PlayerData = TypeFunctions.AddKeyIndexer<PlayerDataType.PlayerData>
export type PlayerDataKey = PlayerDataType.PlayerDataKey
export type Deltas = { [PlayerDataKey]: any }

export type Mutator = (state: PlayerData) -> ()
export type Transaction = {
	Id: number,
	TimeStamp: number,
	Mutator: Mutator,
}
export type TransactionResult = {
	TransactionId: number,
	Success: boolean,
	Reason: string?,
}

type Promise<T> = LeanPromise.Promise<T>

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

local _authoritativeData: PlayerData? = nil
local _effectiveData: PlayerData? = nil
local _frozenAuthoritativeData: PlayerData? = nil
local _frozenEffectiveData: PlayerData? = nil
local _pendingTransactions: { Transaction } = {}
local _nextTransactionId = 0

local _initialDataSignal = Signal.new() :: Signal.Signal<PlayerData>

const DataController = {}

DataController.OnInitialDataLoaded = Signal.new() :: Signal.Signal<PlayerData>
DataController.OnDataUpdated = Signal.new() :: Signal.Signal<PlayerData, Deltas>
DataController.OnTransactionReconciled = Signal.new() :: Signal.Signal<TransactionResult>

--[[
	Pure projection helper: folds authoritative data over all pending transactions.
]]
local function computeEffectiveData(): PlayerData?
	if not _authoritativeData then
		return nil
	end

	local projected = TableUtil.DeepClone(_authoritativeData)
	for _, transaction in _pendingTransactions do
		transaction.Mutator(projected)
	end

	return projected
end

--[[
	Re-projects effective data, refreshes the O(1) frozen cache, and fires
	`OnDataUpdated` if diffs exist.
]]
local function updateEffectiveProjection()
	const prevEffective = _effectiveData
	const newEffective = computeEffectiveData()

	if not newEffective then
		return
	end

	_effectiveData = newEffective
	const frozenEffective = TableUtil.DeepFreezeClone(newEffective) :: PlayerData
	_frozenEffectiveData = frozenEffective

	if not prevEffective then
		return
	end

	const effectiveDiff = TableUtil.Diff(prevEffective, newEffective)
	if effectiveDiff then
		DataController.OnDataUpdated:Fire(frozenEffective, effectiveDiff)
	end
end

--[[
	Called when the server replicates the full initial player data snapshot.
]]
local function onInitialDataLoaded(data: PlayerData)
	const authCopy = TableUtil.DeepClone(data)
	_authoritativeData = authCopy
	_frozenAuthoritativeData = TableUtil.DeepFreezeClone(authCopy) :: PlayerData

	table.clear(_pendingTransactions)

	const effectiveCopy = TableUtil.DeepClone(data)
	_effectiveData = effectiveCopy
	const frozenEffective = TableUtil.DeepFreezeClone(effectiveCopy) :: PlayerData
	_frozenEffectiveData = frozenEffective

	_initialDataSignal:Fire(frozenEffective)
	DataController.OnInitialDataLoaded:Fire(frozenEffective)
	DataController.OnDataUpdated:Fire(frozenEffective, {})
end

--[[
	Called when the server replicates delta updates.
]]
local function onPlayerDataUpdated(deltas: Deltas, lastTxId: number?)
	if not _authoritativeData then
		logger:warn("Failed to update local data cache: authoritative data not initialized")
		return
	end

	-- Retire any pending transactions that the server has already folded into this snapshot
	if lastTxId then
		for i = #_pendingTransactions, 1, -1 do
			if _pendingTransactions[i].Id <= lastTxId then
				table.remove(_pendingTransactions, i)
			end
		end
	end

	-- Update authoritative ground truth
	const updated = TableUtil.Apply(TableUtil.DeepClone(_authoritativeData), deltas) :: PlayerData
	_authoritativeData = updated
	_frozenAuthoritativeData = TableUtil.DeepFreezeClone(updated) :: PlayerData

	-- Re-project effective state and emit only net changes to listeners
	updateEffectiveProjection()
end

function DataController.IsLoaded(): boolean
	return _frozenEffectiveData ~= nil
end

--[[
	O(1) synchronous getter for authoritative server data.
	Use for flows that must **never** be optimistically predicted (e.g. Robux purchases).
]]
function DataController.GetAuthoritativeData(): PlayerData?
	return _frozenAuthoritativeData
end

--[[
	O(1) synchronous getter for projected effective data.
]]
function DataController.GetEffectiveData(): PlayerData?
	return _frozenEffectiveData
end

--[[
	O(1) synchronous getter for projected effective data.

	Alias for `DataController.GetEffectiveData()`.
]]
function DataController.Get(): PlayerData?
	return _frozenEffectiveData
end

--[[
	Asynchronous getter for projected effective data.
]]
function DataController.GetEffectiveDataAsync(): Promise<PlayerData>
	if _frozenEffectiveData then
		return LeanPromise.resolve(_frozenEffectiveData)
	end

	return LeanPromise.new(function(resolve, _reject, onCancel)
		local connection: Signal.Connection? = nil

		connection = _initialDataSignal:Once(function(data: PlayerData)
			resolve(data)
		end)

		onCancel(function()
			if connection and connection.Connected then
				connection:Disconnect()
			end
		end)
	end) :: Promise<PlayerData>
end

--[[
	Alias to `GetEffectiveDataAsync` for UI view consumers.
]]
function DataController.GetDataAsync(): Promise<PlayerData>
	return DataController.GetEffectiveDataAsync()
end

--[[
	Registers an optimistic mutation patch in the queue and immediately updates effective state.
	@return The generated transactionId
]]
function DataController.PredictMutation(mutator: Mutator): number
	if not _authoritativeData or not _effectiveData then
		logger:warn("Cannot predict mutation: Player data is not loaded yet")
		return -1
	end

	_nextTransactionId += 1
	const transactionId = _nextTransactionId

	const transaction: Transaction = {
		Id = transactionId,
		TimeStamp = os.clock(),
		Mutator = mutator,
	}

	table.insert(_pendingTransactions, transaction)
	updateEffectiveProjection()

	-- Safety timeout: rollback if unacknowledged after timeout window
	task.delay(DEFAULT_TRANSACTION_TIMEOUT, function()
		DataController.ReconcileTransaction(transactionId, false)
	end)

	return transactionId
end

--[[
	For actions that don't have a 1-to-1 RemoteEvent ticket (e.g. instant UI toggles).
]]
function DataController.PredictEphemeralMutation(mutator: Mutator, duration: number?): number
	const txId = DataController.PredictMutation(mutator)
	if txId == -1 then
		return -1
	end

	-- Auto-retire as confirmed once server replication is expected to have arrived
	const expireSeconds = if duration ~= nil then duration else 0.5
	task.delay(expireSeconds, function()
		DataController.ReconcileTransaction(txId, true)
	end)
	return txId
end

--[[
	Reconciles a pending speculative transaction.
	- If `isConfirmed` is `true`: The server confirmed the action. The patch is retired 
	  from the queue because S_auth now incorporates the change.
	- If `isConfirmed` is `false`: The server rejected the action (or timed out). The patch
	  is discarded, automatically rolling back S_eff to S_auth, and an event is emitted.
]]
function DataController.ReconcileTransaction(
	transactionId: number,
	isConfirmed: boolean,
	reason: string?,
	serverDeltas: Deltas?
)
	local targetIndex: number? = nil
	for index, transaction in _pendingTransactions do
		if transaction.Id == transactionId then
			targetIndex = index
			break
		end
	end

	-- Transaction was already reconciled or expired
	if not targetIndex then
		return
	end

	table.remove(_pendingTransactions, targetIndex)

	-- If the server provided an explicit delta payload with the acknowledgement, merge it into S_auth
	if serverDeltas and _authoritativeData then
		const updatedAuth = TableUtil.Apply(TableUtil.DeepClone(_authoritativeData :: any), serverDeltas) :: PlayerData
		_authoritativeData = updatedAuth
		_frozenAuthoritativeData = TableUtil.DeepFreezeClone(updatedAuth) :: PlayerData
	end

	updateEffectiveProjection()

	DataController.OnTransactionReconciled:Fire({
		TransactionId = transactionId,
		Success = isConfirmed,
		Reason = reason,
	})
end

function DataController.Setup()
	Network.connectEvent(Network.RemoteEvents.PlayerDataUpdated, onPlayerDataUpdated)
	Network.connectEvent(Network.RemoteEvents.InitialDataLoaded, onInitialDataLoaded)
end

return table.freeze(DataController)
