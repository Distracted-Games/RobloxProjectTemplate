--[[
	Specifies the names of all RemoteEvents. One RemoteEvent object gets
    generated for each name	in this list, and these names are used as enums when
    interacting with the Network module to tell it which remote event to fire
    without typing out typo-prone string literals.
]]

export type EnumType = "ExampleRemote1"
    | "ExampleRemote2"

local RemoteEventName: { [EnumType]: EnumType } = {
    ExampleRemote1 = "ExampleRemote1" :: "ExampleRemote1",
    ExampleRemote2 = "ExampleRemote2" :: "ExampleRemote2",
}

return RemoteEventName
