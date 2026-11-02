--!strict
--[[
	@author DistractedGames
	@version 1.2.1
	@license MIT License

	Yield-Safe Pooled Runner Signal Implementation

	A Signal class that dispatches and observes events with behavior matching
	RBXScriptSignal. Caches runner coroutines so yielding inside signal handlers
	incurs minimal overhead compared to naive signal implementations.

	Based upon the work of stravant and sleitnick.
]]

const Connection = {}
Connection.__index = Connection

const Signal = {}
Signal.__index = Signal

type ConnectionData<T...> = {
	Connected: boolean,
	_listener: (T...) -> (),
	_signal: Signal<T...>,
	_next: Connection<T...>?,
}

export type Connection<T... = ...any> = setmetatable<ConnectionData<T...>, typeof(Connection)>

type SignalData<T...> = {
	_head: Connection<T...>?,
	_listenerCount: number,
	_proxyHandler: RBXScriptConnection?,
	_yieldedThreads: { [thread]: boolean }?,
	_isDestroyed: boolean?,
}

export type Signal<T... = ...any> = setmetatable<SignalData<T...>, typeof(Signal)>

-- The currently idle thread to run the next handler on
local freeRunnerThread: thread? = nil

-- Acquires the currently idle runner thread, executes the callback on it,
-- and releases the thread back to the idle slot once the callback finishes.
-- If the callback yields, a new runner thread will be created for subsequent handlers.
local function acquireRunnerAndCall(callback: (...any) -> (), ...: any)
	const acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	callback(...)
	-- The handler finished running cleanly; this runner thread is free again.
	freeRunnerThread = acquiredRunnerThread
end

-- Coroutine runner loop that repeatedly yields waiting for the next handler and arguments.
local function runEventHandlerInFreeThread(...: any)
	acquireRunnerAndCall(...)
	while true do
		acquireRunnerAndCall(coroutine.yield())
	end
end

-- Static deferred dispatcher to avoid allocating a closure on every listener during FireDeferred.
local function runDeferredListener<T...>(connection: Connection<T...>, ...: T...)
	if connection.Connected then
		connection._listener(...)
	end
end

--[[
	Disconnects the connection from its parent Signal so it will no longer receive events.
]]
function Connection.Disconnect<T...>(self: Connection<T...>)
	if not self.Connected then
		return
	end
	self.Connected = false

	const signal = self._signal
	signal._listenerCount -= 1

	-- Unhook the node without clearing `_next` so any active `Fire` calls
	-- currently sitting on this node can continue iterating forward.
	if signal._head == self then
		signal._head = self._next
		return
	end

	local previous = signal._head
	while previous and previous._next ~= self do
		previous = previous._next
	end
	if previous then
		previous._next = self._next
	end
end

Connection.Destroy = Connection.Disconnect

--[[
	Constructs a new Signal instance.
]]
function Signal.new<T...>(): Signal<T...>
	const self = setmetatable({
		_head = nil,
		_listenerCount = 0,
		_proxyHandler = nil,
		_yieldedThreads = nil,
		_isDestroyed = false,
	}, Signal) :: Signal<T...>

	return self
end

--[[
	Constructs a new Signal that wraps around an existing RBXScriptSignal.

	Note: The created Signal establishes a strong connection to the underlying
	RBXScriptSignal. You must call `Destroy()` on the returned Signal when it is
	no longer needed to disconnect the proxy handler.
]]
function Signal.Wrap<T...>(rbxScriptSignal: RBXScriptSignal): Signal<T...>
	if typeof(rbxScriptSignal) ~= "RBXScriptSignal" then
		error(`[Signal]: Wrap expects an RBXScriptSignal; got {typeof(rbxScriptSignal)}`, 2)
	end

	const signal = Signal.new() :: Signal<T...>
	signal._proxyHandler = rbxScriptSignal:Connect(function(...: any)
		signal:Fire(...)
	end)

	return signal
end

--[[
	Checks if the given object is a Signal instance.
]]
function Signal.Is(object: any): boolean
	return type(object) == "table" and getmetatable(object) == Signal
end

--[[
	Connects a callback function to the signal, which will be invoked anytime the signal is fired.
]]
function Signal.Connect<T...>(self: Signal<T...>, callback: (T...) -> ()): Connection<T...>
	if self._isDestroyed then
		error("[Signal]: Cannot connect to a destroyed Signal.", 2)
	end
	if typeof(callback) ~= "function" then
		error(`[Signal]: Listener must be a function; got {typeof(callback)}`, 2)
	end

	const connection = setmetatable({
		Connected = true,
		_listener = callback,
		_signal = self,
		_next = self._head,
	}, Connection) :: Connection<T...>

	self._head = connection
	self._listenerCount += 1

	return connection
