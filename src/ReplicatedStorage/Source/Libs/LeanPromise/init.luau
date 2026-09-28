--!strict
--[[
	Copyright (c) 2019 Eryn L. K.
	https://github.com/evaera/roblox-lua-promise

	This library is a derivative work of the original Promise.lua library by evaera,
	licensed under the MIT License.

	---

	Copyright (c) 2025 Distracted Games

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.
]]

--[[
	A modern, robust, and strictly-typed Promise implementation for Luau.
	Designed to handle asynchronous operations like DataStore calls or asset loading
	in a clean, non-blocking, and readable way.

	LeanPromise is a complete, feature-complete refactor of the popular
	Promise.lua library by evaera, architected to align with modern Luau
	idioms and a professional, type-safe workflow.
]]

local PromiseError = require(script.PromiseError)

type PromiseError = PromiseError.PromiseError

type ClassType<T> = {
	-- Private properties
	_status: string,
	_values: { any }?,
	_valuesLength: number,
	_unhandledRejection: boolean,
	_parent: Promise<T>?,
	_reason: any?,
	_consumers: { [Promise<T>]: boolean },
	_fulfilledCallbacks: { (T) -> () },
	_rejectedCallbacks: { (any) -> () },
	_cancellationHook: (() -> ())?,
	-- Public Methods
	andThen: (self: Promise<T>, onFulfilled: ((T) -> ...any)?, onRejected: ((any) -> ...any)?) -> Promise<T>,
	catch: (self: Promise<T>, onRejected: ((any) -> ())?) -> Promise<T>,
	finally: (self: Promise<T>, onFinally: (() -> ())?) -> Promise<T>,
	cancel: (self: Promise<T>) -> (),
	all: (promises: { Promise<T> }) -> Promise<T>,
	race: (promises: { Promise<T> }) -> Promise<T>,
	delay: (seconds: number) -> Promise<T>,
	await: (self: Promise<T>) -> ...any,
	-- Constructor
	new: (
		executor: (resolve: (T) -> (), reject: (any) -> (), onCancel: ((() -> ())?) -> boolean) -> ()
	) -> Promise<T>,
}

-- An enum for the different states a Promise can be in.
local Status = {
	Started = "Started" :: "Started",
	Resolved = "Resolved" :: "Resolved",
	Rejected = "Rejected" :: "Rejected",
	Cancelled = "Cancelled" :: "Cancelled", -- Note: we're omitting cancellation for this refactor to simplify
}
table.freeze(Status)

--[[
    A more robust xpcall handler that creates our rich error object.
]]
local function makeErrorHandler(traceback: string)
	return function(err: any): PromiseError
		if PromiseError.is(err) then
			return err
		end
		return PromiseError.new({
			error = err,
			kind = PromiseError.Kind.ExecutionError,
			trace = debug.traceback(tostring(err), 2),
			context = "Promise created at:\n" .. traceback,
		})
	end
end

--[[
    Safely calls a function and captures its return values or error.
    We use xpcall to provide our custom error handling function.
]]
local function runExecutor(traceback: string, callback: (...any) -> ...any, ...: any): (boolean, ...any)
	return xpcall(callback, makeErrorHandler(traceback), ...)
end

local Promise = {}
Promise.__index = Promise

export type Promise<T> = setmetatable<ClassType<T>, typeof(Promise)>

function Promise.new<T>(
	executor: (
		resolve: (...any) -> (),
		reject: (any) -> (),
		onCancel: ((() -> ())?) -> boolean
	) -> ()
): Promise<T>
	-- Capturing stack trace at the moment of creation.
	local traceback = debug.traceback(nil, 2)

	local self = setmetatable({}, Promise) :: Promise<T>
	self._status = Status.Started
	self._values = nil
	self._valuesLength = -1
	self._reason = nil
	self._fulfilledCallbacks = {}
	self._rejectedCallbacks = {}
	self._cancellationHook = nil
	self._parent = nil
	self._consumers = {}

	local function resolve(...)
		-- A promise can only be settled once. Ignore if not 'Started'.
		if self._status ~= Status.Started then
			return
		end

		local n = select("#", ...)
		self._status = Status.Resolved
		self._values = { ... }
		self._valuesLength = n

		-- We clear all callbacks after firing to free up memory.
		for _, callback in ipairs(self._fulfilledCallbacks) do
			task.spawn(callback, ...)
		end
		table.clear(self._fulfilledCallbacks)
		table.clear(self._rejectedCallbacks)
	end

	local function reject(reason: any)
		if self._status ~= Status.Started then
			return
		end

		self._status = Status.Rejected
		self._reason = reason

		for _, callback in ipairs(self._rejectedCallbacks) do
			task.spawn(callback, reason)
		end
		table.clear(self._fulfilledCallbacks)
		table.clear(self._rejectedCallbacks)
	end

	local function onCancel(cancellationHook: (() -> ())?): boolean
		if cancellationHook then
			if self._status == Status.Cancelled then
				task.spawn(cancellationHook)
			else
				self._cancellationHook = cancellationHook
			end
		end

		return self._status == Status.Cancelled
	end

	task.spawn(function()
		local success, result = runExecutor(traceback, function()
			executor(resolve, reject, onCancel)
		end)

		-- If the executer function itself errors (not an async rejection), we
		-- must reject the promise.
		if not success then
			reject(result)
		end
	end)

	return self
