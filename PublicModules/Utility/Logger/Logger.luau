--!strict
--[[
    Logger
    @author DistractedGames
    @version 1.1.0

    A configurable logging utility that can be used across multiple scripts.

    Example usage:
    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local Logger = require(ReplicatedStorage.Source.Utility.Logger)

    local logger = Logger.new({
        Debug = false, -- When true, will print debug messages, when false only warnings/errors
        Prefix = "ScriptName" -- Prefixes [ScriptName] before the logger message
    })

    -- Calling the logger message:
    logger.log(`This is a debug message and wil only print if Debug is true`)
    logger.log(`This is an error and will print a warnign in output no matter what`, true)
    -- The second one is marked as a warning with the `true` value after the message
    ```
]]

export type LoggerConfig = {
    Debug: boolean,
    Prefix: string?, -- Optional prefix for log messages
}

export type Logger = {
    log: (message: string, isWarning: boolean?) -> (),
    setConfig: (newConfig: LoggerConfig) -> (),
    getConfig: () -> LoggerConfig,
}

-- Creates a new logger instance with default configuration.
local function new(initialConfig: LoggerConfig?): Logger
    local config: LoggerConfig = initialConfig or {
        Debug = false,
        Prefix = nil,
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
