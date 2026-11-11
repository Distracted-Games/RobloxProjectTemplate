--!strict

const Connections = require("./Connections")
const LeanPromise = require("../Libs/LeanPromise")

type Promise<T> = LeanPromise.Promise<T>

--[[
	Returns a Promise that resolves with the first child of `instance` for which `refine`
	returns a non-nil value. Existing children are checked first, then each added child.

	`refine` is the single source of truth for both the match and the resolved type, so the
	call site needs no casts and the check can never disagree with the type. it must be
	synchronous and non-yielding:

		waitForChildWhereAsync(character, function(child: Instance): Humanoid?
			return if child:IsA("Humanoid") then child else nil
		end):andThen(function(humanoid)
			-- `humanoid` is a Humanoid here.
		end)

	Rejects if the optional timeout elapses, `instance` is destroyed, or `refine` throws while
	inspecting an added child. Cancelling the Promise disconnects everything it created.

	***Note:*** Can be used to match more than just a class:
	
		-- By name and class together
		waitForChildWhereAsync(tool, function(child: Instance): BasePart?
			return if child:IsA("BasePart") and child.Name == "Handle" then child else nil
		end)

		-- By attribute
		waitForChildWhereAsync(map, function(child: Instance): Model?
			return if child:IsA("Model") and child:GetAttribute("IsSpawn") == true then child else nil
		end)
]]
local function waitForChildWhereAsync<T>(
	instance: Instance,
	refine: (child: Instance) -> T?,
	timeout: number?
): Promise<T>
	for _, child in instance:GetChildren() do
		const ok, match = pcall(refine, child)

		if not ok then
			return LeanPromise.reject(match)
		end

		if match ~= nil then
			return LeanPromise.resolve(match)
		end
	end

	if timeout ~= nil and timeout <= 0 then
		return LeanPromise.reject(`No matching child of {instance:GetFullName()} (timeout was {timeout}s).`)
	end

	-- The executor runs synchronously up to its first yield, so no child can be added between
	-- the scan above and the ChildAdded connection below.
	return LeanPromise.new(function(resolve, reject, onCancel)
		const connections = Connections.new()
		local timeoutThread: thread? = nil

		local function cleanup()
			connections:DisconnectAll()

			-- The timeout callback also calls this from `timeoutThread`; cancelling the running
			-- thread would stop it before it can reject.
			if
				timeoutThread
				and coroutine.running() ~= timeoutThread
				and coroutine.status(timeoutThread) == "suspended"
			then
				task.cancel(timeoutThread)
			end
			timeoutThread = nil
		end

		onCancel(cleanup)

		connections:Add(instance.ChildAdded:Connect(function(addedChild: Instance)
			const ok, result = pcall(refine, addedChild)
			if not ok then
				cleanup()
				reject(result)
				return
			end

			if result == nil then
				return
			end

			cleanup()
			resolve(result)
		end))

		connections:Add(instance.Destroying:Connect(function()
			cleanup()
			reject(`{instance:GetFullName()} was destroyed while waiting for a matching child.`)
		end))

		if timeout ~= nil then
			timeoutThread = task.delay(timeout, function()
				cleanup()
				reject(`Timed out after {timeout}s waiting for a matching child of {instance:GetFullName()}.`)
			end)
		end
	end)
end

return waitForChildWhereAsync
