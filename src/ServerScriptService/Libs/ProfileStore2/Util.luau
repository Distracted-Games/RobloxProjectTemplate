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
    Contains generic table utility function used by the ProfileStore system.
]]

local Util = {}

--[[
        Recursively creates a deep copy of a table, ensuring that nested tables
        are also copied instead of referenced.
]]
function Util.DeepCopyTable<T>(original: T): T
    local copy = {} :: any
    for key, value in pairs(original :: any) do
        if typeof(value) == "table" then
            copy[key] = Util.DeepCopyTable(value :: any)
        else
            copy[key] = value
        end
    end
    return copy
end

--[[
    Recursively fills in missing string-keyed fields in a `target` table from a `template table.
    This is used to safely update saved data with new default values.
]]
function Util.ReconcileTable(target: { [string]: any }, template: { [string]: any })
    for key, templateValue in pairs(template) do
        if typeof(key) ~= "string" then
            continue
        end

        local targetValue = target[key]
        if targetValue == nil then
            if typeof(templateValue) == "table" then
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

return table.freeze(Util)