end

--[[
	Connects a callback function to the signal that will only be invoked the next time the signal
	fires, automatically disconnecting itself before execution.
]]
function Signal.Once<T...>(self: Signal<T...>, callback: (T...) -> ()): Connection<T...>
	if self._isDestroyed then
		error("[Signal]: Cannot connect to a destroyed Signal.", 2)
	end
	if typeof(callback) ~= "function" then
		error(`[Signal]: Listener must be a function; got {typeof(callback)}`, 2)
	end

	local connection: Connection<T...>
	local isDone = false

	connection = self:Connect(function(...: T...)
		if isDone then
			return
		end

		isDone = true
		connection:Disconnect()
		callback(...)
	end)

	return connection
end

--[[
	Returns an array of all active connections currently listening to the signal,
	ordered from newest to oldest (LIFO).
]]
function Signal.GetConnections<T...>(self: Signal<T...>): { Connection<T...> }
	const connections = table.create(self._listenerCount) :: { Connection<T...> }
	local count = 0
	local item = self._head
	while item do
		count += 1
		connections[count] = item
		item = item._next
	end

	return connections
end

--[[
	Returns the current number of active listeners connected to the signal in O(1) time.
	Note: This count includes any active internal connections created by `Wait()`.
]]
function Signal.GetListenerCount<T...>(self: Signal<T...>): number
	return self._listenerCount
end

--[[
	Disconnects all active connections from the signal and cancels any threads currently
	yielded via `Wait()`.
]]
function Signal.DisconnectAll<T...>(self: Signal<T...>)
	local item = self._head
	while item do
		item.Connected = false
		item = item._next
	end
	self._head = nil
	self._listenerCount = 0

	const yieldedThreads = self._yieldedThreads
	if yieldedThreads then
		for thread in yieldedThreads do
			if coroutine.status(thread) == "suspended" then
				task.cancel(thread)
			end
		end
		table.clear(yieldedThreads)
	end
end

--[[
	Fires the signal, invoking all connected listener callbacks immediately on a reusable
	runner coroutine with the provided arguments.
]]
function Signal.Fire<T...>(self: Signal<T...>, ...: T...)
	local item = self._head
	while item do
		if item.Connected then
			local runnerThread: thread = freeRunnerThread or coroutine.create(runEventHandlerInFreeThread)
			freeRunnerThread = runnerThread
			task.spawn(runnerThread, item._listener, ...)
		end
		item = item._next
	end
end

--[[
	Fires the signal using `task.defer` for each connected listener callback without closure allocations.
]]
function Signal.FireDeferred<T...>(self: Signal<T...>, ...: T...)
	local item = self._head
	while item do
		task.defer(runDeferredListener, item, ...)
		item = item._next
	end
end

--[[
	Yields the calling thread until the signal next fires, returning the fired arguments.
]]
function Signal.Wait<T...>(self: Signal<T...>): T...
	if self._isDestroyed then
		error("[Signal]: Cannot wait on a destroyed Signal.", 2)
	end

	local existingThreads = self._yieldedThreads
	const yieldedThreads: { [thread]: boolean } = if existingThreads then existingThreads else {}
	if not existingThreads then
		self._yieldedThreads = yieldedThreads
	end

	const runningThread = coroutine.running()
	yieldedThreads[runningThread] = true

	self:Once(function(...: T...)
		yieldedThreads[runningThread] = nil

		if coroutine.status(runningThread) == "suspended" then
			task.spawn(runningThread, ...)
		end
	end)

	return coroutine.yield()
end

--[[
	Disconnects all listeners, cancels any waiting threads, marks the signal as destroyed,
	and disconnects the underlying RBXScriptSignal proxy if this signal was created with `Signal.Wrap`.
]]
function Signal.Destroy<T...>(self: Signal<T...>)
	self._isDestroyed = true
	self:DisconnectAll()

	const proxyHandler = self._proxyHandler
	if proxyHandler then
		proxyHandler:Disconnect()
		self._proxyHandler = nil
	end
end

return table.freeze({
	new = Signal.new,
	Wrap = Signal.Wrap,
	Is = Signal.Is,
})
