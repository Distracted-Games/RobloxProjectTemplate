# Logger Utility

A lightweight, configurable logging utility for Roblox Luau projects. This module helps you trace execution, debug issues, and format output consistently across scripts.

## 🚀 Features

- Contextual logging with function name and line number
- Optional prefix for identifying the source script or system
- Configurable verbosity via `Debug` flag
- Supports both debug messages and warnings
- Includes serialization to format tables for printing
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
    Debug = true, -- When true, will print debug messages, when false only warnings/errors
    Prefix = "MyScript" -- Prefixes [MyScript] before the logger message
})
local myTable = {
    name = "Test",
    value = 123,
}

-- This is the default debug message use:
logger.log(`Debug messages will only print if Debug is true`)
-- Output: [MyScript] [debugMessage:15] Debug messages will only print if Debug is true

-- This statement is marked as a warning with the `true` value after the message:
logger.log(`Warning messages will print regardless of Debug value`, true)
-- Output: [MyScript] [warningMessage:20] Warning messages will print regardless of Debug value

--[[ New in version 1.2.0 ]]--
-- Use the logger's serialize function inside an interpolated string to print tables.
logger.log(`Processing data: {logger.serialize(myTable)}`)
-- Output: [MyScript] [processData:35] Processing data: { name = Test, value = 123 }
```

## 🔧 API

### `Logger.new(config: LoggerConfig): Logger`

Creates a new logger instance.
- `Debug: boolean` — If true, enables debug output via `print`
- `Prefix: string?` — Optional prefix for log messages (e.g. script name or system)

### `logger.log(message: string, isWarning: boolean?)`

Logs a message to the output.
- If `isWarning` is true, uses `warn()`
- If false or omitted, uses `print()` only if `Debug` is enabled

### `logger.serialize(value: any): string`

Serializes table values for printing.
- Has a set sub-table depth to prevent infinite looping

### `logger.setConfig(newConfig: LoggerConfig)`

Updates the logger’s configuration.

### `logger.getConfig(): LoggerConfig`

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
