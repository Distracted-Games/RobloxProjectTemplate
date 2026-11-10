--!strict

const TableUtil = {}

const ARRAY_SENTINEL = "__array" :: "__array"
const DELETE = "\0__DIFF_DELETE__\0" :: "\0__DIFF_DELETE__\0"

TableUtil.ARRAY_SENTINEL = ARRAY_SENTINEL
TableUtil.DELETE = DELETE

export type Delta = {
	[any]: any,
}

export type DiffResult = Delta | typeof(DELETE)

local function isEmptyTable(tbl: { [any]: any }): boolean
	return next(tbl) == nil
end

local function isNonEmptyDenseArray(tbl: { [any]: any }): boolean
	local count = 0
	local maxKey = 0

	for key in tbl do
		if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
			return false
		end

		count += 1
		if key > maxKey then
			maxKey = key
		end
	end

	return count > 0 and count == maxKey
end

local function deepEqual(left: any, right: any): boolean
	if left == right then
		return true
	end

	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end

	for key, leftValue in left :: { [any]: any } do
		if not deepEqual(leftValue, (right :: { [any]: any })[key]) then
			return false
		end
	end

	for key in right :: { [any]: any } do
		if (left :: { [any]: any })[key] == nil then
			return false
		end
	end

	return true
end

function TableUtil.DeepClone<T>(value: T): T
	if type(value) ~= "table" then
		return value :: T
	end

	local result = {}

	for key, child in value :: { [any]: any } do
		result[TableUtil.DeepClone(key)] = TableUtil.DeepClone(child)
	end

	return result :: T
end

local function cloneUnwrappingDeltas(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local tbl = value :: { [any]: any }
	if tbl[ARRAY_SENTINEL] ~= nil then
		return TableUtil.DeepClone(tbl[ARRAY_SENTINEL])
	end

	local result = {}
	for key, child in tbl do
		if child ~= DELETE then
			result[TableUtil.DeepClone(key)] = cloneUnwrappingDeltas(child)
		end
	end

	return result
end

local function _diff(original: { [any]: any }, updated: { [any]: any }): DiffResult?
	const originalIsArray = isNonEmptyDenseArray(original)
	const updatedIsArray = isNonEmptyDenseArray(updated)

	if originalIsArray and updatedIsArray then
		if deepEqual(original, updated) then
			return nil
		end
		return {
			[ARRAY_SENTINEL] = TableUtil.DeepClone(updated),
		}
	end

	if isEmptyTable(original) and updatedIsArray then
		return {
			[ARRAY_SENTINEL] = TableUtil.DeepClone(updated),
		}
	end

	if originalIsArray and isEmptyTable(updated) then
		return {
			[ARRAY_SENTINEL] = {},
		}
	end

	local deltas: Delta = {}
	local hasChanges = false

	for key, newValue in updated do
		const oldValue = original[key]

		if type(oldValue) == "table" and type(newValue) == "table" then
			const nestedDeltas = _diff(oldValue, newValue)
			if nestedDeltas then
				deltas[key] = nestedDeltas
				hasChanges = true
			end
		elseif oldValue ~= newValue then
			deltas[key] = if type(newValue) == "table" then TableUtil.DeepClone(newValue) else newValue
			hasChanges = true
		end
	end

	for key in original do
		if updated[key] == nil then
			deltas[key] = DELETE
			hasChanges = true
		end
	end

	return if hasChanges then deltas else nil
end

function TableUtil.DeepFreeze<T>(tbl: T): T
	if type(tbl) ~= "table" or table.isfrozen(tbl) then
		return tbl
	end

	for _, value in tbl :: any do
		if type(value) == "table" then
			TableUtil.DeepFreeze(value)
		end
	end

	return table.freeze(tbl)
end

function TableUtil.DeepFreezeClone<T>(value: T): T
	return TableUtil.DeepFreeze(TableUtil.DeepClone(value))
end

function TableUtil.Diff(original: { [any]: any }, updated: { [any]: any }): Delta?
	const deltas = _diff(original, updated)

	if deltas == nil or deltas == DELETE then
		return nil
	end

	return deltas
end

--[[
	Recursively applies a delta table to a target table in-place, unwrapping
	atomic `__array` replacement envelopes produced by `TableUtil.Diff`.
]]
function TableUtil.Apply<T>(target: T, delta: Delta): T
	const targetMap = target :: any
	if delta[ARRAY_SENTINEL] ~= nil then
		table.clear(targetMap)
		const replacement = delta[ARRAY_SENTINEL]
		if type(replacement) == "table" then
			for index, item in replacement :: { [any]: any } do
				targetMap[index] = TableUtil.DeepClone(item)
			end
		end
		return target
	end

	for key, deltaValue in delta do
		if deltaValue == DELETE then
			targetMap[key] = nil
		elseif type(deltaValue) == "table" and deltaValue[ARRAY_SENTINEL] ~= nil then
			targetMap[key] = TableUtil.DeepClone(deltaValue[ARRAY_SENTINEL])
		elseif type(deltaValue) == "table" and type(targetMap[key]) == "table" then
			TableUtil.Apply(targetMap[key], deltaValue)
		elseif type(deltaValue) == "table" then
			targetMap[key] = cloneUnwrappingDeltas(deltaValue)
		else
			targetMap[key] = deltaValue
		end
	end

	return target
end

function TableUtil.IsDeleted(value: any): boolean
	return value == DELETE
end

return TableUtil
