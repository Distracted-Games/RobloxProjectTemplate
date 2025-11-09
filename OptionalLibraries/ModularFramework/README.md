# ModuleLoader Framework

This framework provides a clean, unified approach to loading and initializing **ModuleScripts** across both the server and client in a Roblox experience. It is designed to simplify dependency management, reduce boilerplate, and enforce a consistent lifecycle for your modules.

## 🚀 Overview

The framework consists of three core scripts:

| Script                      | Location (Recommended)              | Purpose                          |
|----------------------------|-------------------------------------|----------------------------------|
| `ModuleLoader.luau`        | `ReplicatedStorage/Source`          | Shared loader logic              |
| `ServerModuleLoader.server.luau` | `ServerScriptService/Source`     | Entry point for server modules   |
| `ClientModuleLoader.client.luau` | `StarterPlayerScripts/Source`    | Entry point for client modules   |

> 💡 You may use `/src` instead of `/Source` if preferred — both are supported by the template structure.

## 🧠 Design Philosophy

This system enforces a **two-pass lifecycle** for all modules:

1. **Setup Phase**  
   Each module is required and, if it defines a `Setup()` method, that method is called.  
   This phase is for initialization tasks that do **not depend on other modules**, such as configuration or object registration.

2. **Start Phase**  
   After all modules have completed setup, the loader calls the `Start()` method on each module (if present).  
   This phase is for activating functionality that **may depend on other modules** being initialized.

This implicit dependency handling avoids the need for complex graphs or manual ordering.

## 📦 How to Use

1. Place your modules inside the appropriate service folder:
   - Server-only modules → `ServerScriptService/Source`
   - Client-only modules → `StarterPlayerScripts/Source`
   - Shared modules → `ReplicatedStorage/Source`

2. Each module can optionally define one or both lifecycle methods:

```lua
-- ExampleModule.luau
local ExampleModule = {}

function ExampleModule.Setup()
    print("Setting up ExampleModule")
end

function ExampleModule.Start()
    print("Starting ExampleModule")
end

return ExampleModule
```

3. The loader will automatically require and execute these methods in the correct order.

## 🛠️ Features
- Automatic discovery of all ModuleScripts via `GetDescendants()`
- Retry logic for lifecycle methods with configurable limits and delays
- Debug logging with source and line info for easier tracing
- Environment-aware loading (server vs client)
- Minimal boilerplate — only one server and one client script required

## ⚠️ Notes
- The loader skips any ModuleScript that does not return a table or lacks the target method.
- A loading screen LocalScript in `ReplicatedFirst` is allowed as an exception.
- You can enable verbose logging by setting `config.Debug = true` inside `ModuleLoader`.

## 📁 Folder Placement
To keep your project organized, we recommend placing these files in:

```
ReplicatedStorage/
└── Source/
    └── ModuleLoader.luau

ServerScriptService/
└── Source/
    └── ServerModuleLoader.server.luau

StarterPlayerScripts/
└── Source/
    └── ClientModuleLoader.client.luau
```

---

This framework is designed to be lightweight, extensible, and easy to integrate into any Roblox project. Feel free to adapt it to your needs or contribute improvements!