end

--[[
    Helper function to safely execute a handler and pass the result to the next promise in the chain.
]]
local function createChainedCallback<T>(
	traceback: string,
	handler: (...any) -> T | Promise<T>,
	resolve: (T) -> (),
	reject: (any) -> ()
): (...any) -> ()
	return function(...)
		-- Safely execute the user-provided success or failure handler.
		local success, result = runExecutor(traceback, handler, ...)

		if success then
			-- If the handler returns another promise, we must wait for it to settle
			-- before resolving the current link in tha chain.
			if typeof(result) == "table" and getmetatable(result) == Promise then
				(result :: Promise<T>):andThen(resolve, reject)
			else
				-- Otherwise, just resolve with the returned value.
				resolve(result)
			end
		else
			-- If the handler itself errors, reject the next promise in the chain.
			reject(result)
		end
	end
end

function Promise.andThen(
	self: Promise<any>,
	onFulfilled: ((...any) -> any?)?,
	onRejected: ((any) -> any?)?
): Promise<any>
	if self._status == Status.Cancelled then
		local p = Promise.new(function() end)
		p:cancel()
		return p
	end

	-- Mark this promise as "handled" to revent unhandled rejection warnings.
	if onRejected then
		self._unhandledRejection = false
	end

	-- Cature the traceback for creating the next link in the chain.
	local traceback = debug.traceback(nil, 2)

	-- Create the next promise in the chain. It starts in a "Started" state.
	-- This new promise will only settle when our current promise ('self') settles.
	local nextPromise = Promise.new(function(resolve, reject)
		local successCallback = if onFulfilled
			then createChainedCallback(traceback, onFulfilled, resolve, reject)
			else resolve

		local failureCallback = if onRejected
			then createChainedCallback(traceback, onRejected, resolve, reject)
			else reject

		if self._status == Status.Started then
			-- If the current promise is still running, queue these callbacks.
			-- They will be executed later when 'self' resolved or rejects.
			table.insert(self._fulfilledCallbacks, successCallback)
			table.insert(self._rejectedCallbacks, failureCallback)
		elseif self._status == Status.Resolved and self._values then
			-- If the current promise has already suceeded, schedule the success
			-- callback to run on the next frame.
			task.spawn(successCallback, unpack(self._values, 1, self._valuesLength))
		elseif self._status == Status.Rejected and self._values then
			-- If the current promise has already failed, schedule the failure callback.
			task.spawn(failureCallback, unpack(self._values, 1, self._valuesLength))
		end
	end)

	nextPromise._parent = self
	self._consumers[nextPromise] = true

	return nextPromise
end

function Promise.cancel(self: Promise<any>)
	if self._status ~= Status.Started then
		return
	end

	self._status = Status.Cancelled

	if self._cancellationHook then
		task.spawn(self._cancellationHook)
	end

	-- Propagate cancellation DOWN the chain to consumers
	for consumer, _ in self._consumers do
		(consumer :: Promise<any>):cancel()
	end

	table.clear(self._fulfilledCallbacks)
	table.clear(self._rejectedCallbacks)
end

-- Shorthand for :andThen(nil, onRejected)
function Promise.catch(self: Promise<any>, onRejected: (any) -> ()): Promise<any>
	return self:andThen(nil, onRejected)
end

function Promise.finally(self: Promise<any>, onFinally: (() -> ())?): Promise<any>
	if not onFinally then
		return self -- If no handler, just return the original promise
	end

	self._unhandledRejection = false -- A `:finally` counts as handling a rejection.
	local traceback = debug.traceback(nil, 2)

	return Promise.new(function(resolve: (...any) -> (), reject: (any) -> ())
		-- This callback runs regardless of the outcome of 'self'.
		local function finallyCallback()
			local success, result = runExecutor(traceback, onFinally)

			if not success then
				-- If the finally handler itself errors, the entire chain must reject.
				reject(result)
				return
			end

			-- Helper function to forward the original promise's settlement.
			local function passThroughOriginalOutcome()
				if self._status == Status.Resolved and self._values then
					resolve(unpack(self._values, 1, self._valuesLength))
				elseif self._status == Status.Rejected and self._values then
					reject(unpack(self._values, 1, self._valuesLength))
				else
					-- This could happen if the promise was cancelled or resolved with no values.
					-- We resolve with no value to signal the chain can continue.
					resolve()
				end
			end

			-- If the finally handler returnss a promise, wait for it.
			if typeof(result) == "table" and getmetatable(result) == Promise then
				(result :: Promise<any>):andThen(
					passThroughOriginalOutcome,
					reject -- If the returned promise rejects, the whole chain rejects.
				)
			else
				-- If the handler was a simple function, we can immediately pass the original outcome.
				passThroughOriginalOutcome()
			end
		end

		-- Hook into the original promise's settlement.
		if self._status == Status.Started then
			table.insert(self._fulfilledCallbacks, finallyCallback)
			table.insert(self._rejectedCallbacks, finallyCallback)
		else
			-- Already settled, run immediately.
			task.spawn(finallyCallback)
		end
	end)
