--!strict

-- selene: allow(undefined_variable)
--[[
	Returns an EnumType of the given dictionary's type (`typeof()`).

	Example:
	```lua
	local Currency = {
		Coins = "Coins",
		Gems = "Gems",
	}

	type EnumType = TypeFunctions.EnumOf<typeof(Currency)>
	```
]]
export type function EnumOf(T)
	assert(T:is("table"), "EnumOf<T> requires a table type")

	local result = types.never

	for key in T:properties() do
		result = types.unionof(result, key)
	end

	return result
end

-- selene: allow(undefined_variable)
--[[
	Returns a table type based on a given Enum.

	Example:
	```lua
	type EnumType =
		"Coins"
		| "Gems"

	local Currency: TypeFunctions.FromEnum<EnumType> = {
		Coins = "Coins",
		Gems = "Gems",
	}
	```
]]
export type function FromEnum(T)
	local tbl = types.newtable()

	if T:is("union") then
		for _, component in T:components() do
            assert(
                component:is("singleton") and type(component:value()) == "string",
                "FromEnum<T> expects string literal unions"
            )

			tbl:setreadproperty(component, component)
			tbl:setwriteproperty(component, component)
		end
	elseif T:is("singleton") then
        assert(
            type(T:value()) == "string",
            "FromEnum<T> expects a string literal"
        )

		tbl:setreadproperty(T, T)
		tbl:setwriteproperty(T, T)
	else
		error(`FromEnum<T> expects string literal(s). Got {T.tag}`)
	end
	
	tbl:setindexer(T, T)
	
	return tbl
end

-- selene: allow(undefined_variable)
--[[
	Adds an automatically typed indexer to a given dictionary table's type.
	Satisfies new type solver without having to add `{ [string]: any }`.

	Example:
	```lua
	local Currency = {
		Coins = 100,
		Gems = 50,
	}

	for currency, amount in Currency :: TypeFunctions.AddKeyIndexer<typeof(Currency)> do
		print(`{currency} = {amount}`)
	end
	```
]]
export type function AddKeyIndexer(T)
    local new = types.newtable()

    local keys = types.never
    local values = types.never

    for key, property in T:properties() do
        new:setproperty(key, property.read)

        keys = types.unionof(keys, key)
        values = types.unionof(values, property.read)
    end

    new:setindexer(keys, values)

    return new
end

return nil
