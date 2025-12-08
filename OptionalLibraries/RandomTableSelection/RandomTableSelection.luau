--!strict
--[[
    RandomTableSelection
    @author DistractedGames
    @version 2.0.0

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

export type Item = string | Instance

export type WeightedEntry = {
    item: Item,
    weight: number,
}

type ClassType = {
    isArray: boolean,
    itemList: { Item },
    weightList: { number }?,
    totalWeight: number?,

    -- Methods
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

local RNG = Random.new() -- Never reused. Good for perfroamnce and correctness.

local function isArray(tbl: { Item } | { [Item]: number }): boolean
    if #tbl > 0 then
        local index = next(tbl)
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
    local threshold = RNG:NextNumber() * total
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

    if isArray(items) then
        self.isArray = true
        self.itemList, self.weightList, self.totalWeight = buildFromArray(items :: { Item })
    else
        self.isArray = false
        self.itemList, self.weightList, self.totalWeight = buildFromWeighted(items :: { [Item]: number })
    end

    return self
end

-- Core selection
function RandomTableSelection.getRandomItem(self: RandomTableSelection): Item?
    if #self.itemList == 0 then
        return nil
    end

    if self.isArray then
        local index = RNG:NextInteger(1, #self.itemList)
        return self.itemList[index]
    else
        return weightedSelect(self.itemList, self.weightList :: { number }, self.totalWeight :: number)
    end
end

function RandomTableSelection.getRandomItemWithWeight(self: RandomTableSelection): WeightedEntry?
    local item = self:getRandomItem()
    if item == nil then
        return nil
    end

    if self.isArray then
        local uniform = 1 / #self.itemList
        return { item = item, weight = uniform }
    else
        local index = table.find(self.itemList, item)
        local weight = if index then (self.weightList :: { number })[index] else 1
        local total = self.totalWeight :: number
        return { item = item, weight = weight / total }
    end
end

-- Queries
function RandomTableSelection.containsItem(self: RandomTableSelection, item: Item): boolean
    return table.find(self.itemList, item) ~= nil
end

function RandomTableSelection.getAllItems(self: RandomTableSelection): { Item }
    return table.clone(self.itemList)
end

function RandomTableSelection.getAllItemsWithWeights(self: RandomTableSelection): { WeightedEntry }
    local result = {}

    if self.isArray then
        local uniform = 1 / #self.itemList
        for _, item in self.itemList :: { Item } do
            table.insert(result, { item = item, weight = uniform })
        end
    else
        local weightList = self.weightList :: { number }
        local total = self.totalWeight :: number

        for i, item in self.itemList :: { Item } do
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
    if self.isArray then
        table.insert(self.itemList, item)
        return
    end

    local newWeight = weight or 1
    table.insert(self.itemList, item)
    table.insert(self.weightList :: { number }, newWeight)
    self.totalWeight = (self.totalWeight :: number) + newWeight
end

function RandomTableSelection.removeItem(self: RandomTableSelection, item: Item): boolean
    local index = table.find(self.itemList, item)
    if not index then
        return false
    end

    if self.isArray then
        table.remove(self.itemList, index)
        return true
    end

    local weightList = self.weightList :: { number }
    local removedWeight = weightList[index]

    table.remove(self.itemList, index)
    table.remove(weightList, index)
    self.totalWeight = (self.totalWeight :: number) - removedWeight

    return true
end

return RandomTableSelection
