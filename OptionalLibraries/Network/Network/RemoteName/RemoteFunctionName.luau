--[[
    NOTE: You shouldn't normally use a RemoteFunction from server -> client as it
    can create a memory leak if the client never responds. This is technically
    handled by the Network module, but consider instead using a RemoteEvent that
    sends the request to the client to respond, implement some logic on the
    server to timeout the request, and have the client use the same RemoteEvent
    to send its response back to the server. The server should almost never need
    to ask the client for information anyway.

	Specifies the names of all RemoteFunctions. One RemoteFunction object gets
    generated for each name	in this list, and these names are used as enums when
    interacting with the Network moduel to tell it which remote function to fire
    without typing out typo-prone string literals.
]]

export type EnumType = ""

local RemoteFunctionName: { [EnumType]: EnumType } = {}

return RemoteFunctionName
