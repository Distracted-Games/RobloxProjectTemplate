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
    A robust, yield-safe Signal implementation.
    Based on the work of stravant.
]]

type SignalClassType<T...> = {
    _head: Connection?,
    _listenerCount: number,
    Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
    Fire: (self: Signal<T...>, ...any) -> (),
    Wait: (self: Signal<T...>) -> T...,
    GetListenerCount: (self: Signal<T...>) -> number,
}

type ConnectionClassType = {
    Disconnect: (self: Connection) -> (),
    IsConnected: boolean,
    _listener: (...any) -> (),
    _signal: any, -- is a Signal
    _next: Connection?,
}

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

export type Connection = setmetatable<ConnectionClassType, typeof(Connection)>
export type Signal<T...> = setmetatable<SignalClassType<T...>, typeof(Signal)>

local freeRunnerThread: thread?

local function acquireRunnerAndCall(callback: (...any) -> ...any?, ...)
	local runner = freeRunnerThread
	freeRunnerThread = nil
	callback(...)
    freeRunnerThread = runner -- The runner is now free.
end

local function runEventHandlerInFreeThread(...)
	acquireRunnerAndCall(...)
	while true do
		acquireRunnerAndCall(coroutine.yield())
	end
end

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({}, Signal) :: Signal<T...>
	self._head = nil
	self._listenerCount = 0
	return self
end

function Signal.Connect<T...>(self: Signal<T...>, callback: (...any) -> ()): Connection
	if typeof(callback) ~= "function" then
		error("Listener must be a function.", 2)
	end

	local connection = setmetatable({}, Connection) :: Connection
	connection.IsConnected = true
	connection._listener = callback
	connection._signal = self
	connection._next = self._head

	self._head = connection
	self._listenerCount += 1

	return connection
end

function Connection.Disconnect(self: Connection)
	if not self.IsConnected then
		return
	end
	self.IsConnected = false

	local signal = self._signal
	signal._listenerCount -= 1

	if signal._head == self then
		signal._head = self._next
	else
		local prev = signal._head
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
end

function Signal.Fire<T...>(self: Signal<T...>, ...)
	local item = self._head
	while item do
		if item.IsConnected then
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
			end
			if freeRunnerThread then
				task.spawn(freeRunnerThread :: thread, item._listener, ...)
			end
		end
		item = item._next
	end
end

function Signal.Wait<T...>(self: Signal<T...>, ...): T...
	local runningThread = coroutine.running()
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(runningThread, ...)
	end)
	return coroutine.yield()
end

function Signal.GetListenerCount<T...>(self: Signal<T...>): number
	return self._listenerCount
end

return {
	new = Signal.new,
}
