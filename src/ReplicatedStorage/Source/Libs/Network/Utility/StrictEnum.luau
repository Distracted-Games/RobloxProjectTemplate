--!strict

--[[
	This type function allows a custom StrictEnum table's type to be set using the associated EnumType.

	Example:
	```lua
	local StrictEnum = require(path.to.StrictEnum)

	export type EnumType =
		"This"
		| "That"
		| "TheOther"

	local ExampleEnum: StrictEnum.FromEnum<EnumType> = {
		This = "This",
		That = "That",
		TheOther = "TheOther",
	}
	
	return ExampleEnum
	```

	If the table is missing a value from the EnumType list, an error will be shown.
	in addition, the table itself will now carry the correct key-value types even if missing.
]]

-- selene: allow(undefined_variable)
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

return nil
