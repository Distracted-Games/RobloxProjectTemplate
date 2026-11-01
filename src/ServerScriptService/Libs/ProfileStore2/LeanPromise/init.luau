--!strict
--[[
	LeanPromise
	@author: DistractedGames
	@version: 1.3.0

	Copyright (c) 2019 Eryn L. K.
	https://github.com/evaera/roblox-lua-promise

	This library is a derivative work of the original Promise.lua library by evaera,
	licensed under the MIT License.

	---

	Copyright (c) 2026 Distracted Games

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

	LeanPromise is a refactored derivative of the Promise.lua library by evaera,
	architected to align with modern Luau idioms and a strict, type-safe workflow.
]]

const PromiseError = require("@self/PromiseError")

const Status = table.freeze({
	Started = "Started" :: "Started",
	Resolved = "Resolved" :: "Resolved",
	Rejected = "Rejected" :: "Rejected",
	Cancelled = "Cancelled" :: "Cancelled",
})

export type PromiseError = PromiseError.PromiseError
export type StatusType = "Started" | "Resolved" | "Rejected" | "Cancelled"

type PrototypeMetatable = {}

type AnyPromiseData = {
	_status: StatusType,
	_values: { any }?,
	_valuesLength: number,
	_unhandledRejection: boolean,
	_parent: any,
	_reason: any,
	_consumers: { [any]: boolean },
	_fulfilledCallbacks: { (...any) -> () },
	_rejectedCallbacks: { (any) -> () },
	_cancellationHook: (() -> ())?,
	_thread: thread?,
	_source: string,
	read andThen: (
		self: AnyPromise,
		onFulfilled: ((value: any) -> ...any)?,
		onRejected: ((reason: any) -> ...any)?
	) -> AnyPromise,
	read catch: (self: AnyPromise, onRejected: (reason: any) -> ...any) -> AnyPromise,
	read finally: (self: AnyPromise, onFinally: ((status: StatusType) -> ...any)?) -> AnyPromise,
	read cancel: (self: AnyPromise) -> (),
	read getStatus: (self: AnyPromise) -> StatusType,
	read await: (self: AnyPromise) -> any,
}

export type AnyPromise = setmetatable<AnyPromiseData, PrototypeMetatable>

type PromiseData<T> = {
	_status: StatusType,
	_values: { any }?,
	_valuesLength: number,
	_unhandledRejection: boolean,
	_parent: any,
	_reason: any,
	_consumers: { [any]: boolean },
	_fulfilledCallbacks: { (...any) -> () },
	_rejectedCallbacks: { (any) -> () },
	_cancellationHook: (() -> ())?,
	_thread: thread?,
	_source: string,
	read andThen: (
		self: Promise<T>,
		onFulfilled: ((value: T) -> ...any)?,
		onRejected: ((reason: any) -> ...any)?
	) -> AnyPromise,
	read catch: (self: Promise<T>, onRejected: (reason: any) -> ...any) -> AnyPromise,
	read finally: (self: Promise<T>, onFinally: ((status: StatusType) -> ...any)?) -> Promise<T>,
	read cancel: (self: Promise<T>) -> (),
	read getStatus: (self: Promise<T>) -> StatusType,
	read await: (self: Promise<T>) -> T,
}

export type Promise<T = any> = setmetatable<PromiseData<T>, PrototypeMetatable>

type InternalExecutor = (
	resolve: (...any) -> (),
	reject: (any) -> (),
	onCancel: (cancellationHook: (() -> ())?) -> boolean
) -> ()

const PromisePrototype: { [string]: any } = {}
PromisePrototype.__index = PromisePrototype

const Promise = {}

--[[
	Creates an xpcall error handler that preserves PromiseError instances and custom
	table error objects while wrapping primitive/string/nil errors in a PromiseError.
]]
local function makeErrorHandler(traceback: string): (err: any) -> any
	return function(err: any): any
		if PromiseError.is(err) or typeof(err) == "table" then
			return err
		end
		return PromiseError.new({
			error = err,
			kind = PromiseError.Kind.ExecutionError,
			trace = debug.traceback(tostring(err), 2),
			context = `Promise created at:\n{traceback}`,
		})
	end
end

