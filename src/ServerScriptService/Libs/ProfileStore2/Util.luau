--!strict
--[[
	Contains generic table and error classification utilities used by the ProfileStore system.
]]

const NON_RETRYABLE_ERROR_PATTERNS = {
	"101:",
	"102:",
	"103:",
	"104:",
	"105:",
	"106:",
	"107:",
	"108:",
	"Cannot store",
	"not allowed in DataStore",
	"UTF%-8",
	"exceeds the .* limit",
	"not valid",
	"tables cannot be cyclic",
}

local Util = {}

--[[
	Recursively creates a deep copy of a value, ensuring that nested tables
	and buffers are copied instead of referenced.
]]
function Util.DeepCopyTable<T>(original: T): T
	if typeof(original) == "buffer" then
		const sourceBuffer = original :: any
		const length = buffer.len(sourceBuffer)
		const clonedBuffer = buffer.create(length)
		buffer.copy(clonedBuffer, 0, sourceBuffer)
		return clonedBuffer :: any
	end

	if typeof(original) ~= "table" then
		return original :: T
	end

	local copy: { [any]: any } = {}
	for key, value in original :: { [any]: any } do
		if typeof(value) == "table" or typeof(value) == "buffer" then
			copy[key] = Util.DeepCopyTable(value)
		else
			copy[key] = value
		end
	end

	return copy :: any
end

--[[
	Recursively fills in missing string-keyed fields in a `target` table from a `template` table.
	This is used to safely update saved data with new default values.
]]
function Util.ReconcileTable(target: { [string]: any }, template: { [string]: any })
	for key, templateValue in template do
		if typeof(key) ~= "string" then
			continue
		end

		local targetValue = target[key]
		if targetValue == nil then
			if typeof(templateValue) == "table" or typeof(templateValue) == "buffer" then
				target[key] = Util.DeepCopyTable(templateValue)
			else
				target[key] = templateValue
			end
		elseif typeof(targetValue) == "table" and typeof(templateValue) == "table" then
			-- If the key exists in both and both are tables, recurse.
			Util.ReconcileTable(targetValue, templateValue)
		end
	end
end

--[[
	Determines whether a DataStore API error message represents a transient error
	(such as throttling, network failure, or HTTP 5xx) that can succeed on retry,
	versus a permanent validation/serialization error (such as >4MB payload,
	invalid UTF-8, cyclic tables, or disallowed types).
]]
function Util.IsTransientDataStoreError(errorMessage: string): boolean
	for _, pattern in NON_RETRYABLE_ERROR_PATTERNS do
		if string.find(errorMessage, pattern) ~= nil then
			return false
		end
	end

	return true
end

--[[
	Waits up to `duration` seconds, waking early if `shouldAbort()` returns true.
	Returns true if aborted early, or false if the full duration elapsed.
]]
function Util.WaitInterruptible(duration: number, shouldAbort: () -> boolean): boolean
	const deadline = os.clock() + duration
	while os.clock() < deadline do
		if shouldAbort() then
			return true
		end
		task.wait()
	end

	return shouldAbort()
end

return table.freeze(Util)
