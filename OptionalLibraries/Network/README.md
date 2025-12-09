# Network Library

The `Network` library provides a **type-safe, high-level interface for RemoteEvents and RemoteFunctions** in Roblox.
It automatically manages the creation, replication, and invocation of remotes, so you don’t have to manually create folders, assign remotes, or handle client/server differences.
It also enforces argument type safety when connecting signals, reducing runtime errors caused by missing or misnamed remotes.

---

## 🧩 Features

* Automatic creation of RemoteEvent and RemoteFunction folders and instances.
* Type-safe enums for all remote names, reducing typo-prone string usage (and providing auto-complete).
* Automatic client/server distinctions when connecting events or binding functions.
* Safe client/server invocation with `pcall` for network error handling.
* Lightweight and modular, fully compatible with Rojo and VS Code workflows.

---

## 🧩 Dependencies

The library relies on a few simple internal modules:

* `RemoteEventName` — Enum of all RemoteEvent names for use with `Network`.
* `RemoteFunctionName` — Enum of all RemoteFunction names for use with `Network`.
* `RemoteFolderName` — Constants for the RemoteEvents and RemoteFunctions folder names.
* `createRemotesFolders` — Creates the folders for remotes and populates them with instances.
* `waitForAllRemotesAsync` — Waits for all remotes to replicate on the client before usage.
* `getInstance` — Safely retrieves a nested Instance or an instance created at runtime (like our remotes), erroring if the path is invalid.

All dependencies are included within the Network library folder, so no additional installation is required.

---

## 🧩 Getting Started

### Server Setup

```lua
local Network = require(ReplicatedStorage.Network)

-- Initialize remotes on the server
Network.startServer()
```

### Client Setup

```lua
local Network = require(ReplicatedStorage.Network)

-- Wait for server to replicate all remotes
Network.startClientAsync()
```

> ⚠️ Both `startServer()` and `startClientAsync()` must be called before any other Network functions.

> 💡 If using the [Modular Framework](/OptionalLibraries/ModularFramework/), make sure to call these start functions from the single server and local scripts **before** calling the `ModuleLoader` function.

---

## 🧩 Using Network

### Connecting RemoteEvents

```lua
Network.connectEvent(Network.RemoteEvents.ExampleRemote1, function(player, message)
    print(player.Name, message)
end)
```

Automatically handles `OnServerEvent` vs `OnClientEvent`.

---

### Binding RemoteFunctions

```lua
Network.bindFunction(Network.RemoteFunctions.ExampleRemoteFunc1, function(player, x, y)
    return x + y
end)
```

Automatically handles `OnServerInvoke` vs `OnClientInvoke`.

---

### Firing Events

```lua
-- From client to server
Network.fireServer(Network.RemoteEvents.ExampleRemote1, "Hello Server!")

-- From server to one client
Network.fireClient(Network.RemoteEvents.ExampleRemote1, player, "Hello Player!")

-- From server to all clients
Network.fireAllClients(Network.RemoteEvents.ExampleRemote1, "Hello Everyone!")

-- From server to all clients in a table
Network.fireSpecificClients(Network.RemoteEvents.ExampleRemote1, { player1, player2 }, "Hello Everyone in the table!")

-- From server to all clients except any provided in the excluded table
Network.fireAllClientsExcept(Network.RemoteEvents.ExampleRemote1, { excludedPlayer }, "Hello Everyone Else!")

-- From server to all clients within range of a given position
Network.fireClientsInRange(Network.RemoteEvents.ExampleRemote1, Vector3.zero, 100, "Hello Everyone within 100 studs of the world origin!")

-- From server to all clients within range except those provided in the exclusion table
Network.fireClientsInRangeExcept(Network.RemoteEvents.ExampleRemote1, Vector3.zero, 100, { excludedPlayers }, "Hello Everyone else within 100 studs of the world origin!")
```

---

### Invoking Functions

```lua
-- Client calls server function
local success, result = Network.invokeServerAsync(Network.RemoteFunctions.ExampleRemoteFunc1, 2, 3)

-- Server calls client function
local success, result = Network.invokeClientAsync(Network.RemoteFunctions.ExampleRemoteFunc1, player, 2, 3)
```

All invocations are wrapped in `pcall` to prevent hangs from network errors.
