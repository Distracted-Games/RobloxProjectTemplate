--!strict
--[[
    Logger
    @author DistractedGames
    @version 1.3.1

    A configurable logging utility that can be used across multiple scripts.
    Includes a specific logger for including collapsible tables in debug messages.
    Also includes a serializing function for converting tables to readable strings within logs.

    Example usage:
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
    -- Output: [MyScript] [debugMessage:27] Debug messages will only print if Debug is true
    
    -- This statement is marked as a warning with the `true` value after the message:
    logger.log(`Warning messages will print regardless of Debug value`, true)
    -- Output: [MyScript] [warningMessage:31] Warning messages will print regardless of Debug value

    -- Use the `logTable` method to include a regular table printout, similar to the normal `print` function.
    -- The message is optional and prints before the table itself if included.
    logger.logTable(myTable, "This is a table of data:")
    -- Output: [MyScript] [debugMessage:36] This is a table of data: ▸ {...}
    
    -- Use the logger's serialize function inside an interpolated string to print tables.
    logger.log(`Processing data: {logger.serialize(myTable)}`)
    -- Output: [MyScript] [processData:40] Processing data: { name = Test, value = 123 }
    ```
]]

export type LoggerConfig = {
    Debug: boolean,
    Prefix: string?, -- Optional prefix for log messages
}

export type Logger = {
    log: (message: string, isWarning: boolean?) -> (),
    logTable: (table: any, message: string?) -> (),
    serialize: (value: any) -> string,
    setConfig: (newConfig: LoggerConfig) -> (),
    getConfig: () -> LoggerConfig,
}

-- Maximum depth for table serialization to prevent infinite loops.
local MAX_SERIALIZE_DEPTH = 3

-- Internal function to serialize table values for printing format.
local function serializeValue(value: any, depth: number): string
	depth = depth or 1
	if depth > MAX_SERIALIZE_DEPTH then
		return "{...}" -- Prevents infinite recursion
	end

	local valueType = typeof(value)

	if valueType == "table" then
		local parts = {}
		-- Simple check for array-like vs dictionary-like tables
		local isArray = #value > 0 and not next(value, #value)

		for key, val in pairs(value) do
			if isArray then
				table.insert(parts, serializeValue(val, depth + 1))
			else
				table.insert(parts, `{tostring(key)} = {serializeValue(val, depth + 1)}`)
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

-- Creates a new logger instance with default configuration.
local function new(initialConfig: LoggerConfig?): Logger
    local config: LoggerConfig = initialConfig or {
        Debug = false,
        Prefix = nil :: string?,
    }

    -- Used in lew of a metatable to keep things simple.
    local logger = {}

    --[[
        Logs a formatted message to the output.
        Uses `warn` for warnings and `print` for debug messages.
        The log includes the calling function's name and line for easier debugging.
        @param message The core message to log.
        @param isWarning If true, formats the message as a warning.
    ]]
    function logger.log(message: string, isWarning: boolean?)
        local prefix = if config.Prefix then `[{config.Prefix}] ` else ""
        local source, line, funcName = debug.info(2, "sln")
        local formattedSource = `{string.match(source, "@(.*)")}`
        local logHeader = `{prefix} [{funcName or formattedSource}:{line}]`

        if isWarning then
            warn(`{logHeader} {message}`)
        elseif config.Debug then
            print(`{logHeader} {message}`)
        end
    end

    --[[
        Logs a formatted table and optional message to the output.
        The log includes the calling function's name and line for easier debugging.
        @param table The table to be printed.
        @param message An optional message to prepend to the table output.
    ]]
    function logger.logTable(table: any, message: string?)
		if not config.Debug then
            return
        end

        local prefix = if config.Prefix then `[{config.Prefix}] ` else ""
        local source, line, funcName = debug.info(2, "sln")
        local formattedSource = `{string.match(source, "@(.*)")}`
        local logHeader = `{prefix} [{funcName or formattedSource}:{line}]`

        if message then
            print(logHeader, message, table)
        else
            print(logHeader, table)
        end
    end

    -- Used to serialize table values for printing.
    function logger.serialize(value: any): string
		return serializeValue(value, 1)
	end

    -- Used to update Logger configuration anytime after creation.
    function logger.setConfig(newConfig: LoggerConfig)
        config.Debug = newConfig.Debug
        config.Prefix = newConfig.Prefix
    end

    -- Used to get the current Logger configuration.
    function logger.getConfig()
        return table.clone(config)
    end

    return logger
end

return {
    new = new
}
