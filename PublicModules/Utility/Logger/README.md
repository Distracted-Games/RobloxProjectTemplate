# Logger Utility

A lightweight, configurable logging utility for Roblox Luau projects. This module helps you trace execution, debug issues, and format output consistently across scripts.

## 🚀 Features

- Contextual logging with function name and line number
- Optional prefix for identifying the source script or system
- Configurable verbosity via `Debug` flag
- Supports both debug messages and warnings
- Simple API with no metatables or dependencies

## 📦 Installation

Place `Logger.luau` in a shared location such as:

```
ReplicatedStorage/
└── Source/
    └── Utility/
        └── Logger.luau
```


## 🧠 Usage

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Source.Utility.Logger)

local logger = Logger.new({
    Debug = true, -- Enables debug messages
    Prefix = "CombatSystem" -- Optional prefix for log output
})

-- Debug message (only prints if Debug is true)
logger.log("Initializing combat manager")

-- Warning message (always prints)
logger.log("Failed to load weapon config", true)
```

## 🔧 API

`Logger.new(config: LoggerConfig): Logger`

Creates a new logger instance.
- `Debug: boolean` — If true, enables debug output via `print`
- `Prefix: string?` — Optional prefix for log messages (e.g. script name or system)

`logger.log(message: string, isWarning: boolean?)`

Logs a message to the output.
- If `isWarning` is true, uses `warn()`
- If false or omitted, uses `print()` only if `Debug` is enabled

`logger.setConfig(newConfig: LoggerConfig)`

Updates the logger’s configuration.

`logger.getConfig(): LoggerConfig`

Returns a copy of the current configuration.

## 🧪 Output Format

Each log includes:
- Prefix (if set)
- Calling function name or source file
- Line number
- Message content

Example:
```
[CombatSystem] [initCombat:42] Failed to initialize weapon stats
```

## ✅ Best Practices
- Use one logger per system or script for clarity
- Prefix loggers with meaningful names (e.g. `"Inventory"`, `"Matchmaking"`)
- Keep `Debug = false` in production environments to reduce noise

---

This utility is designed to be dropped into any Roblox project and used immediately. Feel free to adapt it to your needs or contribute improvements!
