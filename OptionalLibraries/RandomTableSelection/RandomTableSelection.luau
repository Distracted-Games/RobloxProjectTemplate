--!strict
--[[
    RandomTableSelection
    @author DistractedGames
    @version 2.1.1

    A utility class that provides random selection from either:

    - An array (uniform probability)
    - A dictionary where { [item] = weight }
    
    Internally, all weighted tables are normalized into:
    - self.itemlist: { item, item, ... }    -- stable ordering
    - self.weightList: { number, number }   -- same index as itemList
    - self.totalWeight: number              -- cumulative sum

    This guarantees deterministic iteration order, fast selection, and simpler
    maintenance.
]]
local RandomTableSelection = {}
RandomTableSelection.__index = RandomTableSelection

export type Item = string

export type WeightedEntry = {
    item: Item,
    weight: number,
}

type ClassType = {
    getRandomItem: (self: RandomTableSelection) -> Item?,
    getRandomItemWithWeight: (self: RandomTableSelection) -> WeightedEntry?,
    containsItem: (self: RandomTableSelection, item: Item) -> boolean,
    getAllItems: (self: RandomTableSelection) -> { Item },
    getAllItemsWithWeights: (self: RandomTableSelection) -> { WeightedEntry },
    getAllItemsWithWeightsSorted: (self: RandomTableSelection) -> { WeightedEntry },
    addItem: (self: RandomTableSelection, item: Item, weight: number?) -> (),
    removeItem: (self: RandomTableSelection, item: Item) -> boolean,
}

type RandomTableSelection = setmetatable<ClassType, typeof(RandomTableSelection)>

type PrivateState = {
    isArray: boolean,
    itemList: { Item },
    weightList: { number }?,
    totalWeight: number?,
	indexMap: { [Item]: number },
}

local _private: { [RandomTableSelection]: PrivateState } = setmetatable({}, { __mode = "k" }) :: any

local function isArray(tbl: { Item } | { [Item]: number }): boolean
    if #tbl > 0 then
        local index = next(tbl :: any)
        return typeof(index) == "number"
    end
    return false
end

local function buildFromArray(items: { Item }): ({ Item }, nil, nil)
    local itemList = table.clone(items)
    local weightList = nil
    return itemList, weightList, nil
end

local function buildFromWeighted(items: { [Item]: number }): ({ Item }, { number }, number)
    local itemList = {}
    local weightList = {}
    local total = 0

    for item, weight in items do
        if typeof(weight) == "number" and weight > 0 then
            table.insert(itemList, item)
            table.insert(weightList, weight)
            total += weight
        end
    end

    return itemList, weightList, total
end

local function weightedSelect(itemList: { Item }, weightList: { number }, total: number): Item?
    local threshold = math.random() * total
    local running = 0

    for i = 1, #weightList do
        running += weightList[i]
        if threshold <= running then
            return itemList[i]
        end
    end

    return itemList[#itemList] -- Extremely rare fallback
end

-- Constructor
function RandomTableSelection.new(items: { Item } | { [Item]: number }): RandomTableSelection
    assert(typeof(items) == "table", `[RandomTableSelection.new]: expected table, got {typeof(items)}`)

    local self = setmetatable({}, RandomTableSelection) :: RandomTableSelection

	_private[self] = {
		isArray = false,
		itemList = {},
		weightList = nil,
		totalWeight = nil,
		indexMap = {},
	}

	local state = _private[self]

    if isArray(items) then
        state.isArray = true
        state.itemList, state.weightList, state.totalWeight = buildFromArray(items :: { Item })
    else
        state.isArray = false
        state.itemList, state.weightList, state.totalWeight = buildFromWeighted(items :: { [Item]: number })
	end

	for i, item in state.itemList do
		state.indexMap[item] = i
	end

    return self
end

-- Core selection
function RandomTableSelection.getRandomItem(self: RandomTableSelection): Item?
	local state = _private[self]

    if #state.itemList == 0 then
        return nil
    end

    if state.isArray then
        local index = math.random(1, #state.itemList)
        return state.itemList[index]
    else
        return weightedSelect(state.itemList, state.weightList :: { number }, state.totalWeight :: number)
    end
end

function RandomTableSelection.getRandomItemWithWeight(self: RandomTableSelection): WeightedEntry?
	local state = _private[self]

    local item = self:getRandomItem()
    if item == nil then
        return nil
    end

    if state.isArray then
        local uniform = 1 / #state.itemList
        return { item = item, weight = uniform }
    else
        local index = state.indexMap[item]
        local weight = if index then (state.weightList :: { number })[index] else 1
        local total = state.totalWeight :: number
        return { item = item, weight = weight / total }
    end
end

-- Queries
function RandomTableSelection.containsItem(self: RandomTableSelection, item: Item): boolean
	local state = _private[self]

    return state.indexMap[item] ~= nil
end

function RandomTableSelection.getAllItems(self: RandomTableSelection): { Item }
	local state = _private[self]

    return table.clone(state.itemList)
end

function RandomTableSelection.getAllItemsWithWeights(self: RandomTableSelection): { WeightedEntry }
	local state = _private[self]

    local result = {}

    if state.isArray then
        local uniform = 1 / #state.itemList
        for _, item in state.itemList :: { Item } do
            table.insert(result, { item = item, weight = uniform })
        end
    else
        local weightList = state.weightList :: { number }
        local total = state.totalWeight :: number

        for i, item in state.itemList :: { Item } do
            table.insert(result, { item = item, weight = weightList[i] / total })
        end
    end

    return result
end

function RandomTableSelection.getAllItemsWithWeightsSorted(self: RandomTableSelection): { WeightedEntry }
    local entries = self:getAllItemsWithWeights()

    table.sort(entries, function(a: WeightedEntry, b: WeightedEntry)
        return a.weight < b.weight
    end)

    return entries
end

-- Mutation
function RandomTableSelection.addItem(self: RandomTableSelection, item: Item, weight: number?)
	local state = _private[self]

	table.insert(state.itemList, item)
	state.indexMap[item] = #state.itemList

	if not state.isArray then
	    local newWeight = weight or 1
		table.insert(state.weightList :: { number }, newWeight)
	    state.totalWeight = (state.totalWeight :: number) + newWeight
	end
end

function RandomTableSelection.removeItem(self: RandomTableSelection, item: Item): boolean
	local state = _private[self]

    local index = state.indexMap[item]
    if not index then
        return false
    end

	local lastIndex = #state.itemList
	local lastItem = state.itemList[lastIndex]

	-- Swapping last item into removed slot to prevent shifting and having to
	-- re-index each item.
	state.itemList[index] = lastItem
	state.indexMap[lastItem] = index

	state.itemList[lastIndex] = nil
    state.indexMap[item] = nil

    if not state.isArray then
		local weightList = state.weightList :: { number }
		
		local removedWeight = weightList[index]
		local lastWeight = weightList[lastIndex]
		
		weightList[index] = lastWeight
		weightList[lastIndex] = nil

		state.totalWeight = (state.totalWeight :: number) - removedWeight
    end

    return true
end

return RandomTableSelection
