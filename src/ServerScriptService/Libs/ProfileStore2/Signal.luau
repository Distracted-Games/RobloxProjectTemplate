--!strict
--[[
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
	A robust, yield-safe Signal implementation.
	Based on the work of stravant.
]]

local Connection = {}
Connection.__index = Connection

local Signal = {}
Signal.__index = Signal

type ConnectionData<T...> = {
	IsConnected: boolean,
	_listener: (T...) -> (),
	_signal: Signal<T...>,
	_next: Connection<T...>?,
}

export type Connection<T... = ...any> = setmetatable<ConnectionData<T...>, typeof(Connection)>

type SignalData<T...> = {
	_head: Connection<T...>?,
	_listenerCount: number,
}

export type Signal<T... = ...any> = setmetatable<SignalData<T...>, typeof(Signal)>

local freeRunnerThread: thread?

local function acquireRunnerAndCall(callback: (...any) -> (), ...: any)
	local runner = freeRunnerThread
	freeRunnerThread = nil
	callback(...)
	-- The handler finished running cleanly; this runner thread is free again.
	freeRunnerThread = runner
end

local function runEventHandlerInFreeThread(...: any)
	acquireRunnerAndCall(...)
	while true do
		acquireRunnerAndCall(coroutine.yield())
	end
end

function Connection.Disconnect<T...>(self: Connection<T...>)
	if not self.IsConnected then
		return
	end
	self.IsConnected = false

	local signal = self._signal
	signal._listenerCount -= 1

	if signal._head == self then
		signal._head = self._next
		return
	end

	local prev = signal._head
	while prev and prev._next ~= self do
		prev = prev._next
	end
	if prev then
		prev._next = self._next
	end
end

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({}, Signal) :: Signal<T...>
	self._head = nil
	self._listenerCount = 0
	return self
end

function Signal.Connect<T...>(self: Signal<T...>, callback: (T...) -> ()): Connection<T...>
	if typeof(callback) ~= "function" then
		error("[Signal]: Listener must be a function.", 2)
	end

	local connection = setmetatable({}, Connection) :: Connection<T...>
	connection.IsConnected = true
	connection._listener = callback
	connection._signal = self
	connection._next = self._head

	self._head = connection
	self._listenerCount += 1

	return connection
end

function Signal.Once<T...>(self: Signal<T...>, callback: (T...) -> ()): Connection<T...>
	if typeof(callback) ~= "function" then
		error("[Signal]: Listener must be a function.", 2)
	end

	local connection: Connection<T...>
	connection = self:Connect(function(...: T...)
		connection:Disconnect()
		callback(...)
	end)

	return connection
end

function Signal.Fire<T...>(self: Signal<T...>, ...: T...)
	local item = self._head
	while item do
		if item.IsConnected then
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
			end
			task.spawn(freeRunnerThread :: thread, item._listener, ...)
		end
		item = item._next
	end
end

function Signal.Wait<T...>(self: Signal<T...>): T...
	const runningThread = coroutine.running()
	local connection: Connection<T...>
	connection = self:Connect(function(...: T...)
		connection:Disconnect()
		task.spawn(runningThread, ...)
	end)
	return coroutine.yield()
end

function Signal.GetListenerCount<T...>(self: Signal<T...>): number
	return self._listenerCount
end

function Signal.DisconnectAll<T...>(self: Signal<T...>)
	local item = self._head
	while item do
		item.IsConnected = false
		item = item._next
	end
	self._head = nil
	self._listenerCount = 0
end

return table.freeze({
	new = Signal.new,
})