end

-- Helper function to create an already-resolved promise
function Promise.resolve<T>(value: T): Promise<T>
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

-- Helper function to create an already-rejected promise
function Promise.reject(reason: any): Promise<any>
	return Promise.new(function(_, reject)
		reject(reason)
	end)
end

--[[
    Accepts an array of Promises and returns a new promise that:
    - Resolves with a table of all resolved values after all input promises resolve.
    - Rejects is ANY input promise rejects.
]]
function Promise.all<T>(promises: { Promise<T> }): Promise<{ T }>
	local traceback = debug.traceback(nil, 2)

	if typeof(promises) ~= "table" then
		error(`Promise.all expects a table of promises, got: {typeof(promises)}`, 2)
	end

	-- Edge case handling of an empty table being passed.
	if #promises == 0 then
		return Promise.resolve({} :: { any })
	end

	return Promise.new(function(resolve: ({ T }) -> (), reject, onCancel)
		local resolvedValues: { T } = {}
		local promisesRemaining = #promises

		-- Cancellaion proagation
		onCancel(function()
			for _, promise in ipairs(promises :: { Promise<T> }) do
				promise:cancel()
			end
		end)

		for index, promise in ipairs(promises) do
			-- Ensure all inputs are valid promises
			if typeof(promise) ~= "table" or getmetatable(promise) ~= Promise then
				-- We reject the main promise, not error, to keep behavior async
				reject(PromiseError.new({
					error = `Value at index {index} is not a promise.`,
					kind = PromiseError.Kind.ExecutionError,
					trace = traceback,
				}))
				return
			end

			local function onFulfilled(value)
				resolvedValues[index] = value
				promisesRemaining -= 1

				-- If this was the last promise to resolve, resolve the main promise
				if promisesRemaining <= 0 then
					resolve(resolvedValues)
				end
			end

			(promise :: Promise<T>):andThen(
				onFulfilled,
				reject -- If any promise rejects, the entire .all() rejects immediately.
			)
		end
	end) :: Promise<{ T }>
end

--[[
    Accepts an array of Promises and returns a new promise that:
    - Resolves as soon as the FIRST input promise resolves.
    - Rejects as soon as the FIRST input promise rejects.
]]
function Promise.race<T>(promises: { Promise<T> }): Promise<T>
	local traceback = debug.traceback(nil, 2)

	if typeof(promises) ~= "table" then
		error(`Promise.race expects a table of promises, got: {typeof(promises)}`, 2)
	end

	return Promise.new(function(resolve: (T) -> (), reject, onCancel)
		local isSettled = false

		onCancel(function()
			for _, promise in ipairs(promises :: { Promise<T> }) do
				promise:cancel()
			end
		end)

		for index, promise in ipairs(promises) do
			if typeof(promise) ~= "table" or getmetatable(promise) ~= Promise then
				reject(PromiseError.new({
					error = `Value at index {index} is not a promise.`,
					kind = PromiseError.Kind.ExecutionError,
					trace = traceback,
				}))
				return
			end

			local function onFulfilled(value)
				if not isSettled then
					isSettled = true
					resolve(value)
				end
			end

			local function onRejected(err)
				if not isSettled then
					isSettled = true
					reject(err)
				end
			end

			(promise :: Promise<T>):andThen(onFulfilled, onRejected)
		end
	end) :: Promise<T>
end

--[[
    Returns a Promise that resolves after the specified number of seconds.
    Hooks into the cancellation pipeline to physically cancel the scheduled task
    if the Promise is cancelled before the delay finishes.
]]
function Promise.delay(seconds: number): Promise<number>
	return Promise.new(function(resolve, _, onCancel)
		-- Schedule the resolution and capture the running thread
		local thread = task.delay(seconds, function()
			resolve(seconds)
		end)

		-- If this Promise is cancelled, kill the scheduled task immediately
		onCancel(function()
			task.cancel(thread)
		end)
	end) :: Promise<number>
end

--[[
	Yields the current thread until the Promise is settled.
	
	@return The resolved values, or errors if the Promise was rejected.
]]
function Promise.await(self: Promise<any>): ...any
	-- Awaiting counts as handling a rejection
	self._unhandledRejection = false

	if self._status == Status.Started then
		local thread = coroutine.running()

		-- Hook into the promise completion to resume this thread
		self:finally(function()
			task.spawn(thread)
		end)

		-- Yield execution until finally() calles task.spawn
		coroutine.yield()
	end

	if self._status == Status.Resolved and self._values then
		return unpack(self._values, 1, self._valuesLength)
	elseif self._status == Status.Rejected then
		-- Throw the rejection reason up the call stack
		error(tostring(self._reason), 2)
	end

	-- Return nothing if Cancelled
	return
end

return {
	new = Promise.new,
	all = Promise.all,
	race = Promise.race,
	resolve = Promise.resolve,
	reject = Promise.reject,
	delay = Promise.delay,
	await = Promise.await,
}
