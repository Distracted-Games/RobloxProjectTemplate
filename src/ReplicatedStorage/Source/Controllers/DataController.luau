--!strict

const LeanPromise = require("../Libs/LeanPromise")
const Logger = require("../Utility/Logger")
const Network = require("../Libs/Network")
const PlayerDataType = require("../Types/PlayerDataType")
const Signal = require("../Libs/Signal")
const TableUtil = require("../Utility/TableUtil")
const TypeFunctions = require("../Utility/TypeFunctions")

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

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

local _authoritativeData: PlayerData? = nil
local _effectiveData: PlayerData? = nil
local _pendingTransactions: { Transaction } = {}
local _nextTransactionId = 0

local _initialDataSignal = Signal.new() :: Signal.Signal<PlayerData>

local DataController = {}

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
	Re-projects effective data, updates the cache, and fires OnDataUpdated if diffs exist.
]]
local function updateEffectiveProjection()
	local prevEffective = _effectiveData
	local newEffective = computeEffectiveData()

	if not newEffective then
		return
	end

	_effectiveData = newEffective

	if not prevEffective then
		return
	end

	local effectiveDiff = TableUtil.Diff(prevEffective, newEffective)
	if effectiveDiff then
		local frozenCopy = TableUtil.DeepFreezeClone(_effectiveData) :: PlayerData
		DataController.OnDataUpdated:Fire(frozenCopy, effectiveDiff)
	end
end

--[[
	Called when the server replicates the full initial player data snapshot.
]]
local function onInitialDataLoaded(data: PlayerData)
	_authoritativeData = TableUtil.DeepClone(data)
	table.clear(_pendingTransactions)
	_effectiveData = TableUtil.DeepClone(data)

	local frozenCopy = TableUtil.DeepFreezeClone(_effectiveData)
	_initialDataSignal:Fire(frozenCopy)
	DataController.OnInitialDataLoaded:Fire(frozenCopy)
	DataController.OnDataUpdated:Fire(frozenCopy, {})
end

--[[
	Called when the server replicates delta updates.
]]
local function onPlayerDataUpdated(deltas: Deltas, lastTxId: number?)
	if not _authoritativeData then
		logger:warn(`Failed to update local data cache: authoritative data not initialized`)
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
	local updated = TableUtil.Apply(TableUtil.DeepClone(_authoritativeData), deltas)
	_authoritativeData = updated

	-- Re-project effective state and emit only net changes to listeners
	updateEffectiveProjection()
end

--[[
	Synchronous getter for authoritative server data.

	This function is only useful for actions that should **never** be optimistically
	predicted (e.g., Robux purchases, trading high-tier items with other players),
	where you want to ensure the server truth has enough balance before replicating.
]]
function DataController.GetAuthoritativeData(): PlayerData?
	if _authoritativeData then
		return TableUtil.DeepFreezeClone(_authoritativeData)
	end
	return nil
end

--[[
	Synchronous getter for projected effective data.
]]
function DataController.GetEffectiveData(): PlayerData?
	if _effectiveData then
		return TableUtil.DeepFreezeClone(_effectiveData)
	end
	return nil
end

--[[
	Asynchronous getter for projected effective data.
]]
function DataController.GetEffectiveDataAsync(): Promise<PlayerData>
	if _effectiveData then
		local frozenCopy = TableUtil.DeepFreezeClone(_effectiveData)
		return LeanPromise.resolve(frozenCopy)
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
	local transactionId = _nextTransactionId

	local transaction: Transaction = {
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
	For actions that don't have a 1-to-1 RemoteEvent ticket (e.g. coin pickups).
]]
function DataController.PredictEphemeralMutation(mutator: Mutator, duration: number?): number
	local txId = DataController.PredictMutation(mutator)

	-- Auto-retire as confirmed once server replication is expected to have arrived
	task.delay(duration or 0.5, function()
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
		_authoritativeData = TableUtil.Apply(TableUtil.DeepClone(_authoritativeData :: any), serverDeltas)
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