--[[
	Safely invokes a callback with xpcall and captures its return values or error reason.
]]
local function runExecutor(traceback: string, callback: (...any) -> ...any, ...: any): (boolean, ...any)
	return xpcall(callback, makeErrorHandler(traceback), ...)
end

function Promise.is(value: any): boolean
	return typeof(value) == "table" and getmetatable(value) == PromisePrototype
end

local function dequeueCallbacks(target: AnyPromise, onFulfilled: ((...any) -> ())?, onRejected: ((any) -> ())?)
	if target._status ~= Status.Started then
		return
	end

	if onFulfilled then
		const fulfilledIndex = table.find(target._fulfilledCallbacks, onFulfilled)
		if fulfilledIndex then
			table.remove(target._fulfilledCallbacks, fulfilledIndex)
		end
	end

	if onRejected then
		const rejectedIndex = table.find(target._rejectedCallbacks, onRejected)
		if rejectedIndex then
			table.remove(target._rejectedCallbacks, rejectedIndex)
		end
	end
end

local function attachCancelHook(target: AnyPromise, hook: () -> ())
	if target._status == Status.Cancelled then
		task.spawn(hook)
		return
	end

	const previousHook = target._cancellationHook
	if previousHook then
		target._cancellationHook = function()
			previousHook()
			hook()
		end
	else
		target._cancellationHook = hook
	end
end

local function finalizePromise(self: AnyPromise)
	const currentParent = self._parent
	if currentParent then
		currentParent._consumers[self] = nil
		self._parent = nil
	end

	table.clear(self._fulfilledCallbacks)
	table.clear(self._rejectedCallbacks)
	table.clear(self._consumers)
	self._cancellationHook = nil
	self._thread = nil
end

local function scheduleUnhandledRejectionCheck(self: AnyPromise)
	self._unhandledRejection = true
	task.defer(function()
		if self._unhandledRejection then
			warn(`Unhandled Promise rejection:\n\n{tostring(self._reason)}\n\n{self._source}`)
		end
	end)
end

local function rejectPromise(self: AnyPromise, reason: any)
	if self._status ~= Status.Started then
		return
	end

	self._status = Status.Rejected
	self._reason = reason

	const callbacks = self._rejectedCallbacks
	self._rejectedCallbacks = {}
	const hadListeners = #callbacks > 0
	finalizePromise(self)

	if not hadListeners then
		scheduleUnhandledRejectionCheck(self)
	end

	for _, callback in callbacks do
		task.spawn(callback, reason)
	end
end

local function resolvePromise(self: AnyPromise, ...: any)
	if self._status ~= Status.Started then
		return
	end

	if Promise.is((...)) then
		if select("#", ...) > 1 then
			const warnMsg = "Promise resolved with multiple values where the first is a Promise; "
				.. "extra values ignored."
			warn(`{warnMsg}\n{self._source}`)
		end

		const chainedPromise = (...) :: AnyPromise
		if chainedPromise == self then
			rejectPromise(
				self,
				PromiseError.new({
					error = "TypeError: A Promise cannot be resolved with itself.",
					kind = PromiseError.Kind.ExecutionError,
					context = `Promise created at:\n{self._source}`,
				})
			)
			return
		end

		chainedPromise._unhandledRejection = false

		if chainedPromise._status == Status.Cancelled then
			self:cancel()
			return
		elseif chainedPromise._status == Status.Resolved then
			const values = chainedPromise._values or {}
			resolvePromise(self, table.unpack(values, 1, chainedPromise._valuesLength))
			return
		elseif chainedPromise._status == Status.Rejected then
			rejectPromise(self, chainedPromise._reason)
			return
		end

		-- Adopt the pending inner Promise as our active parent for bidirectional cancellation.
		const previousParent = self._parent
		if previousParent then
			previousParent._consumers[self] = nil
		end
		self._parent = chainedPromise
		chainedPromise._consumers[self] = true

		local function onAdoptedFulfilled(...: any)
			resolvePromise(self, ...)
		end

		local function onAdoptedRejected(reason: any)
			rejectPromise(self, reason)
		end

		table.insert(chainedPromise._fulfilledCallbacks, onAdoptedFulfilled)
		table.insert(chainedPromise._rejectedCallbacks, onAdoptedRejected)

		attachCancelHook(self, function()
			dequeueCallbacks(chainedPromise, onAdoptedFulfilled, onAdoptedRejected)
		end)

		return
	end

	self._status = Status.Resolved
	self._valuesLength = select("#", ...)
	self._values = { ... }

	const callbacks = self._fulfilledCallbacks
	self._fulfilledCallbacks = {}
	finalizePromise(self)

	for _, callback in callbacks do
		task.spawn(callback, ...)
	end
