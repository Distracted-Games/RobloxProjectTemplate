--!strict

--[[
    Logger
    @author DistractedGames
    @version 2.0.0

    A configurable logging utility that can be used across multiple scripts.
    Includes a specific logger for including collapsible tables in debug messages.
    Also includes a serializing function for converting tables to readable strings within logs.

    Example usage:
    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local Logger = require(ReplicatedStorage.Source.Utility.Logger)

    local logger = Logger.new({
        Debug = true, -- When true, will print debug messages, when false only warnings/errors
        Prefix = script.Name -- Prefixes [MyScript] (the calling script's name) before the logger message
    })
    local myTable = {
        name = "Test",
        value = 123,
    }

    -- This is the default debug message use:
    logger:debug(`Debug messages will only print if Debug is true`)
    -- Output: [MyScript] [debugMessage:27] Debug messages will only print if Debug is true
    
    -- This statement is marked as a warning:
    logger:warn(`Warning messages will print regardless of Debug value`)
    -- Output: [MyScript] [warningMessage:31] Warning messages will print regardless of Debug value

    -- Use the `logTable` method to include a regular table printout, similar to the normal `print` function.
    -- The message is optional and prints before the table itself if included.
    logger:logTable(myTable, "This is a table of data:")
    -- Output: [MyScript] [debugMessage:36] This is a table of data: ▸ {...}
    
    -- Use the logger's serialize function inside an interpolated string to print tables.
    logger:debug(`Processing data: {logger:serialize(myTable)}`)
    -- Output: [MyScript] [processData:40] Processing data: { name = Test, value = 123 }
    ```
]]

local Logger = {}
Logger.__index = Logger

export type LoggerConfig = {
    Debug: boolean,
    Prefix: string?,
}

export type LoggerData = {
    Debug: boolean,
    Prefix: string?,
    debug: (self: Logger, message: string) -> (),
    warn: (self: Logger, message: string) -> (),
    error: (self: Logger, message: string) -> (),
    logTable: (self: Logger, tbl: any, message: string?) -> (),
    serialize: (self: Logger, value: any, maxDepth: number?) -> string,
}

export type Logger = setmetatable<LoggerData, typeof(Logger)>

-- Maximum depth for table serialization to prevent infinite loops by default.
const DEFAULT_MAX_SERIALIZE_DEPTH = 3

-- Internal function to serialize table values for printing format.
local function serializeValue(value: any, depth: number, maxDepth: number): string
    if depth > maxDepth then
        return "{...}" -- Prevents infinite recursion
    end

    local valueType = typeof(value)

    if valueType == "table" then
        local parts = {}
        -- Simple check for array-like vs dictionary-like tables
        local isArray = #value > 0 and not next(value, #value)

        for key, val in value do
            if isArray then
                table.insert(parts, serializeValue(val, depth + 1, maxDepth))
            else
                table.insert(parts, `{tostring(key)} = {serializeValue(val, depth + 1, maxDepth)}`)
            end
        end
        if isArray then
            return "[" .. table.concat(parts, ", ") .. "]"
        else
            return "{ " .. table.concat(parts, ", ") .. " }"
        end
    elseif valueType == "string" then
        return value -- Return raw string for clean logs
    else
        return tostring(value)
    end
end

--[[
    Creates a new logger instance with default configuration.
]]
function Logger.new(initialConfig: LoggerConfig?): Logger
    local self = setmetatable({}, Logger) :: Logger
    
    local config = initialConfig or {
        Debug = false,
        Prefix = nil :: string?,
    }

    self.Debug = config.Debug
    self.Prefix = config.Prefix

    return self
end

--[[
    Internal helper to format the log header.
]]
local function formatLogHeader(prefix: string?, source: string?, line: number?, funcName: string?): string
    local prefixStr = if prefix then `[{prefix}] ` else ""
    
    local displayContext = "Unknown"
    if funcName and funcName ~= "" then
        displayContext = funcName
    elseif source then
        displayContext = string.match(source, "([^%./\\]+)$") or source
    end
    
    return `{prefixStr}[{displayContext}:{line or -1}]`
end

--[[
    Logs a debug message to the output if Debug is true.
    The log includes the calling function's name and line for easier debugging.
    @param message The core message to log.
]]
function Logger.debug(self: Logger, message: string)
    if not self.Debug then
        return
    end

    local source, line, funcName = debug.info(2, "sln")
    local logHeader = formatLogHeader(self.Prefix, source, line, funcName)
    print(`{logHeader} {message}`)
end

--[[
    Logs a warning message to the output, regardless of the Debug setting.
    @param message The warning message to log.
]]
function Logger.warn(self: Logger, message: string)
    local source, line, funcName = debug.info(2, "sln")
    local logHeader = formatLogHeader(self.Prefix, source, line, funcName)
    warn(`{logHeader} {message}`)
end

--[[
    Logs an error message to the output, regardless of the Debug setting.
    @param message The error message to log.
]]
function Logger.error(self: Logger, message: string)
    local source, line, funcName = debug.info(2, "sln")
    local logHeader = formatLogHeader(self.Prefix, source, line, funcName)
    -- Level 2 throws the error pointing to the script that called `Logger:error`
    error(`{logHeader} {message}`, 2) 
end

--[[
    Logs a formatted table and optional message to the output.
    The log includes the calling function's name and line for easier debugging.
    @param tbl The table to be printed.
    @param message An optional message to prepend to the table output.
]]
function Logger.logTable(self: Logger, tbl: any, message: string?)
    if not self.Debug then
        return
    end

    local source, line, funcName = debug.info(2, "sln")
    local logHeader = formatLogHeader(self.Prefix, source, line, funcName)

    if message then
        print(logHeader, message, tbl)
    else
        print(logHeader, tbl)
    end
end

--[[
    Used to serialize table values for printing.
    @param value The value to serialize.
    @param maxDepth Optional max depth to prevent infinite recursion (defaults to 3).
]]
function Logger.serialize(_self: Logger, value: any, maxDepth: number?): string
    local depthLimit = maxDepth or DEFAULT_MAX_SERIALIZE_DEPTH
    return serializeValue(value, 1, depthLimit)
end

return Logger
