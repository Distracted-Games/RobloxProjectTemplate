--!strict

const TableUtil = {}

const DELETE = "\0__DIFF_DELETE__\0" :: "\0__DIFF_DELETE__\0"
TableUtil.DELETE = DELETE

export type Delta = {
	[any]: any,
}

export type DiffResult = Delta | typeof(DELETE)

local function _diff(original: { [any]: any }, updated: { [any]: any }): DiffResult?
	local deltas: Delta = {}
	local hasChanges = false

	for key, newValue in updated do
		local oldValue = original[key]

		if type(oldValue) == "table" and type(newValue) == "table" then
			local nestedDeltas = _diff(oldValue, newValue)
			if nestedDeltas then
				deltas[key] = nestedDeltas
				hasChanges = true
			end
		elseif oldValue ~= newValue then
			deltas[key] = newValue
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

function TableUtil.DeepClone<T>(value: T): T
	if type(value) ~= "table" then
		return value :: T
	end

	local result = {}

	for key, child in (value :: { [any]: any }) do
		result[TableUtil.DeepClone(key)] = TableUtil.DeepClone(child)
	end

	return result :: T
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
	local deltas = _diff(original, updated)

	if deltas == nil or deltas == DELETE then
		return nil
	end

	return deltas
end

--[[
    Recursively applies a delta table to a target table in-place.
]]
function TableUtil.Apply(target: { [any]: any }, delta: Delta): { [any]: any }
	for key, deltaValue in delta do
		if deltaValue == DELETE then
			target[key] = nil
		elseif type(deltaValue) == "table" and type(target[key]) == "table" then
			TableUtil.Apply(target[key], deltaValue)
		elseif type(deltaValue) == "table" then
			target[key] = TableUtil.DeepClone(deltaValue)
		else
			target[key] = deltaValue
		end
	end

	return target
end

function TableUtil.IsDeleted(value: any): boolean
	return value == DELETE
end

return TableUtil