end

local function createInternalPromise(traceback: string, executor: InternalExecutor?, parent: AnyPromise?): any
	if parent ~= nil and not Promise.is(parent) then
		error("Argument #3 to createInternalPromise must be a Promise or nil", 2)
	end

	const self = (setmetatable({}, PromisePrototype) :: any) :: AnyPromise
	self._status = Status.Started
	self._values = nil
	self._valuesLength = -1
	self._unhandledRejection = false
	self._reason = nil
	self._fulfilledCallbacks = {}
	self._rejectedCallbacks = {}
	self._cancellationHook = nil
	self._parent = nil
	self._consumers = {}
	self._thread = nil
	self._source = traceback

	if parent and parent._status == Status.Started then
		self._parent = parent
		parent._consumers[self] = true
	end

	if not executor then
		return self
	end

	local function resolve(...: any)
		resolvePromise(self, ...)
	end

	local function reject(reason: any)
		rejectPromise(self, reason)
	end

	local function onCancel(cancellationHook: (() -> ())?): boolean
		if cancellationHook then
			attachCancelHook(self, cancellationHook)
		end

		return self._status == Status.Cancelled
	end

	local threadCompleted = false
	const executorThread = task.spawn(function()
		const success, err = runExecutor(traceback, executor, resolve, reject, onCancel)
		threadCompleted = true
		self._thread = nil
		if not success then
			rejectPromise(self, err)
		end
	end)

	if not threadCompleted and self._status == Status.Started then
		self._thread = executorThread
	end

	return self
end

function Promise.new<T>(executor: (
	resolve: ((value: T) -> ()) & ((...any) -> ()),
	reject: (reason: any) -> (),
	onCancel: (cancellationHook: (() -> ())?) -> boolean
) -> ()): Promise<T>
	if typeof(executor) ~= "function" then
		error(`Promise.new expects a function executor, got: {typeof(executor)}`, 2)
	end

	const traceback = debug.traceback(nil, 2)
	return createInternalPromise(traceback, executor :: InternalExecutor, nil)
end

function PromisePrototype.getStatus(self: AnyPromise): StatusType
	return self._status
end

function PromisePrototype.andThen(
	self: AnyPromise,
	onFulfilled: ((value: any) -> ...any)?,
	onRejected: ((reason: any) -> ...any)?
): AnyPromise
	if onFulfilled ~= nil and typeof(onFulfilled) ~= "function" then
		error(`Promise:andThen expects a function for onFulfilled, got: {typeof(onFulfilled)}`, 2)
	end
	if onRejected ~= nil and typeof(onRejected) ~= "function" then
		error(`Promise:andThen expects a function for onRejected, got: {typeof(onRejected)}`, 2)
	end

	const traceback = debug.traceback(nil, 2)
	self._unhandledRejection = false

	if self._status == Status.Cancelled then
		const cancelled = createInternalPromise(traceback, nil, nil)
		cancelled:cancel()
		return cancelled
	end

	return createInternalPromise(traceback, function(resolve, reject, onCancel)
		local function invokeHandler(handler: (...any) -> ...any, ...: any)
			const results = table.pack(runExecutor(traceback, handler, ...))
			if not results[1] then
				reject(results[2])
				return
			end
			resolve(table.unpack(results, 2, results.n))
		end

		local successCallback: (...any) -> () = resolve
		if onFulfilled then
			const handler = onFulfilled
			successCallback = function(...: any)
				invokeHandler(handler, ...)
			end
		end

		local failureCallback: (any) -> () = reject
		if onRejected then
			const handler = onRejected
			failureCallback = function(reason: any)
				invokeHandler(handler, reason)
			end
		end

		if self._status == Status.Started then
			table.insert(self._fulfilledCallbacks, successCallback)
			table.insert(self._rejectedCallbacks, failureCallback)

			onCancel(function()
				dequeueCallbacks(self, successCallback, failureCallback)
			end)
		elseif self._status == Status.Resolved then
			const values = self._values or {}
			successCallback(table.unpack(values, 1, self._valuesLength))
		elseif self._status == Status.Rejected then
			failureCallback(self._reason)
		end
	end, self)
