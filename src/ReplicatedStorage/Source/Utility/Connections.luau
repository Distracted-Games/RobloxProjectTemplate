--!strict

const Signal = require("../Libs/Signal")

--[[
	Takes a table of connections and then disconnects them all when prompted.
--]]
local Connections = {}
Connections.__index = Connections

type ConnectionOrSignal = RBXScriptConnection | Signal.Connection

type ClassType = {
	_connections: { RBXScriptConnection | Signal.Connection },
	Add: (self: Connections, ...ConnectionOrSignal) -> (),
	Remove: (self: Connections, ...ConnectionOrSignal) -> (),
	RemoveAndDisconnect: (self: Connections, ...ConnectionOrSignal) -> (),
	Disconnect: (self: Connections) -> (),
}

export type Connections = setmetatable<ClassType, typeof(Connections)>

function Connections.new(): Connections
	local self = setmetatable({}, Connections) :: Connections
	self._connections = {}

	return self
end

function Connections.Add(self: Connections, ...: ConnectionOrSignal)
	for _, connection in { ... } do
		assert(not table.find(self._connections, connection), "This connection has already been added")
		table.insert(self._connections, connection)
	end
end

function Connections.Remove(self: Connections, ...: ConnectionOrSignal)
	for _, connection in { ... } do
		local index = table.find(self._connections, connection)
		if index then
			table.remove(self._connections, index)
		end
	end
end

function Connections.RemoveAndDisconnect(self: Connections, ...: ConnectionOrSignal)
	for _, connection in { ... } do
		local index = table.find(self._connections, connection)
		if index then
			(connection :: RBXScriptConnection):Disconnect()
			table.remove(self._connections, index)
		end
	end
end

function Connections.Disconnect(self: Connections)
	for _, connection in self._connections do
		(connection :: RBXScriptConnection):Disconnect()
	end

	self._connections = {}
end

return Connections