end

function PromisePrototype.cancel(self: AnyPromise)
	if self._status ~= Status.Started then
		return
	end

	self._status = Status.Cancelled

	if self._cancellationHook then
		const hook = self._cancellationHook
		self._cancellationHook = nil
		task.spawn(hook)
	end

	const executorThread = self._thread
	self._thread = nil
	if executorThread and executorThread ~= coroutine.running() then
		if coroutine.status(executorThread) == "suspended" then
			pcall(task.cancel, executorThread)
		end
	end

	const parent = self._parent
	if parent then
		parent._consumers[self] = nil
		self._parent = nil
		if next(parent._consumers) == nil then
			parent:cancel()
		end
	end

	const consumersToCancel: { AnyPromise } = {}
	for consumer in self._consumers do
		table.insert(consumersToCancel, consumer)
	end
	table.clear(self._consumers)

	for _, consumer in consumersToCancel do
		consumer._parent = nil
		consumer:cancel()
	end

	table.clear(self._fulfilledCallbacks)
	table.clear(self._rejectedCallbacks)
end

function PromisePrototype.catch(self: AnyPromise, onRejected: (reason: any) -> ...any): AnyPromise
	if typeof(onRejected) ~= "function" then
		error(`Promise:catch expects a function for onRejected, got: {typeof(onRejected)}`, 2)
	end
	return self:andThen(nil, onRejected)
end

function PromisePrototype.finally(self: AnyPromise, onFinally: ((status: StatusType) -> ...any)?): AnyPromise
	if onFinally == nil then
		return self
	end
	if typeof(onFinally) ~= "function" then
		error(`Promise:finally expects a function for onFinally, got: {typeof(onFinally)}`, 2)
	end

	const traceback = debug.traceback(nil, 2)
	self._unhandledRejection = false

	local handlerRan = false
	local function runFinallyOnce(status: StatusType): (boolean, any)
		if handlerRan then
			return true, nil
		end
		handlerRan = true
		const ok, result = runExecutor(traceback, onFinally, status)
		return ok, result
	end

	if self._status == Status.Cancelled then
		const cancelled = createInternalPromise(traceback, nil, nil)
		cancelled:cancel()
		task.spawn(runFinallyOnce, Status.Cancelled)
		return cancelled
	end

	return createInternalPromise(traceback, function(resolve, reject, onCancel)
		local function settleWithOriginalOutcome()
			if self._status == Status.Resolved then
				const values = self._values or {}
				resolve(table.unpack(values, 1, self._valuesLength))
			elseif self._status == Status.Rejected then
				reject(self._reason)
			end
		end

		local function finallyCallback()
			const ok, result = runFinallyOnce(self._status)
			if not ok then
				reject(result)
				return
			end

			if Promise.is(result) then
				const returnedPromise = result :: AnyPromise
				const continuation = returnedPromise:andThen(function()
					if self._status == Status.Resolved then
						const values = self._values or {}
						return table.unpack(values, 1, self._valuesLength)
					elseif self._status == Status.Rejected then
						return Promise.reject(self._reason)
					end
					return nil
				end)
				resolve(continuation)
			else
				settleWithOriginalOutcome()
			end
		end

		if self._status == Status.Started then
			table.insert(self._fulfilledCallbacks, finallyCallback)
			table.insert(self._rejectedCallbacks, finallyCallback)

			onCancel(function()
				dequeueCallbacks(self, finallyCallback, finallyCallback)
				runFinallyOnce(Status.Cancelled)
			end)
		else
			finallyCallback()
		end
	end, self)
end

--[[
	Yields the current thread until the Promise settles.
	Returns the resolved value(s), or throws the rejection reason (or an
	AlreadyCancelled PromiseError if the Promise was cancelled).
]]
function PromisePrototype.await(self: AnyPromise): ...any
	const traceback = debug.traceback(nil, 2)
	self._unhandledRejection = false

	if self._status == Status.Started then
		const callerThread = coroutine.running()
		local resumed = false

		local function resumeCaller()
			if not resumed then
				resumed = true
				if coroutine.status(callerThread) == "suspended" then
					task.spawn(callerThread)
				end
			end
		end

		createInternalPromise(traceback, function(resolve, _, onCancel)
			local function onSettled()
				resolve(nil)
				resumeCaller()
			end

			table.insert(self._fulfilledCallbacks, onSettled)
			table.insert(self._rejectedCallbacks, onSettled)

			onCancel(function()
				dequeueCallbacks(self, onSettled, onSettled)
				resumeCaller()
			end)
		end, self)

		coroutine.yield()
	end

	self._unhandledRejection = false

	if self._status == Status.Resolved then
		const values = self._values or {}
		return table.unpack(values, 1, self._valuesLength)
	elseif self._status == Status.Rejected then
		if self._reason == nil then
			error("Promise rejected with nil.", 2)
		end
		error(self._reason, 0)
	end

	error(
		PromiseError.new({
			error = "Attempted to await a cancelled Promise.",
			kind = PromiseError.Kind.AlreadyCancelled,
			context = `Promise awaited at:\n{traceback}`,
		}),
		2
	)
end

function Promise.resolve<T>(value: T): Promise<T>
	const traceback = debug.traceback(nil, 2)
	if Promise.is(value) then
		return createInternalPromise(traceback, function(resolve)
			resolve(value)
		end, nil)
	end

	const resolved = createInternalPromise(traceback, nil, nil)
	resolved._status = Status.Resolved
	resolved._valuesLength = 1
	resolved._values = { value }
	return resolved
end

function Promise.reject(reason: any): Promise<any>
	const traceback = debug.traceback(nil, 2)
	const rejected = createInternalPromise(traceback, nil, nil)
	rejected._status = Status.Rejected
	rejected._reason = reason
	scheduleUnhandledRejectionCheck(rejected :: AnyPromise)
	return rejected
end

--[[
	Accepts an array of Promises and returns a new Promise that:
	- Resolves with an array of all resolved values once every input Promise resolves.
	- Rejects immediately if any input Promise rejects, cancelling remaining derived consumers.
]]
function Promise.all<T>(promises: { Promise<T> }): Promise<{ T }>
	const traceback = debug.traceback(nil, 2)

	if typeof(promises) ~= "table" then
		error(`Promise.all expects a table of promises, got: {typeof(promises)}`, 2)
	end

	for index, promise in promises do
		if not Promise.is(promise) then
			const errMsg = `Promise.all expects every element to be a Promise, `
				.. `got {typeof(promise)} at index {index}`
			error(errMsg, 2)
		end
	end

	if #promises == 0 then
		return Promise.resolve({} :: { T })
	end

	for _, promise in promises do
		if promise._status == Status.Cancelled then
			const cancelled: Promise<{ T }> = createInternalPromise(traceback, nil, nil)
			cancelled:cancel()
			return cancelled
		end
	end

	local allPromise: Promise<{ T }>
	local shouldCancelSelf = false

	allPromise = createInternalPromise(traceback, function(resolve, reject, onCancel)
		const resolvedValues: { T } = {}
		const derivedPromises: { AnyPromise } = {}
		local promisesRemaining = #promises
		local isSettled = false

		local function cancelDerived()
			for _, derived in derivedPromises do
				derived:cancel()
			end
		end

		onCancel(function()
			isSettled = true
			cancelDerived()
		end)

		for index, promise in promises do
			local function onFulfilled(value: T)
				if isSettled then
					return
				end
				resolvedValues[index] = value
				promisesRemaining -= 1

				if promisesRemaining == 0 then
					isSettled = true
					resolve(resolvedValues)
				end
			end

			local function onRejected(err: any)
				if isSettled then
					return
				end
				isSettled = true
				cancelDerived()
				reject(err)
			end

			const derived = promise:andThen(onFulfilled, onRejected)
			derivedPromises[index] = derived

			attachCancelHook(derived, function()
				if not isSettled then
					isSettled = true
					cancelDerived()
					if allPromise and allPromise._status == Status.Started then
						allPromise:cancel()
					else
						shouldCancelSelf = true
					end
				end
			end)
		end

		if isSettled then
			cancelDerived()
		end
	end, nil)

	if shouldCancelSelf and allPromise._status == Status.Started then
		allPromise:cancel()
	end

	return allPromise
end

--[[
	Accepts an array of Promises and returns a new Promise that settles as soon as
	the first input Promise resolves or rejects, cancelling losing derived consumers.
]]
function Promise.race<T>(promises: { Promise<T> }): Promise<T>
	const traceback = debug.traceback(nil, 2)

	if typeof(promises) ~= "table" then
		error(`Promise.race expects a table of promises, got: {typeof(promises)}`, 2)
	end

	for index, promise in promises do
		if not Promise.is(promise) then
			const errMsg = `Promise.race expects every element to be a Promise, `
				.. `got {typeof(promise)} at index {index}`
			error(errMsg, 2)
		end
	end

	if #promises > 0 then
		local allAlreadyCancelled = true
		for _, promise in promises do
			if promise._status ~= Status.Cancelled then
				allAlreadyCancelled = false
				break
			end
		end
		if allAlreadyCancelled then
			const cancelled: Promise<T> = createInternalPromise(traceback, nil, nil)
			cancelled:cancel()
			return cancelled
		end
	end

	local racePromise: Promise<T>
	local shouldCancelSelf = false

	racePromise = createInternalPromise(traceback, function(resolve, reject, onCancel)
		const derivedPromises: { AnyPromise } = {}
		local isSettled = false
		local cancelledCount = 0

		local function cancelDerived()
			for _, derived in derivedPromises do
				derived:cancel()
			end
		end

		onCancel(function()
			isSettled = true
			cancelDerived()
		end)

		if #promises == 0 then
			return
		end

		for index, promise in promises do
			local function onFulfilled(value: T)
				if isSettled then
					return
				end
				isSettled = true
				cancelDerived()
				resolve(value)
			end

			local function onRejected(err: any)
				if isSettled then
					return
				end
				isSettled = true
				cancelDerived()
				reject(err)
			end

			const derived = promise:andThen(onFulfilled, onRejected)
			derivedPromises[index] = derived

			if derived._status == Status.Cancelled then
				cancelledCount += 1
			else
				attachCancelHook(derived, function()
					cancelledCount += 1
					if cancelledCount == #promises and not isSettled then
						isSettled = true
						if racePromise and racePromise._status == Status.Started then
							racePromise:cancel()
						else
							shouldCancelSelf = true
						end
					end
				end)
			end
		end

		if isSettled then
			cancelDerived()
		elseif cancelledCount == #promises then
			isSettled = true
			shouldCancelSelf = true
		end
	end, nil)

	if shouldCancelSelf and racePromise._status == Status.Started then
		racePromise:cancel()
	end

	return racePromise
end

--[[
	Returns a Promise that resolves with the elapsed duration after the specified
	number of seconds. Cancelling the Promise cancels the underlying scheduled task.
]]
function Promise.delay(seconds: number): Promise<number>
	if typeof(seconds) ~= "number" or seconds ~= seconds then
		error(`Promise.delay expects a valid number of seconds, got: {tostring(seconds)}`, 2)
	end

	const traceback = debug.traceback(nil, 2)
	return createInternalPromise(traceback, function(resolve, _, onCancel)
		const startClock = os.clock()
		const scheduledThread = task.delay(seconds, function()
			resolve(os.clock() - startClock)
		end)

		onCancel(function()
			if coroutine.status(scheduledThread) == "suspended" then
				task.cancel(scheduledThread)
			end
		end)
	end, nil)
end

const awaitMethod: <T>(self: Promise<T>) -> T = PromisePrototype.await :: any

return table.freeze({
	Status = Status,
	Error = PromiseError,
	is = Promise.is,
	new = Promise.new,
	all = Promise.all,
	race = Promise.race,
	resolve = Promise.resolve,
	reject = Promise.reject,
	delay = Promise.delay,
	await = awaitMethod,
})
